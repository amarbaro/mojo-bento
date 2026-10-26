# HTTP server

`src/bento/{net,http,server}.mojo`. Gate `b1` (`tests/run.sh b1`): 59 raw-HTTP rows in `tests/cases/http.txt`.

## Shape

```
worker x N  --epoll_wait--> one shared epoll set (EPOLLONESHOT)
  listen fd  -> accept up to 128, add each conn, re-arm listen
  conn fd    -> recv once, parse every complete request, run Handler.handle for each,
                one send for all responses, re-arm (or close)
  signalfd   -> stop()
```

No queue and no lock: ONESHOT gives each ready connection to exactly one worker, so a handler may block
(a Batcher.submit parks one worker, the others keep serving). `Server.serve(workers, signals, drain_ms)` blocks the
caller; `stop()` is safe from any thread; `Handler.handle(self, req, mut resp)` runs on many threads on one
shared value (read-only, or lock what it mutates); `Handler.draining()` is called once on SIGTERM. Health,
metrics and sd_notify are in ops.md, endpoints in endpoints.md, streaming in streaming.md.

## Parser (`http.parse_request`)

Grammar from h11; stricter where leniency allows request smuggling. Differences from h11, all by design:
bare LF and obsolete line folding are 400; control bytes 0x01-0x1f and 0x7f in a header value are 400
(h11 allows all but NUL); Content-Length together with Transfer-Encoding is 400 (h11 lets chunked win);
an HTTP/1.0 request keeps the connection only with `Connection: keep-alive` (h11 never does).
Limits: head over `max_head` is 431, body over `max_body` is 413 (checked on Content-Length before the
body is read), unknown Transfer-Encoding is 501, major version != 1 is 505. `Expect: 100-continue` is answered
once per request. h11's normalisation is kept: repeated Content-Length folds into one header holding the
number, Transfer-Encoding is lower-cased.

## Oracle

`tools/http_oracle.py`: h11 parses (blocking-socket server, own process), the status for what h11 leaves to
the server (limits, versions, CL+TE) is that file's policy. `selfcheck` also runs the 25 rows flagged `hs`
against `http.server`; the other rows differ in http.server's own framing (HTTP/0.9 error pages,
exact-match `Connection: close`). Row flags: `hs head trickle split:N half`.

## Limits

Linux x86-64 (packed 12-byte `epoll_event`), IPv4 only. No idle-connection timeout. A slow reader
parks its worker in `send_all` for up to 5 s. 16384 connection slots (fd number is the index).

## Numbers

`scripts/bench.sh` (receipt `docs/receipts/bench.txt`): localhost, 4 workers, echo handler, Python load generators
(`tools/http_bench.py`, so the rates are a lower bound), Ryzen 7 7800X3D, one 3 s run per row.

| Load | Requests per second |
|---|---|
| 1 connection | 53,522 |
| 8 connections | 238,565 |
| 32 connections | 281,840 |
| 8 connections, pipeline 16 | 1,308,085 |
| `POST /add` through `Service` with metrics, 8 connections | 224,977 |
