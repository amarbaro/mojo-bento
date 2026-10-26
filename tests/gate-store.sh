#!/usr/bin/env bash
# B5 gate: tests/cases/store.txt (list/get/register/delete/weights/tree on a BentoML-built fixture) printed by
# bento.store.ModelStore (tests/store_cases.mojo) must equal what BentoML's own ModelStore prints (tools/store_oracle.py);
# the oracle output is committed as store.expect and, with the oracle venv present, regenerated and compared too.
# Last: BentoML must read back the store the Mojo side just changed.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .work/t
scripts/mojo.sh tests/store_cases.mojo .work/store_cases 2> .work/t/store-build.err || { echo "FAIL build: tests/store_cases.mojo"; cat .work/t/store-build.err; exit 1; }
if [[ -x .venv/bin/python ]]; then
  .venv/bin/python -I tools/store_oracle.py tests/cases/store.txt tests/cases/store-fixture "$PWD/.work/t/oracle-store" 2>/dev/null > .work/t/store.live
  cmp -s .work/t/store.live tests/cases/store.expect || { echo "FAIL oracle drift: store.expect"; diff .work/t/store.live tests/cases/store.expect | head -10; exit 1; }
fi
timeout 30 .work/store_cases tests/cases/store.txt tests/cases/store-fixture "$PWD/.work/t/mojo-store" > .work/t/store.got
cmp -s .work/t/store.got tests/cases/store.expect || { echo "FAIL store: output differs from BentoML's"; diff tests/cases/store.expect .work/t/store.got | head -20; exit 1; }
if [[ -x .venv/bin/python ]]; then
  .venv/bin/python -I - "$PWD/.work/t/mojo-store/models" "$PWD/.work/t/oracle-store/models" <<'PY' || { echo "FAIL readback: BentoML reads the Mojo-written store differently"; exit 1; }
import sys
from bentoml._internal.models import ModelStore
a, b = ModelStore(sys.argv[1]), ModelStore(sys.argv[2])
la, lb = [(str(m.tag), m.creation_time) for m in a.list()], [(str(m.tag), m.creation_time) for m in b.list()]
assert la == lb, (la, lb)
for name in sorted({t.split(":")[0] for t, _ in la}):
    assert str(a.get(name).tag) == str(b.get(name).tag), name
PY
fi
echo "ops: $(grep -vc '^#\|^$' tests/cases/store.txt), output lines: $(wc -l < .work/t/store.got)"
echo "PASS store"
