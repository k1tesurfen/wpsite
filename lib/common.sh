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

# client_set <client> <key> <value> — in-place config write (yq -i, NOT eval/source;
# preserves comments). yq appends a brand-new client at the end of .clients. Strings
# only — fine for ssh/wp_root/local_host/... fields (list fields stay hand-edited).
client_set() { # client key value
  yq -i ".clients.\"$1\".\"$2\" = \"$3\"" "$WPSITE_CONFIG"
}

# Remove a client's whole config entry (used by `client remove` / to roll back a failed add).
config_remove_client() { yq -i "del(.clients.\"$1\")" "$WPSITE_CONFIG"; }

# client_unset <client> <key> — delete one key under a client (used by `client edit --unset`).
client_unset() { yq -i "del(.clients.\"$1\".\"$2\")" "$WPSITE_CONFIG"; }

require_client() { # client_name
  local c="$1"
  [ -n "$c" ] || die "No client specified."
  config_has_client "$c" || die "Client '$c' not found in $WPSITE_CONFIG"
}

# ---------------------------------------------------------------------------
# Dev sites (local-only sandboxes; no SSH source). Live under .dev in the config,
# created by `wpsite new` / `wpsite clone`. A name is EITHER a client or a dev site
# — never both (the creators refuse a name that already exists as either kind).
# ---------------------------------------------------------------------------

# null-guarded: `keys` on a missing .dev would error, so default to {}.
config_dev_sites() { yq -r '(.dev // {}) | keys | .[]' "$WPSITE_CONFIG"; }

config_has_dev() { yq -e ".dev.\"$1\"" "$WPSITE_CONFIG" >/dev/null 2>&1; }

# dev_get <name> <key> — reads .dev.<name>.<key>
dev_get() { _yq ".dev.\"$1\".\"$2\""; }

# dev_set <name> <key> <value> — in-place config write (yq -i, NOT eval/source;
# preserves comments). Strings only — fine for host/version/source fields.
dev_set() { # name key value
  yq -i ".dev.\"$1\".\"$2\" = \"$3\"" "$WPSITE_CONFIG"
}

# Remove a dev site's whole config entry (used by `destroy`).
config_remove_dev() { yq -i "del(.dev.\"$1\")" "$WPSITE_CONFIG"; }

# Classify a name: "client", "dev", or "" (unknown). Clients win on collision,
# though the creators prevent collisions in the first place.
target_kind() { # name
  if config_has_client "$1"; then printf 'client'
  elif config_has_dev "$1"; then printf 'dev'
  fi
  return 0
}

require_target() { # name
  local n="$1"
  [ -n "$n" ] || die "No site specified."
  [ -n "$(target_kind "$n")" ] || die "No client or dev site named '$n' in $WPSITE_CONFIG"
}

# Every managed site (clients + dev), one per line. Used by status / stop --all.
config_all_targets() { config_clients; config_dev_sites; }

# A DNS-label-safe site name: lowercase letters, digits, hyphens; not empty; no
# leading/trailing hyphen. Used for container names, the compose project, the
# .test host and the proxy route filename, so it must be strict.
_valid_site_name() { # name
  local n="$1"
  [[ "$n" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]
}

# Per-client derived paths (SSH-backed clients live under base_dir/clients/).
client_base()       { printf '%s/clients/%s' "$(config_base_dir)" "$1"; }
client_backup_dir() { printf '%s/backups' "$(client_base "$1")"; }
client_docker_dir() { printf '%s/docker' "$(client_base "$1")"; }

# ---------------------------------------------------------------------------
# Cloud backup sync (mounted Google Drive folder = single source of truth)
# ---------------------------------------------------------------------------

# Global cloud root (the mounted Drive folder). Empty when the feature isn't
# configured — every cloud operation then no-ops with a quiet skip.
config_cloud_base() {
  local d; d="$(_yq '.cloud_base')"
  [ -n "$d" ] && expand_tilde "$d"
  return 0
}

# Rolling-retention count. Default 4; global .keep_backups overrides the default.
config_keep_backups() {
  local n; n="$(_yq '.keep_backups')"
  case "$n" in ''|*[!0-9]*) printf '4' ;; *) printf '%s' "$n" ;; esac
}

# Retention for one client: clients.<c>.keep_backups → global → 4.
client_keep_backups() { # client
  local n; n="$(client_get "$1" keep_backups)"
  case "$n" in ''|*[!0-9]*) config_keep_backups ;; *) printf '%s' "$n" ;; esac
}

# Production domain (host only, no proto/path/port/www) from the newest backup's
# meta.env SOURCE_HOME — the default cloud subfolder name. Empty if none yet.
_cloud_domain_from_meta() { # client
  local backup_dir latest meta source_home host
  backup_dir="$(client_backup_dir "$1")"
  [ -d "$backup_dir" ] || return 0
  # shellcheck disable=SC2012  # timestamp dirs; mtime sort via ls is fine
  latest="$(ls -td "$backup_dir"/*/ 2>/dev/null | head -1)"; latest="${latest%/}"
  [ -n "$latest" ] || return 0
  meta="$latest/meta.env"
  [ -f "$meta" ] || return 0
  source_home="$(grep -m1 '^SOURCE_HOME=' "$meta" 2>/dev/null | cut -d= -f2- || true)"
  [ -n "$source_home" ] || return 0
  host="${source_home#*://}"; host="${host%%/*}"; host="${host%%:*}"; host="${host#www.}"
  printf '%s' "$host"
}

