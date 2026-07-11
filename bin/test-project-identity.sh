#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$DIR/xcbox-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# A unique nested Xcode project is discoverable from the repository root. Two
# artifacts in the same directory still describe one project, and workspaces
# internal to an .xcodeproj are not counted separately.
REPO="$T/repo"
git init -q "$REPO"
mkdir -p "$REPO/apps/My App/MyApp.xcodeproj/project.xcworkspace" \
  "$REPO/apps/My App/MyApp.xcworkspace" "$REPO/apps/My App/Sources" \
  "$REPO/Packages/LocalLibrary"
: > "$REPO/Packages/LocalLibrary/Package.swift"
APP=$(canonical_path "$REPO/apps/My App")
[ "$(resolve_project_dir "$REPO")" = "$APP" ] || fail "unique nested Xcode project was not resolved from repo root"
[ "$(resolve_project_dir "$REPO/apps/My App/Sources")" = "$APP" ] || fail "nearest project ancestor was not resolved"

# Xcode projects take precedence over nested Swift dependency packages.
[ "$(discover_project_dirs "$REPO")" = "$APP" ] || fail "nested Package.swift displaced the Xcode project"

# Lifecycle commands use that same resolution. A fake container CLI keeps this
# focused on selection/naming and guarantees no real box is touched.
FAKEBIN="$T/fakebin"
mkdir -p "$FAKEBIN" "$T/xcbox-home"
cat > "$FAKEBIN/container" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAKEBIN/container"
STATUS=$(PATH="$FAKEBIN:$PATH" XCBOX_HOME="$T/xcbox-home" GATEWAY_PORT=65432 PROJECT="$REPO" "$DIR/xcbox" status)
printf '%s\n' "$STATUS" | grep -Fq "xcbox status — $APP" || fail "status did not resolve the nested project"
BOX_NAME=$(sanitize_name "$APP")
REMOVE=$(PATH="$FAKEBIN:$PATH" PROJECT="$REPO" "$DIR/xcbox" rm)
printf '%s\n' "$REMOVE" | grep -Fq "$BOX_NAME" || fail "rm did not use canonical project identity"

# Canonical identity is stable through symlinks and differs for same-basename
# projects at different paths.
ln -s "$REPO/apps/My App" "$T/app-link"
[ "$(sanitize_name "$T/app-link")" = "$(sanitize_name "$APP")" ] || fail "symlink produced a second box identity"
OTHER="$T/other/My App"
mkdir -p "$OTHER/Other.xcodeproj"
[ "$(sanitize_name "$OTHER")" != "$(sanitize_name "$APP")" ] || fail "same-basename projects collided"
case "$(sanitize_name "$APP")" in xcbox-my-app-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) fail "unexpected box name: $(sanitize_name "$APP")" ;; esac

# Old basename-only boxes are reported only when no canonical box exists.
LEGACY=$(legacy_box_name "$APP")
box_exists() { [ "$1" = "$LEGACY" ]; }
legacy_box_detected "$APP" "$BOX_NAME" || fail "legacy box was not detected"
box_exists() { [ "$1" = "$LEGACY" ] || [ "$1" = "$BOX_NAME" ]; }
if legacy_box_detected "$APP" "$BOX_NAME"; then fail "legacy box blocked an existing canonical box"; fi
unset -f box_exists

# Once a second Xcode project exists, repository-root discovery is ambiguous
# and must explain how to select explicitly. Starting within either project is
# still unambiguous.
mkdir -p "$REPO/tools/Helper/Helper.xcodeproj"
ERR="$T/ambiguity.err"
if resolve_project_dir "$REPO" >"$T/ambiguity.out" 2>"$ERR"; then
  fail "ambiguous repository root selected a project"
else
  RC=$?
fi
[ "$RC" -eq 2 ] || fail "ambiguity returned $RC instead of 2"
[ ! -s "$T/ambiguity.out" ] || fail "ambiguity wrote a project to stdout"
grep -Fq "$APP" "$ERR" || fail "ambiguity did not list the app"
grep -Fq "$REPO/tools/Helper" "$ERR" || fail "ambiguity did not list the helper"
grep -Fq "PROJECT" "$ERR" || fail "ambiguity did not explain explicit selection"
[ "$(resolve_project_dir "$APP")" = "$APP" ] || fail "explicit project directory became ambiguous"
if PATH="$FAKEBIN:$PATH" PROJECT="$REPO" "$DIR/xcbox" status >"$T/status.out" 2>"$T/status.err"; then
  fail "status selected a box for an ambiguous repository"
else
  RC=$?
fi
[ "$RC" -eq 2 ] || fail "status ambiguity returned $RC instead of 2"
[ ! -s "$T/status.out" ] || fail "ambiguous status inspected a box"

# Package-only repositories get the same nested discovery behavior.
PACKAGE_REPO="$T/package-repo"
git init -q "$PACKAGE_REPO"
mkdir -p "$PACKAGE_REPO/libs/OnlyPackage/Sources"
: > "$PACKAGE_REPO/libs/OnlyPackage/Package.swift"
PACKAGE=$(canonical_path "$PACKAGE_REPO/libs/OnlyPackage")
[ "$(resolve_project_dir "$PACKAGE_REPO")" = "$PACKAGE" ] || fail "unique nested package was not resolved"
[ "$(resolve_project_dir "$PACKAGE_REPO/libs/OnlyPackage/Sources")" = "$PACKAGE" ] || fail "package ancestor was not resolved"

echo "project identity OK: nested discovery, ambiguity, canonical paths, collision-safe names"
