#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$DIR/xcbox-lib.sh"

# --- explicit function-existence assertions (honest RED: undefined fns inside
# `if` are masked and silently evaluate false, which would hide a missing fn) ---
for fn in box_exists box_running ensure_box ensure_agent carry_git_identity register_mcp node_supported runtime_lock_hash runtime_locked_package_version runtime_package_version runtime_ready ensure_runtime gateway_alive gateway_bind_matches gateway_listener_pid gateway_pid_is_ours stop_gateway canonical_path repo_mount_root find_xcode_project_dirs find_swift_package_dirs discover_project_dirs resolve_project_dir require_project_dir project_context_dir legacy_box_name sanitize_name legacy_box_detected gateway_bind_is_loopback container_host_bridge_configured ensure_container_gateway_route; do
  declare -F "$fn" >/dev/null || { echo "FAIL: $fn not defined"; exit 1; }
done

# --- repo_mount_root: a subdir of a git repo resolves to the repo toplevel;
# a non-repo dir resolves to itself (so .git is always inside the box mount) ---
RT=$(mktemp -d)
( cd "$RT" && git init -q && mkdir -p sub/dir )
RT_TOP=$(cd "$RT/sub/dir" && git rev-parse --show-toplevel)   # git's own canonical toplevel
[ "$(repo_mount_root "$RT/sub/dir")" = "$RT_TOP" ] || { echo "FAIL: repo_mount_root subdir: $(repo_mount_root "$RT/sub/dir") != $RT_TOP"; exit 1; }
NR=$(mktemp -d)
NR_CANONICAL=$(canonical_path "$NR")
[ "$(repo_mount_root "$NR")" = "$NR_CANONICAL" ] || { echo "FAIL: repo_mount_root non-repo: $(repo_mount_root "$NR") != $NR_CANONICAL"; exit 1; }
rm -rf "$RT" "$NR"

# --- sanitize_name: readable slug plus a stable collision-resistant suffix ---
SANITIZED=$(sanitize_name /tmp/My.App)
case "$SANITIZED" in
  xcbox-my.app-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) echo "FAIL: sanitize_name unexpected: $SANITIZED"; exit 1 ;;
esac
[ "$SANITIZED" = "$(sanitize_name /tmp/My.App)" ] || { echo "FAIL: sanitize_name is unstable"; exit 1; }

# --- box_exists is false for a bogus name (no match), and does not error ---
if box_exists "xcbox-definitely-not-a-real-box-xyz"; then echo "FAIL: box_exists matched a bogus name"; exit 1; fi

# --- safe gateway defaults + Apple container localhost DNS bridge detection ---
gateway_bind_is_loopback || { echo "FAIL: default gateway bind is not loopback"; exit 1; }
[ -x "$GATEWAY_SCRIPT" ] || { echo "FAIL: built-in gateway is missing or not executable"; exit 1; }
case "$GATEWAY_CMD_DEFAULT" in
  *supergateway*|*npx*) echo "FAIL: default gateway command still uses an external bridge"; exit 1 ;;
esac
container() {
  if [ "$*" = "system dns list" ]; then
    printf 'DOMAIN\nhost.container.internal\n'
    return 0
  fi
  return 1
}
container_host_bridge_configured || { echo "FAIL: configured localhost DNS bridge not detected"; exit 1; }
ensure_container_gateway_route || { echo "FAIL: configured localhost DNS bridge rejected"; exit 1; }
container() {
  if [ "$*" = "system dns list" ]; then printf 'DOMAIN\n'; return 0; fi
  return 1
}
if container_host_bridge_configured; then echo "FAIL: missing localhost DNS bridge accepted"; exit 1; fi
if ensure_container_gateway_route >/dev/null 2>&1; then echo "FAIL: missing localhost DNS bridge route accepted"; exit 1; fi
unset -f container

# --- gateway_alive: false when pid file points at a dead process ---
TMPHOME=$(mktemp -d); export XCBOX_HOME="$TMPHOME"
printf '%s\n' "$GATEWAY_BIND_HOST:$GATEWAY_PORT" > "$XCBOX_HOME/gateway.bind"
gateway_bind_matches || { echo "FAIL: recorded gateway bind not recognized"; exit 1; }
printf '%s\n' "0.0.0.0:$GATEWAY_PORT" > "$XCBOX_HOME/gateway.bind"
if gateway_bind_matches; then echo "FAIL: unsafe recorded gateway bind accepted"; exit 1; fi
( exit 0 ) & DEAD=$!; wait "$DEAD" 2>/dev/null || true
echo "$DEAD" > "$XCBOX_HOME/gateway.pid"
if gateway_alive; then echo "FAIL: gateway_alive true for dead pid $DEAD"; exit 1; fi

# --- ensure_gateway: a failing GATEWAY_CMD fails fast AND leaves a non-empty log ---
export GATEWAY_PORT=8791   # unlikely to be in use; gateway_up returns fast (conn refused)
export GATEWAY_CMD="sh -c 'echo BOOMERR >&2; exit 7'"
if ensure_gateway; then echo "FAIL: ensure_gateway returned success for a failing command"; exit 1; fi
grep -q BOOMERR "$XCBOX_HOME/gateway.log" || { echo "FAIL: failed start left no diagnostic in gateway.log"; exit 1; }

# --- stop_gateway refuses to signal an unrelated live pid ---
echo "$$" > "$XCBOX_HOME/gateway.pid"
if stop_gateway >/dev/null 2>&1; then echo "FAIL: stop_gateway accepted an unrelated pid"; exit 1; fi
kill -0 "$$" 2>/dev/null || { echo "FAIL: stop_gateway signaled an unrelated pid"; exit 1; }
rm -rf "$TMPHOME"

echo "lib OK: safe gateway route, canonical identity, box_exists, gateway_alive, ensure_gateway failure visibility"
