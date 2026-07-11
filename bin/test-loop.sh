#!/usr/bin/env bash
# Login-independent end-to-end proof on a throwaway generated iOS app.
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$DIR/xcbox-lib.sh"
TEST_BOX_HOME_ROOT=$(mktemp -d)
# Read dynamically by box_home_dir from the sourced helper library.
# shellcheck disable=SC2034
XCBOX_BOX_HOME_ROOT="$TEST_BOX_HOME_ROOT"

# AUTO_TMP_ROOT is set only when we mint our own tmp dir (DEMO_DIR unset).
# Teardown below removes exactly that root — never a caller-supplied DEMO_DIR's
# parent — so an override like DEMO_DIR=/Users/me/projects/Foo can't make the
# trap rm -rf the grandparent ("/Users/me/projects").
if [ -n "${DEMO_DIR:-}" ]; then
  DEMO="$DEMO_DIR"
  AUTO_TMP_ROOT=""
else
  AUTO_TMP_ROOT=$(mktemp -d)
  DEMO="$AUTO_TMP_ROOT/IosboxDemo"
fi
mkdir -p "$DEMO"
NAME=$(sanitize_name "$DEMO")
cleanup() {
  container stop "$NAME" >/dev/null 2>&1 || true
  container rm   "$NAME" >/dev/null 2>&1 || true
  rm -rf "$TEST_BOX_HOME_ROOT" || true
  if [ -n "$AUTO_TMP_ROOT" ]; then
    rm -rf "$AUTO_TMP_ROOT" || true        # our own mktemp root only
  else
    rm -rf "$DEMO" || true                 # caller-supplied DEMO_DIR: remove just the demo dir we populated, never its parent
  fi
}
trap cleanup EXIT

# --- 1. Generate a throwaway app (app target + unit-test target + scheme) ---
command -v xcodegen >/dev/null || { echo "FAIL: xcodegen not installed (brew install xcodegen)"; exit 1; }
mkdir -p "$DEMO/Sources" "$DEMO/Tests"
cat > "$DEMO/project.yml" <<'YAML'
name: IosboxDemo
options: { bundleIdPrefix: com.example, deploymentTarget: { iOS: "17.0" } }
targets:
  IosboxDemo:
    type: application
    platform: iOS
    sources: [Sources]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.example.IosboxDemo
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
        TARGETED_DEVICE_FAMILY: "1"
  IosboxDemoTests:
    type: bundle.unit-test
    platform: iOS
    sources: [Tests]
    settings:
      base:
        # Test bundles need their own generated Info.plist too, or codesigning fails
        # ("Cannot code sign because the target does not have an Info.plist file...").
        # Confirmed live against this host's toolchain.
        GENERATE_INFOPLIST_FILE: YES
    dependencies: [ { target: IosboxDemo } ]
schemes:
  IosboxDemo:
    build: { targets: { IosboxDemo: all, IosboxDemoTests: [test] } }
    test:  { targets: [IosboxDemoTests] }
YAML
cat > "$DEMO/Sources/App.swift" <<'SWIFT'
import SwiftUI
enum Maths { static func add(_ a: Int, _ b: Int) -> Int { a + b } }
@main struct DemoApp: App { var body: some Scene { WindowGroup { Text("hi") } } }
SWIFT
cat > "$DEMO/Tests/MathsTests.swift" <<'SWIFT'
import XCTest
@testable import IosboxDemo
final class MathsTests: XCTestCase { func testAdd() { XCTAssertEqual(Maths.add(2, 3), 5) } }
SWIFT
( cd "$DEMO" && xcodegen generate >/dev/null )
[ -d "$DEMO/IosboxDemo.xcodeproj" ] || { echo "FAIL: demo project not generated"; exit 1; }
echo "demo generated at $DEMO"

