"""Cork dispatcher decisions, ported from BentoML `_internal/marshal/dispatcher.py` (Apache-2.0, see NOTICE).

A pure state machine with an injected clock: no threads, no sleeping. The caller feeds it arrivals and batch
completions and asks `step(now)` what the controller does next. `bento.batch.Batcher` drives it from real threads
and `tests/batch_replay.mojo` from a virtual clock, so both run the same decisions.
"""

comptime TICKET = 0.001  # CorkDispatcher.TICKET_INTERVAL: the controller polls this often while it waits
comptime DECAY = 0.95
comptime N_KEPT = 50
comptime N_SKIPPED = 2
comptime REFRESH_RATE = 1.0 / 5.0  # one parameter refresh per 5 s (the TokenBucket rate)

comptime IDLE = 0  # queue empty: sleep until an arrival
comptime CANCEL = 1  # the head job waited too long: `out_id` is dropped (BentoML returns the fallback)
comptime SLEEP = 2  # poll again after TICKET
comptime DISPATCH = 3  # run the batch `out_ids`

# (requests required before cancelling, requests to train on, training batch size) of the four warm-up phases
comptime PHASES = 4


def _required(p: Int) -> Int:
    return N_SKIPPED if p == 0 else (6 if p == 1 else (5 if p == 2 else 3))


def _train(p: Int) -> Int:
    return N_SKIPPED + 6 if p == 0 else 1


def _tbatch(p: Int) -> Int:
    return 1 if p < 2 else p


struct Optimizer(Movable):
    """Fits duration = o_a * n + o_b over the last 50 batches; `wait` is their mean queue wait."""

    var o_a: Float64
    var o_b: Float64
    var wait: Float64
    var n: List[Int]
    var dur: List[Float64]
    var wt: List[Float64]
    var counter: Int
    var tb_amount: Float64
    var tb_last: Float64

    def __init__(out self, max_latency: Float64, now: Float64):
        self.o_a = min(2.0, max_latency * 2.0 / 30.0)
        self.o_b = min(1.0, max_latency * 1.0 / 30.0)
        self.wait = 0.0
        self.n = List[Int]()
        self.dur = List[Float64]()
        self.wt = List[Float64]()
        self.counter = 0
        self.tb_amount = 2.0
        self.tb_last = now

    def log_outbound(mut self, now: Float64, n: Int, wait: Float64, duration: Float64) -> Bool:
        """True when the refresh token bucket let this batch trigger a parameter refresh."""
        if self.counter <= N_SKIPPED + 4:
            self.counter += 1
            if self.counter <= N_SKIPPED:
                return False
        self.n.append(n)
        self.dur.append(duration)
        self.wt.append(wait)
        if len(self.n) > N_KEPT:
            _ = self.n.pop(0)
            _ = self.dur.pop(0)
            _ = self.wt.pop(0)
        # TokenBucket.consume(1, 1/5, 1)
        var cur = min((now - self.tb_last) * REFRESH_RATE + self.tb_amount, 1.0)
        if 1.0 > cur:
            return False
        self.tb_amount = cur - 1.0
        self.tb_last = now
        return True

    def refresh(mut self):
        """numpy.linalg.lstsq of [n, 1] against the durations, clamped as the Python does."""
        var k = len(self.n)
        if k == 0:
            return
        var sn = 0
        var snn = 0
        var sy = 0.0
        for i in range(k):
            sn += self.n[i]
            snn += self.n[i] * self.n[i]
            sy += self.dur[i]
        var ybar = sy / Float64(k)
        var a: Float64
        var b: Float64
        if k * snn == sn * sn:
            # every n equal: rank 1, lstsq returns the minimum-norm solution along (n, 1)
            var n0 = Float64(self.n[0])
            a = n0 * ybar / (n0 * n0 + 1.0)
            b = ybar / (n0 * n0 + 1.0)
        else:
            var nbar = Float64(sn) / Float64(k)
            var sxy = 0.0
            var sxx = 0.0
            for i in range(k):
                var dx = Float64(self.n[i]) - nbar
                sxy += dx * (self.dur[i] - ybar)
                sxx += dx * dx
            a = sxy / sxx
            b = ybar - a * nbar
        var w = 0.0
        for i in range(k):
            w += self.wt[i]
        self.o_a = max(0.000001, a)
        self.o_b = max(0.0, b)
        self.wait = max(0.0, w * 1.0 / Float64(k))


