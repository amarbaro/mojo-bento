# Adaptive batcher

`src/bento/dispatch.mojo` is BentoML's `CorkDispatcher` + `Optimizer` (`_internal/marshal/dispatcher.py`) as a pure state
machine with an injected clock. `src/bento/batch.mojo` drives it from threads.

```
worker threads --submit(item)--> Batcher --enqueue--> Cork (queue, Optimizer, one-batch semaphore)
                                    |                    ^ step(now): IDLE | CANCEL | SLEEP | DISPATCH
                         controller thread, polls 1 ms ---+
                                    | DISPATCH
                         batch thread: run_batch(List[In]) -> List[Out], results to each waiting worker
```

## What is ported

Warm-up in four training phases (1, 1, 2, 3 requests), then steady state: cork while `n * (wn + 1 ms + o_a) <= wait * 0.95`,
cancel a head job whose estimated latency `w0 + o_a * n + o_b` passes `max_latency`, one batch in flight. The Optimizer
fits `duration = o_a * n + o_b` over the last 50 batches (`numpy.linalg.lstsq`; when every `n` is equal it returns the
minimum-norm solution, which is ported too) and refreshes at most once per 5 s.

`max_inflight` is the semaphore count of BentoML's `NonBlockSema` (its `shared_sema`): 1 runs one batch at a time, as BentoML does;
2 lets the next batch start while one runs, for a backend that queues admitted work. The gate replays at 1.

Not ported: splitting one job across two batches (`split_job`, needs a tensor container; every item counts as 1) and
`shared_sema` between dispatchers.

## API

`Batcher[In, Out](run_batch, max_latency_ms=10000, max_batch_size=32, max_inflight=1)`; `submit(item) raises -> Out` blocks the calling
thread; `close()`; `stats() -> (batches, items)`. `run_batch` is a plain `def(List[In]) thin raises -> List[Out]`
(carry context in `In`). It raises: every item of that batch raises its message. A queued item that passes `max_latency_ms`
raises `batcher: overloaded (waited longer than max_latency)` (BentoML answers those with its fallback, HTTP 503);
the estimates start pessimistic (`o_a = max_latency * 2/30`), so a tiny limit drops requests until the first batches
train the Optimizer, exactly as BentoML does.

## Gate

Gate `b3`: `tests/gate-batch-replay.sh`: 16 arrival traces (`tests/cases/batch/*.trace`: sparse, poisson, bursts, overload, 30 s
runs where `wait` turns non-zero) replayed on a virtual clock by BentoML's real `CorkDispatcher` (`tools/batch_oracle.py`:
asyncio loop whose clock jumps to the next handle, `time.time` patched) and by `tests/batch_replay.mojo`; batch sizes, first-job
waits, cancel decisions and optimizer parameters must match (`tools/batch_cmp.py`: times to 2 ns, parameters to 1e-6).
Each trace's oracle output is committed as `<trace>.expect`; with the dev environment (`uv sync`) present it is regenerated and compared too.
Traces are drawn so no two clock events fall within 10 ns (their order would be heap luck in Python): `tools/batch_traces.py`.
`tests/batch_threads.mojo` runs the Batcher under 16 real threads.
