# xcbox shared helpers. Source this; do not execute.
# Values confirmed by the Task 1 spike:
XCBOX_LIB_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
XCBOX_ROOT="${XCBOX_RUNTIME_ROOT:-$(cd -P "$XCBOX_LIB_DIR/.." >/dev/null 2>&1 && pwd)}"
XCBOX_HOME="${XCBOX_HOME:-$HOME/.xcbox-home}"
GATEWAY_PORT="${GATEWAY_PORT:-8765}"
MCP_ENDPOINT="${MCP_ENDPOINT:-/mcp}"
# Keep the unauthenticated gateway off physical network interfaces. Apple
# container's localhost DNS bridge makes this loopback listener reachable from
# boxes as host.container.internal without exposing it to the LAN.
GATEWAY_BIND_HOST="${XCBOX_GATEWAY_BIND_HOST:-127.0.0.1}"
GATEWAY_HOST="${XCBOX_GATEWAY_HOST:-host.container.internal}"
GATEWAY_LOCALHOST_IP="${XCBOX_GATEWAY_LOCALHOST_IP:-203.0.113.113}"
GATEWAY_CONTAINER_URL="http://$GATEWAY_HOST:$GATEWAY_PORT$MCP_ENDPOINT"
GATEWAY_SCRIPT="$XCBOX_LIB_DIR/xcbox-gateway.mjs"
GATEWAY_PROCESS_PATTERN="${XCBOX_GATEWAY_PROCESS_PATTERN:-xcbox-gateway.mjs}"
GATEWAY_START_ATTEMPTS="${XCBOX_GATEWAY_START_ATTEMPTS:-60}"
GATEWAY_START_DELAY="${XCBOX_GATEWAY_START_DELAY:-2}"
PROJECT_DISCOVERY_DEPTH="${XCBOX_PROJECT_DISCOVERY_DEPTH:-4}"
RUNTIME_LOCKFILE="$XCBOX_ROOT/package-lock.json"
RUNTIME_STAMP="$XCBOX_ROOT/node_modules/.xcbox-lock-sha256"
XCODEBUILDMCP_BIN="$XCBOX_ROOT/node_modules/.bin/xcodebuildmcp"
# xcbox-gateway owns the stateful HTTP transport and launches one stdio
# XcodeBuildMCP child per MCP session.
GATEWAY_CMD_DEFAULT='"$XCBOX_NODE_BIN" "$XCBOX_GATEWAY_SCRIPT"'
GATEWAY_CMD="${GATEWAY_CMD:-$GATEWAY_CMD_DEFAULT}"

runtime_lock_hash() {
  [ -f "$RUNTIME_LOCKFILE" ] || return 1
  shasum -a 256 "$RUNTIME_LOCKFILE" 2>/dev/null | awk '{print $1}'
}

node_supported() {
  command -v node >/dev/null 2>&1 && node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 20 ? 0 : 1)' 2>/dev/null
}

runtime_locked_package_version() {
  local package_name="$1"
  node -e '
    const fs = require("node:fs");
    const lock = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const entry = lock.packages?.[`node_modules/${process.argv[2]}`];
    if (!entry?.version) process.exit(1);
    process.stdout.write(entry.version);
  ' "$RUNTIME_LOCKFILE" "$package_name" 2>/dev/null
}

runtime_package_version() {
  local package_name="$1"
  node -e '
    const fs = require("node:fs");
    const packagePath = process.argv[1];
    process.stdout.write(JSON.parse(fs.readFileSync(packagePath, "utf8")).version);
  ' "$XCBOX_ROOT/node_modules/$package_name/package.json" 2>/dev/null
}

runtime_ready() {
  local expected installed
  expected=$(runtime_lock_hash) || return 1
  installed=$(cat "$RUNTIME_STAMP" 2>/dev/null) || return 1
  [ "$installed" = "$expected" ] &&
    [ -x "$XCODEBUILDMCP_BIN" ] &&
    [ -r "$GATEWAY_SCRIPT" ] &&
    [ "$(runtime_package_version @modelcontextprotocol/sdk)" = "$(runtime_locked_package_version @modelcontextprotocol/sdk)" ] &&
    [ "$(runtime_package_version xcodebuildmcp)" = "$(runtime_locked_package_version xcodebuildmcp)" ]
}

