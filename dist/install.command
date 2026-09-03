#!/usr/bin/env bash
#
# wpsite suite installer — double-click this file to install everything.
#
# It opens in Terminal and, using the Homebrew you already have, installs the runtime
# dependencies, copies the app(s) into /Applications, and wires the bundled CLIs onto
# your PATH. Re-runnable and safe: it only ever adds/updates, and asks for your password
# once (for the /usr/local/bin symlinks).
#
# Distribute this file NEXT TO wpsite.app (and, once it exists, mandos.app) + the Brewfile
# — see dist/README.md for how to assemble the delivery folder.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="/Applications"
BIN_DIR="/usr/local/bin"

# ── pretty logging ──────────────────────────────────────────────────────────
c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
step() { printf '\n%s▶ %s%s\n' "$c_dim" "$1" "$c_off"; }
ok()   { printf '%s✓ %s%s\n' "$c_ok" "$1" "$c_off"; }
warn() { printf '%s! %s%s\n' "$c_warn" "$1" "$c_off"; }
die()  { printf '%s✗ %s%s\n' "$c_err" "$1" "$c_off" >&2; printf '\nDrücke eine Taste zum Schließen …\n'; read -r -n 1; exit 1; }

# Run a command, escalating with sudo only when the target dir isn't writable.
as_root() { if [ -w "$1" ] || { [ ! -e "$1" ] && [ -w "$(dirname "$1")" ]; }; then shift; "$@"; else shift; sudo "$@"; fi; }

echo "═══════════════════════════════════════════════"
echo "  wpsite — Installation"
echo "═══════════════════════════════════════════════"

# ── 1. Homebrew (assumed present) ─────────────────────────────────────────────
step "Prüfe Homebrew …"
if ! command -v brew >/dev/null 2>&1; then
  die "Homebrew nicht gefunden. Bitte zuerst installieren: https://brew.sh  (dann diese Datei erneut ausführen)."
fi
ok "Homebrew gefunden: $(command -v brew)"

# ── 2. runtime dependencies via Brewfile ──────────────────────────────────────
step "Installiere Abhängigkeiten (yq, imagemagick, ffmpeg, Docker) …"
if [ -f "$HERE/Brewfile" ]; then
  brew bundle --file="$HERE/Brewfile" || warn "Einige Formeln konnten nicht installiert werden — siehe oben."
  ok "Abhängigkeiten verarbeitet."
else
  warn "Kein Brewfile neben dieser Datei — überspringe Abhängigkeiten."
fi

# ── 3. copy app bundles into /Applications ────────────────────────────────────
# Copy an <app>.app from the delivery folder to /Applications (replacing any old copy)
# and clear its quarantine flag so it launches without the Gatekeeper block (the suite is
# unsigned; the user is deliberately installing it).
install_app() {
  local app="$1" src="$HERE/$1"
  if [ ! -d "$src" ]; then
    return 1
  fi
  step "Installiere $app nach $APPS_DIR …"
  as_root "$APPS_DIR/$app" rm -rf "$APPS_DIR/$app"
  as_root "$APPS_DIR" cp -R "$src" "$APPS_DIR/$app"
  xattr -dr com.apple.quarantine "$APPS_DIR/$app" 2>/dev/null || true
  ok "$app installiert."
  return 0
}

install_app "wpsite.app" || die "wpsite.app liegt nicht neben dieser Datei — Lieferordner unvollständig."
install_app "mandos.app" || warn "mandos.app nicht gefunden — überspringe (die GUI ist optional; die mandos-CLI wird unten separat behandelt)."

# ── 4. symlink the bundled CLIs onto PATH ─────────────────────────────────────
# The CLI is bundled inside the app; find it by name (robust to the exact Resources
# subpath) and symlink it into /usr/local/bin. bin/wpsite resolves its real path to find
# lib/, so the symlink into the bundle works and lib/ stays alongside it.
link_cli() {
  local name="$1" app="$2" src
  src="$(find "$APPS_DIR/$app/Contents/Resources" -type f -name "$name" -path '*/bin/*' 2>/dev/null | head -1 || true)"
  [ -z "$src" ] && src="$(find "$APPS_DIR/$app/Contents/Resources" -type f -name "$name" 2>/dev/null | head -1 || true)"
  if [ -z "$src" ]; then
    return 1
  fi
  chmod +x "$src" 2>/dev/null || true
  as_root "$BIN_DIR" mkdir -p "$BIN_DIR"
  as_root "$BIN_DIR/$name" ln -sfn "$src" "$BIN_DIR/$name"
  ok "$name → $BIN_DIR/$name"
  return 0
}

step "Verknüpfe die Kommandozeilen-Tools (evtl. Passwort-Abfrage) …"
link_cli "wpsite" "wpsite.app" || die "wpsite-CLI im App-Bundle nicht gefunden."

if [ -d "$APPS_DIR/mandos.app" ]; then
  link_cli "mandos" "mandos.app" || warn "mandos-CLI im mandos.app-Bundle nicht gefunden."
elif ! command -v mandos >/dev/null 2>&1; then
  warn "mandos-CLI fehlt. Installiere sie separat:  cd ~/git/mandos && make install"
else
  ok "mandos bereits vorhanden: $(command -v mandos)"
fi

# ── done ──────────────────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════"
ok "Installation abgeschlossen."
echo '  • Starte „wpsite“ aus dem Programme-Ordner (Launchpad/Spotlight).'
echo '  • Beim ersten Start führt dich die App durch die Einrichtung.'
echo '  • Docker Desktop einmalig starten und die Rechte-Abfrage bestätigen.'
echo "═══════════════════════════════════════════════"
printf '\nDrücke eine Taste zum Schließen …\n'
read -r -n 1
