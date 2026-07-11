#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$DIR/xcbox-lib.sh"
ensure_gateway
# Security regression: Supergateway itself has no effective host-bind option,
# so verify xcbox's preload forced the live listener onto IPv4 loopback.
LISTENER=$(lsof -nP -iTCP:"$GATEWAY_PORT" -sTCP:LISTEN 2>/dev/null || true)
echo "$LISTENER" | grep -qF "TCP 127.0.0.1:$GATEWAY_PORT (LISTEN)" || {
  echo "gateway is not loopback-only:"; echo "$LISTENER"; exit 1
}
RECORDED_PID=$(cat "$XCBOX_HOME/gateway.pid")
[ "$RECORDED_PID" = "$(gateway_listener_pid)" ] && gateway_pid_is_ours "$RECORDED_PID" || {
  echo "gateway.pid does not identify the verified listener"; exit 1
}
# ensure_gateway confirms liveness via /healthz. Now confirm the MCP endpoint answers a
# real (stateful) session — initialize + tools/list must return XcodeBuildMCP's tools —
# using the same session-aware client (mcp-call.js) the agent/harness use.
URL="http://127.0.0.1:${GATEWAY_PORT:-8765}${MCP_ENDPOINT:-/mcp}"
if node "$DIR/mcp-call.js" "$URL" '[{"method":"tools/list","params":{}}]' | grep -qiE 'build_sim|discover_projs|simulator'; then
  echo "gateway OK"
else
  echo "no tools (gateway not serving MCP over a session)"; exit 1
fi