# --- 2. Gateway + project-only box ---
if ! container ls >/dev/null 2>&1; then container system start; fi
ensure_container_gateway_route
ensure_gateway
ensure_box "$NAME" "$DEMO"
EXPECTED_BOX_HOME=$(canonical_path "$(box_home_dir "$NAME")")
ACTUAL_BOX_HOME=$(canonical_path "$(box_root_mount_source "$NAME")")
[ "$ACTUAL_BOX_HOME" = "$EXPECTED_BOX_HOME" ] || { echo "FAIL: box /root is not the isolated project home"; exit 1; }
echo "home OK: /root is isolated at $EXPECTED_BOX_HOME"
STATUS_OUTPUT=$(PROJECT="$DEMO" XCBOX_BOX_HOME_ROOT="$TEST_BOX_HOME_ROOT" "$DIR/xcbox" status)
printf '%s\n' "$STATUS_OUTPUT" | grep -q 'OK   box can reach host gateway' \
  || { echo "FAIL: status did not verify the gateway from inside the box"; echo "$STATUS_OUTPUT"; exit 1; }
printf '%s\n' "$STATUS_OUTPUT" | grep -q 'OK   real MCP session lists Xcode build tools' \
  || { echo "FAIL: status did not verify a real MCP session from inside the box"; echo "$STATUS_OUTPUT"; exit 1; }
echo "status OK: container gateway and real MCP probes passed"

# --- 3. Isolation: project visible, host home NOT ---
container exec "$NAME" ls "$DEMO" >/dev/null 2>&1 || { echo "FAIL: project not visible in box"; exit 1; }
if container exec "$NAME" ls "$HOME/Desktop" >/dev/null 2>&1; then echo "FAIL: host Desktop visible in box (isolation broken)"; exit 1; fi
echo "isolation OK: project visible, host home blocked"

# --- 4. SSH-agent auth round-trip (proves push prerequisite, login-independent) ---
# GitHub's ssh returns exit 1 with a 'successfully authenticated' banner when auth works.
if box_ssh_agent_ready "$NAME"; then
  echo "ssh agent OK: forwarded socket has a loaded identity"
else
  echo "WARN: forwarded SSH agent has no usable identity — status repair guidance verified by unit test"
fi
if container exec "$NAME" sh -c 'ssh -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1' | grep -qi "successfully authenticated"; then
  echo "ssh OK: forwarded agent authenticates to GitHub"
  SSH_STATUS=confirmed
else
  echo "WARN: GitHub SSH auth not confirmed (no key in agent, or offline) — push step is manual (Task 6)"
  SSH_STATUS=skipped
fi

# --- 5. Drive XcodeBuildMCP from INSIDE the box, over ONE real MCP session ---
URL="$GATEWAY_CONTAINER_URL"
# box_mcp <callsJSON>: runs a JSON array of {method,params} in ONE session via
# mcp-call.js (piped into the box's node); prints one result JSON per line.
box_mcp() { container exec -i "$NAME" node - "$URL" "$1" < "$DIR/mcp-call.js"; }

# 5a. Diagnostic: print the relevant tool input schemas.
echo "== tool schemas (discover_projs/build_sim/test_sim) =="
box_mcp '[{"method":"tools/list","params":{}}]' | node -e '
  let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
    const t=JSON.parse(s).tools||[];
    for (const n of ["discover_projs","build_sim","test_sim","list_sims","session_set_defaults"])
      { const x=t.find(z=>z.name===n); if(x) console.log(n, JSON.stringify(x.inputSchema)); }
  });'

# 5b. discover_projs — guaranteed round-trip: gateway sees the host project. (assert)
DISC=$(box_mcp '[{"method":"tools/call","params":{"name":"discover_projs","arguments":{"workspaceRoot":"'"$DEMO"'"}}}]')
echo "$DISC" | grep -qi "IosboxDemo" || { echo "FAIL: discover_projs did not find the demo project"; echo "$DISC"; exit 1; }
echo "discover OK: XcodeBuildMCP discovered the demo from inside the box"

