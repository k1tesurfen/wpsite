# shellcheck shell=bash
# wpsite list [client] — without a client, list all clients + backup counts;
# with a client, list that client's individual backups (newest first).

cmd_list() {
  config_require
  if [ -n "${1:-}" ]; then
    require_client "$1"
    _list_client_backups "$1"
  else
    _list_all_clients
  fi
}

_list_all_clients() {
  local client backup_dir count latest
  printf '%-16s %-8s %s\n' "CLIENT" "BACKUPS" "LATEST" >&2
  while IFS= read -r client; do
    [ -n "$client" ] || continue
    backup_dir="$(client_backup_dir "$client")"
    if [ -d "$backup_dir" ]; then
      count="$(find "$backup_dir" -maxdepth 1 -mindepth 1 -type d | grep -c . || true)"
      # shellcheck disable=SC2012  # timestamp dirs; mtime sort via ls is fine
      latest="$(ls -td "$backup_dir"/*/ 2>/dev/null | head -1)"
      latest="$(basename "${latest%/}" 2>/dev/null)"
    else
      count=0; latest="-"
    fi
    printf '%-16s %-8s %s\n' "$client" "$count" "${latest:--}"
  done < <(config_clients)
}

# Per-backup detail, newest first. Mode comes from meta.env (or inferred from the
# presence of media_map.txt for pre-BACKUP_MODE backups).
_list_client_backups() { # client
  local client="$1" backup_dir d ts mode size
  backup_dir="$(client_backup_dir "$client")"
  [ -d "$backup_dir" ] && [ -n "$(ls -A "$backup_dir" 2>/dev/null)" ] \
    || { log_info "No backups for $client yet (run: wpsite backup $client)."; return 0; }

  printf '%-18s %-12s %-7s %s\n' "BACKUP" "MODE" "SIZE" "PASS TO --backup" >&2
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    ts="$(basename "$d")"
    # || true: grep finding no BACKUP_MODE (pre-field backups) must not trip set -e.
    mode="$(grep -m1 '^BACKUP_MODE=' "$d/meta.env" 2>/dev/null | cut -d= -f2- || true)"
    [ -n "$mode" ] || mode="$([ -f "$d/media_map.txt" ] && echo placeholder || echo full?)"
    size="$(du -sh "$d" 2>/dev/null | cut -f1 || true)"
    printf '%-18s %-12s %-7s %s\n' "$ts" "$mode" "${size:-?}" "$ts"
  done < <(ls -td "$backup_dir"/*/ 2>/dev/null)
}
