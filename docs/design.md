# Design

bento answers like BentoML 1.4.39 byte for byte, from one native binary with no Python at serve time. Every gate
compares bytes on the wire or on disk with BentoML itself. The HTTP parser is h11's, and stricter where leniency
allows request smuggling.

## One epoll set, N workers

`Server.serve` runs N worker threads on one shared epoll set (mojo-aio) with `EPOLLONESHOT`: a ready fd wakes one
worker, which reads once, answers every complete pipelined request in one `send`, then re-arms it. No thread or task
per connection, and no lock around the set. SIGTERM arrives through a signalfd: `/readyz` turns 503, open requests
finish, then `serve` closes every connection it accepted ([server.md](server.md), [ops.md](ops.md)).

## Endpoints are structs, validation is pydantic's

`Service[*Es]` takes the endpoint structs as a variadic, so routing is fixed at compile time and there is no
registry. Each endpoint lists typed `Field`s. Coercion follows pydantic's lax mode, and a failure answers with
pydantic's error body, so a client written for BentoML cannot tell the two apart ([endpoints.md](endpoints.md)).

## The batcher is a state machine with an injected clock

BentoML's `CorkDispatcher` + `Optimizer` became `Cork` (dispatch.mojo): `step(now)` returns IDLE, CANCEL, SLEEP or
DISPATCH. Because the clock is an argument, recorded BentoML traces replay against it deterministically (gate b3).
`Batcher` (batch.mojo) only adds the threads ([batch.md](batch.md)).

## Store and packaging keep BentoML's layout

`ModelStore` reads and writes BentoML's `<root>/<name>/<version>/model.yaml` tree; the gate checks both directions
([store.md](store.md)). `scripts/bento build` writes one directory: binary, runtime libraries, models, a sha256 lock
and a systemd unit ([build.md](build.md)).

## Libraries, not copies

aio, gguf, json, posix, safetensors and systemd are separate libraries by the same author, declared in
`[tool.mojo] deps`. The conda package depends on their packages; `scripts/deps.sh` pins each to a commit for source
builds ([api.md](api.md)).

## Not covered

The model runtime: a bento service calls its own Mojo inference code, there is no Python runner or remote
runner as in BentoML. Linux x86-64 only. The systemd and sandbox gates (b4systemd, b7) run locally, not in CI.