# 5c. build_sim + test_sim — the build/test round-trip (criterion #2).
# RECONCILED AGAINST THE LIVE SCHEMA (step 5a, XcodeBuildMCP 2.6.2):
#   - build_sim/test_sim take NO direct projectPath/scheme/simulator args — those are set
#     via session_set_defaults. The gateway is stateful, so we run
#     session_set_defaults -> build_sim -> test_sim in ONE MCP session (mcp-call.js opens a
#     single session for the whole array): the in-memory defaults from the first call carry
#     to the build/test calls, exactly as the real agent's MCP client sees them. No
#     persist:true / on-disk config needed (that was a workaround for the old stateless mode).
#   - simulatorName + implicit OS=latest is unreliable: this host's latest installed runtime
#     (iOS 26.5) has no plain "iPhone 16" device, so xcodebuild's destination matcher fails.
#     Resolve a concrete simulatorId via `xcrun simctl` up front and pass THAT.
PROJ_XC="$DEMO/IosboxDemo.xcodeproj"
SIM="${XCBOX_SIM:-iPhone 16}"
SIMID=$(xcrun simctl list devices available --json 2>/dev/null | node -e "
  let s=''; process.stdin.on('data',d=>s+=d).on('end',()=>{
    const j = JSON.parse(s);
    const name = process.argv[1];
    let best = null;
    for (const devices of Object.values(j.devices)) {
      for (const d of devices) { if (d.name === name && d.isAvailable) best = d.udid; }
    }
    if (!best) process.exit(1);
    console.log(best);
  });" "$SIM")
[ -n "$SIMID" ] || { echo "FAIL: no available simulator named '$SIM' (xcrun simctl list devices available); set XCBOX_SIM"; exit 1; }
echo "simulator OK: resolved '$SIM' -> $SIMID"

# One session: set defaults, then build, then test. Results printed one JSON per line.
CALLS=$(cat <<JSON
[
  {"method":"tools/call","params":{"name":"session_set_defaults","arguments":{"projectPath":"$PROJ_XC","scheme":"IosboxDemo","simulatorId":"$SIMID"}}},
  {"method":"tools/call","params":{"name":"build_sim","arguments":{}}},
  {"method":"tools/call","params":{"name":"test_sim","arguments":{}}}
]
JSON
)
RESULTS=$(box_mcp "$CALLS") || true   # mcp-call.js exits 1 on a tool error; grep the per-call results below for a specific verdict
SETDEF=$(printf '%s\n' "$RESULTS" | sed -n 1p)
BUILD=$(printf  '%s\n' "$RESULTS" | sed -n 2p)
TEST=$(printf   '%s\n' "$RESULTS" | sed -n 3p)

echo "$SETDEF" | grep -qi "updated" || { echo "FAIL: session_set_defaults did not succeed"; echo "$RESULTS"; exit 1; }
echo "defaults OK: project/scheme/simulator set for the session"
# Match the real success text exactly ("✅ Build succeeded."), never "❌ Build failed."
echo "$BUILD" | grep -qE "Build succeeded\." || { echo "FAIL: build_sim did not succeed"; echo "$BUILD"; exit 1; }
echo "build OK: build_sim succeeded via the gateway"
# Require a positive pass count AND zero failures. XcodeBuildMCP's FAILURE summary also
# contains the word "passed" ("❌ N tests failed, 0 passed, …"), so a bare "passed" match
# would false-positive; and "✅ Test succeeded." (0 tests) must not match either.
#   success: "✅ N tests passed, 0 failed, S skipped (⏱️ …)"   (N >= 1)
echo "$TEST" | grep -qE '[1-9][0-9]* tests? passed, 0 failed' || { echo "FAIL: test_sim did not pass"; echo "$TEST"; exit 1; }
echo "test OK: test_sim passed via the gateway"

echo "LOOP OK (ssh: $SSH_STATUS): generate → isolate → ssh → discover → build → test, all from a project-only box"
