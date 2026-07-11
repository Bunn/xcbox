#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
XCBOX="$DIR/xcbox"

OUT=$("$XCBOX" doctor 2>&1 || true)
# Reports each prerequisite by name.
for label in "Apple Silicon" "macOS" "Xcode" "Node/npm" "container CLI" "gateway route" "git identity" "SSH agent"; do
  echo "$OUT" | grep -qi "$label" || { echo "FAIL: doctor missing check '$label'"; echo "$OUT"; exit 1; }
done
echo "doctor OK: all prerequisite checks reported"
