#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
GIT_CONFIG_GLOBAL="$T/host.gitconfig"
git config --file "$GIT_CONFIG_GLOBAL" gpg.format ssh
git config --file "$GIT_CONFIG_GLOBAL" commit.gpgsign true

fail() { echo "FAIL: $*" >&2; exit 1; }

PROJECT="$T/App"
mkdir -p "$PROJECT/App.xcodeproj" "$T/fakebin" "$T/home"
BOX_NAME=$(XCBOX_HOME="$T/home" bash -c '. "$1/xcbox-lib.sh"; sanitize_name "$2"' _ "$DIR" "$PROJECT")
BOX_HOME="$T/home/boxes/$BOX_NAME"
mkdir -p "$BOX_HOME"
printf '1\n' > "$BOX_HOME/.xcbox-home-version"
mkdir -p "$T/home/projects"
printf 'codex\n' > "$T/home/projects/$BOX_NAME.agent"

cat > "$T/fakebin/container" <<'EOF'
#!/usr/bin/env bash
cmd="${1:-}"; shift || true
case "$cmd" in
  ls)
    printf '[{"id":"%s"}]\n' "$FAKE_BOX_NAME"
    ;;
  inspect)
    printf '[{"id":"%s","configuration":{"mounts":[{"destination":"/root","source":"%s"}]}}]\n' "$FAKE_BOX_NAME" "$FAKE_BOX_HOME"
    ;;
  exec)
    all="$*"
    case "$all" in
      *'/root/.npm-global/bin/codex --version'*) printf 'codex-cli 0.144.1\n'; exit 0 ;;
      *'/root/.npm-global/bin/codex mcp list'*) printf 'ios-build\n'; exit 0 ;;
      *'git config --global --get gpg.format'*) exit "${FAKE_SIGNING_RC:-0}" ;;
      *'ssh-add -l'*) exit "${FAKE_SSH_RC:-0}" ;;
      *'node -e'*) exit "${FAKE_GATEWAY_RC:-0}" ;;
      *'node - '*)
        # Drain the piped mcp-call.js so the writer never sees a closed pipe.
        while IFS= read -r _; do :; done
        [ "${FAKE_MCP_RC:-0}" = 0 ] && printf '{"tools":[{"name":"build_sim"}]}\n'
        exit "${FAKE_MCP_RC:-0}"
        ;;
      *) exit 1 ;;
    esac
    ;;
  system)
    [ "${1:-} ${2:-} ${3:-}" = 'dns list ' ] && printf 'DOMAIN\nhost.container.internal\n'
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/fakebin/container"

status() {
  PATH="$T/fakebin:$PATH" \
    PROJECT="$PROJECT" XCBOX_HOME="$T/home" GATEWAY_PORT=65431 \
    GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" \
    FAKE_BOX_NAME="$BOX_NAME" FAKE_BOX_HOME="$BOX_HOME" \
    FAKE_GATEWAY_RC="${FAKE_GATEWAY_RC:-0}" FAKE_MCP_RC="${FAKE_MCP_RC:-0}" FAKE_SSH_RC="${FAKE_SSH_RC:-0}" FAKE_SIGNING_RC="${FAKE_SIGNING_RC:-0}" \
    "$DIR/xcbox" status 2>&1
}

OUT=$(FAKE_GATEWAY_RC=0 FAKE_MCP_RC=0 FAKE_SSH_RC=0 status) || fail "healthy status exited nonzero"
printf '%s\n' "$OUT" | grep -Fq 'selected agent: codex' || fail "healthy status missed remembered Codex selection"
printf '%s\n' "$OUT" | grep -Fq 'codex agent installed' || fail "healthy status missed Codex version"
printf '%s\n' "$OUT" | grep -Fq 'box can reach host gateway' || fail "healthy status missed container gateway"
printf '%s\n' "$OUT" | grep -Fq 'real MCP session lists Xcode build tools' || fail "healthy status missed real MCP session"
printf '%s\n' "$OUT" | grep -Fq 'forwarded SSH agent has an identity' || fail "healthy status missed SSH agent"
printf '%s\n' "$OUT" | grep -Fq 'SSH commit signing uses a forwarded agent identity' || fail "healthy status missed commit signing"

OUT=$(FAKE_GATEWAY_RC=1 FAKE_MCP_RC=0 FAKE_SSH_RC=1 status) || fail "failing diagnostics made status exit nonzero"
printf '%s\n' "$OUT" | grep -Fq 'FAIL box cannot reach host gateway' || fail "gateway failure was not reported"
printf '%s\n' "$OUT" | grep -Fq 'FAIL forwarded SSH agent unavailable/empty' || fail "SSH failure was not reported"
if printf '%s\n' "$OUT" | grep -Fq 'real MCP session'; then fail "MCP was probed after gateway failure"; fi

OUT=$(FAKE_GATEWAY_RC=0 FAKE_MCP_RC=1 FAKE_SSH_RC=0 status) || fail "MCP failure made status exit nonzero"
printf '%s\n' "$OUT" | grep -Fq 'FAIL MCP session failed' || fail "MCP failure was not reported"
printf '%s\n' "$OUT" | grep -Fq "xcbox logs" || fail "MCP repair guidance was omitted"

OUT=$(FAKE_GATEWAY_RC=0 FAKE_MCP_RC=0 FAKE_SSH_RC=0 FAKE_SIGNING_RC=1 status) || fail "signing diagnostics made status exit nonzero"
printf '%s\n' "$OUT" | grep -Fq 'FAIL SSH commit signing unavailable' || fail "signing failure was not reported"

echo "status probes OK: container gateway, real MCP session, SSH agent/signing, repair diagnostics"
