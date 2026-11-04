#!/usr/bin/env bash
# Fetch the Mojo libraries bento imports ([tool.mojo] deps in pyproject.toml) into lib/, each pinned to a commit.
# A lib/<pkg> that exists already (a symlink to a local checkout) is kept.
set -euo pipefail
cd "$(dirname "$0")/.."
while read -r pkg repo sha; do
  [[ -e lib/$pkg ]] && continue
  d=.work/deps/$repo
  rm -rf "$d" && git init -q "$d"
  { git -C "$d" fetch -q --depth 1 "https://github.com/amarbaro/$repo" "$sha" && git -C "$d" checkout -q FETCH_HEAD; } \
    || { echo "FAIL setup: fetch $repo $sha"; exit 1; }
  mkdir -p lib && ln -s "../$d/src/$pkg" "lib/$pkg"
done <<'PINS'
aio mojo-aio f902fc8ed350bd7b865b3e526600022923bc2a15
gguf mojo-gguf-core 118faa2c82fc08fc9f828fa14906ff24d54d949a
json mojo-json 70ff3c988af1b9e88685ce1b8243ccf73f342acc
posix mojo-posix ee4f89da1d9f472c83977c3222e01fc142b85010
safetensors mojo-safetensors 07f6d0fd6a56ad5c4850c354e94661eff45aff7a
systemd mojo-systemd 93f3ec367e8cd9d8c3a9db7ffadd0973be8515b0
PINS
