# Streaming

`Response.begin_stream / write / sse / end_stream` (http.mojo), `trait StreamEndpoint`, `emit` (endpoint.mojo).
Gate `b6` (`tests/run.sh b6`) (26 wire rows vs BentoML, plus the SSE checks in `tools/b6_oracle.py sse`).

## Two shapes

| | Wire | Use |
|---|---|---|
| generator endpoint: `emit(resp, item)` | BentoML's own: `text/event-stream; charset=utf-8`, one HTTP chunk per item, no event framing: a string as is, anything else as Python's `json.dumps` | clients written for BentoML |
| SSE: `resp.sse(data, event, id)` | one chunk per event: `event:`, `id:`, a `data:` line per line, blank line (WHATWG HTML 9.2) | browsers, OpenAI-style `data: {...}` / `data: [DONE]` clients |

`write(bytes)` is the primitive under both. HTTP/1.1 is chunked; an HTTP/1.0 client gets a close-delimited body
and the connection ends with the stream. A response that streamed leaves the connection open for the next request
(keep-alive) unless the client asked to close or the stream broke.

## Errors, as BentoML does them

- Raise before the first send: the usual error answer (`[{"error":...}]`, the 500 body), the connection stays open.
- Raise after the first send: the stream ends cleanly where it stands (no error marker on the wire).
- Bad input: the 400 validation body, before any stream starts.
- A stream with no items still answers 200 with an empty chunked body.
- The peer left: `write` raises `stream: client gone`; the endpoint stops generating, the server closes the
  connection. A send that stalls 5 s counts as gone.

## Cost and limits

A streaming handler holds one worker for as long as it streams: size `serve(workers)` for the number of concurrent
streams (the Batcher parks a worker the same way). 100000 SSE events to one client: 176,056 events per second, one chunk each (`scripts/bench.sh`, receipt `docs/receipts/bench.txt`).
Earlier pipelined answers on the connection are flushed before the stream's head.
