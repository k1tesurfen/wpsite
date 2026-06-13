# shellcheck shell=bash
# wpsite apply <client> — run the (locally-rehearsed) upgrade ON PRODUCTION, in place.
# NEVER copies replica data back; it re-runs the same WP-CLI updates against the live
# site, after taking a fresh backup as a rollback point. Heavily guarded: typed
# confirmation, a terminal, one client at a time. Rollback is intentionally MANUAL
# (an untested automated prod-rollback would be its own footgun) — apply points you at
# the fresh backup and the steps.
#
# IMPORTANT: this command performs real, irreversible changes on a production server.

# Typed-name confirmation, read from the terminal (works even if stdin is piped).
# Returns 0 only if the user types the exact client name.
_confirm_prod() { # client
  printf 'Type the client name (%s) to proceed: ' "$1" >&2
  local ans=""
  read -r ans 2>/dev/null < /dev/tty || read -r ans 2>/dev/null || ans=""
  [ "$ans" = "$1" ]
}

# Run a wp-cli command on the production server over SSH (in the WP root).
_prod_wp() { # ssh_target wp_root wp-args...
  local t="$1" root="$2"; shift 2
  wpsite_ssh "$t" "cd '$root' && wp $* --allow-root"
}

# Capture name,version,update for plugins+themes from prod into the given dir.
_prod_versions() { # ssh_target wp_root dir suffix
  local t="$1" root="$2" dir="$3" sfx="$4"
  _prod_wp "$t" "$root" plugin list --fields=name,version,update --format=csv 2>/dev/null | tr -d '\r' > "$dir/plugins.$sfx.csv"
  _prod_wp "$t" "$root" theme  list --fields=name,version,update --format=csv 2>/dev/null | tr -d '\r' > "$dir/themes.$sfx.csv"
}

cmd_apply() {
  local client="${1:-}"
  config_require
  require_client "$client"
  require rsync

  local ssh_target wp_root
  ssh_target="$(client_get "$client" ssh)"
  wp_root="$(client_get "$client" wp_root)"
  [ -n "$ssh_target" ] && [ -n "$wp_root" ] || die "clients.$client.ssh / wp_root not set."

  # Soft rehearsal check — did they run the local upgrade --review first?
  if [ -z "$(_latest_upgrade_dir "$client")" ]; then
    log_warn "No local upgrade rehearsal found for $client."
    log_warn "Strongly recommended first: wpsite upgrade $client --review"
  fi

  # Hard confirmation: type the client name. No --yes bypass.
  log_warn "This UPGRADES PRODUCTION for '$client' ($ssh_target:$wp_root)."
  log_warn "It is irreversible. A fresh backup will be taken as a rollback point."
  _confirm_prod "$client" || die "Aborted (confirmation did not match)."

  ssh_setup_mux
  trap _backup_cleanup EXIT

  # 1) Fresh backup = rollback point. No backup -> we do not touch production.
  log_info "[1/5] Fresh production backup (rollback point)..."
  _backup_one_client "$client" "0" \
    || die "Backup failed — refusing to upgrade production without a rollback point."
  local backup_dir
  # shellcheck disable=SC2012  # timestamp dirs; mtime sort via ls is fine
  backup_dir="$(ls -td "$(client_backup_dir "$client")"/*/ 2>/dev/null | head -1)"
  backup_dir="${backup_dir%/}"

  local stamp dir
  stamp="$(date +%Y%m%d_%H%M%S)"
  dir="$(client_base "$client")/applies/$stamp"
  mkdir -p "$dir"
  local core_before; core_before="$(_prod_wp "$ssh_target" "$wp_root" core version 2>/dev/null | tr -d '\r')"
  _prod_versions "$ssh_target" "$wp_root" "$dir" before

  # 2) Maintenance mode on.
  log_info "[2/5] Maintenance mode ON..."
  _prod_wp "$ssh_target" "$wp_root" maintenance-mode activate >/dev/null 2>&1 || log_warn "could not enable maintenance mode"

  # 3) Upgrades on production (in place).
  log_info "[3/5] Updating core/plugins/themes on PRODUCTION..."
  local ok=1
  _prod_wp "$ssh_target" "$wp_root" core update          >/dev/null 2>&1 || { ok=0; log_warn "core update failed"; }
  _prod_wp "$ssh_target" "$wp_root" core update-db        >/dev/null 2>&1 || { ok=0; log_warn "core update-db failed"; }
  _prod_wp "$ssh_target" "$wp_root" plugin update --all   >/dev/null 2>&1 || { ok=0; log_warn "plugin update failed"; }
  _prod_wp "$ssh_target" "$wp_root" theme update --all    >/dev/null 2>&1 || { ok=0; log_warn "theme update failed"; }
  _prod_wp "$ssh_target" "$wp_root" cache flush           >/dev/null 2>&1 || true

  # 4) Maintenance mode off (always, even if an update failed — don't strand the site).
  log_info "[4/5] Maintenance mode OFF..."
  _prod_wp "$ssh_target" "$wp_root" maintenance-mode deactivate >/dev/null 2>&1 || log_warn "could not disable maintenance mode — CHECK THE SITE"

  # Report (reuses the local upgrade report renderer).
  local core_after; core_after="$(_prod_wp "$ssh_target" "$wp_root" core version 2>/dev/null | tr -d '\r')"
  _prod_versions "$ssh_target" "$wp_root" "$dir" after
  _upgrade_report "$client (PRODUCTION)" "$stamp" "$core_before" "$core_after" "$dir" | tee "$dir/report.txt" >&2

  # 5) Verify the live site responds.
  log_info "[5/5] Verifying production responds..."
  local home code
  home="$(_prod_wp "$ssh_target" "$wp_root" option get home 2>/dev/null | tr -d '\r')"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$home" 2>/dev/null || echo 000)"

  ssh_close_mux
  trap - EXIT

  if [ "$ok" = 1 ] && [ "$code" = "200" ]; then
    log_ok "Production upgraded: $home (HTTP 200). Report: $dir/report.txt"
    return 0
  fi

  log_error "Production upgrade had problems (update ok=$ok, homepage HTTP $code)."
  log_error "Rollback point (DB + code): $backup_dir"
  log_error "To roll back manually: restore that backup's db.sql to prod and reinstall the"
  log_error "prior plugin/theme/core versions (see $dir/plugins.before.csv). Then re-check the site."
  return 1
}