ensure_runtime() {
  local install_lock="$XCBOX_HOME/runtime-install.lock" acquired="" expected i lock_pid
  runtime_ready && return 0
  node_supported || { echo "ERROR: Node.js 20+ is required to install the gateway runtime." >&2; return 1; }
  command -v npm >/dev/null 2>&1 || { echo "ERROR: npm is required to install the gateway runtime." >&2; return 1; }
  mkdir -p "$XCBOX_HOME"

  for i in $(seq 1 120); do
    if mkdir "$install_lock" 2>/dev/null; then acquired=1; break; fi
    runtime_ready && return 0
    lock_pid=$(cat "$install_lock/pid" 2>/dev/null || true)
    if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
      rm -f "$install_lock/pid"
      rmdir "$install_lock" 2>/dev/null || true
      continue
    fi
    sleep 0.5
  done
  if [ -z "$acquired" ]; then
    echo "ERROR: timed out waiting for another xcbox runtime installation; remove $install_lock if it is stale." >&2
    return 1
  fi
  printf '%s\n' "$$" > "$install_lock/pid"

  echo "==> installing pinned gateway runtime from package-lock.json"
  if ! npm --prefix "$XCBOX_ROOT" ci --omit=dev; then
    rm -f "$install_lock/pid"; rmdir "$install_lock" 2>/dev/null || true
    echo "ERROR: could not install the pinned gateway runtime." >&2
    return 1
  fi
  expected=$(runtime_lock_hash) || {
    rm -f "$install_lock/pid"; rmdir "$install_lock" 2>/dev/null || true
    echo "ERROR: could not fingerprint package-lock.json." >&2
    return 1
  }
  printf '%s\n' "$expected" > "$RUNTIME_STAMP"
  rm -f "$install_lock/pid"; rmdir "$install_lock" 2>/dev/null || true

  if ! runtime_ready; then
    echo "ERROR: npm ci completed but the pinned gateway binaries are unavailable." >&2
    return 1
  fi
  echo "==> gateway runtime ready (built-in bridge, MCP SDK $(runtime_package_version @modelcontextprotocol/sdk), xcodebuildmcp $(runtime_package_version xcodebuildmcp))"
}

gateway_bind_is_loopback() {
  case "$GATEWAY_BIND_HOST" in
    127.*|localhost|::1) return 0 ;;
    *) return 1 ;;
  esac
}

# True when Apple container has a DNS domain that forwards to host loopback.
# `container system dns list` prints a DOMAIN header followed by domain names.
container_host_bridge_configured() {
  container system dns list 2>/dev/null | awk -v host="$GATEWAY_HOST" '
    NR > 1 && $1 == host { found=1 }
    END { exit(found ? 0 : 1) }
  '
}

ensure_container_gateway_route() {
  if ! gateway_bind_is_loopback; then
    echo "WARNING: gateway bind override '$GATEWAY_BIND_HOST' may expose unauthenticated Xcode tools to the network." >&2
    return 0
  fi
  if container_host_bridge_configured; then return 0; fi
  cat >&2 <<EOF
xcbox: the loopback-only build gateway is not reachable from containers yet.
Configure Apple container's localhost DNS bridge once, then retry:

  sudo container system dns create $GATEWAY_HOST --localhost $GATEWAY_LOCALHOST_IP

The rule may need to be recreated after restarting Apple container or macOS.
EOF
  return 1
}

# True if DIR looks like an iOS/Xcode project (has any of: *.xcodeproj,
# *.xcworkspace, Package.swift). Accepts if ANY is present.
is_ios_project() {
  local dir="$1"
  compgen -G "$dir/*.xcodeproj"   >/dev/null 2>&1 && return 0
  compgen -G "$dir/*.xcworkspace" >/dev/null 2>&1 && return 0
  [ -e "$dir/Package.swift" ] && return 0
  return 1
}

canonical_path() {
  [ -d "$1" ] || return 1
  (cd -P "$1" >/dev/null 2>&1 && pwd)
}

repo_mount_root() {
  local dir root
  dir=$(canonical_path "$1") || return 1
  root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$root" ]; then canonical_path "$root"; else printf '%s\n' "$dir"; fi
}

