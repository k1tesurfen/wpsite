# shellcheck shell=bash
# wpsite push <client> [<devname>] — GATEWAY-ONLY: take a backup and ship it to the dev
# box, then build it there as a dev site.
#
# This is the one command that spans both machines, and it exists so the gateway/dev-box
# boundary is never worth shortcutting: the whole hop is `wpsite push acme`, so there is
# no ergonomic pressure to put a production SSH key on the dev box. See DEVBOX-PLAN.md.
#
#   production --SSH--> gateway --rsync over the tailnet--> dev box --> Docker replica
#              (backup)          (the packet)                (clone)
#
# The packet is just the backup directory: db.sql, wp-content.tar.gz, meta.env and
# (multisite) sites.csv. meta.env carries the WP/PHP versions, table prefix and
# production URLs, so it refers to nothing on the gateway.

# Extensions rsync must NOT waste CPU re-compressing. wp-content.tar.gz is already
# gzipped; db.sql is plain text and compresses ~10x on the wire, which is the point.
WPSITE_PUSH_SKIP_COMPRESS="gz,tgz,zip,bz2,xz,mp4,mov,webm,jpg,jpeg,png,gif,webp,pdf"

cmd_push() {
  local client="" devname="" backup_id="" full=1 devbox="" do_clone=1 replace=0 dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --light)     full=0; shift ;;
      --full)      full=1; shift ;;
      --backup)    backup_id="${2:-}"; shift 2 ;;
      --backup=*)  backup_id="${1#*=}"; shift ;;
      --devbox)    devbox="${2:-}"; shift 2 ;;
      --devbox=*)  devbox="${1#*=}"; shift ;;
      --no-clone)  do_clone=0; shift ;;
      --replace)   replace=1; shift ;;
      --dry-run)   dry=1; shift ;;
      -*) die "Unknown flag: $1" ;;
      *)
        if [ -z "$client" ]; then client="$1"; elif [ -z "$devname" ]; then devname="$1";
        else die "Unexpected argument: $1"; fi
        shift ;;
    esac
  done

  config_require_registry
  require rsync
  require ssh
  [ -n "$client" ] || die "Usage: wpsite push <client> [<devname>] [--light] [--backup <id>] [--replace]"
  require_client "$client"

  [ -n "$devname" ] || devname="$client-dev"
  _valid_site_name "$devname" \
    || die "Invalid dev site name '$devname' (use lowercase letters, digits, hyphens)."

  [ -n "$devbox" ] || devbox="$(config_devbox_host)"
  [ -n "$devbox" ] || die "No dev box configured. Add it to $WPSITE_CONFIG:
  devbox:
    host: devbox            # ssh target (e.g. a tailnet name)
    base_dir: websites      # base_dir on that machine
…or pass --devbox <host> / set WPSITE_DEVBOX."
  local rbase; rbase="$(config_devbox_base)"

  # --- 1. The packet: an existing backup, or a fresh one from production -----------
  local latest
  if [ -n "$backup_id" ]; then
    latest="$(resolve_backup_dir "$client" "${backup_id%/}")"
    [ -d "$latest" ] || die "Backup '$backup_id' not found for '$client'. See: wpsite list --backups $client"
    log_info "Shipping existing backup $(basename "$latest") (no production access needed)."
  elif [ "$dry" = 1 ]; then
    latest="$(latest_backup_dir "$client")"
    [ -n "$latest" ] || die "Nothing to dry-run: no complete backup on disk for '$client'."
    log_info "[dry-run] would take a fresh $([ "$full" = 1 ] && echo full || echo light) backup; using $(basename "$latest") to plan."
  else
    log_info "Taking a fresh $([ "$full" = 1 ] && echo 'full (real media)' || echo 'light (placeholder media)') backup of '$client'..."
    ssh_setup_mux
    trap ssh_close_mux EXIT
    _backup_one_client "$client" "$full" || die "Backup of '$client' failed; nothing pushed."
    ssh_close_mux
    trap - EXIT
    latest="$(latest_backup_dir "$client")"
    [ -n "$latest" ] || die "Backup reported success but no complete backup is on disk."
  fi
  _is_complete_backup "$latest" || die "Backup at $latest is incomplete; not pushing."

  local id size
  id="$(basename "$latest")"
  size="$(du -sh "$latest" 2>/dev/null | cut -f1 || true)"
  log_info "Packet: $id (${size:-?}) → $devbox:$rbase/clients/$client/backups/"

  # --- 2. Ship it -----------------------------------------------------------------
  local remote_backups="$rbase/clients/$client/backups"
  if [ "$dry" = 1 ]; then
    log_info "[dry-run] ssh $devbox mkdir -p $remote_backups"
    log_info "[dry-run] rsync $latest → $devbox:$remote_backups/"
  else
    # shellcheck disable=SC2029  # deliberate: %q quotes it HERE so the remote shell
    # receives one safe literal. The path is ours, not user input from the dev box.
    ssh "$devbox" "mkdir -p $(printf '%q' "$remote_backups")" \
      || die "Cannot reach or write on '$devbox' (tried: mkdir -p $remote_backups)."
    # --partial/--append-verify so a dropped tailnet link resumes instead of restarting
    # a multi-GB transfer; --skip-compress so only the compressible member is deflated.
    rsync -a --info=progress2 --partial --append-verify \
          --compress --skip-compress="$WPSITE_PUSH_SKIP_COMPRESS" \
          "$latest" "$devbox:$remote_backups/" \
      || die "rsync to '$devbox' failed; the dev box may hold a partial packet ($id)."
    log_ok "Packet $id delivered."
  fi

  [ "$do_clone" = 1 ] || { log_info "--no-clone: build it there with  wpsite clone $client $devname --backup $id"; return 0; }

  # --- 3. Build it there ----------------------------------------------------------
  # The dev box has no client registry, so the per-client sanitize list travels as a
  # flag: the knowledge stays here, and the dev box just receives slugs.
  local deact remote_cmd
  deact="$(client_get "$client" deactivate_plugins | tr '\n' ' ' | sed 's/ *$//')"
  remote_cmd="wpsite clone $(printf '%q %q' "$client" "$devname") --backup $(printf '%q' "$id")"
  [ -n "$deact" ] && remote_cmd="$remote_cmd --deactivate $(printf '%q' "$deact")"
  [ "$replace" = 1 ] && remote_cmd="wpsite destroy $(printf '%q' "$devname") >/dev/null 2>&1; $remote_cmd"

  if [ "$dry" = 1 ]; then
    log_info "[dry-run] ssh $devbox '$remote_cmd'"
    return 0
  fi
  log_info "Building '$devname' on $devbox..."
  # -t so the remote build streams its progress here (it is a long operation).
  ssh -t "$devbox" "$remote_cmd" \
    || die "Remote build failed. The packet IS on the dev box — retry there with:
  wpsite clone $client $devname --backup $id"
  log_ok "'$devname' is built on $devbox from $id."
  return 0
}
