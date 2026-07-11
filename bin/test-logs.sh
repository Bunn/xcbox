#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
XCBOX="$DIR/xcbox"
T=$(mktemp -d)
FOLLOW_PID=""
GATEWAY_PID=""
cleanup() {
  [ -z "$FOLLOW_PID" ] || kill "$FOLLOW_PID" >/dev/null 2>&1 || true
  [ -z "$GATEWAY_PID" ] || kill "$GATEWAY_PID" >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

LOG="$T/gateway.log"
printf 'one\ntwo\nthree\nfour\n' > "$LOG"

OUT=$(XCBOX_HOME="$T" XCBOX_LOG_LINES=2 "$XCBOX" logs)
[ "$OUT" = $'three\nfour' ] || fail "XCBOX_LOG_LINES tail unexpected: $OUT"
OUT=$(XCBOX_HOME="$T" "$XCBOX" logs --lines 1)
[ "$OUT" = 'four' ] || fail "--lines tail unexpected: $OUT"
OUT=$(XCBOX_HOME="$T" "$XCBOX" logs -n 3)
[ "$OUT" = $'two\nthree\nfour' ] || fail "-n tail unexpected: $OUT"
OUT=$(XCBOX_HOME="$T" "$XCBOX" logs --lines=2)
[ "$OUT" = $'three\nfour' ] || fail "--lines=N tail unexpected: $OUT"

for args in '--lines' '--lines 0' '--lines nope' '--wat'; do
  # Intentional word splitting exercises the CLI argument combinations above.
  # shellcheck disable=SC2086
  if XCBOX_HOME="$T" "$XCBOX" logs $args >"$T/error.out" 2>"$T/error.err"; then
    fail "invalid logs arguments succeeded: $args"
  fi
done

EMPTY=$(XCBOX_HOME="$T/missing" "$XCBOX" logs -f)
printf '%s\n' "$EMPTY" | grep -q 'no gateway log yet' || fail "missing follow log was not explained"

# Follow mode streams a newly appended line. Stopping the follower must not
# signal an unrelated gateway process.
sleep 30 & GATEWAY_PID=$!
XCBOX_HOME="$T" "$XCBOX" logs --follow --lines 1 > "$T/follow.out" 2> "$T/follow.err" & FOLLOW_PID=$!
printf 'five\n' >> "$LOG"
found=""
for ((attempt=1; attempt<=50; attempt++)); do
  if grep -q '^five$' "$T/follow.out"; then found=1; break; fi
  sleep 0.1
done
[ -n "$found" ] || fail "follow mode did not stream appended line"
kill "$FOLLOW_PID" >/dev/null 2>&1 || true
wait "$FOLLOW_PID" 2>/dev/null || true
FOLLOW_PID=""
kill -0 "$GATEWAY_PID" 2>/dev/null || fail "stopping log follower signaled gateway"
kill "$GATEWAY_PID" >/dev/null 2>&1 || true
wait "$GATEWAY_PID" 2>/dev/null || true
GATEWAY_PID=""

mkdir -p "$T/unsafe"
ln -s "$LOG" "$T/unsafe/gateway.log"
if XCBOX_HOME="$T/unsafe" "$XCBOX" logs >/dev/null 2>"$T/symlink.err"; then
  fail "symlinked gateway log was accepted"
fi
grep -q 'refusing symlinked gateway log' "$T/symlink.err" || fail "symlink refusal was not explained"

echo "logs OK: fixed tail, line controls, follow streaming, safe interruption, argument validation"