find_xcode_project_dirs() {
  local root="$1" depth="$PROJECT_DISCOVERY_DEPTH"
  case "$depth" in ''|*[!0-9]*) depth=4 ;; esac
  find "$root" -mindepth 1 -maxdepth "$depth" \
    \( -type d \( -name .git -o -name node_modules -o -name .build -o -name .swiftpm -o -name DerivedData -o -name Pods -o -name Carthage -o -name vendor \) -prune \) -o \
    \( -type d \( -name '*.xcodeproj' -o -name '*.xcworkspace' \) -print -prune \) 2>/dev/null \
    | while IFS= read -r artifact; do canonical_path "$(dirname "$artifact")"; done \
    | LC_ALL=C sort -u
}

find_swift_package_dirs() {
  local root="$1" depth="$PROJECT_DISCOVERY_DEPTH"
  case "$depth" in ''|*[!0-9]*) depth=4 ;; esac
  find "$root" -mindepth 1 -maxdepth "$depth" \
    \( -type d \( -name .git -o -name node_modules -o -name .build -o -name .swiftpm -o -name DerivedData -o -name Pods -o -name Carthage -o -name vendor \) -prune \) -o \
    \( -type f -name Package.swift -print \) 2>/dev/null \
    | while IFS= read -r manifest; do canonical_path "$(dirname "$manifest")"; done \
    | LC_ALL=C sort -u
}

discover_project_dirs() {
  local root="$1" projects
  projects=$(find_xcode_project_dirs "$root") || return 1
  if [ -n "$projects" ]; then printf '%s\n' "$projects"; else find_swift_package_dirs "$root"; fi
}

# Resolve INPUT to one canonical project directory. Prefer the nearest ancestor
# that is itself a project; otherwise discover a unique project below the git
# root. Return 2 for ambiguity and 1 when no project can be found.
resolve_project_dir() {
  local input root dir projects count
  input=$(canonical_path "$1") || return 1
  root=$(git -C "$input" rev-parse --show-toplevel 2>/dev/null || true)
  if [ -z "$root" ]; then
    if is_ios_project "$input"; then printf '%s\n' "$input"; return 0; fi
    return 1
  fi
  root=$(canonical_path "$root") || return 1

  dir="$input"
  while :; do
    if is_ios_project "$dir"; then printf '%s\n' "$dir"; return 0; fi
    [ "$dir" = "$root" ] && break
    case "$dir/" in "$root/"*) dir=$(dirname "$dir") ;; *) break ;; esac
  done

  projects=$(discover_project_dirs "$root") || return 1
  count=$(printf '%s\n' "$projects" | awk 'NF { count++ } END { print count+0 }')
  if [ "$count" -eq 1 ]; then
    printf '%s\n' "$projects"
    return 0
  fi
  if [ "$count" -gt 1 ]; then
    echo "xcbox: multiple Xcode/Swift project directories found under $root:" >&2
    printf '%s\n' "$projects" | sed 's/^/  - /' >&2
    echo "Set PROJECT to the intended directory and retry." >&2
    return 2
  fi
  return 1
}

require_project_dir() {
  local input="$1" project rc canonical
  if project=$(resolve_project_dir "$input"); then
    printf '%s\n' "$project"
    return 0
  else
    rc=$?
  fi
  [ "$rc" -eq 2 ] && return 2
  canonical=$(canonical_path "$input" 2>/dev/null || printf '%s' "$input")
  echo "xcbox: no .xcodeproj/.xcworkspace/Package.swift found in or below $canonical — run me from an Xcode/Swift project." >&2
  return 1
}

# Informational commands remain useful outside a project, but ambiguity must
# never select an arbitrary box for status/stop/rm.
project_context_dir() {
  local input="$1" project rc
  if project=$(resolve_project_dir "$input"); then
    printf '%s\n' "$project"
    return 0
  else
    rc=$?
  fi
  [ "$rc" -eq 2 ] && return 2
  canonical_path "$input"
}

legacy_box_name() {
  printf 'xcbox-%s' "$(basename "$1" | tr -d '\n' | tr -c 'A-Za-z0-9_.-' '-' | tr '[:upper:]' '[:lower:]')"
}

# Container identity from the full canonical project path. The readable prefix
# aids `container ls`; the hash prevents same-basename collisions.
sanitize_name() {
  local path slug hash
  path=$(canonical_path "$1" 2>/dev/null || printf '%s' "$1")
  slug=$(basename "$path" | tr -d '\n' | tr -c 'A-Za-z0-9_.-' '-' | tr '[:upper:]' '[:lower:]' | cut -c1-40 | sed 's/[-._]*$//')
  [ -n "$slug" ] || slug=project
  hash=$(printf '%s' "$path" | shasum -a 256 | awk '{print substr($1,1,8)}')
  printf 'xcbox-%s-%s' "$slug" "$hash"
}

