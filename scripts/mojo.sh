#!/usr/bin/env bash
# mojo build with src/ on the include path: scripts/mojo.sh src/app.mojo out/app
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -eq 2 ] || { echo "FAIL usage: scripts/mojo.sh SRC OUT"; exit 2; }
mkdir -p "$(dirname "$2")"
.venv/bin/mojo build -I src "$1" -o "$2"
