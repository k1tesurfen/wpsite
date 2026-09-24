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

# ---------------------------------------------------------------------------
# Platform shims
#
# wpsite runs on macOS (gateway) and Debian 13 (dev box) from one codebase. Where a
# platform-specific COMMAND is unavoidable it is confined to a shim here — detected by
# CAPABILITY (`have`), never by `uname`, so both branches are exercisable anywhere by
# adjusting PATH. Do not add platform branches to cmd_*.sh; extend a shim instead.
# ---------------------------------------------------------------------------

# Install hint for a missing dependency, matched to the host's package manager. Package
# names genuinely differ between the two (`--cask docker` vs `docker.io`, `gnu-tar` vs
# `tar`), so callers may pass both. Run via $() — set -e safe.
_pkg_hint() { # brew_pkg [apt_pkg]
  local brewp="$1" aptp="${2:-$1}"
  if have brew;        then printf 'brew install %s' "$brewp"
  elif have apt-get;   then printf 'sudo apt install %s' "$aptp"
  else                      printf 'install %s' "$aptp"; fi
  return 0
}

# Open a file or URL in the host's default handler. `xdg-open` is checked FIRST because
# it is unambiguous (it exists only where it means "open this"), while `open` is a macOS
# builtin whose name is taken by unrelated tools elsewhere. With neither — the normal
# case on a HEADLESS dev box, where there is no browser at all — it just prints the
# target so it can be pasted into a browser on another machine. Never fails.
_open_file() { # path_or_url
  local t="$1"
  if have xdg-open; then
    xdg-open "$t" >/dev/null 2>&1 || log_info "Open manually: $t"
  elif have open; then
    open "$t" >/dev/null 2>&1 || log_info "Open manually: $t"
  else
    log_info "Open manually: $t"
  fi
  return 0
}

# Modification time of a path as a Unix timestamp; empty when it cannot be determined.
# GNU coreutils spells this `stat -c %Y`, BSD/macOS `stat -f %m` — and the wrong one is
# not a clean failure: GNU's `-f` means --file-system and would treat `%m` as a FILENAME,
# printing filesystem info on stdout while exiting non-zero. So try GNU first (BSD stat
# rejects -c outright with no stdout) and VALIDATE that what came back is numeric before
# trusting it. Run via $() — set -e safe.
_mtime() { # path
  local t
  t="$(stat -c %Y "$1" 2>/dev/null || true)"
  case "$t" in ''|*[!0-9]*) t="$(stat -f %m "$1" 2>/dev/null || true)" ;; esac
  case "$t" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$t"
  return 0
}

# macOS ships `openrsync` (Apple's BSD-licensed reimplementation, swapped in years ago to
# drop the GPLv3 dependency of classic rsync) as /usr/bin/rsync. It self-identifies via
# `rsync --version`'s first line starting with "openrsync:" instead of "rsync  version".
# openrsync has no --info, --skip-compress or --append-verify at all — passing them is a
# hard `unrecognized option` failure, not a silent ignore. Homebrew's `rsync` formula
# installs the real (samba/GNU) rsync 3.x, which has all three. Debian's `rsync` package
# is already the real one. Capability-detected here, not by `uname`, so a Mac with
# `brew install rsync` on PATH gets the fast path automatically. Run via `if`.
_rsync_is_openrsync() {
  rsync --version 2>&1 | head -1 | grep -q '^openrsync:'
}

# This machine's ROLE, or empty when unset (= unrestricted, the default). "dev" makes the
# dispatcher refuse the gateway commands outright — see bin/wpsite. A GUARDRAIL against
# running a production command on the wrong machine, NOT a security control: the real
# boundary is that a dev box holds no production credential (DEVBOX-PLAN.md §5.10).
config_role() {
  local r="${WPSITE_ROLE:-}"
  if [ -z "$r" ] && [ -f "$WPSITE_CONFIG" ]; then
    r="$(_yq '.role' 2>/dev/null || true)"
  fi
  printf '%s' "$r"
  return 0
}