legacy_box_detected() {
  local project="$1" current_name="$2" legacy
  legacy=$(legacy_box_name "$project")
  [ "$legacy" != "$current_name" ] && ! box_exists "$current_name" && box_exists "$legacy"
}

print_legacy_box_migration() {
  local project="$1" current_name="$2" legacy
  legacy=$(legacy_box_name "$project")
  cat >&2 <<EOF
xcbox: legacy box '$legacy' exists for a basename matching this project.
xcbox now uses collision-safe identity '$current_name' and will not guess that
the legacy box belongs to $project.

Inspect it first, then migrate safely (the shared ~/.xcbox-home is preserved):
  container stop $legacy
  container rm $legacy
  xcbox up
EOF
}

# Liveness check via xcbox-gateway's health endpoint (returns "ok"). We do NOT
# probe an MCP method here: the gateway runs --stateful, where a sessionless
# request is rejected and an initialize would leak a session per call.
gateway_up() {
  node -e 'fetch("http://127.0.0.1:'"$GATEWAY_PORT"'/healthz").then(r=>r.text()).then(t=>process.exit(/ok/i.test(t)?0:1)).catch(()=>process.exit(1))' 2>/dev/null
}

# --- Box config (centralized so the CLI and harness share it) ---
XCBOX_IMAGE="${XCBOX_IMAGE:-node:22}"
INNER_PATH="${INNER_PATH:-/root/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
AGENT_INSTALL="${XCBOX_AGENT_INSTALL:-@anthropic-ai/claude-code}"

gateway_alive() {
  local pid
  pid=$(cat "$XCBOX_HOME/gateway.pid" 2>/dev/null) || return 1
  gateway_pid_is_ours "$pid"
}

gateway_bind_matches() {
  [ "$(cat "$XCBOX_HOME/gateway.bind" 2>/dev/null)" = "$GATEWAY_BIND_HOST:$GATEWAY_PORT" ]
}

gateway_listener_pid() {
  lsof -nP -t -iTCP:"$GATEWAY_PORT" -sTCP:LISTEN 2>/dev/null | sed -n '1p'
}

gateway_pid_is_ours() {
  local pid="${1:-}" listener
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o command= 2>/dev/null | grep -qF -- "$GATEWAY_PROCESS_PATTERN" || return 1
  listener=$(lsof -nP -a -p "$pid" -iTCP:"$GATEWAY_PORT" -sTCP:LISTEN 2>/dev/null) || return 1
  if gateway_bind_is_loopback; then
    printf '%s\n' "$listener" | grep -qF "TCP $GATEWAY_BIND_HOST:$GATEWAY_PORT (LISTEN)"
  else
    [ -n "$listener" ]
  fi
}

gateway_launcher_is_ours() {
  local pid="${1:-}"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o command= 2>/dev/null | grep -qF -- "$GATEWAY_PROCESS_PATTERN"
}

clear_gateway_metadata() {
  rm -f "$XCBOX_HOME/gateway.pid" "$XCBOX_HOME/gateway.launcher.pid" "$XCBOX_HOME/gateway.bind"
}

cleanup_gateway_start() {
  local launcher_pid="${1:-}" listener_pid
  listener_pid=$(gateway_listener_pid 2>/dev/null || true)
  if gateway_pid_is_ours "$listener_pid"; then kill "$listener_pid" 2>/dev/null || true; fi
  if gateway_launcher_is_ours "$launcher_pid"; then kill "$launcher_pid" 2>/dev/null || true; fi
  wait "$launcher_pid" 2>/dev/null || true
  clear_gateway_metadata
}

