#!/usr/bin/env bash
# Local macOS integration test: install both supported agents in one throwaway
# Apple container and verify that each can retain its own ios-build MCP config.
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$DIR/xcbox-lib.sh"

command -v container >/dev/null 2>&1 || { echo "FAIL: Apple container CLI is required" >&2; exit 1; }
container ls >/dev/null 2>&1 || container system start

T=$(mktemp -d)
NAME="xcbox-agent-smoke-$$"
cleanup() {
  container stop "$NAME" >/dev/null 2>&1 || true
  container rm "$NAME" >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT INT TERM

mkdir -p "$T/home"
chmod 700 "$T/home"
container run -d --name "$NAME" -v "$T/home:/root" "$XCBOX_IMAGE" sleep infinity >/dev/null

for agent in claude codex; do
  ensure_agent "$NAME" "$agent" 0
  register_mcp "$NAME" "$agent"
  version=$(agent_version "$NAME" "$agent")
  [ -n "$version" ] || { echo "FAIL: $agent version probe failed" >&2; exit 1; }
  agent_mcp_registered "$NAME" "$agent" || { echo "FAIL: $agent MCP registration failed" >&2; exit 1; }
  echo "$agent OK: $version; ios-build MCP registered"
done

# Installing/configuring the second agent must not remove the first one's CLI
# or MCP entry from the shared, project-isolated home.
agent_version "$NAME" claude >/dev/null
agent_mcp_registered "$NAME" claude
echo "agent container OK: Claude Code and Codex coexist with independent MCP state"
