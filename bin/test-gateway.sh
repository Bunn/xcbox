#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$DIR/xcbox-lib.sh"
ensure_gateway
# ensure_gateway confirms liveness via /healthz. Now confirm the MCP endpoint answers a
# real (stateful) session — initialize + tools/list must return XcodeBuildMCP's tools —
# using the same session-aware client (mcp-call.js) the agent/harness use.
URL="http://127.0.0.1:${GATEWAY_PORT:-8765}${MCP_ENDPOINT:-/mcp}"
if node "$DIR/mcp-call.js" "$URL" '[{"method":"tools/list","params":{}}]' | grep -qiE 'build_sim|discover_projs|simulator'; then
  echo "gateway OK"
else
  echo "no tools (gateway not serving MCP over a session)"; exit 1
fi
