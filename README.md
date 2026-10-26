# mojo-bento

[![CI](https://github.com/amarbaro/mojo-bento/actions/workflows/ci.yml/badge.svg)](https://github.com/amarbaro/mojo-bento/actions/workflows/ci.yml)

BentoML's serving core as a Mojo library: an epoll HTTP/1.1 server, typed JSON endpoints that answer byte for byte like
BentoML 1.4.39 (success and validation errors), health and Prometheus metrics, sd_notify with a graceful drain, chunked
and SSE streaming, an adaptive batcher that makes BentoML's own batching decisions, and a model store in BentoML's
layout. Every behaviour is compared with BentoML 1.4.39, h11 and `prometheus_client` by a gate that runs in CI. Linux
x86-64, CPU only, no dependency but the `mojo` package.

```mojo
from json import Json
from posix import block_signals
from bento.endpoint import Service, Endpoint, Field, T_INT
from bento.server import Server

struct Add(Endpoint):
    comptime name = "add"
    def __init__(out self): pass
    def fields(self) -> List[Field]: return [Field("a", T_INT), Field("b", T_INT)]
    def call(self, args: Json) raises -> Json: return Json.of(args.get("a").int() + args.get("b").int())

def main() raises:
    block_signals([2, 15])                   # SIGINT and SIGTERM become a drain
    var srv = Server(Service(Add()), "127.0.0.1", 3000)
    srv.serve(4, True)                       # 4 workers; POST /add {"a": 1, "b": 2} answers 3
```

## Install

Requires Mojo 1.1 (`uv sync` installs it) and Linux x86-64.

| Way | Command |
|---|---|
| Source path | `mojo build -I path/to/mojo-bento/src app.mojo -o app` |
| Vendor | copy `src/` (`bento/` plus the five libraries it imports, listed in [docs/vendored.md](docs/vendored.md)) |

`examples/quickstart.mojo` answers a request without a socket; `scripts/bento build SERVICE.toml OUT` packages a
service into one directory ([docs/build.md](docs/build.md)).

## What you get

- **Server**: epoll with `EPOLLONESHOT`, keep-alive, pipelining, request limits, `Expect: 100-continue`, SIGTERM drain
  with `/readyz` turning 503 ([server.md](docs/server.md), [ops.md](docs/ops.md)). The parser follows h11 and is
  stricter where leniency allows request smuggling.
- **Endpoints**: `Service(Ep1(), Ep2())`, fields with pydantic's lax coercion, BentoML's 400 validation body, 404 and
  405 answers ([endpoints.md](docs/endpoints.md)).
- **Operations**: `/healthz`, `/livez`, `/readyz`, `/metrics` with BentoML's metric names, `READY=1` and watchdog pings.
- **Streaming**: BentoML's chunked generator shape and real SSE ([streaming.md](docs/streaming.md)).
- **Batcher**: `Batcher[In, Out]`, BentoML's `CorkDispatcher` and `Optimizer` as a state machine ([batch.md](docs/batch.md)).
- **Model store**: `ModelStore`, BentoML's directory layout in both directions ([store.md](docs/store.md)).

The calls are in [docs/api.md](docs/api.md); every gate and its last receipt is below and in
[docs/receipts/](docs/receipts/).

| Gate | Compares | Rows | Runs |
|---|---|---|---|
| b1 | raw HTTP requests with h11 (and 25 with `http.server`) | 59 | CI |
| b2 | endpoint answers with a BentoML service: status, headers, body bytes | 74 | CI |
| b3 | batcher decisions with BentoML's dispatcher on replayed traces | 16 traces | CI |
| b4 | health and metrics answers, Prometheus parse and exact counts, drain | 18 rows + counts | CI |
| b5 | model store operations with BentoML's store | 78 ops, 368 lines | CI |
| b6 | streaming wire bytes and SSE framing with BentoML | 26 rows | CI |
| b4systemd, b7 | a live `Type=notify` unit; a packaged bento served in a sandbox | | local |

## Performance

`scripts/bench.sh`: localhost, 4 workers, Python load generators (so a lower bound), Ryzen 7 7800X3D, one 3 s run per
row. Receipt: [docs/receipts/bench.txt](docs/receipts/bench.txt).

| Load | Result |
|---|---|
| echo handler, 1 connection | 53,522 req/s |
| echo handler, 8 connections | 238,565 req/s |
| echo handler, 32 connections | 281,840 req/s |
| echo handler, 8 connections, pipeline 16 | 1,308,085 req/s |
| `POST /add` through `Service` with metrics, 8 connections | 224,977 req/s |
| SSE, 100,000 events to one client | 176,056 events/s |

No BentoML number is given: the comparison here is about answers, not speed.

## Limits

- Linux x86-64 only (the packed 12-byte `epoll_event`), HTTP/1.0 and 1.1, IPv4, no TLS, no idle-connection timeout, 16384
  connection slots. A slow reader parks its worker for up to 5 s.
- A handler runs on many threads at once; a streaming handler or a batched caller holds one worker while it waits, so
  size `serve(workers)` for them.
- Not covered by the answers-equal claim: integers past Int64, NaN and Infinity output, form and multipart bodies, the
  trailing-slash redirect, serde messages for malformed numbers (see [endpoints.md](docs/endpoints.md)). The batcher does
  not split one job across two batches; the model store does not export or import.
- `bento build` ships no Python environment and no Docker image.
- `b4systemd` needs a systemd user manager and `b7` needs bubblewrap, patchelf and readelf, so those two run locally
  (`scripts/local-gates.sh`), not in CI.
- The engine adapter that served the author's LLM engine is not part of this repository.
