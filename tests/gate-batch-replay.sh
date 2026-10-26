#!/usr/bin/env bash
# B3 gate 1: every tests/cases/batch/*.trace replayed by bento.dispatch.Cork (tests/batch_replay.mojo) equals the
# output of BentoML's own CorkDispatcher on the same virtual clock (tools/batch_oracle.py).
# The oracle output is committed as <trace>.expect; with the oracle venv present it is regenerated and must equal it.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .work/t
.venv/bin/mojo build -I src tests/batch_replay.mojo -o .work/t/batch_replay 2>.work/t/build.err || { echo "FAIL build: tests/batch_replay.mojo"; cat .work/t/build.err; exit 1; }
fail=0; n=0
for f in tests/cases/batch/*.trace; do
  t=$(basename "$f" .trace); n=$((n+1))
  if [[ -x .venv/bin/python ]]; then
    .venv/bin/python -I tools/batch_oracle.py "$f" > ".work/t/$t.live" 2>/dev/null || { echo "FAIL oracle: $t"; fail=$((fail+1)); continue; }
    python3 -I tools/batch_cmp.py "$f.expect" ".work/t/$t.live" > ".work/t/$t.cmp" || { echo "FAIL oracle drift: $t: $(head -2 ".work/t/$t.cmp")"; fail=$((fail+1)); continue; }
  fi
  timeout 20 .work/t/batch_replay "$f" > ".work/t/$t.got" || { echo "FAIL replay: $t"; fail=$((fail+1)); continue; }
  python3 -I tools/batch_cmp.py "$f.expect" ".work/t/$t.got" > ".work/t/$t.cmp" || { echo "FAIL $t: $(head -3 ".work/t/$t.cmp")"; fail=$((fail+1)); continue; }
  echo "ok $t: $(cat ".work/t/$t.cmp")"
done
echo "traces: $n, failures: $fail"
[[ $fail -eq 0 ]] || { echo "FAIL batch-replay: $fail"; exit 1; }
echo "PASS batch-replay"
