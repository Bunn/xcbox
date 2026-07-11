#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$DIR/.." && pwd)

node -e '
  const manifest = require(process.argv[1]);
  const lock = require(process.argv[2]);
  const expected = { "@modelcontextprotocol/sdk": "1.27.1", xcodebuildmcp: "2.6.2" };
  for (const [name, version] of Object.entries(expected)) {
    if (manifest.dependencies[name] !== version) throw new Error(`${name} is not pinned to ${version}`);
    if (lock.packages[`node_modules/${name}`].version !== version) throw new Error(`${name} lock mismatch`);
  }
' "$REPO/package.json" "$REPO/package-lock.json"

TEST_ROOT=$(mktemp -d)
TEST_HOME=$(mktemp -d)
export XCBOX_RUNTIME_ROOT="$TEST_ROOT"
export XCBOX_HOME="$TEST_HOME"
. "$DIR/xcbox-lib.sh"
case "$GATEWAY_CMD_DEFAULT" in
  *npx*|*@latest*) echo "FAIL: gateway command still performs a live package resolution"; exit 1 ;;
esac

cleanup() { rm -rf "$TEST_ROOT" "$TEST_HOME"; }
trap cleanup EXIT

printf '{"lockfileVersion":3,"packages":{"node_modules/@modelcontextprotocol/sdk":{"version":"1.27.1"},"node_modules/xcodebuildmcp":{"version":"2.6.2"}}}\n' > "$RUNTIME_LOCKFILE"
CALLS="$TEST_HOME/npm-calls"

install_fake_runtime() {
  mkdir -p "$XCBOX_ROOT/node_modules/.bin" "$XCBOX_ROOT/node_modules/@modelcontextprotocol/sdk" "$XCBOX_ROOT/node_modules/xcodebuildmcp"
  printf '#!/bin/sh\n' > "$XCODEBUILDMCP_BIN"
  chmod +x "$XCODEBUILDMCP_BIN"
  printf '{"version":"1.27.1"}\n' > "$XCBOX_ROOT/node_modules/@modelcontextprotocol/sdk/package.json"
  printf '{"version":"2.6.2"}\n' > "$XCBOX_ROOT/node_modules/xcodebuildmcp/package.json"
}

npm() {
  printf '%s\n' "$*" >> "$CALLS"
  [ "$*" = "--prefix $XCBOX_ROOT ci --omit=dev" ] || return 1
  install_fake_runtime
}

ensure_runtime
runtime_ready || { echo "FAIL: installed runtime not recognized"; exit 1; }
[ "$(runtime_locked_package_version @modelcontextprotocol/sdk)" = "1.27.1" ] || { echo "FAIL: wrong locked MCP SDK version"; exit 1; }
[ "$(runtime_package_version @modelcontextprotocol/sdk)" = "1.27.1" ] || { echo "FAIL: wrong MCP SDK version"; exit 1; }
[ "$(runtime_package_version xcodebuildmcp)" = "2.6.2" ] || { echo "FAIL: wrong xcodebuildmcp version"; exit 1; }
[ "$(wc -l < "$CALLS" | tr -d ' ')" = 1 ] || { echo "FAIL: initial install count"; exit 1; }

printf '{"version":"9.9.9"}\n' > "$XCBOX_ROOT/node_modules/@modelcontextprotocol/sdk/package.json"
if runtime_ready; then echo "FAIL: installed version drift was accepted"; exit 1; fi
printf '{"version":"1.27.1"}\n' > "$XCBOX_ROOT/node_modules/@modelcontextprotocol/sdk/package.json"
runtime_ready || { echo "FAIL: restored exact runtime not recognized"; exit 1; }

# Once the stamp and binaries match, ensure_runtime must not invoke npm. This is
# the offline-start property: the registry is irrelevant after installation.
npm() { echo "FAIL: npm called for an unchanged lock" >&2; return 1; }
ensure_runtime

# Any lockfile change invalidates the stamp and triggers exactly one refresh.
printf ' ' >> "$RUNTIME_LOCKFILE"
npm() {
  printf '%s\n' "$*" >> "$CALLS"
  install_fake_runtime
}
ensure_runtime
runtime_ready || { echo "FAIL: refreshed runtime not recognized"; exit 1; }
[ "$(wc -l < "$CALLS" | tr -d ' ')" = 2 ] || { echo "FAIL: lock change did not trigger one refresh"; exit 1; }

echo "runtime OK: exact pins; offline reuse; lockfile change refreshes install"
