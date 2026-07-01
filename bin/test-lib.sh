#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$DIR/xcbox-lib.sh"

# --- explicit function-existence assertions (honest RED: undefined fns inside
# `if` are masked and silently evaluate false, which would hide a missing fn) ---
for fn in box_exists box_running ensure_box ensure_agent carry_git_identity register_mcp gateway_alive repo_mount_root; do
  declare -F "$fn" >/dev/null || { echo "FAIL: $fn not defined"; exit 1; }
done

# --- repo_mount_root: a subdir of a git repo resolves to the repo toplevel;
# a non-repo dir resolves to itself (so .git is always inside the box mount) ---
RT=$(mktemp -d)
( cd "$RT" && git init -q && mkdir -p sub/dir )
RT_TOP=$(cd "$RT/sub/dir" && git rev-parse --show-toplevel)   # git's own canonical toplevel
[ "$(repo_mount_root "$RT/sub/dir")" = "$RT_TOP" ] || { echo "FAIL: repo_mount_root subdir: $(repo_mount_root "$RT/sub/dir") != $RT_TOP"; exit 1; }
NR=$(mktemp -d)
[ "$(repo_mount_root "$NR")" = "$NR" ] || { echo "FAIL: repo_mount_root non-repo: $(repo_mount_root "$NR") != $NR"; exit 1; }
rm -rf "$RT" "$NR"

# --- sanitize_name: lowercases, replaces unsafe chars, no trailing dash ---
[ "$(sanitize_name /tmp/My.App)" = "xcbox-my.app" ] || { echo "FAIL: sanitize_name unexpected: $(sanitize_name /tmp/My.App)"; exit 1; }

# --- box_exists is false for a bogus name (no match), and does not error ---
if box_exists "xcbox-definitely-not-a-real-box-xyz"; then echo "FAIL: box_exists matched a bogus name"; exit 1; fi

# --- gateway_alive: false when pid file points at a dead process ---
TMPHOME=$(mktemp -d); export XCBOX_HOME="$TMPHOME"
( exit 0 ) & DEAD=$!; wait "$DEAD" 2>/dev/null || true
echo "$DEAD" > "$XCBOX_HOME/gateway.pid"
if gateway_alive; then echo "FAIL: gateway_alive true for dead pid $DEAD"; exit 1; fi

# --- ensure_gateway: a failing GATEWAY_CMD fails fast AND leaves a non-empty log ---
export GATEWAY_PORT=8791   # unlikely to be in use; gateway_up returns fast (conn refused)
export GATEWAY_CMD="sh -c 'echo BOOMERR >&2; exit 7'"
if ensure_gateway; then echo "FAIL: ensure_gateway returned success for a failing command"; exit 1; fi
grep -q BOOMERR "$XCBOX_HOME/gateway.log" || { echo "FAIL: failed start left no diagnostic in gateway.log"; exit 1; }
rm -rf "$TMPHOME"

echo "lib OK: sanitize_name, box_exists, gateway_alive, ensure_gateway failure visibility"
