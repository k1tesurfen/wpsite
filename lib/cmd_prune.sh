# shellcheck shell=bash
# wpsite prune [<client>|--all] [<backup-id>] [--keep N] [--older-than Nd] [--dry-run] [--yes]
#
# Delete backups. Two forms:
#   wpsite prune <client>            rolling retention: keep newest <keep_backups>
#   wpsite prune --all               (default 4), skipping -permanent backups.
#   wpsite prune <client> <id>       delete THAT backup — even if permanent.
#
# The cloud is the source of truth, so prune deletes from local AND cloud (and the
# sync manifest) together. Already-built/running replicas are unaffected — their
# data lives in the Docker volume + extracted wp-content, not the backup artifacts.

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

# Backups for one client that the policy marks for deletion. Ranks newest-first by
# the timestamp in the folder NAME (YYYYMMDD_HHMMSS sorts chronologically and is
# robust across machines, unlike mtime on Drive-downloaded files). Protects the
# newest `keep`, then (if set) keeps only those older than `older` days. -permanent
# backups are excluded entirely — never touched by policy prune.
_prune_candidates() { # client keep older_days
  local client="$1" keep="$2" older="$3" bd
  bd="$(client_backup_dir "$client")"
  [ -d "$bd" ] || return 0
  local dirs=() d name
  # shellcheck disable=SC2012  # timestamp dirs; name sort via ls is intentional
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    d="${d%/}"; name="$(basename "$d")"
    case "$name" in *.tmp.*) continue ;; esac   # skip in-flight cloud-copy staging dirs
    _is_persistent_backup "$name" && continue
    dirs+=("$d")
  done < <(ls -d "$bd"/*/ 2>/dev/null | sort -r)
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

# Explicit single-backup deletion (wpsite prune <client> <id>). Deletes from local
# + cloud + manifest, EVEN IF permanent. Tolerates the bare or suffixed id.
_prune_single() { # client id dry yes
  local client="$1" id="$2" dry="$3" yes="$4" bd base actual sz
  bd="$(client_backup_dir "$client")"
  base="${id%-permanent}"
  if   [ -d "$bd/$base-permanent" ]; then actual="$base-permanent"
  elif [ -d "$bd/$base" ];           then actual="$base"
  else die "No backup '$base' for $client (see: wpsite list $client)."; fi

  if [ -n "$(client_cloud_dir "$client")" ] && ! cloud_available "$client"; then
    die "$client: cloud is configured but not mounted — refusing to delete (it would resurrect on the next sync). Mount Drive and retry."
  fi

  sz="$(du -sh "$bd/$actual" 2>/dev/null | cut -f1 || true)"
  log_info "Delete backup: $client / $actual (${sz:-?})$(_is_persistent_backup "$actual" && echo '  [PERMANENT]')"
  log_info "  Removes it from local + cloud + sync manifest."
  [ "$dry" = 1 ] && { log_info "(dry run — nothing deleted)"; return 0; }

  if [ "$yes" != 1 ]; then
    printf 'Delete this backup everywhere? [y/N] ' >&2
    local ans=""
    read -r ans 2>/dev/null < /dev/tty || read -r ans 2>/dev/null || ans=""
    case "$ans" in y|Y|yes|YES) ;; *) log_info "Aborted; nothing deleted."; return 0 ;; esac
  fi

  if _do_delete_backup "$client" "$actual" both; then log_ok "Deleted $actual ($client)."
  else log_warn "$actual: some parts could not be deleted."; fi
}

cmd_prune() {
  local all=0 keep="" older_days="" dry=0 yes=0 client="" target_id=""
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
      *)  if [ -z "$client" ]; then client="$1"; else target_id="$1"; fi; shift ;;
    esac
  done

  config_require
  if [ -n "$keep" ]; then
    case "$keep" in ''|*[!0-9]*) die "--keep must be a whole number" ;; esac
  fi

  # Single-backup form: wpsite prune <client> <backup-id>
  if [ -n "$target_id" ]; then
    [ "$all" = 1 ] && die "Specify a single <client> with a <backup-id>, not --all."
    require_client "$client"
    _prune_single "$client" "$target_id" "$dry" "$yes"
    return
  fi

  # Default policy: per-client rolling retention (keep_backups, default 4).
  local default_keep=0
  [ -z "$keep" ] && [ -z "$older_days" ] && default_keep=1

  local clients=() c
  if [ "$all" = 1 ]; then
    [ -z "$client" ] || die "Use either a <client> or --all, not both."
    while IFS= read -r c; do [ -n "$c" ] && clients+=("$c"); done < <(config_clients)
  else
    [ -n "$client" ] || die "Specify a <client>, a <client> <backup-id>, or --all."
    require_client "$client"
    clients=("$client")
  fi

  local policy=""
  if [ "$default_keep" = 1 ]; then policy="keep newest per-client keep_backups (default 4)"
  else
    [ -n "$keep" ]       && policy="keep newest $keep"
    [ -n "$older_days" ] && policy="${policy:+$policy, }delete older than ${older_days}d"
  fi
  log_info "Prune policy: $policy  (skips -permanent backups)"

  # Collect deletions across the target clients as "client|dir" entries. Skip any
  # client whose cloud is configured-but-unmounted: deleting locally only would be
  # undone by the next sync (cloud is the source of truth).
  local del=() eff_keep
  for c in "${clients[@]}"; do
    if [ -n "$(client_cloud_dir "$c")" ] && ! cloud_available "$c"; then
      log_warn "$c: cloud configured but not mounted — skipping (would resurrect on next sync)."
      continue
    fi
    eff_keep="$keep"
    [ "$default_keep" = 1 ] && eff_keep="$(client_keep_backups "$c")"
    while IFS= read -r d; do [ -n "$d" ] && del+=("$c|$d"); done \
      < <(_prune_candidates "$c" "$eff_keep" "$older_days")
  done

  if [ "${#del[@]}" -eq 0 ]; then
    log_ok "Nothing to prune."
    return 0
  fi

  # Preview.
  local now total_kb=0 entry cc dd sz kb age
  now="$(date +%s)"
  printf '%-14s %-26s %-7s %s\n' "CLIENT" "BACKUP" "SIZE" "AGE" >&2
  for entry in "${del[@]}"; do
    cc="${entry%%|*}"; dd="${entry#*|}"
    sz="$(du -sh "$dd" 2>/dev/null | cut -f1)"
    kb="$(du -sk "$dd" 2>/dev/null | cut -f1)"; total_kb=$(( total_kb + ${kb:-0} ))
    age=$(( (now - $(stat -f %m "$dd" 2>/dev/null || echo "$now")) / 86400 ))
    printf '%-14s %-26s %-7s %dd\n' "$cc" "$(basename "$dd")" "${sz:-?}" "$age"
  done
  log_info "Total: ${#del[@]} backup(s), ~$(_human_kb "$total_kb")  (local + cloud)"

  [ "$dry" = 1 ] && { log_info "(dry run — nothing deleted)"; return 0; }

  if [ "$yes" != 1 ]; then
    printf 'Delete the above backup(s) from local + cloud? [y/N] ' >&2
    # Prefer the controlling terminal (works even if stdin is piped); fall back to
    # stdin; empty/none -> abort. 2>/dev/null BEFORE </dev/tty so a missing tty is
    # silent (redirections apply left-to-right).
    local ans=""
    read -r ans 2>/dev/null < /dev/tty || read -r ans 2>/dev/null || ans=""
    case "$ans" in y|Y|yes|YES) ;; *) log_info "Aborted; nothing deleted."; return 0 ;; esac
  fi

  local removed=0
  for entry in "${del[@]}"; do
    cc="${entry%%|*}"; dd="${entry#*|}"
    if _do_delete_backup "$cc" "$(basename "$dd")" both; then removed=$(( removed + 1 )); else log_warn "Failed to delete $dd"; fi
  done
  log_ok "Deleted $removed backup(s), freed ~$(_human_kb "$total_kb")."
}
