#!/usr/bin/env bash
# Stage the wpsite CLI (bin/ + lib/) into the Tauri resources dir so `tauri build`
# bundles it INTO wpsite.app. This runs from `beforeBuildCommand`, before Tauri packages
# resources. The app doesn't call the bundled copy directly (it shells out to
# /usr/local/bin/wpsite); the bundle is the SOURCE the installer symlinks from, so the
# app carries its own CLI and stays self-contained in /Applications.
#
# bin/wpsite resolves its real path to find lib/, so the two MUST stay siblings — we copy
# both under resources/cli/{bin,lib}. Staged dir is git-ignored + rebuilt each time.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # wpsite-gui/scripts
GUI="$(dirname "$HERE")"                                # wpsite-gui
REPO="$(dirname "$GUI")"                                # wpsite (repo root)
DEST="$GUI/src-tauri/resources/cli"

[ -f "$REPO/bin/wpsite" ] || { echo "stage-cli: $REPO/bin/wpsite not found" >&2; exit 1; }

rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$REPO/bin" "$DEST/bin"
cp -R "$REPO/lib" "$DEST/lib"
chmod +x "$DEST/bin/wpsite"

echo "stage-cli: bundled wpsite CLI → $DEST (bin/ + lib/)"
