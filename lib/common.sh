# shellcheck shell=bash
# Shared library for wpsite: logging, config loading, dependency checks, ssh helpers.
# Sourced by bin/wpsite — do not execute directly.

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

WPSITE_VERBOSE="${WPSITE_VERBOSE:-0}"

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  _C_RESET=$'\033[0m'; _C_RED=$'\033[31m'; _C_YEL=$'\033[33m'
  _C_BLU=$'\033[34m'; _C_GRN=$'\033[32m'; _C_DIM=$'\033[2m'
else
  _C_RESET=''; _C_RED=''; _C_YEL=''; _C_BLU=''; _C_GRN=''; _C_DIM=''
fi

_log() { # level color message...
  local level="$1" color="$2"; shift 2
  printf '%s%s%s %s\n' "$color" "$level" "$_C_RESET" "$*" >&2
}

log_info()  { _log "•" "$_C_BLU" "$@"; }
log_ok()    { _log "✓" "$_C_GRN" "$@"; }
log_warn()  { _log "!" "$_C_YEL" "$@"; }
log_error() { _log "✗" "$_C_RED" "$@"; }
log_debug() { [ "$WPSITE_VERBOSE" = "1" ] && _log "·" "$_C_DIM" "$@" || true; }

die() { log_error "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

require() { # cmd [brew-package]
  local cmd="$1" pkg="${2:-$1}"
  have "$cmd" || die "'$cmd' not found. Install with: brew install $pkg"
}

# ---------------------------------------------------------------------------
# Config (YAML, parsed with yq)
# ---------------------------------------------------------------------------

WPSITE_CONFIG="${WPSITE_CONFIG:-$HOME/.config/wpsite/wpsite.yml}"

config_require() {
  require yq
  [ -f "$WPSITE_CONFIG" ] || die "Config not found at $WPSITE_CONFIG (see wpsite.yml.example)"
}

# Expand a leading ~/ to $HOME (avoids eval on config values).
expand_tilde() {
  local stripped="${1#"~/"}"
  if [ "$stripped" != "$1" ]; then    # had a literal ~/ prefix
    printf '%s' "$HOME/$stripped"
  else
    printf '%s' "$1"
  fi
}

# yq query helper; prints empty string for missing keys (never the literal "null").
_yq() { yq -r "$1 // \"\"" "$WPSITE_CONFIG"; }

config_base_dir() {
  local d; d="$(_yq '.base_dir')"
  [ -n "$d" ] || die "base_dir not set in $WPSITE_CONFIG"
  expand_tilde "$d"
}

config_clients() { yq -r '.clients | keys | .[]' "$WPSITE_CONFIG"; }

config_has_client() { yq -e ".clients.\"$1\"" "$WPSITE_CONFIG" >/dev/null 2>&1; }

# client_get <client> <key> — reads .clients.<client>.<key>
client_get() { _yq ".clients.\"$1\".\"$2\""; }

require_client() { # client_name
  local c="$1"
  [ -n "$c" ] || die "No client specified."
  config_has_client "$c" || die "Client '$c' not found in $WPSITE_CONFIG"
}

# Per-client derived paths
client_base()       { printf '%s/%s' "$(config_base_dir)" "$1"; }
client_backup_dir() { printf '%s/backups' "$(client_base "$1")"; }
client_docker_dir() { printf '%s/docker' "$(client_base "$1")"; }

# Local hostname for a replica, e.g. acme.test. Overridable via clients.<c>.local_host.
client_local_host() {
  local override; override="$(client_get "$1" local_host)"
  [ -n "$override" ] && { printf '%s' "$override"; return; }
  printf '%s.test' "$1"
}

# ---------------------------------------------------------------------------
# SSH with connection multiplexing (one auth, reused across calls)
# ---------------------------------------------------------------------------

# Kept under /tmp (not $TMPDIR) because the ControlPath socket has a hard 104-byte
# limit on macOS, and $TMPDIR (/var/folders/...) is too long once the %C hash is added.
WPSITE_SSH_CONTROL_DIR="/tmp/wpsite-ssh.$$"

ssh_setup_mux() {
  mkdir -p "$WPSITE_SSH_CONTROL_DIR"
  chmod 700 "$WPSITE_SSH_CONTROL_DIR"
}

# wpsite_ssh <ssh_target> [ssh args...]
wpsite_ssh() {
  local target="$1"; shift
  ssh -o ControlMaster=auto \
      -o ControlPath="$WPSITE_SSH_CONTROL_DIR/%C" \
      -o ControlPersist=120 \
      "$target" "$@"
}

# ---------------------------------------------------------------------------
# Docker
# ---------------------------------------------------------------------------

# Gracefully tear down a client's compose project: stop+remove containers, the
# network, named volumes (-v) and any orphans. Must pass -p <project> — the
# containers are created with it, and without it Compose guesses the project from
# the directory name and tears down nothing. Works with or without the dir/file.
_compose_down() { # project docker_dir
  local project="$1" dir="$2"
  if [ -f "$dir/docker-compose.yml" ]; then
    ( cd "$dir" && docker compose -p "$project" down -v --remove-orphans >/dev/null 2>&1 || true )
  else
    docker compose -p "$project" down -v --remove-orphans >/dev/null 2>&1 || true
  fi
}

ssh_close_mux() {
  [ -d "$WPSITE_SSH_CONTROL_DIR" ] || return 0
  local sock
  for sock in "$WPSITE_SSH_CONTROL_DIR"/*; do
    [ -S "$sock" ] || continue
    ssh -o ControlPath="$sock" -O exit _ 2>/dev/null || true
  done
  rm -rf "$WPSITE_SSH_CONTROL_DIR"
}
