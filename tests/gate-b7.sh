#!/usr/bin/env bash
# B7: bento build -> move the dir -> serve it in a sandbox that sees only /usr and the bento (no $HOME, no venv)
# -> the B2 oracle rows answer the same; verify catches a changed file; a missing model fails the build.
set -euo pipefail
cd "$(dirname "$0")/.."
PY=.venv/bin/python; W=$PWD/.work/b7; rm -rf "$W"; mkdir -p "$W/store/iris/v1" "$W/store/iris/v3" "$W/store/tok/v2"
echo v3 > "$W/store/iris/latest"; echo weights-v3 > "$W/store/iris/v3/model.bin"; echo tok > "$W/store/tok/v2/tokenizer.json"
scripts/bento build tests/b7/service.toml "$W/build"
mv "$W/build" "$W/moved"; B=$W/moved
[ "$(cat "$B/models/iris/latest")" = v3 ] && [ -f "$B/models/iris/v3/model.bin" ] && [ -f "$B/models/tok/v2/tokenizer.json" ] && [ ! -e "$B/models/iris/v1" ] || { echo "FAIL models: wrong set in $B/models"; exit 1; }
readelf -d "$B/bin/b2svc" | grep -q 'ORIGIN/../lib' || { echo "FAIL rpath"; exit 1; }
scripts/bento verify "$B"
# sandbox: only system dirs and the bento; the Mojo venv and the repo do not exist inside
bwrap --ro-bind /usr /usr --symlink usr/lib /lib --symlink usr/lib64 /lib64 --symlink usr/bin /bin --proc /proc --dev /dev \
  --ro-bind "$B" /srv/bento --tmpfs /tmp --unshare-all --share-net --die-with-parent \
  /srv/bento/bento-serve > "$W/serve.out" 2>&1 &
pid=$!; trap 'kill $pid 2>/dev/null || true; kill ${bpid:-} 2>/dev/null || true' EXIT
for _ in $(seq 100); do grep -q '^LISTEN ' "$W/serve.out" && break; sleep 0.05; done
port=$(sed -n 's/^LISTEN //p' "$W/serve.out"); [ -n "$port" ] || { echo "FAIL sandbox serve:"; cat "$W/serve.out"; exit 1; }
echo "sandboxed bento listening on $port"
$PY -c 'import bentoml' 2>/dev/null || { echo "FAIL setup: oracle venv"; exit 1; }
source <(sed -n '/^bento_start()/,/^}/p' tests/run.sh); bento_start; bpid=${bento_pid:-}
$PY tools/b2_oracle.py tests/cases/b2.txt "$bento_port" "$port"
echo tamper >> "$B/models/iris/v3/model.bin"
if scripts/bento verify "$B" 2>/dev/null; then echo "FAIL verify: tampered file passed"; exit 1; fi; echo "verify rejects a changed file: ok"
sed 's/"tok:v2"/"tok:v9"/' tests/b7/service.toml > "$W/bad.toml"; sed -i "s|^entry = .*|entry = \"$PWD/tests/b2_service.mojo\"|" "$W/bad.toml"
if scripts/bento build "$W/bad.toml" "$W/bad" 2> "$W/bad.err"; then echo "FAIL build: missing model accepted"; exit 1; fi
grep -q 'FAIL model: tok:v9' "$W/bad.err" && echo "missing model fails the build: ok"