stop_gateway() {
  local pid launcher_pid listener_pid i
  pid=$(cat "$XCBOX_HOME/gateway.pid" 2>/dev/null || true)

  if [ -z "$pid" ]; then
    if gateway_up; then
      echo "ERROR: a gateway is answering on :$GATEWAY_PORT but has no xcbox ownership metadata; refusing to kill it." >&2
      return 1
    fi
    clear_gateway_metadata
    echo "xcbox: gateway not running"
    return 0
  fi

  if ! kill -0 "$pid" 2>/dev/null; then
    clear_gateway_metadata
    if gateway_up; then
      echo "ERROR: the recorded gateway pid is stale but another process is answering on :$GATEWAY_PORT; refusing to kill it." >&2
      return 1
    fi
    echo "xcbox: gateway not running (cleared stale pid $pid)"
    return 0
  fi

  if ! gateway_pid_is_ours "$pid"; then
    echo "ERROR: pid $pid is not the verified xcbox gateway listener on $GATEWAY_BIND_HOST:$GATEWAY_PORT; refusing to kill it." >&2
    return 1
  fi

  echo "==> stopping gateway listener (pid $pid)"
  kill "$pid" 2>/dev/null || {
    echo "ERROR: could not signal gateway pid $pid" >&2
    return 1
  }
  # Reap it when stop_gateway runs in the same shell that launched it (tests and
  # one-shot callers). In normal CLI use it is not our child, so wait is a no-op.
  wait "$pid" 2>/dev/null || true

  for i in $(seq 1 50); do
    listener_pid=$(gateway_listener_pid 2>/dev/null || true)
    [ -z "$listener_pid" ] && break
    sleep 0.1
  done
  listener_pid=$(gateway_listener_pid 2>/dev/null || true)
  if [ -n "$listener_pid" ]; then
    echo "ERROR: gateway port :$GATEWAY_PORT is still held by pid $listener_pid after shutdown" >&2
    return 1
  fi

  launcher_pid=$(cat "$XCBOX_HOME/gateway.launcher.pid" 2>/dev/null || true)
  for i in $(seq 1 20); do
    gateway_launcher_is_ours "$launcher_pid" || break
    sleep 0.1
  done
  if gateway_launcher_is_ours "$launcher_pid"; then
    kill "$launcher_pid" 2>/dev/null || {
      echo "ERROR: gateway listener stopped, but launcher pid $launcher_pid could not be signaled" >&2
      return 1
    }
    wait "$launcher_pid" 2>/dev/null || true
    for i in $(seq 1 20); do
      gateway_launcher_is_ours "$launcher_pid" || break
      sleep 0.1
    done
    if gateway_launcher_is_ours "$launcher_pid"; then
      echo "ERROR: gateway listener stopped, but launcher pid $launcher_pid is still alive" >&2
      return 1
    fi
  fi

  clear_gateway_metadata
  echo "==> gateway stopped; port :$GATEWAY_PORT is free"
}

