"""Adaptive batcher: BentoML's CorkDispatcher for threads.

`Batcher[In, Out].submit(item)` blocks the calling worker thread until its batch has run and returns that item's
output. Batches form by `bento.dispatch.Cork` (the same decisions BentoML makes, replayed in tests/batch_replay.mojo):
one controller thread polls it every millisecond, one thread per batch runs `run_batch`, `max_inflight` batches at a time (1: as BentoML).

Errors: `run_batch` raising fails every item of that batch with its message; an item that waits longer than
`max_latency_ms` fails with "batcher: overloaded" (BentoML answers those with its fallback, an HTTP 503).
"""
from std.ffi import external_call
from std.memory import alloc
from bento.sync import Mutex, Cond
from std.time import perf_counter_ns
from bento.dispatch import Cork, IDLE, CANCEL, SLEEP, DISPATCH

comptime QUEUED = 0
comptime OK = 1
comptime FAILED = 2
comptime DROPPED = 3

comptime OVERLOADED = "batcher: overloaded (waited longer than max_latency)"


struct Job[In: Copyable & Deinitable, Out: Copyable & Deinitable](Movable):
    var input: Self.In
    var output: Optional[Self.Out]
    var err: String
    var state: Int

    def __init__(out self, var input: Self.In):
        self.input = input^
        self.output = None
        self.err = String()
        self.state = QUEUED


struct Core[In: Copyable & Deinitable, Out: Copyable & Deinitable](Movable):
    """Everything the threads share; heap-allocated so its address is stable."""

    var cork: Cork
    var run_batch: def(List[Self.In]) thin raises -> List[Self.Out]
    var jobs: Dict[Int, Int]  # job id -> address of its Job
    var next_id: Int
    var mu: Mutex
    var work: Cond  # the controller waits for jobs here
    var done: Cond  # submitters and close() wait for results here
    var started: Bool
    var stop: Bool
    var inflight: Int  # batch threads still running
    var ctl: UInt64
    var t0: Int
    var batches: Int
    var items: Int

    def __init__(out self, var cork: Cork, run_batch: def(List[Self.In]) thin raises -> List[Self.Out]):
        self.cork = cork^
        self.run_batch = run_batch
        self.jobs = Dict[Int, Int]()
        self.next_id = 0
        self.mu = Mutex()
        self.work = Cond()
        self.done = Cond()
        self.started = False
        self.stop = False
        self.inflight = 0
        self.ctl = 0
        self.t0 = perf_counter_ns()
        self.batches = 0
        self.items = 0

    def now(self) -> Float64:
        return Float64(perf_counter_ns() - self.t0) / 1e9


struct Batch(Movable):
    """What one batch thread runs: its job ids and when it started."""

    var core: Int  # address of the Core
    var ids: List[Int]
    var start: Float64
    var first: Float64  # when its oldest item was enqueued
    var training: Bool

    def __init__(out self, core: Int, var ids: List[Int], start: Float64, first: Float64, training: Bool):
        self.core = core
        self.ids = ids^
        self.start = start
        self.first = first
        self.training = training


def _batch_main[In: Copyable & Deinitable, Out: Copyable & Deinitable](arg: Int) abi("C") -> Int:
    var b = MutPointer[Batch, MutUntrackedOrigin](unsafe_from_address=arg)
    var c = MutPointer[Core[In, Out], MutUntrackedOrigin](unsafe_from_address=b[].core)
    var inputs = List[In]()
    c[].mu.lock()
    for id in b[].ids:
        var j = MutPointer[Job[In, Out], MutUntrackedOrigin](unsafe_from_address=c[].jobs.get(id, 0))
        inputs.append(j[].input.copy())
    c[].mu.unlock()
    var outs = List[Out]()
    var err = String()
    var failed = False
    try:
        outs = c[].run_batch(inputs)
        if len(outs) != len(inputs):
            raise Error("batcher: run_batch returned " + String(len(outs)) + " outputs for " + String(len(inputs)) + " inputs")
    except e:
        failed = True
        err = String(e)
    c[].mu.lock()
    for k in range(len(b[].ids)):
        var j = MutPointer[Job[In, Out], MutUntrackedOrigin](unsafe_from_address=c[].jobs.get(b[].ids[k], 0))
        if failed:
            j[].err = err
            j[].state = FAILED
        else:
            j[].output = outs[k].copy()
            j[].state = OK
    if failed:
        c[].cork.failed()
    else:
        c[].cork.done(c[].now(), b[].start, len(b[].ids), b[].first, b[].training)
    c[].batches += 1
    c[].items += len(b[].ids)
    c[].inflight -= 1
    c[].done.broadcast()
    c[].mu.unlock()
    b.unsafe_deinit_pointee()
    b.unsafe_free()
    return 0


