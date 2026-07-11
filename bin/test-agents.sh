#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

export XCBOX_HOME="$T/state"
export XCBOX_PROJECT_METADATA_ROOT="$XCBOX_HOME/projects"
. "$DIR/xcbox-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

valid_agent claude || fail "claude was rejected"
valid_agent codex || fail "codex was rejected"
if valid_agent other; then fail "unknown agent was accepted"; fi
[ "$(agent_binary claude)" = claude ] || fail "Claude binary mapping is wrong"
[ "$(agent_binary codex)" = codex ] || fail "Codex binary mapping is wrong"
[ "$(agent_install_spec claude 0)" = '@anthropic-ai/claude-code@2.1.207' ] || fail "Claude pin is wrong"
[ "$(agent_install_spec codex 0)" = '@openai/codex@0.144.1' ] || fail "Codex pin is wrong"
[ "$(agent_install_spec claude 1)" = '@anthropic-ai/claude-code@latest' ] || fail "Claude update is not explicit latest"
[ "$(agent_install_spec codex 1)" = '@openai/codex@latest' ] || fail "Codex update is not explicit latest"
[ "$(codex_platform_install_spec 0)" = '@openai/codex-linux-arm64@npm:@openai/codex@0.144.1-linux-arm64' ] || fail "Codex platform pin is wrong"
[ "$(codex_platform_install_spec 1)" = '@openai/codex-linux-arm64@npm:@openai/codex@linux-arm64' ] || fail "Codex platform update is wrong"

NAME=xcbox-agent-test
record_box_agent "$NAME" claude
[ "$(read_box_agent "$NAME")" = claude ] || fail "saved Claude selection was not read"
[ "$(resolve_agent "$NAME" '')" = claude ] || fail "saved selection was not reused"
[ "$(XCBOX_AGENT=codex resolve_agent "$NAME" '')" = codex ] || fail "XCBOX_AGENT did not override saved selection"
[ "$(XCBOX_AGENT=codex resolve_agent "$NAME" claude)" = claude ] || fail "explicit agent did not take precedence"
[ "$(printf '2\n' | prompt_agent)" = codex ] || fail "interactive Codex choice failed"
record_box_agent "$NAME" codex
[ "$(read_box_agent "$NAME")" = codex ] || fail "switch to Codex was not remembered"

if resolve_agent xcbox-new '' >/dev/null 2>"$T/noninteractive.err"; then
  fail "missing non-interactive selection was accepted"
fi
grep -q -- '--agent claude or --agent codex' "$T/noninteractive.err" || fail "non-interactive guidance is missing"

BAD="$XCBOX_PROJECT_METADATA_ROOT/$NAME.agent"
rm -f "$BAD"
ln -s "$T/elsewhere" "$BAD"
if record_box_agent "$NAME" codex >/dev/null 2>"$T/unsafe.err"; then
  fail "symlinked agent metadata was accepted"
fi
grep -q 'unsafe agent metadata file' "$T/unsafe.err" || fail "unsafe agent metadata was not explained"
rm -f "$BAD"

CALLS="$T/container.calls"
container() {
  printf '%s\n' "$*" >> "$CALLS"
  case "$*" in
    *'claude --version'*) [ "${CLAUDE_TEST_RC:-0}" = 0 ] && printf '2.1.207 (Claude Code)\n'; return "${CLAUDE_TEST_RC:-0}" ;;
    *'codex --version'*) [ "${CODEX_TEST_RC:-0}" = 0 ] && printf 'codex-cli 0.144.1\n'; return "${CODEX_TEST_RC:-0}" ;;
    *'claude mcp list'*) printf 'ios-build\n' ;;
    *'codex mcp list'*) printf 'ios-build enabled\n' ;;
  esac
  return 0
}

: > "$CALLS"
CLAUDE_TEST_RC=1 ensure_agent box claude 0
grep -Fq 'npm install -g @anthropic-ai/claude-code@2.1.207' "$CALLS" || fail "Claude was not installed at its pin"

: > "$CALLS"
CODEX_TEST_RC=1 ensure_agent box codex 0
grep -Fq 'npm install -g @openai/codex@0.144.1 @openai/codex-linux-arm64@npm:@openai/codex@0.144.1-linux-arm64' "$CALLS" || fail "Codex and its Linux ARM64 binary were not installed at their pins"

: > "$CALLS"
CODEX_TEST_RC=0 ensure_agent box codex 0
if grep -Fq 'npm install' "$CALLS"; then fail "installed Codex was reinstalled"; fi

: > "$CALLS"
CODEX_TEST_RC=0 ensure_agent box codex 1
grep -Fq 'npm install -g @openai/codex@latest @openai/codex-linux-arm64@npm:@openai/codex@linux-arm64' "$CALLS" || fail "Codex update did not request matching latest packages"

: > "$CALLS"
register_mcp box claude
grep -Fq '/root/.npm-global/bin/claude mcp add --scope user --transport http ios-build http://host.container.internal:8765/mcp' "$CALLS" || fail "Claude MCP registration is wrong"

: > "$CALLS"
register_mcp box codex
grep -Fq '/root/.npm-global/bin/codex mcp add ios-build --url http://host.container.internal:8765/mcp' "$CALLS" || fail "Codex MCP registration is wrong"

[ "$(agent_version box codex)" = 'codex-cli 0.144.1' ] || fail "Codex version probe failed"
agent_mcp_registered box claude || fail "Claude MCP status probe failed"
agent_mcp_registered box codex || fail "Codex MCP status probe failed"

mkdir -p "$T/App/App.xcodeproj"
if PROJECT="$T/App" "$DIR/xcbox" --agent other >/dev/null 2>"$T/invalid-cli.err"; then
  fail "CLI accepted an unsupported agent"
fi
grep -q "unsupported agent 'other'" "$T/invalid-cli.err" || fail "CLI did not explain the unsupported agent"

echo "agents OK: prompt, project memory, overrides, pinned installs, updates, Claude/Codex MCP"
