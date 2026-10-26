# API

Everything here is exercised by a gate against BentoML 1.4.39 or by `examples/quickstart.mojo`; the detail and the
differences from BentoML are in the page named in each row. Build with `mojo build -I src app.mojo`.

## Serving

| Call | Behaviour | Page |
|---|---|---|
| `Server(handler, host="127.0.0.1", port=0, limits=Limits(), max_conns=16384)` | Binds and listens (port 0: any free port, read it with `port()`). `handler` is any `Handler`. | server.md |
| `srv.serve(workers=4, signals=False, drain_ms=0)` | Blocks the caller and runs `workers` threads on one epoll set. With `signals` (call `posix.block_signals` first in `main`) SIGINT and SIGTERM run the drain: `draining()`, keep serving `drain_ms`, stop; the process exits 0. Sends `READY=1` to systemd when `NOTIFY_SOCKET` is set. | server.md, ops.md |
| `srv.stop()` | Asks every worker to finish its request and return. Safe from any thread. | server.md |
| `trait Handler` | `handle(self, req: Request, mut resp: Response) raises` runs on many threads on one shared value; `draining(self)` is called once on SIGTERM. | server.md |
| `Limits(max_head=16384, max_body=1 << 20)` | Head over the limit is 431, body over it 413. | server.md |

## Endpoints

| Call | Behaviour | Page |
|---|---|---|
| `Service(Ep1(), Ep2(), ...)` | A `Handler`: `POST /<name>` per endpoint, plus `/healthz`, `/livez`, `/readyz` and `/metrics`. `set_ready(False)` turns `/readyz` to 503. | endpoints.md, ops.md |
| `trait Endpoint` | `comptime name`, `fields() -> List[Field]`, `call(self, args: Json) raises -> Json`. A string result is `text/plain`, any other `Json` is `application/json` laid out like Python's `json.dumps`. | endpoints.md |
| `trait StreamEndpoint` | `comptime name`, `fields()`, `stream(self, args: Json, mut resp: Response) raises`. | streaming.md |
| `Field(name, kind)`, `Field(name, kind, default)` | Required and optional input. Kinds `T_STR T_INT T_FLOAT T_BOOL`, `T_LIST` with an element kind. Input is coerced as pydantic's lax mode does. | endpoints.md |
| `http_error(status, message)` | Raise it from `call` for a 4xx with BentoML's error body; any other exception is BentoML's fixed 500 body. | endpoints.md |
| `emit(resp, item)` | One chunk per item the way BentoML streams a generator: a string as is, anything else as `json.dumps`. | streaming.md |
| `resp.sse(data, event="", id="")` | One Server-Sent Event. `resp.begin_stream`, `resp.write` and `resp.end_stream` are the primitives under both. | streaming.md |

## Batching and models

| Call | Behaviour | Page |
|---|---|---|
| `Batcher[In, Out](run_batch, max_latency_ms=10000, max_batch_size=32, max_inflight=1)` | BentoML's `CorkDispatcher` and `Optimizer` as a state machine plus a driving thread. `submit(item) raises -> Out` blocks the calling worker until its batch ran; `close()`; `stats()`. | batch.md |
| `ModelStore(root)` | BentoML's model store layout: `list`, `get`, `register`, `delete`, `weights`. A store BentoML wrote opens here and the reverse. | store.md |

## Packaging

| Command | Behaviour | Page |
|---|---|---|
| `scripts/bento build SERVICE.toml OUT` | Compiles the entry, ships the Modular runtime libraries it loads, copies the models of the store, writes `bento.lock` (sha256 of every file) and a systemd unit. | build.md |
| `scripts/bento serve OUT [PORT]`, `scripts/bento verify OUT` | Runs the packaged service; rechecks every file against the lock. | build.md |

## Vendored libraries

`src/posix`, `src/json`, `src/systemd`, `src/safetensors` and `src/gguf` are copies of this author's Apache-2.0
libraries so that a clone builds with the `mojo` package alone; [vendored.md](vendored.md) lists the sources.
