#!/usr/bin/env bash
# The two gates a hosted runner cannot run: b4systemd (a Type=notify transient user unit under `systemctl --user`) and
# b7 (`bento build`, then the bento served inside a bubblewrap sandbox that sees only /usr and the bento).
# Needs a systemd user manager, bwrap, patchelf, readelf and ldd. Run from the repo root after scripts/ci.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
for c in systemctl bwrap patchelf readelf ldd; do command -v "$c" >/dev/null || { echo "FAIL setup: $c not installed"; exit 1; }; done
tests/run.sh b4systemd b7
