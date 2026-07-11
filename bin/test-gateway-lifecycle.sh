#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

TEST_HOME=$(mktemp -d)
export XCBOX_HOME="$TEST_HOME"
export GATEWAY_PORT="${XCBOX_TEST_GATEWAY_PORT:-18766}"
export XCBOX_GATEWAY_PROCESS_PATTERN=xcbox-lifecycle-gateway
. "$DIR/xcbox-lib.sh"

GATEWAY_CMD="node -e 'const http=require(\"node:http\"); http.createServer((req,res)=>res.end(req.url===\"/healthz\"?\"ok\":\"not found\")).listen($GATEWAY_PORT,\"127.0.0.1\")' xcbox-lifecycle-gateway"

cleanup() {
  stop_gateway >/dev/null 2>&1 || true
  rm -rf "$TEST_HOME"
}
trap cleanup EXIT

assert_started() {
  local recorded listener
  recorded=$(cat "$XCBOX_HOME/gateway.pid")
  listener=$(gateway_listener_pid)
  [ "$recorded" = "$listener" ] || { echo "FAIL: recorded pid $recorded != listener pid $listener"; exit 1; }
  gateway_alive || { echo "FAIL: recorded gateway is not verified"; exit 1; }
  gateway_up || { echo "FAIL: gateway health check failed"; exit 1; }
}

ensure_gateway
assert_started
stop_gateway
[ -z "$(gateway_listener_pid 2>/dev/null || true)" ] || { echo "FAIL: listener survived stop"; exit 1; }
[ ! -e "$XCBOX_HOME/gateway.pid" ] || { echo "FAIL: pid metadata survived stop"; exit 1; }
[ ! -e "$XCBOX_HOME/gateway.launcher.pid" ] || { echo "FAIL: launcher metadata survived stop"; exit 1; }

ensure_gateway
assert_started
stop_gateway
[ -z "$(gateway_listener_pid 2>/dev/null || true)" ] || { echo "FAIL: listener survived second stop"; exit 1; }

# A process that stays alive but never opens the health endpoint must be killed
# when startup times out, with no ownership metadata left behind.
TIMEOUT_PID_FILE="$TEST_HOME/timeout.pid"
# Read dynamically by ensure_gateway from the sourced helper library.
# shellcheck disable=SC2034
GATEWAY_START_ATTEMPTS=2
# shellcheck disable=SC2034
GATEWAY_START_DELAY=0.1
# shellcheck disable=SC2034
GATEWAY_CMD="node -e 'require(\"node:fs\").writeFileSync(\"$TIMEOUT_PID_FILE\",String(process.pid)); setInterval(()=>{},1000)' xcbox-lifecycle-gateway"
if ensure_gateway; then echo "FAIL: gateway without a listener did not time out"; exit 1; fi
TIMEOUT_PID=$(cat "$TIMEOUT_PID_FILE")
if kill -0 "$TIMEOUT_PID" 2>/dev/null; then echo "FAIL: timed-out gateway launcher survived"; exit 1; fi
[ ! -e "$XCBOX_HOME/gateway.pid" ] || { echo "FAIL: timed-out startup left pid metadata"; exit 1; }
[ ! -e "$XCBOX_HOME/gateway.launcher.pid" ] || { echo "FAIL: timed-out startup left launcher metadata"; exit 1; }

echo "gateway lifecycle OK: start → stop → restart → stop; timeout cleanup; foreign-pid safety"