# Cloud backup dir for a client. Override (clients.<c>.cloud_dir) is an absolute
# path used verbatim; otherwise <cloud_base>/<production-domain>. Empty when
# cloud_base is unset (feature off) or no domain can be derived yet.
client_cloud_dir() { # client
  local override; override="$(client_get "$1" cloud_dir)"
  if [ -n "$override" ]; then expand_tilde "$override"; return 0; fi
  local base domain
  base="$(config_cloud_base)"
  [ -n "$base" ] || return 0
  domain="$(_cloud_domain_from_meta "$1")"
  [ -n "$domain" ] || return 0
  printf '%s/%s' "${base%/}" "$domain"
}

# True when a client's cloud dir resolves AND its parent (the Drive mount) exists
# — i.e. we can safely read/write it. Guards every cloud op so an unmounted Drive
# degrades to a warning, never a failure.
cloud_available() { # client
  local dir; dir="$(client_cloud_dir "$1")"
  [ -n "$dir" ] || return 1
  [ -d "$(dirname "$dir")" ]
}

# A backup dir is "complete" (eligible to sync/build) only with all core artifacts.
_is_complete_backup() { # dir
  local d="$1"
  [ -s "$d/db.sql" ] && [ -s "$d/wp-content.tar.gz" ] && [ -s "$d/meta.env" ]
}

# Backup folder identity: YYYYMMDD_HHMMSS, optionally a -permanent suffix.
_is_backup_id()         { [[ "$1" =~ ^[0-9]{8}_[0-9]{6}(-permanent)?$ ]]; }
_is_persistent_backup() { case "$(basename "$1")" in *-permanent) return 0 ;; *) return 1 ;; esac; }

# Map a backup id to its dir, tolerating the -permanent suffix (option A): a bare
# id resolves to <id>-permanent when only the persistent variant exists. Returns
# the canonical path even when missing, so callers can produce their own error.
resolve_backup_dir() { # client id
  local bd id
  bd="$(client_backup_dir "$1")"; id="$2"
  if   [ -d "$bd/$id" ];           then printf '%s/%s' "$bd" "$id"
  elif [ -d "$bd/$id-permanent" ]; then printf '%s/%s-permanent' "$bd" "$id"
  else printf '%s/%s' "$bd" "$id"; fi
}

# Per-dev-site derived paths (local sandboxes live under base_dir/dev/; no backups).
dev_base()       { printf '%s/dev/%s' "$(config_base_dir)" "$1"; }
dev_docker_dir() { printf '%s/docker' "$(dev_base "$1")"; }

# Docker dir for either kind — lifecycle/destroy/status resolve a name to its dir.
target_docker_dir() { # name
  case "$(target_kind "$1")" in
    dev) dev_docker_dir "$1" ;;
    *)   client_docker_dir "$1" ;;
  esac
}

# Ensure the clients/ and dev/ subfolders exist under base_dir. Called when a site
# is created/added; mkdir -p on the full per-site chain also creates them, but this
# guarantees both top-level buckets exist explicitly.
_ensure_base_layout() {
  mkdir -p "$(config_base_dir)/clients" "$(config_base_dir)/dev"
  return 0
}

# Extract the base domain from a URL/hostname and return it with .test suffix.
_local_host_from_url() {
  local url="$1"
  # Strip protocol
  local host="${url#*://}"
  # Strip path/query
  host="${host%%/*}"
  # Strip port if present
  host="${host%%:*}"
  # Strip www.
  host="${host#www.}"

  # Strip common TLD suffixes: .co.uk, .com.au, .or.at, etc.
  case "$host" in
    *.co.*|*.com.*|*.org.*|*.net.*|*.gov.*|*.edu.*)
      local temp="${host%.*}"
      host="${temp%.*}"
      ;;
    *)
      host="${host%.*}"
      ;;
  esac

  printf '%s.test' "$host"
}

# Local hostname for a replica, e.g. acme.test. Overridable via clients.<c>.local_host.
client_local_host() {
  local client="$1"
  local override; override="$(client_get "$client" local_host)"
  [ -n "$override" ] && { printf '%s' "$override"; return; }

  # Dynamically extract from the newest backup's meta.env if it exists
  local backup_dir latest meta source_home
  backup_dir="$(client_backup_dir "$client")"
  if [ -d "$backup_dir" ]; then
    # shellcheck disable=SC2012
    latest="$(ls -td "$backup_dir"/*/ 2>/dev/null | head -1)"
    latest="${latest%/}"
    meta="$latest/meta.env"
    if [ -f "$meta" ]; then
      source_home="$(grep -m1 "^SOURCE_HOME=" "$meta" 2>/dev/null | cut -d= -f2- || true)"
      if [ -n "$source_home" ]; then
        _local_host_from_url "$source_home"
        return
      fi
    fi
  fi

  # Fallback to the client identifier
  printf '%s.test' "$client"
}

# Local hostname for either kind of site. Dev sites store their host explicitly
# (default <name>.test); clients derive it from the backup (client_local_host).
target_local_host() { # name
  if config_has_dev "$1"; then
    local h; h="$(dev_get "$1" host)"
    [ -n "$h" ] && { printf '%s' "$h"; return; }
    printf '%s.test' "$1"
  else
    client_local_host "$1"
  fi
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
