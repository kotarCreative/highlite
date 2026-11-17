#!/usr/bin/env bash
# Isolated end-to-end smoke test for the Linux shell.
#
# It starts its own relay on a fresh loopback port, uses private throwaway
# config/data, checks auth and permissions, exercises the StatusNotifier tray
# menu, verifies single-instance activation, and cleans up only its own process.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
shell="${HIGHLITE_LINUX_BIN:-$root/apps/linux/target/debug/highlite-desktop}"
relay="${HIGHLITE_RELAY_BIN:-$root/target/debug/highlite-relay}"
build=1
require_tray=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build) build=0; shift ;;
    --allow-missing-tray) require_tray=0; shift ;;
    -h|--help) sed -n '1,10p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ "$build" == 1 ]]; then
  cargo build --manifest-path "$root/Cargo.toml" -p highlite-relay
  cargo build --manifest-path "$root/apps/linux/Cargo.toml"
fi
[[ -x "$shell" ]] || { echo "Missing $shell; run without --no-build." >&2; exit 1; }
[[ -x "$relay" ]] || { echo "Missing $relay; run without --no-build." >&2; exit 1; }

tmp_root="${HIGHLITE_LINUX_SMOKE_DIR:-/tmp/opencode}"
mkdir -p "$tmp_root"
tmp="$(mktemp -d "$tmp_root/highlite-linux-smoke.XXXXXX")"
config="$tmp/config"
data="$tmp/data"
log="$tmp/app.log"
app_pid=""
app_id="com.highlite.Highlite.Smoke$$"

cleanup() {
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill -TERM "$app_pid" 2>/dev/null || true
    for _ in $(seq 1 50); do kill -0 "$app_pid" 2>/dev/null || break; sleep 0.1; done
    kill -KILL "$app_pid" 2>/dev/null || true
  fi
  echo "Smoke artifacts: $tmp"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  echo "--- app log ---" >&2
  tail -60 "$log" >&2 || true
  exit 1
}

wait_for() {
  local description="$1"
  shift
  for _ in $(seq 1 200); do
    if "$@"; then return 0; fi
    sleep 0.1
  done
  fail "timed out waiting for $description"
}

relay_child() {
  pgrep -P "$app_pid" -x highlite-relay | head -1
}

port_from_log() {
  sed -nE 's/.*relay ready at http:\/\/127\.0\.0\.1:([0-9]+)\/.*/\1/p' "$log" | tail -1
}

menu_layout() {
  busctl --user call "$sni" /MenuBar com.canonical.dbusmenu GetLayout iias 0 -- -1 0
}

