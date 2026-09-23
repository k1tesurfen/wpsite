# shellcheck shell=bash
# wpsite clone <name> <devname> — initialise a dev site FROM AN ON-DISK BACKUP.
#
# Local-only by design: it is exactly `build`, but into a dev site. It NEVER takes a
# fresh backup and opens no SSH connection — run `wpsite backup <c>` (optionally
# `--light`) first. That makes it behave identically on the gateway and on a dev box,
# and means no replica-building command can reach production. See DEVBOX-PLAN.md §5.2.
#
# Registry-optional too: instead of require_client it only needs a complete backup under
# <base_dir>/clients/<name>/backups/. On the gateway <name> is a real client (and its
# deactivate_plugins list is picked up automatically); on a dev box with no mandos it is
# simply the directory a pushed packet landed in, and --deactivate supplies the list.
#
# Reuses the full build pipeline via _build_from_backup (URL rewrite, known admin,
# Mailpit, plugin sanitization) targeting base_dir/dev/<devname>.

cmd_clone() {
  local source="" devname="" backup_id="" deactivate="" host=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --backup)     backup_id="${2:-}"; shift 2 ;;
      --backup=*)   backup_id="${1#*=}"; shift ;;
      --deactivate) deactivate="${2:-}"; shift 2 ;;
      --deactivate=*) deactivate="${1#*=}"; shift ;;
      --host)       host="${2:-}"; shift 2 ;;
      --host=*)     host="${1#*=}"; shift ;;
      # Media mode is a property of the BACKUP, not of the clone. These used to pick
      # how the fresh backup was taken; there is no fresh backup any more.
      --light|--full)
        die "wpsite clone no longer takes a backup, so $1 has no meaning here.
  Capture the media mode when you back up:  wpsite backup <client> --light
  then clone from it:                       wpsite clone <client> <devname>" ;;
      -*) die "Unknown flag: $1" ;;
      *)
        if [ -z "$source" ]; then source="$1"; elif [ -z "$devname" ]; then devname="$1";
        else die "Unexpected argument: $1"; fi
        shift ;;
    esac
  done

  config_require
  require docker
  local usage="Usage: wpsite clone <name> <devname> [--backup <id>] [--deactivate <slugs>] [--host <host>]"
  [ -n "$source" ]  || die "$usage"
  [ -n "$devname" ] || die "$usage"

  _valid_site_name "$devname" || die "Invalid dev site name '$devname' (use lowercase letters, digits, hyphens)."
  if _name_taken "$devname"; then die "'$devname' already exists as a $(target_kind "$devname" | grep . || echo "mandos client"). Choose another name."; fi

  _ensure_base_layout

  # --- Select the backup: an explicit id, else the newest COMPLETE one -------------
  local latest
  if [ -n "$backup_id" ]; then
    latest="$(resolve_backup_dir "$source" "${backup_id%/}")"
    [ -d "$latest" ] || die "Backup '$backup_id' not found for '$source'. See: wpsite list --backups $source"
  else
    latest="$(latest_backup_dir "$source")"
    [ -n "$latest" ] || die "No complete backup on disk for '$source'.
  On the gateway:  wpsite backup $source [--light]
  On a dev box:    push one over first (see DEVBOX-PLAN.md)"
  fi
  _is_complete_backup "$latest" \
    || die "Backup at $latest is incomplete (needs db.sql, wp-content.tar.gz and meta.env).
  A half-transferred packet looks like this — re-run the copy."

  # Surface the backup's age: with fresh backups no longer automatic, cloning from a
  # stale snapshot is now possible. Computed from the id (a timestamp), not the mtime.
  local id age agetxt=""
  id="$(basename "$latest")"
  age="$(_backup_age_days "$id")"
  [ -n "$age" ] && agetxt=" — ${age} day(s) old"
  [ -n "$age" ] && [ "$age" -ge 30 ] && log_warn "Backup $id is ${age} days old; take a fresh one if the content matters."

  [ -n "$host" ] || host="$devname.$(config_dev_suffix)"
  log_info "Cloning '$source' → dev site '$devname' ($host) from $id$agetxt"

  # Multisite guard/notice: a network clone is reachable at MULTIPLE namespaced hosts,
  # not just the bare one. Tell the user where (so they don't go looking at the bare
  # host) and that mapped subsites fall back to a sanitized host.
  if [ "$(_meta_get MULTISITE "$latest/meta.env")" = "1" ] && [ -f "$latest/sites.csv" ]; then
    log_warn "'$source' is a MULTISITE network — the clone is namespaced under '$host':"
    local prod local_d
    while read -r prod local_d; do
      [ -n "$local_d" ] || continue
      log_warn "    $prod  →  http://$local_d"
    done < <(_ms_pairs "$latest/sites.csv" "$devname")
    log_warn "  (subsites on unrelated mapped domains get a sanitized <host>.$host)"
  fi

  # Plugin sanitization extras: explicit flag wins; otherwise fall back to the client
  # registry, which yields the list on the gateway and empty on a registry-less dev box
  # (client_get is || true-wrapped, so a missing mandos is not an error here).
  [ -n "$deactivate" ] || deactivate="$(wclient_get "$source" deactivate_plugins)"

  # Register the dev site (written before the build so a failed build is cleanable
  # via `wpsite destroy $devname`).
  dev_set "$devname" host "$host"
  dev_set "$devname" source "$source"
  dev_set "$devname" backup "$id"
  dev_set "$devname" wp_version "$(_meta_get WP_VERSION "$latest/meta.env")"
  dev_set "$devname" php "$(_meta_get PHP_VERSION "$latest/meta.env")"

  # Pass devname as the multisite namespace so a network clone can't collide with the
  # client's own build (single-site clone ignores it).
  _build_from_backup "$latest" "$devname" "$host" "$deactivate" "$devname"
}
