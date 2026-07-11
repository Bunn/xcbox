#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

export XCBOX_HOME="$T/state"
export XCBOX_BOX_HOME_ROOT="$XCBOX_HOME/boxes"
export GIT_CONFIG_GLOBAL="$T/host.gitconfig"
. "$DIR/xcbox-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

NAME=xcbox-signing-test
HOME_DIR="$XCBOX_BOX_HOME_ROOT/$NAME"
mkdir -p "$HOME_DIR" "$T/host-keys"
PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestOnlyPublicKey xcbox-test'
printf '%s\n' "$PUBLIC_KEY" > "$T/host-keys/signing.pub"

git config --file "$GIT_CONFIG_GLOBAL" user.name 'Signing Test'
git config --file "$GIT_CONFIG_GLOBAL" user.email signing@example.com
git config --file "$GIT_CONFIG_GLOBAL" gpg.format ssh
git config --file "$GIT_CONFIG_GLOBAL" commit.gpgsign true
git config --file "$GIT_CONFIG_GLOBAL" tag.gpgsign true
git config --file "$GIT_CONFIG_GLOBAL" user.signingkey "$T/host-keys/signing.pub"

CALLS="$T/container.calls"
container() {
  printf '%s\n' "$*" >> "$CALLS"
  case "$*" in *'git config --global --get gpg.format'*) return "${SIGNING_READY_RC:-0}" ;; esac
  return 0
}

host_ssh_commit_signing_enabled || fail "host SSH signing was not detected"
: > "$CALLS"
carry_git_identity "$NAME"
grep -Fq 'git config --global gpg.format ssh' "$CALLS" || fail "SSH signing format was not carried"
grep -Fq 'git config --global commit.gpgsign true' "$CALLS" || fail "commit signing requirement was not carried"
grep -Fq 'git config --global tag.gpgsign true' "$CALLS" || fail "tag signing requirement was not carried"
grep -Fq 'git config --global user.signingkey /root/.config/xcbox/signing-key.pub' "$CALLS" || fail "box signing-key path was not configured"
[ "$(cat "$HOME_DIR/.config/xcbox/signing-key.pub")" = "$PUBLIC_KEY" ] || fail "public signing key was not copied"

# Effective repository config (including relative public-key paths) overrides
# the global defaults used by other projects.
mkdir -p "$T/project"
git -C "$T/project" init -q
printf '%s\n' "$PUBLIC_KEY" > "$T/project/project-signing.pub"
git -C "$T/project" config user.name 'Project Signing Test'
git -C "$T/project" config user.signingkey project-signing.pub
: > "$CALLS"
carry_git_identity "$NAME" "$T/project"
grep -Fq 'git config --global user.name Project Signing Test' "$CALLS" || fail "project-specific identity was not carried"
grep -Fq 'git config --global user.signingkey /root/.config/xcbox/signing-key.pub' "$CALLS" || fail "relative project signing key was not carried"

# Literal public keys remain literals; raw SSH keys are normalized to key::.
git config --file "$GIT_CONFIG_GLOBAL" user.signingkey "$PUBLIC_KEY"
: > "$CALLS"
carry_git_identity "$NAME"
grep -Fq "git config --global user.signingkey key::$PUBLIC_KEY" "$CALLS" || fail "literal SSH key was not normalized"

# A host custom command is not imported into the box; use the documented,
# agent-backed default when no explicit key is selected.
git config --file "$GIT_CONFIG_GLOBAL" --unset user.signingkey
git config --file "$GIT_CONFIG_GLOBAL" gpg.ssh.defaultKeyCommand 'host-only-key-helper --secret-option'
: > "$CALLS"
carry_git_identity "$NAME"
grep -Fq 'git config --global gpg.ssh.defaultKeyCommand ssh-add -L' "$CALLS" || fail "safe agent default was not configured"
if grep -Fq 'host-only-key-helper' "$CALLS"; then fail "arbitrary host signing command entered the box"; fi

# Never treat a private key file as public material.
printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----' > "$T/host-keys/private"
git config --file "$GIT_CONFIG_GLOBAL" user.signingkey "$T/host-keys/private"
if carry_git_identity "$NAME" >/dev/null 2>"$T/private.err"; then
  fail "private signing key was accepted"
fi
grep -q 'refusing to copy non-public SSH key data' "$T/private.err" || fail "private-key refusal was not explained"

# A required key that is not present in the forwarded agent must fail setup,
# rather than silently allowing unsigned commits.
git config --file "$GIT_CONFIG_GLOBAL" user.signingkey "$T/host-keys/signing.pub"
if SIGNING_READY_RC=1 carry_git_identity "$NAME" >/dev/null 2>"$T/agent.err"; then
  fail "missing forwarded signing identity was accepted"
fi
grep -q 'host requires SSH-signed commits' "$T/agent.err" || fail "missing signing identity was not explained"

echo "git signing OK: SSH settings, public-key copy, safe default, private-key refusal, agent guard"