menu_id_for_label() {
  local layout="$1" label="$2"
  python3 - "$layout" "$label" <<'PY'
import re
import sys
layout, wanted = sys.argv[1], sys.argv[2]
for match in re.finditer(r'(\d+) 1 "label" s "([^"]+)"', layout):
    if match.group(2) == wanted:
        print(match.group(1))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

echo "Starting isolated Highlite shell..."
HIGHLITE_DESKTOP_APP_ID="$app_id" \
HIGHLITE_DESKTOP_CONFIG_DIR="$config" \
HIGHLITE_DESKTOP_DATA_DIR="$data" \
HIGHLITE_RELAY_BIN="$relay" \
"$shell" >"$log" 2>&1 &
app_pid=$!

wait_for "relay readiness" bash -c "grep -q 'relay ready at' '$log'"
wait_for "embedded dashboard load" bash -c "grep -q 'dashboard loaded' '$log'"
port="$(port_from_log)"
[[ -n "$port" ]] || fail "could not read relay port"
kill -0 "$app_pid" 2>/dev/null || fail "shell exited during startup"

health="$(curl -fsS --max-time 3 "http://127.0.0.1:$port/healthz")"
grep -q '"status":"ok"' <<<"$health" || fail "unexpected health response"

token="$(sed -n 's/^HIGHLITE_RELAY_READ_TOKEN=//p' "$config/relay.env" | tail -1)"
[[ ${#token} -eq 64 ]] || fail "expected a generated 64-character read token"

status_auth="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 \
  -H "Authorization: Bearer $token" "http://127.0.0.1:$port/v1/sessions")"
[[ "$status_auth" == "200" ]] || fail "read token did not authorize (HTTP $status_auth)"
status_anon="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 \
  "http://127.0.0.1:$port/v1/sessions")"
[[ "$status_anon" == "401" ]] || fail "unauthenticated read was not rejected (HTTP $status_anon)"

[[ "$(stat -c '%a' "$config")" == "700" ]] || fail "config directory is not 0700"
[[ "$(stat -c '%a' "$data")" == "700" ]] || fail "data directory is not 0700"
[[ "$(stat -c '%a' "$config/relay.env")" == "600" ]] || fail "relay.env is not 0600"
if grep -R --line-number --fixed-strings "$token" "$log" >/dev/null 2>&1; then
  fail "read token leaked into the app log"
fi

sni="org.kde.StatusNotifierItem-${app_pid}-1"
wait_for "StatusNotifierItem registration" \
  bash -c "busctl --user list | grep -q '^$sni '"
tray_host="present"
if busctl --user list | grep -q '^org.kde.StatusNotifierWatcher '; then
  registered="$(busctl --user get-property org.kde.StatusNotifierWatcher /StatusNotifierWatcher \
    org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems)"
  grep -q "org.kde.StatusNotifierItem-${app_pid}-" <<<"$registered" ||
    fail "tray item is not registered with the StatusNotifierWatcher"
else
  tray_host="absent"
  if [[ "$require_tray" == 1 ]]; then
    fail "no org.kde.StatusNotifierWatcher is running; rerun with --allow-missing-tray for a degraded check"
  fi
  echo "WARN: no StatusNotifierWatcher; skipping host registration check"
fi

layout="$(menu_layout)"
grep -q 'Relay running' <<<"$layout" || fail "tray menu does not report a running relay"
grep -q 'Open Dashboard' <<<"$layout" || fail "tray menu lacks Open Dashboard"
grep -q 'Quit Highlite' <<<"$layout" || fail "tray menu lacks Quit Highlite"

echo "Exercising tray Stop Relay..."
stop_id="$(menu_id_for_label "$layout" 'Stop Relay')" || fail "Stop Relay menu item missing"
busctl --user call "$sni" /MenuBar com.canonical.dbusmenu Event isvu "$stop_id" clicked s "" 0
wait_for "relay to stop" bash -c "! pgrep -P $app_pid -x highlite-relay >/dev/null"
layout="$(menu_layout)"
grep -q 'Relay stopped' <<<"$layout" || fail "tray menu did not report the stopped relay"

echo "Exercising tray Start Relay..."
start_id="$(menu_id_for_label "$layout" 'Start Relay')" || fail "Start Relay menu item missing"
ready_count_before="$(grep -c 'relay ready at' "$log")"
dashboard_count_before="$(grep -c 'dashboard loaded' "$log")"
busctl --user call "$sni" /MenuBar com.canonical.dbusmenu Event isvu "$start_id" clicked s "" 0
wait_for "relay to restart" bash -c "pgrep -P $app_pid -x highlite-relay >/dev/null"
for _ in $(seq 1 200); do
  ready_count_after="$(grep -c 'relay ready at' "$log")"
  [[ "$ready_count_after" -gt "$ready_count_before" ]] && break
  sleep 0.1
done
[[ "${ready_count_after:-0}" -gt "$ready_count_before" ]] || fail "relay did not report readiness after restart"
for _ in $(seq 1 200); do
  dashboard_count_after="$(grep -c 'dashboard loaded' "$log")"
  [[ "$dashboard_count_after" -gt "$dashboard_count_before" ]] && break
  sleep 0.1
done
[[ "${dashboard_count_after:-0}" -gt "$dashboard_count_before" ]] ||
  fail "embedded dashboard did not reload after relay restart"
new_port="$(port_from_log)"
curl -fsS --max-time 3 "http://127.0.0.1:$new_port/healthz" | grep -q '"status":"ok"' ||
  fail "restarted relay is not healthy"

echo "Checking single-instance activation..."
env HIGHLITE_DESKTOP_APP_ID="$app_id" \
  HIGHLITE_DESKTOP_CONFIG_DIR="$config" \
  HIGHLITE_DESKTOP_DATA_DIR="$data" \
  HIGHLITE_RELAY_BIN="$relay" \
  timeout 10s "$shell" >"$tmp/second.log" 2>&1 ||
  fail "second instance did not exit cleanly"
kill -0 "$app_pid" 2>/dev/null || fail "primary instance exited after duplicate launch"
[[ "$(pgrep -P "$app_pid" -x highlite-relay | wc -l)" -eq 1 ]] ||
  fail "duplicate launch produced more than one owned relay"

echo "Stopping shell and verifying owned relay cleanup..."
kill -TERM "$app_pid"
for _ in $(seq 1 80); do kill -0 "$app_pid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$app_pid" 2>/dev/null && fail "shell did not stop on SIGTERM"
wait_for "owned relay cleanup" bash -c "! pgrep -P $app_pid -x highlite-relay >/dev/null"
app_pid=""

echo "PASS"
echo "  port: $port -> $new_port"
echo "  tray: $sni (host: $tray_host)"
echo "  artifacts: $tmp"
