"""Replay an arrival trace through BentoML's real CorkDispatcher on a virtual clock.

usage: batch_oracle.py TRACE   (run with the oracle venv: .venv/bin/python -I)

TRACE lines: `max_latency_ms N`, `max_batch N`, `dur_a_ns N`, `dur_b_ns N`, `jitter_ns N N ...`, `arrive NS` (all integers).
A batch of n takes a*n + b + jitter[call index mod len] seconds, each term its ns value / 1e9. Time is virtual: asyncio's loop jumps to the
next scheduled handle, and time.time is patched to that clock, so dispatcher.py runs unmodified.
Output sections: `batch T N WAIT ID...`, `res ID T ok|fb`, `param T A B W` (after every optimizer refresh).
"""
import asyncio
import sys
import time

from bentoml._internal.marshal import dispatcher as D

TIE = 1e-8  # two handles this close would run in an order the Mojo replay cannot know


class Sel:
    def __init__(self, loop, real):
        self.loop, self.real = loop, real

    def select(self, timeout):
        lp = self.loop
        if timeout is None:
            raise RuntimeError("virtual loop idle with nothing scheduled")
        if timeout > 0:
            ws = sorted(h._when for h in lp._scheduled if not h._cancelled)
            if len(ws) > 1 and ws[1] - ws[0] < TIE:
                raise RuntimeError(f"tie at t={ws[0]!r}: choose a trace without simultaneous events")
            lp._vt = ws[0]
        return []

    def __getattr__(self, name):
        return getattr(self.real, name)


class VLoop(asyncio.SelectorEventLoop):
    def __init__(self):
        super().__init__()
        self._vt = 0.0
        self._selector = Sel(self, self._selector)

    def time(self):
        return self._vt


def parse(path):
    cfg = {"jitter_ns": [0], "arrive": []}
    for line in open(path):
        w = line.split()
        if not w or w[0].startswith("#"):
            continue
        if w[0] == "arrive":
            cfg["arrive"].append(int(w[1]))
        elif w[0] == "jitter_ns":
            cfg["jitter_ns"] = [int(x) for x in w[1:]]
        else:
            cfg[w[0]] = int(w[1])
    return cfg


def main(path):
    cfg = parse(path)
    loop = VLoop()
    asyncio.set_event_loop(loop)
    time.time = lambda: loop._vt
    arr = [ns / 1e9 for ns in cfg["arrive"]]
    batches, res, params = [], {}, []
    calls = [0]
    jit = [x / 1e9 for x in cfg["jitter_ns"]]
    da, db = cfg["dur_a_ns"] / 1e9, cfg["dur_b_ns"] / 1e9

    async def cb(items):
        k = calls[0]
        calls[0] += 1
        t = loop._vt
        batches.append((t, len(items), t - arr[items[0]], list(items)))
        await asyncio.sleep(da * len(items) + db + jit[k % len(jit)])
        return list(items)

    disp = D.CorkDispatcher(
        int(cfg["max_latency_ms"]), int(cfg["max_batch"]), fallback=lambda: -1, get_batch_size=lambda x: 1
    )
    orig = D.Optimizer.trigger_refresh

    def refresh(self):
        orig(self)
        params.append((loop._vt, self.o_a, self.o_b, self.wait))

    D.Optimizer.trigger_refresh = refresh
    func = disp(cb)
    pending = [len(arr)]

    async def run():
        done = asyncio.Event()

        async def client(i):
            r = await func(i)
            res[i] = (loop._vt, "fb" if r == -1 else "ok")
            pending[0] -= 1
            if pending[0] == 0:
                done.set()

        for i, t in enumerate(arr):
            loop.call_at(t, lambda i=i: loop.create_task(client(i)))
        await done.wait()

    loop.run_until_complete(run())
    for t in asyncio.all_tasks(loop):
        t.cancel()
    loop.run_until_complete(asyncio.sleep(0))
    for t, n, w, ids in batches:
        print(f"batch {t:.9f} {n} {w:.9f} {' '.join(map(str, ids))}")
    for i in sorted(res):
        print(f"res {i} {res[i][0]:.9f} {res[i][1]}")
    for t, a, b, w in params:
        print(f"param {t:.9f} {a:.12e} {b:.12e} {w:.12e}")


main(sys.argv[1])
