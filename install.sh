#!/usr/bin/env bash
# install.sh — put `xcbox` on your PATH by symlinking bin/xcbox into a bin dir.
#
# Usage:
#   ./install.sh                 # auto-pick a writable bin dir already on PATH
#   ./install.sh /usr/local/bin  # install into a specific dir
#   PREFIX="$HOME/bin" ./install.sh
#   ./install.sh --uninstall     # remove the xcbox symlink(s) we created
#
# Only the symlink is created — xcbox still runs from this repo (it resolves the
# symlink to find its lib), so `git pull` here updates the installed command.
set -euo pipefail

# Repo root = dir containing this script (follow symlinks).
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  d=$(cd -P "$(dirname "$SELF")" && pwd); SELF=$(readlink "$SELF")
  case $SELF in /*) ;; *) SELF="$d/$SELF" ;; esac
done
REPO=$(cd -P "$(dirname "$SELF")" && pwd)
XCBOX="$REPO/bin/xcbox"
[ -x "$XCBOX" ] || { echo "error: $XCBOX not found or not executable" >&2; exit 1; }

on_path() { case ":$PATH:" in *":$1:"*) return 0 ;; *) return 1 ;; esac; }

CANDIDATES=(/opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/bin")

# --- uninstall ---
if [ "${1:-}" = "--uninstall" ]; then
  removed=""
  for d in "${CANDIDATES[@]}"; do
    link="$d/xcbox"
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$XCBOX" ]; then
      rm -f "$link" && { echo "removed $link"; removed=1; }
    fi
  done
  [ -n "$removed" ] || echo "no xcbox symlink pointing at $XCBOX found on PATH"
  exit 0
fi

# --- choose target dir: explicit arg/PREFIX, else first writable dir on PATH ---
TARGET="${1:-${PREFIX:-}}"
if [ -z "$TARGET" ]; then
  for d in "${CANDIDATES[@]}"; do
    if [ -d "$d" ] && [ -w "$d" ] && on_path "$d"; then TARGET="$d"; break; fi
  done
fi
if [ -z "$TARGET" ]; then TARGET="$HOME/.local/bin"; mkdir -p "$TARGET"; fi

# --- validate ---
[ -d "$TARGET" ] || { echo "error: target dir $TARGET does not exist" >&2; exit 1; }
if [ ! -w "$TARGET" ]; then
  echo "error: $TARGET is not writable. Re-run with sudo or pick another dir:" >&2
  echo "  sudo ./install.sh \"$TARGET\"   OR   PREFIX=\"\$HOME/.local/bin\" ./install.sh" >&2
  exit 1
fi

# --- link ---
ln -sf "$XCBOX" "$TARGET/xcbox"
echo "linked $TARGET/xcbox -> $XCBOX"

# --- verify + PATH advice ---
if on_path "$TARGET"; then
  if command -v xcbox >/dev/null 2>&1 && xcbox help >/dev/null 2>&1; then
    echo "✅ installed — run 'xcbox' from any project directory (verified: resolves + loads its lib)"
  else
    echo "✅ linked, but 'xcbox' didn't run cleanly — check: xcbox help"
  fi
else
  echo "⚠️  $TARGET is not on your PATH. Add it and restart your shell:"
  echo "    echo 'export PATH=\"$TARGET:\$PATH\"' >> ~/.zshrc"
fi
