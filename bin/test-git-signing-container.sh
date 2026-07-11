#!/usr/bin/env bash
# Local macOS integration test: prove a throwaway SSH key stays on the host
# while Git inside an Apple container creates a verifiable signed commit.
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d)
NAME="xcbox-signing-smoke-$$"
AGENT_PID=""

cleanup() {
  container stop "$NAME" >/dev/null 2>&1 || true
  container rm "$NAME" >/dev/null 2>&1 || true
  [ -z "$AGENT_PID" ] || kill "$AGENT_PID" >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT INT TERM

export XCBOX_HOME="$T/state"
export XCBOX_BOX_HOME_ROOT="$XCBOX_HOME/boxes"
export GIT_CONFIG_GLOBAL="$T/host.gitconfig"
. "$DIR/xcbox-lib.sh"

command -v container >/dev/null 2>&1 || { echo "FAIL: Apple container CLI is required" >&2; exit 1; }
container ls >/dev/null 2>&1 || container system start

export SSH_AUTH_SOCK="$T/agent.sock"
ssh-agent -D -a "$SSH_AUTH_SOCK" >"$T/ssh-agent.log" 2>&1 &
AGENT_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -S "$SSH_AUTH_SOCK" ] && break
  sleep 0.1
done
[ -S "$SSH_AUTH_SOCK" ] || { echo "FAIL: throwaway SSH agent did not start" >&2; exit 1; }

ssh-keygen -q -t ed25519 -N '' -C xcbox-signing-smoke -f "$T/signing-key"
ssh-add "$T/signing-key" >/dev/null
git config --file "$GIT_CONFIG_GLOBAL" user.name 'xcbox Signing Test'
git config --file "$GIT_CONFIG_GLOBAL" user.email xcbox-signing@example.com
git config --file "$GIT_CONFIG_GLOBAL" gpg.format ssh
git config --file "$GIT_CONFIG_GLOBAL" commit.gpgsign true
git config --file "$GIT_CONFIG_GLOBAL" user.signingkey "$T/signing-key.pub"

mkdir -p "$T/repo" "$XCBOX_BOX_HOME_ROOT/$NAME"
printf 'signed by the forwarded agent\n' > "$T/repo/proof.txt"
git -C "$T/repo" init -q

container run -d --name "$NAME" --ssh \
  -v "$T/repo:$T/repo" -v "$XCBOX_BOX_HOME_ROOT/$NAME:/root" -w "$T/repo" \
  "$XCBOX_IMAGE" sleep infinity >/dev/null
carry_git_identity "$NAME" "$T/repo"
container exec "$NAME" git add proof.txt
container exec "$NAME" git commit -qm 'Prove forwarded SSH signing'

git -C "$T/repo" cat-file commit HEAD | grep -q '^gpgsig -----BEGIN SSH SIGNATURE-----' \
  || { echo "FAIL: container commit has no SSH signature" >&2; exit 1; }
printf 'xcbox-signing@example.com %s\n' "$(cat "$T/signing-key.pub")" > "$T/allowed-signers"
git -C "$T/repo" -c gpg.ssh.allowedSignersFile="$T/allowed-signers" verify-commit HEAD >/dev/null \
  || { echo "FAIL: host could not verify the container commit" >&2; exit 1; }

# Also prove the safe first-agent fallback used when the host has no explicit
# user.signingKey but does require SSH-signed commits.
git config --file "$GIT_CONFIG_GLOBAL" --unset user.signingkey
git config --file "$GIT_CONFIG_GLOBAL" gpg.ssh.defaultKeyCommand 'host-only-helper'
carry_git_identity "$NAME" "$T/repo"
printf 'signed through ssh-add fallback\n' > "$T/repo/fallback.txt"
container exec "$NAME" git add fallback.txt
container exec "$NAME" git commit -qm 'Prove forwarded SSH signing fallback'
git -C "$T/repo" -c gpg.ssh.allowedSignersFile="$T/allowed-signers" verify-commit HEAD >/dev/null \
  || { echo "FAIL: ssh-add signing fallback did not verify" >&2; exit 1; }
if grep -R -q -- 'BEGIN OPENSSH PRIVATE KEY' "$XCBOX_BOX_HOME_ROOT/$NAME"; then
  echo "FAIL: private key material entered the box home" >&2
  exit 1
fi

echo "git signing container OK: signed commit verified; private key remained on host"