# A `docker run -p` spec, honouring WPSITE_BIND_ADDR. Empty (the default) publishes on
# ALL interfaces, exactly as before. Set it to 127.0.0.1 — or a tailnet address — on a
# networked dev box so replicas, the mail inbox and the DB browser aren't exposed to the
# whole LAN. Covers the proxy, Mailpit and Adminer. Run via $() — set -e safe.
_port_spec() { # host_port container_port
  local a="${WPSITE_BIND_ADDR:-}"
  if [ -n "$a" ]; then printf '%s:%s:%s' "$a" "$1" "$2"
  else printf '%s:%s' "$1" "$2"; fi
  return 0
}

# Does <host> resolve to 127.0.0.1? macOS has no getent and Linux has no dscacheutil,
# so try each. A status helper — use it in `if`; returns non-zero when it cannot tell.
_resolves_loopback() { # host
  if have dscacheutil; then
    dscacheutil -q host -a name "$1" 2>/dev/null | grep -q '127.0.0.1'
  elif have getent; then
    getent hosts "$1" 2>/dev/null | grep -q '127.0.0.1'
  else
    return 1
  fi
}

# The macOS per-TLD resolver file that makes wildcard *.test work. Overridable so tests
# (and Linux, which has no /etc/resolver) can point it elsewhere.
wpsite_resolver_file() { printf '%s' "${WPSITE_RESOLVER:-/etc/resolver/test}"; }

require() { # cmd [brew-package] [apt-package]
  local cmd="$1" pkg="${2:-$1}" aptp="${3:-}"
  have "$cmd" || die "'$cmd' not found. Install with: $(_pkg_hint "$pkg" "${aptp:-$pkg}")"
}

# ---------------------------------------------------------------------------
# Config (YAML, parsed with yq)
# ---------------------------------------------------------------------------

WPSITE_CONFIG="${WPSITE_CONFIG:-$HOME/.config/wpsite/wpsite.yml}"

# The mandos CLI owns the client registry, SSH access and Google Drive paths; wpsite
# shells out to it (see the client-registry + cloud sections below). Override for tests
# via MANDOS_BIN (point it at a stub).
MANDOS_BIN="${MANDOS_BIN:-mandos}"

# Baseline preconditions for ANY command: yq + a config file. Deliberately does NOT
# require mandos — a dev box (see DEVBOX-PLAN.md) runs `clone`/`new`/`inject`/lifecycle
# with no client registry at all, and the few `client_get`/`cloud base` calls those
# paths make are `|| true`-wrapped and degrade to empty.
config_require() {
  require yq
  [ -f "$WPSITE_CONFIG" ] || die "Config not found at $WPSITE_CONFIG (see wpsite.yml.example)"
}

