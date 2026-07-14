#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$DIR/xcbox-lib.sh"

[ "$(TERM=xterm-256color host_terminal_type)" = xterm-256color ] \
  || { echo "FAIL: host terminal type was not preserved"; exit 1; }
[ "$(TERM=dumb host_terminal_type)" = xterm-256color ] \
  || { echo "FAIL: dumb terminal did not get the interactive fallback"; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cat > "$T/container" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$XCBOX_CAPTURE"
EOF
chmod +x "$T/container"

export PATH="$T:$PATH"
export XCBOX_CAPTURE="$T/arguments"
export TERM=xterm-256color
export COLORTERM=truecolor
export TERM_PROGRAM=Apple_Terminal
export TERM_PROGRAM_VERSION=455
( enter_box xcbox-test /tmp/TestProject )

cat > "$T/expected" <<EOF
exec
-it
-w
/tmp/TestProject
-e
PATH=$INNER_PATH
-e
TERM=xterm-256color
-e
COLORTERM=truecolor
-e
TERM_PROGRAM=Apple_Terminal
-e
TERM_PROGRAM_VERSION=455
xcbox-test
bash
EOF
cmp -s "$T/expected" "$XCBOX_CAPTURE" \
  || { echo "FAIL: container entry did not preserve the terminal environment"; diff -u "$T/expected" "$XCBOX_CAPTURE"; exit 1; }

echo "terminal OK: interactive shell preserves host color and terminal capabilities"
