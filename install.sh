#!/usr/bin/env bash
#
# wpsite installer — symlinks bin/wpsite onto your PATH.
#
#   ./install.sh              install (symlink into /usr/local/bin)
#   ./install.sh --uninstall  remove the symlink
#
# Override the target dir:  WPSITE_BIN_DIR=~/.local/bin ./install.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/bin/wpsite"
BIN_DIR="${WPSITE_BIN_DIR:-/usr/local/bin}"
TARGET="$BIN_DIR/wpsite"

# True if we can write into BIN_DIR (or its nearest existing parent) without sudo.
_writable() {
  local d="$BIN_DIR"
  while [ ! -e "$d" ] && [ "$d" != "/" ]; do d="$(dirname "$d")"; done
  [ -w "$d" ]
}
# Run a command, escalating with sudo only when needed.
as_root() {
  if _writable; then "$@"; else sudo "$@"; fi
}

if [ "${1:-}" = "--uninstall" ]; then
  if [ -L "$TARGET" ] || [ -e "$TARGET" ]; then
    as_root rm -f "$TARGET"
    echo "✓ Removed $TARGET"
  else
    echo "Nothing installed at $TARGET"
  fi
  exit 0
fi

[ -f "$SRC" ] || { echo "ERROR: $SRC not found (run install.sh from the repo)." >&2; exit 1; }
chmod +x "$SRC"

[ -d "$BIN_DIR" ] || as_root mkdir -p "$BIN_DIR"
_writable || echo "Writing to $BIN_DIR needs sudo — you may be prompted for your password."

# Symlink (not copy): the dispatcher resolves its real path to find lib/, so a bare
# copy would break. -n avoids descending into an existing symlinked dir.
as_root ln -sfn "$SRC" "$TARGET"
echo "✓ Linked $TARGET -> $SRC"

echo
echo "Next steps:"
echo "  1) wpsite doctor"
echo "     # if anything's missing: brew install yq imagemagick ffmpeg; brew install --cask docker"
echo "  2) mkdir -p ~/.config/wpsite && cp \"$ROOT/wpsite.yml.example\" ~/.config/wpsite/wpsite.yml"
echo "  3) edit ~/.config/wpsite/wpsite.yml, then:  wpsite backup <client>"
echo
echo "This is a symlink into the repo at:"
echo "  $ROOT"
echo "Keep the repo where it is (moving/deleting it breaks the command)."
