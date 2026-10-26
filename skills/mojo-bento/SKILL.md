---
name: mojo-bento
description: "Serve a Mojo program over HTTP the way BentoML 1.4 does: an epoll HTTP/1.1 server, typed JSON endpoints with BentoML's exact validation errors, /healthz /readyz /metrics, sd_notify, chunked and SSE streaming, an adaptive request batcher, and a BentoML-layout model store. Use when a Mojo service needs an HTTP front that BentoML clients and Prometheus scrapers already understand, or must batch concurrent requests into one model call."
---

# mojo-bento

BentoML's serving core in Mojo 1.1, checked against BentoML 1.4.39 by byte-comparing answers.

## Install

`mojo build -I <repo>/src app.mojo -o app`, or copy `src/bento/` together with the vendored `src/posix/`,
`src/json/`, `src/systemd/`, `src/safetensors/` and `src/gguf/`. Linux x86-64 only.

## Use

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
    block_signals([2, 15])                       # SIGINT, SIGTERM: Server turns them into a drain
    var srv = Server(Service(Add()), "127.0.0.1", 3000)
    srv.serve(4, True)                           # 4 workers, handle signals
```

`POST /add` with `{"a": 1, "b": 2}` answers `3`. `examples/quickstart.mojo` shows the same without a socket.

## Rules

- A handler runs on many threads at once on one shared value: keep it read-only or lock what it mutates.
- A streaming or batching endpoint holds a worker while it waits: give `serve(workers)` at least the number of
  concurrent streams or batched callers you expect.
- `Batcher.submit` blocks the calling worker until its batch ran. `run_batch` is a plain
  `def(List[In]) thin raises -> List[Out]`; an exception in it fails every item of that batch.
- Input errors are BentoML's: 400 with `{"error": "N validation error for Input", "detail": [...]}`. Raise
  `http_error(status, message)` for your own 4xx; any other exception becomes BentoML's fixed 500 body.
- Not covered, do not rely on it: HTTP/2, TLS, IPv6, big integers past Int64, form and multipart bodies, an idle
  connection timeout. Read `docs/server.md` and `docs/endpoints.md` for the exact limits.
- A change is done when `scripts/ci.sh` prints `PASS ci`; the systemd and sandbox gates are `scripts/local-gates.sh`.
