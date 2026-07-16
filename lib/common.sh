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

# The mandos CLI owns the client registry, SSH access and Google Drive paths; wpsite
# shells out to it (see the client-registry + cloud sections below). Override for tests
# via MANDOS_BIN (point it at a stub).
MANDOS_BIN="${MANDOS_BIN:-mandos}"

config_require() {
  require yq
  require "$MANDOS_BIN"
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

# ---------------------------------------------------------------------------
# Client registry — OWNED BY MANDOS.
# wpsite no longer reads or writes the shared client YAML directly; it shells out to
# the `mandos` CLI, which resolves the two-layer local/team config (the team file on
# Google Drive is the source of truth), preserves comments on edits, and refuses
# writes when Drive is unmounted. These helpers keep their original names/signatures
# so the many callers across lib/ don't change.
# ---------------------------------------------------------------------------

# Resolved path of the shared client registry (mandos's team file), or empty when
# mandos runs solo. Kept for doctor/setup/client status messages. (Legacy name.)
_team_config_path() { "$MANDOS_BIN" config get team-config 2>/dev/null || true; }

# Reachability probe for the client registry: prints the registry file path and
# returns 0 when reachable, non-zero when a team file is configured but missing
# (Drive unmounted). Used to skip optional team-config writes. (Legacy name, now a shim.)
_client_file() {
  local t; t="$(_team_config_path)"
  [ -n "$t" ] || { printf '%s' "$WPSITE_CONFIG"; return 0; }   # mandos solo → local file
  [ -f "$t" ] || return 1
  printf '%s' "$t"
}

config_base_dir() {
  local d; d="$(_yq '.base_dir')"
  [ -n "$d" ] || die "base_dir not set in $WPSITE_CONFIG"
  expand_tilde "$d"
}

# Client registry helpers — thin adapters over `mandos client …`. The read helpers end
# with `|| true` so a `set -e` script never aborts when the registry is unreachable
# (mandos already explains why on stderr); they degrade to empty output instead.
config_clients()       { "$MANDOS_BIN" client list || true; }
config_has_client()    { "$MANDOS_BIN" client has "$1"; }
client_get()           { "$MANDOS_BIN" client get "$1" "$2" 2>/dev/null || true; }
client_set()           { "$MANDOS_BIN" client set "$1" "$2" "$3"; }
config_remove_client() { "$MANDOS_BIN" client remove "$1" >/dev/null 2>&1 || true; }
client_unset()         { "$MANDOS_BIN" client unset "$1" "$2"; }

require_client() { # client_name
  local c="$1"
  [ -n "$c" ] || die "No client specified."
  "$MANDOS_BIN" client has "$c" || die "Client '$c' not found (see: mandos client list)."
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

# Global cloud root — now owned by mandos (its local config's cloud_base). Empty when
# unset; every cloud operation then no-ops with a quiet skip. The per-client backup
# folder resolution below (client_cloud_dir) still lives in wpsite: it's derived from
# wpsite's own backup metadata (_cloud_domain_from_meta).
config_cloud_base() { "$MANDOS_BIN" cloud base 2>/dev/null || true; }

# Rolling retention is a FIXED team-wide policy: keep the newest 5 non-permanent
# backups per client. Deliberately NOT configurable — everyone prunes to the same
# depth on the shared cloud. Persist a backup (`--persist`) to exempt it. These stay
# functions (arg-tolerant) so callers don't change.
WPSITE_KEEP_BACKUPS=5
config_keep_backups() { printf '%s' "$WPSITE_KEEP_BACKUPS"; }
client_keep_backups() { printf '%s' "$WPSITE_KEEP_BACKUPS"; }

# Production domain (host only, no proto/path/port/www) from a backup's meta.env
# SOURCE_HOME — the default cloud subfolder name. Empty if none yet. Scans backups
# newest→oldest and uses the first with a valid SOURCE_HOME, so an incomplete newest
# backup (interrupted run, no meta.env) doesn't hide the domain earlier runs recorded.
_cloud_domain_from_meta() { # client
  local backup_dir d meta source_home host
  backup_dir="$(client_backup_dir "$1")"
  [ -d "$backup_dir" ] || return 0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    meta="${d%/}/meta.env"
    [ -f "$meta" ] || continue
    source_home="$(grep -m1 '^SOURCE_HOME=' "$meta" 2>/dev/null | cut -d= -f2- || true)"
    [ -n "$source_home" ] || continue
    host="${source_home#*://}"; host="${host%%/*}"; host="${host%%:*}"; host="${host#www.}"
    printf '%s' "$host"
    return 0
  done < <(
    # shellcheck disable=SC2012  # timestamp dirs; mtime sort via ls is fine
    ls -td "$backup_dir"/*/ 2>/dev/null
  )
  return 0
}

# Backups live in a fixed subfolder INSIDE each domain's project folder — never at
# the domain root. The rest of the domain folder (assets, layout, kunde input, …) is
# the team's working folder and must never be touched by wpsite.
WPSITE_CLOUD_BACKUP_SUBDIR="100_Backup"

# Cloud backup dir for a client, as <cloud_base>/<project-folder>/100_Backup.
# The <project-folder> is, in order of precedence:
#   1. clients.<c>.cloud_dir  — a FULL absolute path, used verbatim (machine-specific,
#      discouraged in the shared team config; escape hatch only).
#   2. clients.<c>.cloud_folder — just the folder NAME under cloud_base (PORTABLE:
#      resolves against each colleague's own cloud_base). Use this when the site's
#      backup domain (a staging/dev URL) doesn't match the curated Drive folder name.
#   3. the production domain derived from meta.env (_cloud_domain_from_meta).
# Empty when cloud_base is unset (feature off) or no folder can be determined. The
# domain folder itself is NEVER created — cloud_available() requires it to pre-exist,
# so only the 100_Backup subfolder is ever written.
client_cloud_dir() { # client
  local override; override="$(client_get "$1" cloud_dir)"
  if [ -n "$override" ]; then expand_tilde "$override"; return 0; fi
  local base folder
  base="$(config_cloud_base)"
  [ -n "$base" ] || return 0
  folder="$(client_get "$1" cloud_folder)"
  [ -n "$folder" ] || folder="$(_cloud_domain_from_meta "$1")"
  [ -n "$folder" ] || return 0
  printf '%s/%s/%s' "${base%/}" "$folder" "$WPSITE_CLOUD_BACKUP_SUBDIR"
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
  # The shared Adminer container attaches to a site's project network on demand
  # (wpsite db); detach it first so `compose down` can actually remove that
  # network instead of leaving it dangling. Best-effort, harmless when absent.
  if [ -n "${WPSITE_ADMINER_CONTAINER:-}" ]; then
    docker network disconnect -f "${project}_default" "$WPSITE_ADMINER_CONTAINER" >/dev/null 2>&1 || true
  fi
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
