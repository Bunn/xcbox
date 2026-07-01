# xcbox shared helpers. Source this; do not execute.
# Values confirmed by the Task 1 spike:
XCBOX_HOME="${XCBOX_HOME:-$HOME/.xcbox-home}"
GATEWAY_PORT="${GATEWAY_PORT:-8765}"
MCP_ENDPOINT="${MCP_ENDPOINT:-/mcp}"
# GATEWAY_CMD: serve XcodeBuildMCP over streamable HTTP, bound to 0.0.0.0.
# --stateful is REQUIRED: the stateless streamableHttp bridge crashes a real MCP
# client's multi-message session ("No connection established for request ID"),
# taking the whole gateway down. Stateful mode keeps a per-client session so
# responses route back correctly. (Found during the Phase 1 manual run.)
GATEWAY_CMD_DEFAULT='npx -y supergateway --stdio "npx -y xcodebuildmcp@latest mcp" --outputTransport streamableHttp --stateful --healthEndpoint /healthz --port '"$GATEWAY_PORT"' --host 0.0.0.0'
GATEWAY_CMD="${GATEWAY_CMD:-$GATEWAY_CMD_DEFAULT}"

# True if DIR looks like an iOS/Xcode project (has any of: *.xcodeproj,
# *.xcworkspace, Package.swift). Accepts if ANY is present.
is_ios_project() {
  local dir="$1"
  compgen -G "$dir/*.xcodeproj"   >/dev/null 2>&1 && return 0
  compgen -G "$dir/*.xcworkspace" >/dev/null 2>&1 && return 0
  [ -e "$dir/Package.swift" ] && return 0
  return 1
}

# Container name from a project path: xcbox-<sanitized-basename>.
sanitize_name() {
  # tr -d '\n' first: basename emits a trailing newline that tr -c would
  # otherwise turn into a trailing '-' in the container name.
  printf 'xcbox-%s' "$(basename "$1" | tr -d '\n' | tr -c 'A-Za-z0-9_.-' '-' | tr '[:upper:]' '[:lower:]')"
}

# The sandbox mount root for a project dir: the git repo toplevel if the dir is
# inside a git repo (so .git comes into the box and commit/push work even when
# the Xcode project sits in a subdirectory of the repo), else the dir itself.
# Echoes an absolute path.
repo_mount_root() {
  git -C "$1" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$1"
}

# Liveness check via supergateway's --healthEndpoint (returns "ok"). We do NOT
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
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

ensure_gateway() {
  mkdir -p "$XCBOX_HOME"
  if gateway_up; then echo "==> build gateway already up on :$GATEWAY_PORT"; return 0; fi
  if [ -f "$XCBOX_HOME/gateway.pid" ] && ! gateway_alive; then
    echo "==> clearing stale gateway pid ($(cat "$XCBOX_HOME/gateway.pid" 2>/dev/null))"
    rm -f "$XCBOX_HOME/gateway.pid"
  fi
  echo "==> starting build gateway (XcodeBuildMCP) on :$GATEWAY_PORT"
  : > "$XCBOX_HOME/gateway.log"
  nohup sh -c "$GATEWAY_CMD" >>"$XCBOX_HOME/gateway.log" 2>&1 &
  local gw_pid=$!
  local i
  for i in $(seq 1 60); do
    if ! kill -0 "$gw_pid" 2>/dev/null; then
      echo "ERROR: gateway exited early; see $XCBOX_HOME/gateway.log" >&2
      sed -n '1,20p' "$XCBOX_HOME/gateway.log" >&2 || true
      return 1
    fi
    if gateway_up; then
      echo "$gw_pid" > "$XCBOX_HOME/gateway.pid"   # record only once confirmed listening
      echo "==> gateway ready"; return 0
    fi
    sleep 2
  done
  echo "ERROR: gateway did not become ready in time; see $XCBOX_HOME/gateway.log" >&2
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
  container exec -e PATH="$INNER_PATH" "$name" sh -c '
    claude mcp remove ios-build -s user >/dev/null 2>&1 || true
    claude mcp add --scope user --transport http ios-build \
      http://192.168.64.1:'"$GATEWAY_PORT$MCP_ENDPOINT"' >/dev/null
  ' || echo "   (warning: could not register ios-build MCP — is the agent installed?)" >&2
}
