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
gguf mojo-gguf-core 1ad0178b7ebc1b470b72260b5684348bc150b292
json mojo-json 70ff3c988af1b9e88685ce1b8243ccf73f342acc
posix mojo-posix 9f9e7639bc99577c479aa79538c1e15c432083fe
safetensors mojo-safetensors 7edf6439526b232c0935cfb6f2e194aa1b4433ad
systemd mojo-systemd dd53aa2113afd41af00d683f7da8ad5d8ff078fc
PINS
