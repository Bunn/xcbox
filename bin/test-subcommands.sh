#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
XCBOX="$DIR/xcbox"

# status in a dir with no box reports a "no box" state and exits 0 (informational)
OUT=$(cd /tmp && "$XCBOX" status 2>&1) || { echo "FAIL: status errored with no box"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -qi "box" || { echo "FAIL: status did not mention box state: $OUT"; exit 1; }

# rm with no box is a safe no-op (exit 0)
( cd /tmp && "$XCBOX" rm ) >/dev/null 2>&1 || { echo "FAIL: rm errored with no box"; exit 1; }

# logs prints something even when no log file exists (a friendly note), exit 0
XCBOX_HOME=$(mktemp -d) "$XCBOX" logs >/dev/null 2>&1 || { echo "FAIL: logs errored with no log"; exit 1; }

echo "subcommands OK: status/rm/logs safe with no box"