# Preconditions for commands that work on CLIENTS (backup, build, apply, redirect, prune,
# test, upgrade, review, hold, …): wpsite's own client registry must be READABLE. An
# unreadable registry (Drive unmounted) must never look like "no clients / nothing held".
# Deliberately does NOT require mandos: only commands that reach production need access,
# and they call require_access for the specific client.
config_require_registry() {
  config_require
  wteam_require
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
# TWO REGISTRIES, deliberately NOT linked (see HARDENING-PLAN.md Phase 1):
#   mandos — the KEYHOLDER. Access only: ssh, wp_root, cloud_folder (the Drive project
#            folder). Read via client_get / written via client_set. Knows nothing about
#            WordPress, and must stay usable without it.
#   wpsite — its OWN shared file on the Drive (wpsite.team.yml), keyed by client ID:
#            everything WordPress/maintenance-specific (hold lists, deactivate lists,
#            review pages, remote_tmp, local_host, login_path, …). Read via wclient_*.
# A client is "in wpsite" only once registered here; only a PASSING `wpsite test <c>` or
# a successful `wpsite backup <c>` registers an ID that mandos knows. Deleting a client in mandos never
# touches wpsite — the client then simply has no production access.
# ---------------------------------------------------------------------------

# Resolved path of mandos's team file, or empty when mandos runs solo / is absent.
_team_config_path() { _mandos config get team-config 2>/dev/null || true; }

# Reachability probe for mandos's registry file (for mandos WRITES only, e.g. the
# cloud_folder auto-remap): prints its path, non-zero when configured but missing.
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

# Run a mandos subcommand. When mandos is not installed AT ALL — a supported dev-box
# configuration, see DEVBOX-PLAN.md — return non-zero silently rather than letting the
# shell print "…: No such file or directory" on stderr for every registry read. Note
# this is NOT the Drive-unmounted case: there mandos exists and explains itself on
# stderr, which callers still want to see. Commands that need production access gate
# on require_access, which fails with a real message instead.
_mandos() { have "$MANDOS_BIN" || return 127; "$MANDOS_BIN" "$@"; }

# --- mandos: ACCESS fields only (ssh, wp_root, cloud_folder) -----------------------
# Reads end with `|| true` so a `set -e` script degrades to empty when mandos or the
# Drive is unreachable (mandos explains why on stderr).
client_get()      { _mandos client get "$1" "$2" 2>/dev/null || true; }
client_set()      { _mandos client set "$1" "$2" "$3"; }
client_unset()    { _mandos client unset "$1" "$2"; }
access_clients()  { _mandos client list 2>/dev/null || true; }
access_has()      { _mandos client has "$1" >/dev/null 2>&1; }

# Production access for <client>: mandos must know it, and it must be a WordPress site.
# Used by every command that reaches the server (backup, apply, test, redirect). Also
# selects the client's SSH port for every following wpsite_ssh call (_ssh_use_client).
require_access() { # client
  local c="$1"
  [ -n "$c" ] || die "No client specified."
  have "$MANDOS_BIN" || die "mandos is not installed — production access needs it (see: wpsite doctor)."
  access_has "$c" || die "No production access for '$c' in mandos (add it with: mandos client add $c)."
  is_wordpress_client "$c" || die "'$c' is not a WordPress client (no wp_root in mandos) — wpsite doesn't manage it. (Set one with: mandos client edit $c)"
  _ssh_use_client "$c"
}

# A client mandos marks as NOT a WordPress site has no wp_root (the add wizard's "Is this
# a WordPress site? → no"). wpsite leaves such clients alone: never registered, never
# backed up, never listed as a candidate.
is_wordpress_client() { [ -n "$(client_get "$1" wp_root)" ]; }

# The SSH port for the client whose server we talk to next. mandos stores `port` only
# when it isn't 22, so this is almost always empty (= ssh's default). One client per
# call path (backup --all switches per client), so a plain global is enough.
_WPSITE_SSH_PORT=""
_ssh_use_client() { # client
  _WPSITE_SSH_PORT="$(client_get "$1" port)"
  return 0
}

# --- wpsite's own registry file -----------------------------------------------------
# Location, in order: WPSITE_TEAM_CONFIG → `team_config:` in the local wpsite.yml →
# DERIVED from mandos's team file (…/01_Global/mandos/mandos.team.yml →
# …/01_Global/wpsite/wpsite.team.yml), so a gateway already set up for mandos needs no
# extra configuration. Empty when none of them resolves (e.g. a dev box).
wpsite_team_file() {
  if [ -n "${WPSITE_TEAM_CONFIG:-}" ]; then printf '%s' "$WPSITE_TEAM_CONFIG"; return 0; fi
  local p=""
  [ -f "$WPSITE_CONFIG" ] && p="$(_yq '.team_config' 2>/dev/null || true)"
  if [ -n "$p" ]; then expand_tilde "$p"; return 0; fi
  local m; m="$(_team_config_path)"
  [ -n "$m" ] || return 0
  printf '%s/wpsite/wpsite.team.yml' "$(dirname "$(dirname "$m")")"
}

# True when the registry file exists and is readable.
wteam_readable() { local f; f="$(wpsite_team_file)"; [ -n "$f" ] && [ -r "$f" ]; }

# Hard gate: the registry must be readable. Never degrade to "empty" here — for upgrade
# and apply an empty hold list would mean updating plugins someone deliberately held.
wteam_require() {
  local f; f="$(wpsite_team_file)"
  [ -n "$f" ] || die "wpsite's client registry is not configured (set team_config: in $WPSITE_CONFIG, or configure mandos so it can be derived)."
  [ -r "$f" ] && return 0
  if [ -d "$(dirname "$f")" ]; then
    die "wpsite's client registry $f does not exist yet (first time? run: wpsite migrate-registry)."
  fi
  die "wpsite's client registry is not reachable: $f (is Google Drive mounted?)"
}

# Read one yq expression from the registry; empty output when unreadable/missing key.
# Values are passed in via strenv() — never interpolated into the expression.
_wq() { # expr
  local f; f="$(wpsite_team_file)"
  [ -n "$f" ] && [ -r "$f" ] || return 0
  yq -r "$1" "$f" 2>/dev/null || true
}

# Write via `yq -i` (comments survive). Refuses when the Drive/parent dir is missing;
# creates the file with a header on first write into an existing folder.
_wq_write() { # expr
  local f; f="$(wpsite_team_file)"
  [ -n "$f" ] || die "wpsite's client registry is not configured."
  if [ ! -f "$f" ]; then
    [ -d "$(dirname "$f")" ] || die "Cannot write wpsite's client registry: $(dirname "$f") is missing (is Google Drive mounted?)"
    printf '%s\n' "# wpsite client registry — WordPress/maintenance settings per client, keyed by" \
      "# client ID. Access (ssh, wp_root, Drive project folder) lives in mandos, NOT here." \
      "# Edited by wpsite (yq -i keeps comments); hand edits are fine." "clients: {}" > "$f"
  fi
  yq -i "$1" "$f"
}

wclient_list() { _wq '(.clients // {}) | keys | .[]'; }
wclient_has()  { # client
  local f; f="$(wpsite_team_file)"
  [ -n "$f" ] && [ -r "$f" ] || return 1
  C="$1" yq -e '.clients | has(strenv(C))' "$f" >/dev/null 2>&1
}
# A scalar, or a list printed one item per line. Empty when unset.
wclient_get() { # client key
  C="$1" K="$2" _wq '.clients[strenv(C)][strenv(K)] | select(. != null) | ((select(tag == "!!seq") | .[]), select(tag != "!!seq"))'
}
wclient_set()   { C="$1" K="$2" V="$3" _wq_write '.clients[strenv(C)][strenv(K)] = strenv(V)'; }
wclient_unset() { C="$1" K="$2" _wq_write 'del(.clients[strenv(C)][strenv(K)])'; }
wclient_register() { # client
  C="$1" D="$(date +%Y-%m-%d)" _wq_write '.clients[strenv(C)].registered = (.clients[strenv(C)].registered // strenv(D))'
}
wclient_forget() { C="$1" _wq_write 'del(.clients[strenv(C)])'; }

# Maps under a client (hold_plugins / manual_updates): name → reason.
wclient_map_keys() { C="$1" M="$2" _wq '(.clients[strenv(C)][strenv(M)] // {}) | keys | .[]'; }
wclient_map_get()  { C="$1" M="$2" K="$3" _wq '.clients[strenv(C)][strenv(M)][strenv(K)] // ""'; }
wclient_map_has()  { # client map key
  local f; f="$(wpsite_team_file)"; [ -n "$f" ] && [ -r "$f" ] || return 1
  C="$1" M="$2" K="$3" yq -e '(.clients[strenv(C)][strenv(M)] // {}) | has(strenv(K))' "$f" >/dev/null 2>&1
}
wclient_map_set()  { C="$1" M="$2" K="$3" V="$4" _wq_write '.clients[strenv(C)][strenv(M)][strenv(K)] = strenv(V)'; }
wclient_map_del()  { C="$1" M="$2" K="$3" _wq_write 'del(.clients[strenv(C)][strenv(M)][strenv(K)])'; }

# Global settings (settings.<key>), e.g. test_mail_to.
wsetting_get() { K="$1" _wq '.settings[strenv(K)] // ""'; }

# The client list/has helpers the rest of wpsite uses = the WPSITE registry.
config_clients()    { wclient_list; }
config_has_client() { wclient_has "$1"; }

# A client wpsite works on: registered in wpsite's registry. (Production access is a
# separate check — require_access.)
require_client() { # client_name
  local c="$1"
  [ -n "$c" ] || die "No client specified."
  wclient_has "$c" && return 0
  if access_has "$c"; then
    die "'$c' is not in wpsite yet — register it with: wpsite test $c   (or its first backup)"
  fi
  die "Client '$c' not found (neither in wpsite nor in mandos)."
}

# A name the creators (new/clone) must refuse: a wpsite client, a dev site, or an ID
# mandos knows (it may be registered in wpsite later).
_name_taken() { # name
  [ -n "$(target_kind "$1")" ] || access_has "$1"
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
config_cloud_base() { _mandos cloud base 2>/dev/null || true; }

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

# Production domain of a client (host only, no proto/www), as recorded by its
# backups. This is what the CUSTOMER-facing report is named after and headed with —
# the client id stays our internal reference. Falls back to the id when no backup
# has recorded a domain yet.
client_domain() { # client
  local domain; domain="$(_cloud_domain_from_meta "$1")"
  [ -n "$domain" ] || domain="$1"
  printf '%s' "$domain"
}

# Every production domain of the client, one per line: a multisite network's sites (from
# the newest backup's sites.csv, in blog order), else the one client_domain. Used by the
# customer report, which must name EVERY site that was maintained.
client_domains() { # client
  local b; b="$(latest_backup_dir "$1" 2>/dev/null || true)"
  if [ -n "$b" ] && grep -qx 'MULTISITE=1' "$b/meta.env" 2>/dev/null && [ -s "$b/sites.csv" ]; then
    tail -n +2 "$b/sites.csv" | cut -d, -f2 | grep -E '^[A-Za-z0-9.-]+$' | awk '!seen[$0]++' || true
    return 0
  fi
  client_domain "$1"; printf '\n'
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
  local override; override="$(wclient_get "$1" cloud_dir)"
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

# Host suffix for DEV SITES (never for client replicas). Default "test"; a dev box sets
# `dev_suffix: dev.test` (or WPSITE_DEV_SUFFIX) so dev sites land on <name>.dev.test and
# a gateway serving *.test can coexist with a dev box serving *.dev.test under one
# dnsmasq, resolved by longest match. NEVER use `.dev` — Google owns it as a real gTLD
# and the whole TLD is HSTS-preloaded, so http:// is force-upgraded to https:// and our
# HTTP-only replicas become unreachable. Run via $() — set -e safe.
config_dev_suffix() {
  local s="${WPSITE_DEV_SUFFIX:-}"
  if [ -z "$s" ] && [ -f "$WPSITE_CONFIG" ]; then
    s="$(_yq '.dev_suffix' 2>/dev/null || true)"
  fi
  [ -n "$s" ] || s="test"
  printf '%s' "${s#.}"
  return 0
}

# The dev box `wpsite push` ships packets to: an ssh target (WPSITE_DEVBOX env, else
# `devbox.host:` in the config) and the base_dir to land them under on that machine
# (`devbox.base_dir:`, default "websites", relative to the remote $HOME unless absolute).
config_devbox_host() {
  local h="${WPSITE_DEVBOX:-}"
  if [ -z "$h" ] && [ -f "$WPSITE_CONFIG" ]; then h="$(_yq '.devbox.host' 2>/dev/null || true)"; fi
  printf '%s' "$h"
  return 0
}
config_devbox_base() {
  local b=""
  [ -f "$WPSITE_CONFIG" ] && b="$(_yq '.devbox.base_dir' 2>/dev/null || true)"
  [ -n "$b" ] || b="websites"
  printf '%s' "$b"
  return 0
}

# Newest COMPLETE backup dir for a site name; empty when there is none. Ranked by the
# id NAME (chronological and machine-robust — the same convention prune uses), not by
# mtime: an rsync'd packet's mtime says when it was copied, not when it was taken. The
# glob is alphabetical, so the last match wins. Completeness is enforced here so a
# half-transferred packet can never be selected. Run via $() — set -e safe.
latest_backup_dir() { # name
  local bd d best=""
  bd="$(client_backup_dir "$1")"
  [ -d "$bd" ] || return 0
  for d in "$bd"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    _is_backup_id "$(basename "$d")" || continue
    _is_complete_backup "$d" || continue
    best="$d"
  done
  [ -n "$best" ] && printf '%s' "$best"
  return 0
}

# Days since a YYYYMMDD date, computed arithmetically (Howard Hinnant's days_from_civil).
# Deliberately avoids `date -d` (GNU) / `date -j` (BSD) — those are the exact BSD-vs-GNU
# split the shims exist for, and there is no need for either when the input is a plain
# civil date. 10# forces base 10 so 08/09 aren't read as invalid octal.
_days_from_civil() { # YYYY MM DD
  local y=$((10#$1)) m=$((10#$2)) d=$((10#$3)) era yoe doy doe
  [ "$m" -le 2 ] && y=$((y - 1))
  if [ "$y" -ge 0 ]; then era=$((y / 400)); else era=$(((y - 399) / 400)); fi
  yoe=$((y - era * 400))
  if [ "$m" -gt 2 ]; then doy=$(((153 * (m - 3) + 2) / 5 + d - 1))
  else doy=$(((153 * (m + 9) + 2) / 5 + d - 1)); fi
  doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
  printf '%s' $((era * 146097 + doe - 719468))
}

# Age in whole days of a backup id (YYYYMMDD_HHMMSS[-permanent]). Empty if unparseable.
# The id IS the capture timestamp, so this needs no filesystem call at all.
_backup_age_days() { # backup_id
  local id="${1%-permanent}" today
  _is_backup_id "$id" || return 0
  today="$(date +%Y%m%d)"
  printf '%s' $(( $(_days_from_civil "${today:0:4}" "${today:4:2}" "${today:6:2}") \
                  - $(_days_from_civil "${id:0:4}" "${id:4:2}" "${id:6:2}") ))
  return 0
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
  local override; override="$(wclient_get "$client" local_host)"
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
    printf '%s.%s' "$1" "$(config_dev_suffix)"
  else
    client_local_host "$1"
  fi
}

# ---------------------------------------------------------------------------
# WP-CLI output hygiene
# ---------------------------------------------------------------------------
# A noisy plugin makes WP-CLI print PHP diagnostics on STDOUT, in the middle of data —
# weinwege: `multiple-domain-mapping-on-single-site` prints "Warning: Undefined array key
# "HTTP_HOST"" (after an empty line) before every CSV header and URL list, so the
# screenshot run got a page called "Warning:" and every CSV its header on line 3. A PHP
# setting can't prevent it (WordPress/WP-CLI switch display_errors back at runtime), so
# both WP-CLI runners (_upgrade_wp, _prod_wp) pass their output through this filter:
# diagnostics — plus the empty line WP-CLI prints before them and a fatal's stack trace —
# move to STDERR. Data captures (2>/dev/null) get clean data; logs (>>log 2>&1) keep the
# lines; the fatal classification (_run_to merges stderr) still sees "Fatal error".
_wp_diag_to_stderr() {
  awk '
    function diag(l) { return l ~ /^(<br \/>)?[[:space:]]*(<b>)?(PHP )?(Warning|Notice|Deprecated|Strict Standards|Fatal error|Parse error|Recoverable fatal error|Catchable fatal error)(<\/b>)?:/ }
    hasheld { if (diag($0)) print held > "/dev/stderr"; else print held; hasheld = 0 }
    diag($0) { print > "/dev/stderr"; trace = ($0 ~ /[Ff]atal error/); next }
    trace && /^(PHP )?(Stack trace:|#[0-9]+ |  thrown in )/ { print > "/dev/stderr"; next }
    { trace = 0 }
    /^[[:space:]]*$/ { held = $0; hasheld = 1; next }   # held: goes wherever the NEXT line goes
    { print }
    END { if (hasheld) print held }
  '
}

# Run a WP-CLI invocation through _wp_diag_to_stderr, keeping its exit status. The status
# travels through a file (a DEBUG trap — bats has one — clobbers PIPESTATUS).
_wp_filtered() { # cmd...
  local rcf rc; rcf="$(mktemp)"
  { local r=0; "$@" || r=$?; echo "$r" > "$rcf"; } | _wp_diag_to_stderr
  rc="$(cat "$rcf" 2>/dev/null || echo 1)"; rm -f "$rcf"
  return "$rc"
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

# wpsite_ssh <ssh_target> [ssh args...] — every production SSH call goes through here.
# A non-default port (mandos `port`, selected by _ssh_use_client) becomes -p; the mux
# ControlPath's %C hash includes the port, so connections never get mixed up.
wpsite_ssh() {
  local target="$1"; shift
  local port_opt=()
  [ -n "${_WPSITE_SSH_PORT:-}" ] && [ "$_WPSITE_SSH_PORT" != 22 ] && port_opt=(-p "$_WPSITE_SSH_PORT")
  ssh -o ControlMaster=auto \
      -o ControlPath="$WPSITE_SSH_CONTROL_DIR/%C" \
      -o ControlPersist=120 \
      ${port_opt[@]+"${port_opt[@]}"} \
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

# --- Bundled WP-CLI fallback -------------------------------------------------------
# Some hosts ship a `wp` that cannot run from our SSH login and offer no way to fix it.
# checkdomain/Plesk (client gerfin): /usr/local/bin/wp is WP-Toolkit's wrapper, which
# require_once's a file under /usr/local/psa that the chrooted shell cannot see — every
# call fatals. `php` itself works there. So when the host's wp can't boot the site,
# wpsite uploads its OWN wp-cli.phar (the host cache <base_dir>/.cache/wp-cli.phar, same
# one builds use) into the remote $HOME and runs `php <phar>` instead. Detected, not
# configured: no registry key. The host's wp stays the first choice because managed hosts'
# wrappers (Mittwald) pick the site's PHP version, which a bare `php` might not.
#
# "Runs" is not enough, though: the host's wp must also pass ARGUMENTS intact. Some
# Mittwald accounts (ksk, maute-areal) carry an old wrapper ending in
# `php_cli wp-cli.phar $@` — unquoted, so every argument is re-split at spaces.
# `wp core version` still works, but `wp eval 'echo "…";'` (apply's boot check, the
# preflight's HTTPS probe, the test mail) and `wp db query "SELECT …"` all die with
# "Too many positional arguments". apply then reported "WP-CLI can't boot WordPress" on a
# perfectly healthy site while `wpsite test` said READY. _remote_wp_args_ok probes this
# (without booting WordPress), and a splitting wrapper counts as unusable.
WPSITE_REMOTE_PHAR=".wpsite/wp-cli.phar"   # relative to the REMOTE $HOME
_WPSITE_WP_BUNDLED=0                        # read by _prod_wp / _remote_wp_cmd
_WPSITE_WP_PREPARED=""                      # client already probed in this process

# Decide host-wp vs bundled phar for <client> and set _WPSITE_WP_BUNDLED. Call once per
# command AFTER ssh_setup_mux (repeat calls for the same client are free). Never fails:
# if neither wp-cli boots, it stays on the host's wp so the caller surfaces the real error.
_remote_wp_prepare() { # client
  local client="$1" t root cache want have_sum
  [ "$_WPSITE_WP_PREPARED" = "$client" ] && return 0
  _WPSITE_WP_PREPARED="$client"
  _WPSITE_WP_BUNDLED=0
  t="$(client_get "$client" ssh)"; root="$(client_get "$client" wp_root)"
  if wpsite_ssh "$t" "cd '$root' && wp core version --allow-root >/dev/null 2>&1" </dev/null; then
    _remote_wp_args_ok "$t" "$root" wp && return 0
    log_warn "$client: the host's wp-cli splits arguments at spaces (a wrapper with an unquoted \$@) — wp eval / db query would fail; trying wpsite's bundled wp-cli"
  else
    log_warn "$client: the host's wp-cli does not boot the site from this SSH login — trying wpsite's bundled wp-cli"
  fi
  _wp_cli_cache_warm || { log_warn "  no local wp-cli.phar to upload (run: wpsite prefetch)"; return 0; }
  cache="$(_wp_cli_cache)"
  want="$(cksum < "$cache" | awk '{print $1 "-" $2}')"
  # shellcheck disable=SC2016  # $HOME is the REMOTE one
  have_sum="$(wpsite_ssh "$t" 'cksum < "$HOME/'"$WPSITE_REMOTE_PHAR"'" 2>/dev/null' </dev/null \
    | awk '{print $1 "-" $2}' || true)"
  if [ "$want" != "$have_sum" ]; then
    log_info "  uploading wp-cli.phar to ~/$WPSITE_REMOTE_PHAR ..."
    # shellcheck disable=SC2016
    wpsite_ssh "$t" 'p="$HOME/'"$WPSITE_REMOTE_PHAR"'"; mkdir -p "$(dirname "$p")" && cat > "$p.tmp" && mv -f "$p.tmp" "$p"' < "$cache" \
      || { log_warn "  could not upload wp-cli.phar to the remote home"; return 0; }
  fi
  _WPSITE_WP_BUNDLED=1
  if wpsite_ssh "$t" "cd '$root' && $(_remote_wp_cmd) core version --allow-root >/dev/null 2>&1" </dev/null \
     && _remote_wp_args_ok "$t" "$root" "$(_remote_wp_cmd)"; then
    log_warn "  using bundled wp-cli (~/$WPSITE_REMOTE_PHAR) for $client"
  else
    _WPSITE_WP_BUNDLED=0
    log_warn "  the bundled wp-cli does not boot the site either — keeping the host's wp"
  fi
  return 0
}

# Does <wp_cmd> on the server receive an argument containing spaces as ONE argument?
# `eval --skip-wordpress` loads no WordPress (no DB, no plugins), so it is a pure
# argument-passing probe, safe on production. The marker is concatenated in PHP, so an
# echo of the command line itself (a stub, an error message) can never match it.
_remote_wp_args_ok() { # ssh_target wp_root wp_cmd
  wpsite_ssh "$1" "cd '$2' && $3 eval --skip-wordpress 'echo \"WPSITE ARGS\" . \" OK\";' --allow-root 2>/dev/null" </dev/null \
    | tr -d '\r' | grep -qx 'WPSITE ARGS OK'
}

# The remote command that invokes wp-cli, as a string for a remote shell (the $HOME
# expands on the SERVER). Plain `wp` unless _remote_wp_prepare selected the bundled phar.
_remote_wp_cmd() {
  if [ "${_WPSITE_WP_BUNDLED:-0}" = 1 ]; then
    # shellcheck disable=SC2016  # $HOME is the REMOTE one
    printf 'php -d memory_limit=512M -d max_execution_time=300 "$HOME/%s"' "$WPSITE_REMOTE_PHAR"
  else
    printf 'wp'
  fi
  return 0
}
