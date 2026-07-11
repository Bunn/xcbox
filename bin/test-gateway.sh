#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$DIR/xcbox-lib.sh"
ensure_gateway
# Security regression: verify xcbox's built-in bridge listens only on IPv4 loopback.
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
if XCBOX_MCP_PROBE_GET=1 node "$DIR/mcp-call.js" "$URL" '[{"method":"tools/list","params":{}}]' | grep -qiE 'build_sim|discover_projs|simulator'; then
  echo "gateway OK"
else
  echo "no tools (gateway not serving MCP over a session)"; exit 1
fi

# State must persist across multiple calls in one HTTP session.
STATE=$(node "$DIR/mcp-call.js" "$URL" '[
  {"method":"tools/call","params":{"name":"session_set_defaults","arguments":{"scheme":"XcboxBridgeSentinel"}}},
  {"method":"tools/call","params":{"name":"session_show_defaults","arguments":{}}}
]')
echo "$STATE" | grep -q "XcboxBridgeSentinel" || { echo "gateway session state did not persist"; echo "$STATE"; exit 1; }

# Two clients get independent stdio children and can make progress concurrently.
P1=$(mktemp); P2=$(mktemp)
node "$DIR/mcp-call.js" "$URL" '[{"method":"tools/list","params":{}}]' >"$P1" 2>&1 & PID1=$!
node "$DIR/mcp-call.js" "$URL" '[{"method":"tools/list","params":{}}]' >"$P2" 2>&1 & PID2=$!
wait "$PID1" || { cat "$P1"; rm -f "$P1" "$P2"; exit 1; }
wait "$PID2" || { cat "$P2"; rm -f "$P1" "$P2"; exit 1; }
grep -qiE 'build_sim|discover_projs|simulator' "$P1" && grep -qiE 'build_sim|discover_projs|simulator' "$P2" \
  || { echo "parallel gateway sessions failed"; cat "$P1" "$P2"; rm -f "$P1" "$P2"; exit 1; }
rm -f "$P1" "$P2"
echo "gateway state + parallel sessions OK"
