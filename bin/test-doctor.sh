#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
XCBOX="$DIR/xcbox"

OUT=$("$XCBOX" doctor 2>&1 || true)
# Reports each prerequisite by name.
for label in "Apple Silicon" "macOS" "Xcode" "container CLI" "git identity" "SSH agent"; do
  echo "$OUT" | grep -qi "$label" || { echo "FAIL: doctor missing check '$label'"; echo "$OUT"; exit 1; }
done
# On this dev machine (arm64 + Xcode + container present), doctor should pass.
"$XCBOX" doctor >/dev/null 2>&1 || { echo "FAIL: doctor did not pass on a configured host"; "$XCBOX" doctor; exit 1; }

echo "doctor OK: all prerequisite checks reported and passing"
