#!/usr/bin/env bash
# Request rate of the server on localhost, measured with tools/http_bench.py (Python clients, so a lower bound), and the
# SSE chunk rate to one client. Prints one line per row. Needs `uv sync`. Receipt: docs/receipts/bench.txt.
set -euo pipefail
cd "$(dirname "$0")/.."
PY=.venv/bin/python; mkdir -p .work/t
scripts/mojo.sh tests/echo_server.mojo .work/echo_server 2> .work/t/bench-build.err || { echo "FAIL build: tests/echo_server.mojo"; cat .work/t/bench-build.err; exit 1; }
scripts/mojo.sh tests/b2_service.mojo .work/b2_service 2>> .work/t/bench-build.err || { echo "FAIL build: tests/b2_service.mojo"; cat .work/t/bench-build.err; exit 1; }
pid=""; trap '[ -z "$pid" ] || kill "$pid" 2>/dev/null || true' EXIT
start() { rm -f .work/t/bench.out; "$@" > .work/t/bench.out 2>&1 & pid=$!
  for _ in $(seq 100); do grep -q '^LISTEN ' .work/t/bench.out 2>/dev/null && break; sleep 0.05; done
  port=$(sed -n 's/^LISTEN //p' .work/t/bench.out); [ -n "$port" ] || { echo "FAIL start: $1 did not listen"; exit 1; }; }
stop() { kill "$pid"; wait "$pid" 2>/dev/null || true; pid=""; }
echo "echo handler, 4 workers"
start .work/echo_server
for c in 1 8 32; do echo "  GET, $c connections: $($PY tools/http_bench.py "$port" "$c" 3 1)"; done
echo "  GET, 8 connections, pipeline 16: $($PY tools/http_bench.py "$port" 8 3 16)"
stop
echo "Service with metrics, 4 workers"
start .work/b2_service
echo "  POST /add, 8 connections: $($PY tools/http_bench.py "$port" 8 3 1 /add '{"a":1,"b":2}')"
s=$(date +%s%N)
bytes=$(curl -s -X POST "localhost:$port/events" -H 'content-type: application/json' -d '{"n":100000}' | wc -c)
ms=$(( ($(date +%s%N) - s) / 1000000 ))
echo "  SSE, 100000 events to one client: $bytes bytes in $ms ms ($(( 100000 * 1000 / ms )) events/s)"
stop
echo "PASS bench"
