#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export XCBOX_HOME="$T/state"
export XCBOX_BOX_HOME_ROOT="$XCBOX_HOME/boxes"
export XCBOX_PROJECT_METADATA_ROOT="$XCBOX_HOME/projects"
. "$DIR/xcbox-lib.sh"
LIST_SCRIPT="$DIR/xcbox-list.mjs"

fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$XCBOX_BOX_HOME_ROOT/xcbox-isolated" "$XCBOX_BOX_HOME_ROOT/xcbox-retained" "$T/App" "$T/Retained"
printf '1\n' > "$XCBOX_BOX_HOME_ROOT/xcbox-isolated/.xcbox-home-version"
printf '1\n' > "$XCBOX_BOX_HOME_ROOT/xcbox-retained/.xcbox-home-version"
record_box_project xcbox-isolated "$T/App"
record_box_project xcbox-retained "$T/Retained"

FIXTURE="$T/inventory.json"
cat > "$FIXTURE" <<JSON
[
  {
    "id":"xcbox-isolated",
    "configuration":{
      "id":"xcbox-isolated",
      "initProcess":{"workingDirectory":"/inferred/wrong"},
      "mounts":[{"destination":"/root","source":"$XCBOX_BOX_HOME_ROOT/xcbox-isolated"}]
    },
    "status":{"state":"running"}
  },
  {
    "id":"xcbox-legacy",
    "configuration":{
      "id":"xcbox-legacy",
      "initProcess":{"workingDirectory":"/legacy/project"},
      "mounts":[{"destination":"/root","source":"$XCBOX_HOME"}]
    },
    "status":{"state":"stopped"}
  },
  {
    "id":"xcbox-mismatch",
    "configuration":{
      "id":"xcbox-mismatch",
      "initProcess":{"workingDirectory":"/mismatch/project"},
      "mounts":[{"destination":"/root","source":"$T/other-home"}]
    },
    "status":{"state":"stopped"}
  },
  {"id":"unrelated","configuration":{"id":"unrelated"},"status":{"state":"running"}}
]
JSON

OUT=$(node "$LIST_SCRIPT" "$XCBOX_HOME" "$XCBOX_BOX_HOME_ROOT" "$XCBOX_PROJECT_METADATA_ROOT" < "$FIXTURE")
printf '%s\n' "$OUT" | grep -Eq '^STATE +HOME +BOX +PROJECT$' || fail "list header missing"
printf '%s\n' "$OUT" | grep -Eq 'running +isolated +xcbox-isolated +.*/App$' || fail "isolated running box missing or metadata ignored"
printf '%s\n' "$OUT" | grep -Eq 'stopped +legacy/shared +xcbox-legacy +/legacy/project$' || fail "legacy box missing"
printf '%s\n' "$OUT" | grep -Eq 'stopped +mismatch +xcbox-mismatch +/mismatch/project$' || fail "mismatched box missing"
printf '%s\n' "$OUT" | grep -Eq 'retained +isolated +xcbox-retained +.*/Retained$' || fail "retained home missing"
printf '%s\n' "$OUT" | grep -q 'WARNING: xcbox-legacy uses legacy/shared' || fail "legacy warning missing"
printf '%s\n' "$OUT" | grep -q 'WARNING: xcbox-mismatch uses mismatch' || fail "mismatch warning missing"
if printf '%s\n' "$OUT" | grep -q unrelated; then fail "non-xcbox container leaked into list"; fi

EMPTY=$(printf '[]\n' | node "$LIST_SCRIPT" "$T/empty-state" "$T/empty-boxes" "$T/empty-projects")
[ "$EMPTY" = 'xcbox: no boxes or retained homes' ] || fail "empty inventory message unexpected: $EMPTY"

# The CLI command is directory-independent and forwards the same inventory to
# the renderer without attempting project discovery.
mkdir -p "$T/fakebin"
cat > "$T/fakebin/container" <<'EOF'
#!/usr/bin/env bash
[ "$*" = 'ls -a --format json' ] || exit 1
cat "$FAKE_CONTAINER_JSON"
EOF
chmod +x "$T/fakebin/container"
CLI=$(cd /tmp && PATH="$T/fakebin:$PATH" FAKE_CONTAINER_JSON="$FIXTURE" XCBOX_HOME="$XCBOX_HOME" XCBOX_BOX_HOME_ROOT="$XCBOX_BOX_HOME_ROOT" XCBOX_PROJECT_METADATA_ROOT="$XCBOX_PROJECT_METADATA_ROOT" "$DIR/xcbox" list)
printf '%s\n' "$CLI" | grep -q xcbox-retained || fail "CLI list omitted retained home"

# Metadata is host-only bookkeeping: reject a symlinked index instead of
# following it to an unintended path.
BAD="$T/bad-index"
ln -s "$T" "$BAD"
XCBOX_PROJECT_METADATA_ROOT="$BAD"
if record_box_project xcbox-unsafe "$T/App" >/dev/null 2>"$T/unsafe.err"; then
  fail "symlinked metadata root was accepted"
fi
grep -q 'unsafe project metadata path' "$T/unsafe.err" || fail "unsafe metadata path was not explained"

echo "list OK: running/stopped boxes, project metadata, legacy warnings, retained homes"
