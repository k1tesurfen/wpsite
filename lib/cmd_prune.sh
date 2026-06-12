# shellcheck shell=bash
# wpsite prune [<client>|--all] [--keep N] [--older-than Nd] [--dry-run] [--yes]
#
# Delete old backups. Default policy if none given: --keep 5. Already-built/running
# replicas are unaffected — their data lives in the Docker volume + extracted
# wp-content, not the backup artifacts.

# Parse a duration token (30d / 2w / 30) into whole days. Non-zero exit if invalid.
_prune_days() {
  local t="${1:-}" num mult=1
  case "$t" in
    *d) num="${t%d}" ;;
    *w) num="${t%w}"; mult=7 ;;
    *)  num="$t" ;;
  esac
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$(( num * mult ))"
}

# Rough KB -> human size for the freed-space summary.
_human_kb() {
  local kb="${1:-0}"
  if   [ "$kb" -ge 1048576 ]; then printf '%d.%dG' "$(( kb / 1048576 ))" "$(( (kb % 1048576) * 10 / 1048576 ))"
  elif [ "$kb" -ge 1024 ];    then printf '%dM' "$(( kb / 1024 ))"
  else printf '%dK' "$kb"; fi
}

# Backups for one client that the policy marks for deletion (newest-first input).
# Protects the newest `keep`, then (if set) keeps only those older than `older` days.
_prune_candidates() { # client keep older_days
  local client="$1" keep="$2" older="$3" bd
  bd="$(client_backup_dir "$client")"
  [ -d "$bd" ] || return 0
  local dirs=() d
  # shellcheck disable=SC2012  # timestamp dirs; mtime sort via ls is fine
  while IFS= read -r d; do [ -n "$d" ] && dirs+=("${d%/}"); done < <(ls -td "$bd"/*/ 2>/dev/null)
  local n="${#dirs[@]}"
  [ "$n" -gt 0 ] || return 0
  local start=0; [ -n "$keep" ] && start="$keep"
  local now thresh i mtime
  now="$(date +%s)"; thresh=$(( ${older:-0} * 86400 ))
  for (( i=start; i<n; i++ )); do
    d="${dirs[i]}"
    if [ -n "$older" ]; then
      mtime="$(stat -f %m "$d" 2>/dev/null || echo "$now")"
      [ "$(( now - mtime ))" -gt "$thresh" ] || continue
    fi
    printf '%s\n' "$d"
  done
}

cmd_prune() {
  local all=0 keep="" older_days="" dry=0 yes=0 client=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --all)          all=1; shift ;;
      --keep)         keep="${2:-}"; shift 2 ;;
      --keep=*)       keep="${1#*=}"; shift ;;
      --older-than)   older_days="$(_prune_days "${2:-}")" || die "Invalid --older-than '${2:-}' (use e.g. 30d or 2w)"; shift 2 ;;
      --older-than=*) older_days="$(_prune_days "${1#*=}")" || die "Invalid --older-than (use e.g. 30d or 2w)"; shift ;;
      --dry-run)      dry=1; shift ;;
      --yes|-y)       yes=1; shift ;;
      -*) die "Unknown flag: $1" ;;
      *)  client="$1"; shift ;;
    esac
  done

  config_require
  if [ -n "$keep" ]; then
    case "$keep" in ''|*[!0-9]*) die "--keep must be a whole number" ;; esac
  fi
  [ -z "$keep" ] && [ -z "$older_days" ] && keep=5   # default policy

  local clients=() c
  if [ "$all" = 1 ]; then
    [ -z "$client" ] || die "Use either a <client> or --all, not both."
    while IFS= read -r c; do [ -n "$c" ] && clients+=("$c"); done < <(config_clients)
  else
    [ -n "$client" ] || die "Specify a <client>, or --all for every client."
    require_client "$client"
    clients=("$client")
  fi

  local policy=""
  [ -n "$keep" ]       && policy="keep newest $keep"
  [ -n "$older_days" ] && policy="${policy:+$policy, }delete older than ${older_days}d"
  log_info "Prune policy: $policy"

  # Collect deletions across the target clients as "client|dir" entries.
  local del=()
  for c in "${clients[@]}"; do
    while IFS= read -r d; do [ -n "$d" ] && del+=("$c|$d"); done \
      < <(_prune_candidates "$c" "$keep" "$older_days")
  done

  if [ "${#del[@]}" -eq 0 ]; then
    log_ok "Nothing to prune."
    return 0
  fi

  # Preview.
  local now total_kb=0 entry cc dd sz kb age
  now="$(date +%s)"
  printf '%-14s %-18s %-7s %s\n' "CLIENT" "BACKUP" "SIZE" "AGE" >&2
  for entry in "${del[@]}"; do
    cc="${entry%%|*}"; dd="${entry#*|}"
    sz="$(du -sh "$dd" 2>/dev/null | cut -f1)"
    kb="$(du -sk "$dd" 2>/dev/null | cut -f1)"; total_kb=$(( total_kb + ${kb:-0} ))
    age=$(( (now - $(stat -f %m "$dd" 2>/dev/null || echo "$now")) / 86400 ))
    printf '%-14s %-18s %-7s %dd\n' "$cc" "$(basename "$dd")" "${sz:-?}" "$age"
  done
  log_info "Total: ${#del[@]} backup(s), ~$(_human_kb "$total_kb")"

  [ "$dry" = 1 ] && { log_info "(dry run — nothing deleted)"; return 0; }

  if [ "$yes" != 1 ]; then
    printf 'Delete the above backup(s)? [y/N] ' >&2
    # Prefer the controlling terminal (works even if stdin is piped); fall back to
    # stdin; empty/none -> abort. 2>/dev/null BEFORE </dev/tty so a missing tty is
    # silent (redirections apply left-to-right).
    local ans=""
    read -r ans 2>/dev/null < /dev/tty || read -r ans 2>/dev/null || ans=""
    case "$ans" in y|Y|yes|YES) ;; *) log_info "Aborted; nothing deleted."; return 0 ;; esac
  fi

  local removed=0
  for entry in "${del[@]}"; do
    dd="${entry#*|}"
    if rm -rf "${dd:?}"; then removed=$(( removed + 1 )); else log_warn "Failed to delete $dd"; fi
  done
  log_ok "Deleted $removed backup(s), freed ~$(_human_kb "$total_kb")."
}
