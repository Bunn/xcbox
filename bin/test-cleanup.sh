#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

export XCBOX_HOME="$T/state"
export XCBOX_BOX_HOME_ROOT="$XCBOX_HOME/boxes"
export XCBOX_PROJECT_METADATA_ROOT="$XCBOX_HOME/projects"
. "$DIR/xcbox-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
make_home() {
  mkdir -p "$XCBOX_BOX_HOME_ROOT/$1"
  printf '1\n' > "$XCBOX_BOX_HOME_ROOT/$1/.xcbox-home-version"
}

STALE=xcbox-stale-test
RUNNING=xcbox-running-stale-test
VALID=xcbox-valid-retained-test
mkdir -p "$T/ValidProject" "$T/MissingProject" "$T/MissingRunningProject" "$T/ResetProject/Reset.xcodeproj" "$T/fakebin"
record_box_project "$STALE" "$T/MissingProject"
record_box_agent "$STALE" codex
record_box_project "$RUNNING" "$T/MissingRunningProject"
record_box_agent "$RUNNING" claude
record_box_project "$VALID" "$T/ValidProject"
rm -rf "$T/MissingProject" "$T/MissingRunningProject"
make_home "$STALE"
make_home "$RUNNING"
make_home "$VALID"

RESET_PROJECT="$T/ResetProject"
RESET_NAME=$(sanitize_name "$RESET_PROJECT")
record_box_project "$RESET_NAME" "$RESET_PROJECT"
record_box_agent "$RESET_NAME" codex
make_home "$RESET_NAME"

cat > "$T/all.json" <<JSON
[
  {"id":"$STALE","status":{"state":"stopped"}},
  {"id":"$RUNNING","status":{"state":"running"}},
  {"id":"$RESET_NAME","status":{"state":"running"}}
]
JSON
cat > "$T/running.json" <<JSON
[
  {"id":"$RUNNING","status":{"state":"running"}},
  {"id":"$RESET_NAME","status":{"state":"running"}}
]
JSON

cat > "$T/fakebin/container" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  'ls -a --format json') cat "$FAKE_ALL_JSON" ;;
  'ls --format json') cat "$FAKE_RUNNING_JSON" ;;
  stop\ *|rm\ *) printf '%s\n' "$*" >> "$FAKE_CONTAINER_CALLS" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/fakebin/container"
: > "$T/container.calls"

xcbox() {
  PATH="$T/fakebin:$PATH" \
    XCBOX_HOME="$XCBOX_HOME" XCBOX_BOX_HOME_ROOT="$XCBOX_BOX_HOME_ROOT" \
    XCBOX_PROJECT_METADATA_ROOT="$XCBOX_PROJECT_METADATA_ROOT" \
    FAKE_ALL_JSON="$T/all.json" FAKE_RUNNING_JSON="$T/running.json" \
    FAKE_CONTAINER_CALLS="$T/container.calls" \
    "$DIR/xcbox" "$@"
}

OUT=$(cd /tmp && xcbox prune)
printf '%s\n' "$OUT" | grep -Fq "REMOVE $STALE" || fail "stopped stale box was not planned"
printf '%s\n' "$OUT" | grep -Fq "SKIP   $RUNNING" || fail "running stale box was not skipped"
printf '%s\n' "$OUT" | grep -Fq 'dry run only' || fail "prune did not default to dry-run"
[ -d "$XCBOX_BOX_HOME_ROOT/$STALE" ] || fail "dry-run removed stale home"

OUT=$(cd /tmp && xcbox prune --yes)
printf '%s\n' "$OUT" | grep -Fq 'pruned 1 stale project(s)' || fail "prune count is wrong"
[ ! -e "$XCBOX_BOX_HOME_ROOT/$STALE" ] || fail "stale home survived prune"
[ ! -e "$XCBOX_PROJECT_METADATA_ROOT/$STALE" ] || fail "stale project metadata survived prune"
[ ! -e "$XCBOX_PROJECT_METADATA_ROOT/$STALE.agent" ] || fail "stale agent metadata survived prune"
[ -d "$XCBOX_BOX_HOME_ROOT/$RUNNING" ] || fail "running stale home was pruned"
[ -d "$XCBOX_BOX_HOME_ROOT/$VALID" ] || fail "valid retained home was pruned"
grep -Fq "rm $STALE" "$T/container.calls" || fail "stale container was not removed"
if grep -Fq "$RUNNING" "$T/container.calls"; then fail "running container was modified"; fi

OUT=$(PROJECT="$RESET_PROJECT" xcbox reset)
printf '%s\n' "$OUT" | grep -Fq 'dry run only' || fail "reset did not default to dry-run"
[ -d "$XCBOX_BOX_HOME_ROOT/$RESET_NAME" ] || fail "reset dry-run removed home"
[ -d "$RESET_PROJECT/Reset.xcodeproj" ] || fail "reset dry-run changed source"

OUT=$(PROJECT="$RESET_PROJECT" xcbox reset --yes)
printf '%s\n' "$OUT" | grep -Fq 'reset complete' || fail "reset completion was not reported"
[ ! -e "$XCBOX_BOX_HOME_ROOT/$RESET_NAME" ] || fail "reset home survived"
[ ! -e "$XCBOX_PROJECT_METADATA_ROOT/$RESET_NAME" ] || fail "reset project metadata survived"
[ ! -e "$XCBOX_PROJECT_METADATA_ROOT/$RESET_NAME.agent" ] || fail "reset agent metadata survived"
[ -d "$RESET_PROJECT/Reset.xcodeproj" ] || fail "reset changed source repository"
grep -Fq "stop $RESET_NAME" "$T/container.calls" || fail "running reset box was not stopped"
grep -Fq "rm $RESET_NAME" "$T/container.calls" || fail "reset box was not removed"

# Cleanup helpers must not follow agent-controlled or misplaced symlinks.
mkdir -p "$T/do-not-remove"
printf 'keep\n' > "$T/do-not-remove/sentinel"
ln -s "$T/do-not-remove" "$XCBOX_BOX_HOME_ROOT/xcbox-unsafe-home"
if remove_box_home xcbox-unsafe-home >/dev/null 2>"$T/unsafe-home.err"; then
  fail "symlinked box home was accepted for removal"
fi
[ -f "$T/do-not-remove/sentinel" ] || fail "symlinked box-home target was modified"
grep -q 'unsafe box home' "$T/unsafe-home.err" || fail "unsafe box home was not explained"

SAFE_METADATA_ROOT="$XCBOX_PROJECT_METADATA_ROOT"
ln -s "$T/do-not-remove" "$T/unsafe-metadata"
XCBOX_PROJECT_METADATA_ROOT="$T/unsafe-metadata"
if remove_box_metadata xcbox-unsafe-metadata >/dev/null 2>"$T/unsafe-metadata.err"; then
  fail "symlinked metadata root was accepted for cleanup"
fi
XCBOX_PROJECT_METADATA_ROOT="$SAFE_METADATA_ROOT"
[ -f "$T/do-not-remove/sentinel" ] || fail "symlinked metadata target was modified"
grep -q 'unsafe project metadata path' "$T/unsafe-metadata.err" || fail "unsafe metadata root was not explained"

echo "cleanup OK: dry-run defaults, stale prune, running-box guard, full project reset"
