#!/usr/bin/env bash
# B4 live check: a Type=notify transient user unit is "activating" until the server sends READY=1, then
# "active" with the STATUS text; its /readyz answers; `systemctl --user stop` ends it cleanly.
# Usage: tests/b4_systemd.sh BIN (a tests/b2_service build)   -- needs a systemd user manager
set -euo pipefail
bin=$(realpath "$1")
unit=bento-b4-test
systemctl --user reset-failed "$unit.service" 2>/dev/null || true
port=$((20000 + RANDOM % 12000))
cleanup() { systemctl --user stop "$unit.service" 2>/dev/null || true; }
trap cleanup EXIT
systemd-run --user --unit="$unit" --collect --service-type=notify --no-block --quiet "$bin" "$port" 1500 0
seen=""
for _ in $(seq 100); do
  st=$(systemctl --user is-active "$unit.service" 2>/dev/null || true)
  seen="$seen $st"
  [ "$st" = active ] && break
  sleep 0.05
done
case "$seen" in *activating*active*) ;; *) echo "FAIL systemd: states seen:$seen (want activating then active)"; exit 1;; esac
for _ in $(seq 20); do  # systemd applies READY and STATUS from one datagram, but a property read may still lag
  status=$(systemctl --user show "$unit.service" -p StatusText --value)
  [ -n "$status" ] && break
  sleep 0.05
done
[ "$status" = "listening on $port" ] || { echo "FAIL systemd: StatusText '$status'"; exit 1; }
[ "$(curl -s -o /dev/null -w '%{http_code}' "localhost:$port/readyz")" = 200 ] || { echo "FAIL systemd: /readyz not 200"; exit 1; }
systemctl --user stop "$unit.service"
st=$(systemctl --user is-active "$unit.service" 2>/dev/null || true)
[ "$st" = inactive ] || { echo "FAIL systemd: after stop the unit is '$st'"; exit 1; }
echo "systemd: states $(echo $seen | tr ' ' '\n' | uniq | tr '\n' ' ')-> StatusText '$status', stop -> inactive"
