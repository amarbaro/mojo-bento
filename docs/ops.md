# Health, metrics, systemd

`src/bento/metrics.mojo`, built into `Service` (endpoint.mojo) and `Server.serve` (server.mojo).
Gates `b4` (`tests/run.sh b4`) and, locally, `b4systemd`.

## Routes (Service)

| Route | Answer |
|---|---|
| `GET`/`HEAD` `/healthz` `/livez` `/readyz` | 200 `text/plain; charset=utf-8`, body `\n` (byte-equal to BentoML) |
| `/readyz` after `set_ready(False)` or SIGTERM | 503 |
| other method on those | 405, `allow: GET, HEAD` (BentoML's order varies per process; the gate compares the set) |
| `GET`/`HEAD` `/metrics` | Prometheus text, `text/plain; version=0.0.4; charset=utf-8` |

## Metrics

BentoML's names and label sets minus `runner_name`: `bentoml_service_request_total` (counter),
`_request_in_progress` (gauge), `_request_duration_seconds` (histogram, buckets 0.005 ... 180, +Inf), labels
`endpoint`, `http_response_code`, `service_name` (`Service(..., name=)`), `service_version="not available"`.
One flat table of Int64 atomics, no lock; `/metrics` reads while handlers write. Status codes are tracked in 11
slots (200 400 401 403 404 405 413 422 429 500 503); other 4xx fold into 400, other 5xx into 500, 2xx and 3xx into
200. Built-in routes and unknown paths are not counted.

## systemd

`Server.serve` sends `READY=1` + `STATUS=listening on <port>` once the workers run (no-op without
NOTIFY_SOCKET), pings the watchdog at half of WATCHDOG_USEC, `STOPPING=1` on the way out. SIGINT/SIGTERM
(`serve(signals=True)`, `posix.block_signals` first in `main`) run the drain: `Handler.draining()` (Service turns
/readyz to 503), `STATUS=draining`, keep serving `drain_ms`, then stop; the process exits 0.

## Gate

1. `tests/cases/b4.txt` (18 rows) to BentoML and the Mojo service: status, content-type, allow, body equal.
2. `tools/b4_check.py metrics`: `prometheus_client`'s parser reads /metrics; after 7 ok, 3 bad (400), 2 raising (500),
   1 denied (403) the counts are exact, histogram count/sum/cumulative buckets/+Inf agree, in_progress is 0;
   then 8 threads x 200 requests count to exactly 1607.
3. `tools/b4_check.py drain`: SIGTERM, /readyz 503 and /healthz 200 during the drain, exit status 0.
4. `b4systemd` (`tests/b4_systemd.sh`, local only, needs a systemd user manager): transient user unit `Type=notify` shows activating (service sleeps 1.5 s first), then
   active with StatusText `listening on <port>`, /readyz 200, `systemctl --user stop` leaves it inactive.

## Cost

`POST /add` through `Service` with the metrics on: 224,977 requests per second on 8 connections (server.md has the load
generator and the other rows).
