# shellcheck shell=bash
# wpsite clone <client> <devname> — initialise a dev site FROM an existing client,
# either from a fresh production backup (default) or a specified existing backup.
# Reuses the full build pipeline (URL rewrite, known admin, Mailpit, plugin
# sanitization) but targets a new local-only dev site under base_dir/dev/<devname>.
# Media defaults to REAL (it's a working sandbox); pass --light for placeholders.

cmd_clone() {
  local source="" devname="" backup_id="" full=1 light=0 full_set=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --backup)   backup_id="${2:-}"; shift 2 ;;
      --backup=*) backup_id="${1#*=}"; shift ;;
      --light)    light=1; full=0; shift ;;
      --full)     full=1; full_set=1; shift ;;
      -*) die "Unknown flag: $1" ;;
      *)
        if [ -z "$source" ]; then source="$1"; elif [ -z "$devname" ]; then devname="$1";
        else die "Unexpected argument: $1"; fi
        shift ;;
    esac
  done

  config_require
  require docker
  [ -n "$source" ]  || die "Usage: wpsite clone <client> <devname> [--backup <id>] [--light]"
  [ -n "$devname" ] || die "Usage: wpsite clone <client> <devname> [--backup <id>] [--light]"
  [ "$light" = 1 ] && [ "$full_set" = 1 ] && die "Use either --light or --full, not both."

  require_client "$source"
  _valid_site_name "$devname" || die "Invalid dev site name '$devname' (use lowercase letters, digits, hyphens)."
  [ -z "$(target_kind "$devname")" ] || die "'$devname' already exists as a $(target_kind "$devname"). Choose another name."

  _ensure_base_layout
  local backup_dir latest
  backup_dir="$(client_backup_dir "$source")"

  if [ -n "$backup_id" ]; then
    # Use an existing backup as-is. Its media mode is fixed; --light/--full no-op.
    if [ "$light" = 1 ] || [ "$full_set" = 1 ]; then
      log_warn "Ignoring media flag — using existing backup '$backup_id' as captured."
    fi
    latest="$(resolve_backup_dir "$source" "${backup_id%/}")"
    [ -d "$latest" ] || die "Backup '$backup_id' not found for $source. See: wpsite list $source"
  else
    # Take a fresh backup from production now (real media by default; --light = placeholders).
    log_info "Taking a fresh $([ "$full" = 1 ] && echo 'full (real media)' || echo 'light (placeholder)') backup of '$source'..."
    ssh_setup_mux
    trap ssh_close_mux EXIT
    _backup_one_client "$source" "$full" || die "Backup of '$source' failed; not cloning."
    ssh_close_mux
    trap - EXIT
    # shellcheck disable=SC2012  # timestamp dirs; mtime sort via ls is fine
    latest="$(ls -td "$backup_dir"/*/ 2>/dev/null | head -1)"
    latest="${latest%/}"
  fi
  [ -f "$latest/db.sql" ] && [ -f "$latest/wp-content.tar.gz" ] \
    || die "Backup at $latest is incomplete (missing db.sql or wp-content.tar.gz)."

  local host="$devname.test"
  log_info "Cloning '$source' → dev site '$devname' ($host) from $(basename "$latest")"

  # Multisite guard/notice: a network clone is reachable at MULTIPLE namespaced hosts,
  # not just <devname>.test. Tell the user where (so they don't go looking at the
  # bare host) and that mapped subsites fall back to a sanitized host.
  if [ "$(_meta_get MULTISITE "$latest/meta.env")" = "1" ] && [ -f "$latest/sites.csv" ]; then
    log_warn "'$source' is a MULTISITE network — the clone is namespaced under '$devname.test':"
    local prod local_d
    while read -r prod local_d; do
      [ -n "$local_d" ] || continue
      log_warn "    $prod  →  http://$local_d"
    done < <(_ms_pairs "$latest/sites.csv" "$devname")
    log_warn "  (subsites on unrelated mapped domains get a sanitized <host>.$devname.test)"
  fi

  # Register the dev site (written before the build so a failed build is cleanable
  # via `wpsite destroy $devname`).
  dev_set "$devname" host "$host"
  dev_set "$devname" source "$source"
  dev_set "$devname" backup "$(basename "$latest")"
  dev_set "$devname" wp_version "$(_meta_get WP_VERSION "$latest/meta.env")"
  dev_set "$devname" php "$(_meta_get PHP_VERSION "$latest/meta.env")"

  # Pass devname as the multisite namespace so a network clone can't collide with the
  # client's own build (single-site clone ignores it).
  _build_from_backup "$latest" "$devname" "$host" "$(client_get "$source" deactivate_plugins)" "$devname"
}