ensure_gateway() {
  local launcher_pid listener_pid old_pid node_bin
  mkdir -p "$XCBOX_HOME"
  if gateway_up; then
    listener_pid=$(gateway_listener_pid 2>/dev/null || true)
    if gateway_bind_matches && gateway_pid_is_ours "$listener_pid"; then
      old_pid=$(cat "$XCBOX_HOME/gateway.pid" 2>/dev/null || true)
      if [ -n "$old_pid" ] && [ "$old_pid" != "$listener_pid" ] && gateway_launcher_is_ours "$old_pid"; then
        printf '%s\n' "$old_pid" > "$XCBOX_HOME/gateway.launcher.pid"
      fi
      printf '%s\n' "$listener_pid" > "$XCBOX_HOME/gateway.pid"
      echo "==> build gateway already up on $GATEWAY_BIND_HOST:$GATEWAY_PORT (pid $listener_pid)"
      return 0
    fi
    cat >&2 <<EOF
ERROR: a gateway is already answering on :$GATEWAY_PORT, but xcbox cannot verify
that it uses the safe $GATEWAY_BIND_HOST bind. Stop the old gateway, then retry:

  xcbox stop --gateway

If it remains running, use: lsof -nP -iTCP:$GATEWAY_PORT -sTCP:LISTEN
EOF
    return 1
  fi
  if [ -f "$XCBOX_HOME/gateway.pid" ] && ! gateway_alive; then
    echo "==> clearing stale gateway pid ($(cat "$XCBOX_HOME/gateway.pid" 2>/dev/null))"
    clear_gateway_metadata
  fi
  if [ "$GATEWAY_CMD" = "$GATEWAY_CMD_DEFAULT" ]; then ensure_runtime || return 1; fi
  echo "==> starting build gateway (XcodeBuildMCP) on $GATEWAY_BIND_HOST:$GATEWAY_PORT"
  : > "$XCBOX_HOME/gateway.log"
  node_bin=$(command -v node)
  nohup env \
    XCBOX_NODE_BIN="$node_bin" \
    XCBOX_GATEWAY_SCRIPT="$GATEWAY_SCRIPT" \
    XCBOX_XCODEBUILDMCP_BIN="$XCODEBUILDMCP_BIN" \
    GATEWAY_PORT="$GATEWAY_PORT" \
    GATEWAY_BIND_HOST="$GATEWAY_BIND_HOST" \
    GATEWAY_HOST="$GATEWAY_HOST" \
    MCP_ENDPOINT="$MCP_ENDPOINT" \
    sh -c "exec $GATEWAY_CMD" >>"$XCBOX_HOME/gateway.log" 2>&1 &
  launcher_pid=$!
  printf '%s\n' "$launcher_pid" > "$XCBOX_HOME/gateway.launcher.pid"
  local i
  for i in $(seq 1 "$GATEWAY_START_ATTEMPTS"); do
    if ! kill -0 "$launcher_pid" 2>/dev/null; then
      echo "ERROR: gateway exited early; see $XCBOX_HOME/gateway.log" >&2
      sed -n '1,20p' "$XCBOX_HOME/gateway.log" >&2 || true
      cleanup_gateway_start "$launcher_pid"
      return 1
    fi
    if gateway_up; then
      listener_pid=$(gateway_listener_pid 2>/dev/null || true)
      if ! gateway_pid_is_ours "$listener_pid"; then
        echo "ERROR: gateway answered but its listener could not be verified; refusing to track or expose it." >&2
        cleanup_gateway_start "$launcher_pid"
        return 1
      fi
      printf '%s\n' "$listener_pid" > "$XCBOX_HOME/gateway.pid"
      printf '%s\n' "$GATEWAY_BIND_HOST:$GATEWAY_PORT" > "$XCBOX_HOME/gateway.bind"
      echo "==> gateway ready (listener pid $listener_pid)"; return 0
    fi
    sleep "$GATEWAY_START_DELAY"
  done
  echo "ERROR: gateway did not become ready in time; see $XCBOX_HOME/gateway.log" >&2
  cleanup_gateway_start "$launcher_pid"
  return 1
}

# grep -qF: fixed-string match (container names contain '.'); quote the name as
# it appears in the JSON so a basename substring can't false-match.
box_exists()  { container ls -a --format json 2>/dev/null | grep -qF "\"$1\""; }
box_running() { container ls    --format json 2>/dev/null | grep -qF "\"$1\""; }

ensure_box() {
  local name="$1" proj="$2"
  mkdir -p "$XCBOX_HOME"
  if ! box_exists "$name"; then
    echo "==> creating sandbox '$name' (project-only: $proj)"
    container run -d --name "$name" --ssh \
      -v "$proj:$proj" -v "$XCBOX_HOME:/root" -w "$proj" \
      "$XCBOX_IMAGE" sleep infinity >/dev/null
  elif ! box_running "$name"; then
    echo "==> starting sandbox '$name'"; container start "$name" >/dev/null
  fi
}

ensure_agent() {
  local name="$1"
  if ! container exec "$name" sh -c 'test -x /root/.npm-global/bin/claude' 2>/dev/null; then
    echo "==> first run: installing agent ($AGENT_INSTALL)"
    container exec -e NPM_CONFIG_PREFIX=/root/.npm-global "$name" npm install -g "$AGENT_INSTALL"
  fi
}

carry_git_identity() {
  local name="$1" gn ge
  gn=$(git config --global user.name 2>/dev/null || true)
  ge=$(git config --global user.email 2>/dev/null || true)
  [ -n "$gn" ] && container exec "$name" git config --global user.name  "$gn"  || true
  [ -n "$ge" ] && container exec "$name" git config --global user.email "$ge" || true
}

register_mcp() {
  local name="$1"
  container exec -e PATH="$INNER_PATH" -e XCBOX_MCP_URL="$GATEWAY_CONTAINER_URL" "$name" sh -c '
    claude mcp remove ios-build -s user >/dev/null 2>&1 || true
    claude mcp add --scope user --transport http ios-build \
      "$XCBOX_MCP_URL" >/dev/null
  ' || echo "   (warning: could not register ios-build MCP — is the agent installed?)" >&2
}
