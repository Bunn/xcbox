#!/usr/bin/env bash
# Linux-safe CI entry point. Apple container/Xcode coverage stays in test-loop.sh.
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$DIR/.." && pwd)
SHELLCHECK_BIN="${SHELLCHECK_BIN:-shellcheck}"

command -v "$SHELLCHECK_BIN" >/dev/null 2>&1 \
  || { echo "FAIL: ShellCheck is required (set SHELLCHECK_BIN to its path)" >&2; exit 1; }

for script in "$ROOT/install.sh" "$DIR"/*.sh; do
  bash -n "$script"
done
for script in "$DIR"/*.js "$DIR"/*.mjs; do
  node --check "$script"
done

"$SHELLCHECK_BIN" --severity=warning -x "$ROOT/install.sh" "$DIR"/*.sh

for test in \
  test-guard.sh \
  test-lib.sh \
  test-project-identity.sh \
  test-box-home.sh \
  test-agents.sh \
  test-git-signing.sh \
  test-list.sh \
  test-cleanup.sh \
  test-logs.sh \
  test-status-probes.sh \
  test-dispatch.sh \
  test-doctor.sh \
  test-subcommands.sh \
  test-terminal.sh \
  test-runtime.sh
do
  "$DIR/$test"
done

EMPTY_TREE=$(git -C "$ROOT" hash-object -t tree /dev/null)
git -C "$ROOT" diff --check "$EMPTY_TREE" HEAD
git -C "$ROOT" diff --check
echo "CI OK: syntax, ShellCheck, Linux-safe unit/runtime tests"