def _controller_main[In: Copyable & Deinitable, Out: Copyable & Deinitable](arg: Int) abi("C") -> Int:
    var c = MutPointer[Core[In, Out], MutUntrackedOrigin](unsafe_from_address=arg)
    c[].mu.lock()
    while not c[].stop:
        var now = c[].now()
        var k = c[].cork.step(now)
        if k == IDLE:
            c[].work.wait(c[].mu)
        elif k == CANCEL:
            var j = MutPointer[Job[In, Out], MutUntrackedOrigin](unsafe_from_address=c[].jobs.get(c[].cork.out_id, 0))
            j[].state = DROPPED
            c[].done.broadcast()
        elif k == SLEEP:
            c[].mu.unlock()
            _ = external_call["usleep", Int32](Int32(1000))
            c[].mu.lock()
        else:
            var b = alloc[Batch](1)
            b.unsafe_write(Batch(arg, c[].cork.out_ids.copy(), now, c[].cork.out_first, c[].cork.out_training))
            var tid = alloc[UInt64](1)
            var rc = external_call["pthread_create", Int32](tid, Int(0), _batch_main[In, Out], Int(b))
            if rc != 0:
                # no thread for this batch: fail its jobs instead of hanging their submitters
                for id in b[].ids:
                    var j = MutPointer[Job[In, Out], MutUntrackedOrigin](unsafe_from_address=c[].jobs.get(id, 0))
                    j[].err = "batcher: pthread_create rc " + String(rc)
                    j[].state = FAILED
                c[].cork.failed()
                c[].done.broadcast()
                b.unsafe_deinit_pointee()
                b.unsafe_free()
            else:
                _ = external_call["pthread_detach", Int32](tid[0])
                c[].inflight += 1
            tid.unsafe_free()
    c[].mu.unlock()
    return 0


struct Batcher[In: Copyable & Deinitable, Out: Copyable & Deinitable](Movable):
    """Share one Batcher between the worker threads; each calls `submit`."""

    var core: MutPointer[Core[Self.In, Self.Out], MutUntrackedOrigin]

    def __init__(
        out self,
        run_batch: def(List[Self.In]) thin raises -> List[Self.Out],
        max_latency_ms: Int = 10000,
        max_batch_size: Int = 32,
        max_inflight: Int = 1,
    ):
        self.core = alloc[Core[Self.In, Self.Out]](1)
        self.core.unsafe_write(Core[Self.In, Self.Out](Cork(max_latency_ms, max_batch_size, 0.0, max_inflight), run_batch))

    def submit(self, var item: Self.In) raises -> Self.Out:
        """Queue `item`, block until its batch ran, return its output."""
        var c = self.core
        c[].mu.lock()
        if c[].stop:
            c[].mu.unlock()
            raise Error("batcher: closed")
        if not c[].started:
            var tid = alloc[UInt64](1)
            var rc = external_call["pthread_create", Int32](tid, Int(0), _controller_main[Self.In, Self.Out], Int(c))
            if rc != 0:
                tid.unsafe_free()
                c[].mu.unlock()
                raise Error("batcher: pthread_create rc " + String(rc))
            c[].ctl = tid[0]
            tid.unsafe_free()
            c[].started = True
        var id = c[].next_id
        c[].next_id += 1
        var j = alloc[Job[Self.In, Self.Out]](1)
        j.unsafe_write(Job[Self.In, Self.Out](item^))
        c[].jobs[id] = Int(j)
        c[].cork.enqueue(id, c[].now())
        c[].work.broadcast()
        while j[].state == QUEUED:
            c[].done.wait(c[].mu)
        _ = c[].jobs.pop(id)
        c[].mu.unlock()
        var state = j[].state
        var err = j[].err
        var out = j[].output.take() if state == OK else Optional[Self.Out](None)
        j.unsafe_deinit_pointee()
        j.unsafe_free()
        if state == DROPPED:
            raise Error(OVERLOADED)
        if state == FAILED:
            raise Error(err)
        return out.take()

    def stats(self) -> Tuple[Int, Int]:
        """(batches run, items run) so far."""
        var c = self.core
        c[].mu.lock()
        var r = (c[].batches, c[].items)
        c[].mu.unlock()
        return r

    def close(self):
        """Stop the controller, wait for the running batch, fail every item still queued with "batcher: closed"."""
        var c = self.core
        c[].mu.lock()
        if c[].stop:
            c[].mu.unlock()
            return
        c[].stop = True
        c[].work.broadcast()
        var started = c[].started
        var ctl = c[].ctl
        c[].mu.unlock()
        if started:
            _ = external_call["pthread_join", Int32](ctl, Int(0))
        c[].mu.lock()
        while c[].inflight > 0:
            c[].done.wait(c[].mu)
        for e in c[].jobs.items():
            var j = MutPointer[Job[Self.In, Self.Out], MutUntrackedOrigin](unsafe_from_address=e.value)
            if j[].state == QUEUED:
                j[].err = "batcher: closed"
                j[].state = FAILED
        c[].done.broadcast()
        c[].mu.unlock()
