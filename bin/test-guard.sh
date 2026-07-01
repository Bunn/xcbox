#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$DIR/xcbox-lib.sh"
T=$(mktemp -d)
mkdir -p "$T/xcodeproj/App.xcodeproj" "$T/ws/App.xcworkspace" "$T/spm" "$T/empty"
: > "$T/spm/Package.swift"
is_ios_project "$T/xcodeproj" || { echo "FAIL: .xcodeproj rejected"; exit 1; }
is_ios_project "$T/ws"        || { echo "FAIL: .xcworkspace rejected"; exit 1; }
is_ios_project "$T/spm"       || { echo "FAIL: Package.swift rejected"; exit 1; }
if is_ios_project "$T/empty"; then echo "FAIL: empty dir accepted"; exit 1; fi
rm -r "$T"
echo "guard OK: accepts xcodeproj/xcworkspace/spm, rejects empty"
