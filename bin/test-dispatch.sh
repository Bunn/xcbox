#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
XCBOX="$DIR/xcbox"

# help lists the subcommands
"$XCBOX" help 2>&1 | grep -q "up" || { echo "FAIL: help missing 'up'"; exit 1; }
for c in list status stop logs rm doctor; do
  "$XCBOX" help 2>&1 | grep -q "$c" || { echo "FAIL: help missing '$c'"; exit 1; }
done

# unknown command exits non-zero with usage
if "$XCBOX" boguscmd >/dev/null 2>&1; then echo "FAIL: unknown command succeeded"; exit 1; fi

# default (no arg) routes to 'up' → in a non-iOS dir, up's guard rejects it
OUT=$(cd /tmp && "$XCBOX" 2>&1 || true)
echo "$OUT" | grep -qi "no .xcodeproj" || { echo "FAIL: default did not route to up's project guard: $OUT"; exit 1; }

echo "dispatch OK: help, unknown-command, default→up guard"
