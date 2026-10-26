#!/usr/bin/env bash
# CI entry point, same on a GitHub runner and a local Ubuntu VM: install (the dev group holds the BentoML oracle),
# build, then every gate that needs no systemd user manager and no sandbox. Those two run locally:
# scripts/local-gates.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v uv >/dev/null || { echo "FAIL setup: uv not installed"; exit 1; }
uv sync || { echo "FAIL setup: uv sync"; exit 1; }
.venv/bin/python -c 'import platform, bentoml; print("oracle python", platform.python_version(), "bentoml", bentoml.__version__)'
mkdir -p .work/t
scripts/mojo.sh examples/quickstart.mojo .work/t/quickstart 2> .work/build.err || { echo "FAIL build: examples/quickstart.mojo"; cat .work/build.err; exit 1; }
tests/run.sh || { echo "FAIL gates: tests/run.sh"; exit 1; }
.work/t/quickstart > /dev/null || { echo "FAIL example: examples/quickstart.mojo"; exit 1; }
echo "PASS ci"
