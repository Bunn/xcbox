#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export XCBOX_HOME="$T/state"
export XCBOX_BOX_HOME_ROOT="$XCBOX_HOME/boxes"
. "$DIR/xcbox-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Simulate the shared home used by older releases. Only login/preferences should
# seed new homes; mutable history, caches, and gateway control state must not.
mkdir -p "$XCBOX_HOME/.claude" "$XCBOX_HOME/.npm"
printf '%s\n' '{"claudeAiOauth":{"accessToken":"legacy"}}' > "$XCBOX_HOME/.claude/.credentials.json"
printf '%s\n' '{"theme":"dark"}' > "$XCBOX_HOME/.claude/settings.json"
printf '%s\n' '{"permissions":{"allow":["/secret"]}}' > "$XCBOX_HOME/.claude/remote-settings.json"
printf '%s\n' '{"hasCompletedOnboarding":true,"projects":{"/secret":{}},"githubRepoPaths":{"repo":"/secret"},"mcpServers":{"old":{}}}' > "$XCBOX_HOME/.claude.json"
printf '%s\n' 'legacy history' > "$XCBOX_HOME/.claude/history.jsonl"
printf '%s\n' 'global cache' > "$XCBOX_HOME/.npm/cache"
printf '%s\n' '123' > "$XCBOX_HOME/gateway.pid"
touch -t 202001010000 "$XCBOX_HOME/.claude/.credentials.json"

ensure_box_home xcbox-alpha >/dev/null
ALPHA=$(box_home_dir xcbox-alpha)
[ -f "$ALPHA/.xcbox-home-version" ] || fail "alpha home was not initialized"
cmp -s "$XCBOX_HOME/.claude/.credentials.json" "$ALPHA/.claude/.credentials.json" || fail "login was not seeded"
cmp -s "$XCBOX_HOME/.claude/settings.json" "$ALPHA/.claude/settings.json" || fail "user preferences were not seeded"
[ ! -e "$ALPHA/.claude/remote-settings.json" ] || fail "remote permission state leaked into alpha"
[ ! -e "$ALPHA/.claude/history.jsonl" ] || fail "Claude history leaked into alpha"
[ ! -e "$ALPHA/.npm/cache" ] || fail "npm cache leaked into alpha"
[ ! -e "$ALPHA/gateway.pid" ] || fail "gateway state leaked into alpha"
node -e '
  const c = require(process.argv[1]);
  if (!c.hasCompletedOnboarding || c.projects || c.githubRepoPaths || c.mcpServers) process.exit(1);
' "$ALPHA/.claude.json" || fail "root Claude config was not sanitized"

# The freshest credentials seed future boxes, but each box receives a copy and
# later mutations stay private.
printf '%s\n' '{"claudeAiOauth":{"accessToken":"alpha-new"}}' > "$ALPHA/.claude/.credentials.json"
touch -t 203001010000 "$ALPHA/.claude/.credentials.json"
ensure_box_home xcbox-beta >/dev/null
BETA=$(box_home_dir xcbox-beta)
cmp -s "$ALPHA/.claude/.credentials.json" "$BETA/.claude/.credentials.json" || fail "beta did not receive freshest login"
printf '%s\n' '{"claudeAiOauth":{"accessToken":"beta-only"}}' > "$BETA/.claude/.credentials.json"
grep -q alpha-new "$ALPHA/.claude/.credentials.json" || fail "beta mutation changed alpha credentials"
grep -q legacy "$XCBOX_HOME/.claude/.credentials.json" || fail "box mutation changed legacy credentials"

# A marked home is never re-seeded over its independently mutated state.
ensure_box_home xcbox-alpha >/dev/null
grep -q alpha-new "$ALPHA/.claude/.credentials.json" || fail "repeat initialization overwrote alpha"

# Inspect parsing and isolation compare the actual /root source with the exact
# per-box path.
INSPECT_SOURCE="$ALPHA"
container() {
  [ "$1" = inspect ] || return 1
  printf '[{"id":"%s","configuration":{"mounts":[{"destination":"/root","source":"%s"}]}}]\n' "$2" "$INSPECT_SOURCE"
}
[ "$(box_root_mount_source xcbox-alpha)" = "$ALPHA" ] || fail "could not parse /root mount source"
box_home_isolated xcbox-alpha || fail "isolated mount was rejected"
INSPECT_SOURCE="$XCBOX_HOME"
if box_home_isolated xcbox-alpha; then fail "shared home mount was accepted"; fi
unset -f container

# New boxes mount only their own home. Existing boxes with a mismatched mount
# are refused instead of being started with shared state.
PROJECT="$T/project"
mkdir -p "$PROJECT"
CAPTURE="$T/container-run.args"
box_exists() { return 1; }
container() {
  [ "$1" = run ] || return 1
  printf '%s\n' "$@" > "$CAPTURE"
}
ensure_box xcbox-new "$PROJECT" >/dev/null
NEW_HOME=$(box_home_dir xcbox-new)
grep -Fxq "$NEW_HOME:/root" "$CAPTURE" || fail "new box did not mount its isolated home"
if grep -Fxq "$XCBOX_HOME:/root" "$CAPTURE"; then fail "new box mounted shared global state"; fi
unset -f container box_exists

# A legacy/shared agent could have left a symlink under boxes/. Never follow it
# into an unintended host path when preparing a future /root mount.
mkdir -p "$T/outside"
ln -s "$T/outside" "$XCBOX_BOX_HOME_ROOT/xcbox-link"
if ensure_box_home xcbox-link >"$T/link.out" 2>"$T/link.err"; then
  fail "symlinked box home was accepted"
fi
grep -q "unsafe box home path" "$T/link.err" || fail "unsafe home path was not explained"
mkdir -p "$XCBOX_BOX_HOME_ROOT/xcbox-partial"
printf '%s\n' unexpected > "$XCBOX_BOX_HOME_ROOT/xcbox-partial/file"
if ensure_box_home xcbox-partial >"$T/partial.out" 2>"$T/partial.err"; then
  fail "non-empty uninitialized box home was accepted"
fi
grep -q "is not empty" "$T/partial.err" || fail "partial home was not explained"

box_exists() { return 0; }
box_home_isolated() { return 1; }
box_root_mount_source() { printf '%s\n' "$XCBOX_HOME"; }
if ensure_box xcbox-shared "$PROJECT" >"$T/migration.out" 2>"$T/migration.err"; then
  fail "existing shared-home box was accepted"
fi
grep -q "cannot be changed in place" "$T/migration.err" || fail "shared-home migration was not explained"
unset -f box_exists box_home_isolated box_root_mount_source

echo "box home OK: isolated mounts, credential seeding, state separation, safe migration"