struct Cork(Movable, Sized):
    var max_latency: Float64
    var max_batch: Int
    var opt: Optimizer
    var ids: List[Int]  # queue, head at `head`
    var enq: List[Float64]
    var head: Int
    var inflight: Int  # batches running
    var max_inflight: Int  # the semaphore: BentoML runs one batch at a time
    var phase: Int
    var req_count: Int
    var phase_wait: Float64
    # outputs of the last step()
    var out_id: Int
    var out_ids: List[Int]
    var out_first: Float64
    var out_training: Bool
    # (time, o_a, o_b, wait) after every refresh, for the replay gate
    var params: List[Float64]

    def __init__(out self, max_latency_ms: Int, max_batch: Int, now: Float64, max_inflight: Int = 1):
        self.max_latency = Float64(max_latency_ms) / 1000.0
        self.max_batch = max_batch
        self.opt = Optimizer(self.max_latency, now)
        self.ids = List[Int]()
        self.enq = List[Float64]()
        self.head = 0
        self.inflight = 0
        self.max_inflight = max_inflight
        self.phase = 0
        self.req_count = 0
        self.phase_wait = 0.0
        self.out_id = -1
        self.out_ids = List[Int]()
        self.out_first = 0.0
        self.out_training = False
        self.params = List[Float64]()
        self._begin_phase()

    def __len__(self) -> Int:
        return len(self.ids) - self.head

    def enqueue(mut self, id: Int, now: Float64):
        self.ids.append(id)
        self.enq.append(now)

    def _begin_phase(mut self):
        if self.phase >= PHASES:
            return
        var tb = min(self.max_batch, _tbatch(self.phase))
        self.phase_wait = 0.0
        if tb > 1:
            self.phase_wait = min(self.max_latency * 0.95, Float64(tb * 2 + 1) * self.opt.o_a + self.opt.o_b)

    def _refresh(mut self, now: Float64):
        self.opt.refresh()
        self.params.append(now)
        self.params.append(self.opt.o_a)
        self.params.append(self.opt.o_b)
        self.params.append(self.opt.wait)

    def _drop_head(mut self):
        self.out_id = self.ids[self.head]
        self.head += 1

    def _take(mut self, training: Bool):
        self.out_ids = List[Int]()
        self.out_first = self.enq[self.head]
        self.out_training = training
        while len(self) > 0 and len(self.out_ids) < self.max_batch:
            self.out_ids.append(self.ids[self.head])
            self.head += 1
        self.inflight += 1
        if self.head > 1024 and self.head * 2 > len(self.ids):  # compact the consumed prefix
            var ids = List[Int]()
            var enq = List[Float64]()
            for i in range(self.head, len(self.ids)):
                ids.append(self.ids[i])
                enq.append(self.enq[i])
            self.ids = ids^
            self.enq = enq^
            self.head = 0

    def step(mut self, now: Float64) -> Int:
        """One iteration of the controller loop (`controller` / `train_optimizer`) at time `now`."""
        var n = len(self)
        if n == 0:
            return IDLE
        var w0 = now - self.enq[self.head]
        if self.phase < PHASES:
            var tb = min(self.max_batch, _tbatch(self.phase))
            if n > _required(self.phase) - self.req_count and w0 >= self.max_latency:
                self._drop_head()
                return CANCEL
            if tb > 1:
                if n < tb and (Float64(tb) * self.opt.o_a + self.opt.o_b) + w0 <= self.phase_wait:
                    return SLEEP
            if self.inflight >= self.max_inflight:
                return SLEEP
            self.req_count += 1
            self._take(True)
            if self.req_count >= _train(self.phase):
                if self.phase >= 1:
                    self._refresh(now)
                self.phase += 1
                self.req_count = 0
                self._begin_phase()
            return DISPATCH
        var wn = now - self.enq[len(self.enq) - 1]
        var a = self.opt.o_a
        var b = self.opt.o_b
        var latency_0 = w0 + a * Float64(n) + b
        if n > 1 and latency_0 >= self.max_latency:
            self._drop_head()
            return CANCEL
        if self.inflight >= self.max_inflight:
            if n == 1 and w0 >= self.max_latency:
                self._drop_head()
                return CANCEL
            return SLEEP
        if n < self.max_batch and Float64(n) * (wn + TICKET + a) <= self.opt.wait * DECAY:
            return SLEEP
        self._take(False)
        return DISPATCH

    def done(mut self, now: Float64, start: Float64, n: Int, first: Float64, training: Bool):
        """A batch of `n` items (oldest enqueued at `first`), started at `start`, returned."""
        var wait = 0.0
        if not training:
            wait = start - first
        if self.opt.log_outbound(now, n, wait, now - start):
            self._refresh(now)
        self.inflight -= 1

    def failed(mut self):
        self.inflight -= 1
