# shellcheck shell=bash
# wpsite list [client] — without a client, list all clients + backup counts;
# with a client, list that client's individual backups (newest first).
# wpsite list --names — machine-readable: client names only, one per line, to
# stdout (team-aware, via config_clients). Used by the GUI / scripting.

cmd_list() {
  config_require
  # Porcelain: just the client names (stdout, one per line). Team-aware — resolves
  # the shared team config, and degrades to empty (with a stderr warning) if Drive
  # is unmounted, so a caller never crashes.
  if [ "${1:-}" = "--names" ]; then
    config_clients
    return 0
  fi
  # Porcelain: just the dev-site names (stdout, one per line). Dev sites are LOCAL
  # (config_dev_sites reads the local config), so this never depends on Drive.
  if [ "${1:-}" = "--dev-names" ]; then
    config_dev_sites
    return 0
  fi
  # Porcelain: COMPLETE backup ids for one client, newest first (used by the GUI clone
  # picker so you can clone from an existing on-disk backup — no fresh backup / network).
  if [ "${1:-}" = "--backups" ]; then
    local bc="${2:-}" bdir d
    { [ -n "$bc" ] && config_has_client "$bc"; } || return 0
    bdir="$(client_backup_dir "$bc")"
    [ -d "$bdir" ] || return 0
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      d="${d%/}"
      if _is_complete_backup "$d"; then basename "$d"; fi
    done < <(ls -td "$bdir"/*/ 2>/dev/null)
    return 0
  fi
  if [ -n "${1:-}" ]; then
    if config_has_dev "$1"; then
      _list_dev_site "$1"
    else
      require_client "$1"
      _list_client_backups "$1"
    fi
  else
    _list_all_clients
    _list_dev_sites
  fi
}

# Dev sites have no backups — show host + pinned versions + source (if a clone).
_list_dev_sites() {
  local name first=1 host wp php source
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ "$first" = 1 ]; then
      printf '\n%-16s %-22s %-10s %s\n' "DEV SITE" "HOST" "WP/PHP" "SOURCE" >&2
      first=0
    fi
    host="$(dev_get "$name" host)"; [ -n "$host" ] || host="$name.test"
    wp="$(dev_get "$name" wp_version)"; php="$(dev_get "$name" php)"
    source="$(dev_get "$name" source)"
    printf '%-16s %-22s %-10s %s\n' "$name" "$host" "${wp:-latest}/${php:-?}" "${source:--}"
  done < <(config_dev_sites)
  return 0
}

_list_dev_site() { # name
  local name="$1" host wp php source
  host="$(dev_get "$name" host)"; [ -n "$host" ] || host="$name.test"
  wp="$(dev_get "$name" wp_version)"; php="$(dev_get "$name" php)"
  source="$(dev_get "$name" source)"
  log_info "Dev site:  $name"
  log_info "  Host:    http://$host"
  log_info "  WP/PHP:  ${wp:-latest} / ${php:-?}"
  log_info "  Source:  ${source:-(none — blank site)}"
  return 0
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
  local client="$1" backup_dir d ts base mark mode size seen_perm=0
  backup_dir="$(client_backup_dir "$client")"
  [ -d "$backup_dir" ] && [ -n "$(ls -A "$backup_dir" 2>/dev/null)" ] \
    || { log_info "No backups for $client yet (run: wpsite backup $client)."; return 0; }

  printf '%-28s %-12s %-7s %s\n' "BACKUP" "MODE" "SIZE" "PASS TO --backup" >&2
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    ts="$(basename "$d")"; base="${ts%-permanent}"; mark=""
    if _is_persistent_backup "$ts"; then mark=" *"; seen_perm=1; fi
    # || true: grep finding no BACKUP_MODE (pre-field backups) must not trip set -e.
    mode="$(grep -m1 '^BACKUP_MODE=' "$d/meta.env" 2>/dev/null | cut -d= -f2- || true)"
    [ -n "$mode" ] || mode="$([ -f "$d/media_map.txt" ] && echo placeholder || echo full?)"
    size="$(du -sh "$d" 2>/dev/null | cut -f1 || true)"
    printf '%-28s %-12s %-7s %s\n' "$ts$mark" "$mode" "${size:-?}" "$base"
  done < <(ls -td "$backup_dir"/*/ 2>/dev/null)
  [ "$seen_perm" = 1 ] && log_info "* = permanent (exempt from rolling prune; delete with: wpsite prune $client <id>)"
  return 0
}
