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
  # Safely shell-escape all remaining arguments to preserve quoting/spaces over SSH
  local escaped_args
  escaped_args="$(printf '%q ' "$@")"
  # Detect if the remote wp command is a shell script wrapper (like on Mittwald).
  # If so, run it directly; otherwise run with PHP memory & time overrides.
  local remote_cmd
  remote_cmd="wp_bin=\$(which wp 2>/dev/null || echo wp); if [ -f \"\$wp_bin\" ] && head -n1 \"\$wp_bin\" 2>/dev/null | grep -qE \"sh|bash\"; then wp $escaped_args --allow-root; else php -d memory_limit=512M -d max_execution_time=300 \"\$wp_bin\" $escaped_args --allow-root; fi"
  wpsite_ssh "$t" "cd '$root' && $remote_cmd"
}

_prod_maintenance_on() { # ssh_target wp_root
  local t="$1" root="$2"
  # Upload custom maintenance.php drop-in first.
  cat << 'EOF' | wpsite_ssh "$t" "cat > '$root/wp-content/maintenance.php'"
<?php
// Custom static maintenance page served during upgrades.
// Bypasses WordPress core and database initialization.
header('HTTP/1.1 503 Service Temporarily Unavailable');
header('Status: 503 Service Temporarily Unavailable');
header('Retry-After: 600');
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Scheduled Maintenance</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background-color: #f7f9fa; color: #333; text-align: center; padding: 100px 20px 50px 20px; }
        .container { max-width: 600px; margin: 0 auto; background: white; padding: 40px; border-radius: 8px; box-shadow: 0 4px 12px rgba(0,0,0,0.05); border-top: 4px solid #007cba; }
        h1 { color: #1d2327; font-size: 24px; margin-top: 0; margin-bottom: 16px; }
        p { color: #50575e; font-size: 16px; line-height: 1.5; margin-bottom: 24px; }
        .spinner { display: inline-block; width: 30px; height: 30px; border: 3px solid #f3f3f3; border-top: 3px solid #007cba; border-radius: 50%; animation: spin 1s linear infinite; }
        @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
    </style>
</head>
<body>
    <div class="container">
        <h1>Scheduled Maintenance</h1>
        <p>This site is currently undergoing scheduled updates and will be back online shortly. Thank you for your patience!</p>
        <div class="spinner"></div>
    </div>
</body>
</html>
EOF

  # Drop the .maintenance file to activate the lock.
  wpsite_ssh "$t" "echo '<?php \$upgrading = time() + 3600; ?>' > '$root/.maintenance'"
}

_prod_maintenance_off() { # ssh_target wp_root
  local t="$1" root="$2"
  wpsite_ssh "$t" "rm -f '$root/.maintenance'"
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
  _prod_maintenance_on "$ssh_target" "$wp_root" || log_warn "could not enable maintenance mode"

  # Multisite networks migrate every subsite's DB → need --network on update-db.
  local is_ms=0
  if [ "$(_prod_wp "$ssh_target" "$wp_root" eval 'echo is_multisite() ? 1 : 0;' 2>/dev/null | tr -d '[:space:]')" = "1" ]; then
    is_ms=1
    log_warn "Multisite network detected — update-db will run --network across all subsites."
    log_warn "Note: the local rehearsal (build/--review) does not yet cover multisite — verify subsites by hand."
  fi

  # 3) Upgrades on production (in place).
  log_info "[3/5] Updating core/plugins/themes on PRODUCTION..."
  local ok=1
  _prod_wp "$ssh_target" "$wp_root" core update >/dev/null 2>&1 || { ok=0; log_warn "core update failed"; }
  if [ "$is_ms" = 1 ]; then
    _prod_wp "$ssh_target" "$wp_root" core update-db --network >/dev/null 2>&1 || { ok=0; log_warn "core update-db --network failed"; }
  else
    _prod_wp "$ssh_target" "$wp_root" core update-db >/dev/null 2>&1 || { ok=0; log_warn "core update-db failed"; }
  fi
  # Update plugins individually (prevents single-plugin failures from breaking the cascade)
  log_info "Updating plugins on PRODUCTION..."
  local plugins
  plugins="$(_prod_wp "$ssh_target" "$wp_root" plugin list --update=available --field=name 2>/dev/null | tr -d '\r')"
  if [ -n "$plugins" ]; then
    local p
    for p in $plugins; do
      if [ "$p" = "wp-staging-pro" ]; then
        log_info "  Skipping premium plugin: $p"
        continue
      fi
      log_info "  Updating plugin: $p..."
      _prod_wp "$ssh_target" "$wp_root" plugin update "$p" >/dev/null 2>&1 || { ok=0; log_warn "  Plugin update failed: $p"; }
    done
  else
    log_info "  All plugins already up to date."
  fi

  # Update themes individually
  log_info "Updating themes on PRODUCTION..."
  local themes
  themes="$(_prod_wp "$ssh_target" "$wp_root" theme list --update=available --field=name 2>/dev/null | tr -d '\r')"
  if [ -n "$themes" ]; then
    local t
    for t in $themes; do
      log_info "  Updating theme: $t..."
      _prod_wp "$ssh_target" "$wp_root" theme update "$t" >/dev/null 2>&1 || { ok=0; log_warn "  Theme update failed: $t"; }
    done
  else
    log_info "  All themes already up to date."
  fi
  _prod_wp "$ssh_target" "$wp_root" cache flush           >/dev/null 2>&1 || true

  # 4) Maintenance mode off (always, even if an update failed — don't strand the site).
  log_info "[4/5] Maintenance mode OFF..."
  _prod_maintenance_off "$ssh_target" "$wp_root" || log_warn "could not disable maintenance mode — CHECK THE SITE"

  # Report (reuses the local upgrade report renderer).
  local core_after; core_after="$(_prod_wp "$ssh_target" "$wp_root" core version 2>/dev/null | tr -d '\r')"
  _prod_versions "$ssh_target" "$wp_root" "$dir" after
  _upgrade_report "$client (PRODUCTION)" "$stamp" "$core_before" "$core_after" "$dir" | tee "$dir/report.txt" >&2

  # German client report and PDF compilation for production
  _client_report_de "$client (PRODUCTION)" "$stamp" "$core_before" "$core_after" "$dir" > "$dir/wartungsbericht.txt"
  cupsfilter -i text/plain -o document-format=application/pdf "$dir/wartungsbericht.txt" > "$dir/wartungsbericht.pdf" 2>/dev/null || true
  log_ok "Wartungsbericht (DE): $dir/wartungsbericht.txt (.pdf)"

  # 5) Verify the live site responds.
  log_info "[5/5] Verifying production responds..."
  local home code
  home="$(_prod_wp "$ssh_target" "$wp_root" option get home 2>/dev/null | tr -d '\r')"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$home" 2>/dev/null || echo 000)"

  # Send verification email via wp_mail()
  local admin_email
  admin_email="$(_prod_wp "$ssh_target" "$wp_root" option get admin_email 2>/dev/null | tr -d '\r')"
  if [ -n "$admin_email" ]; then
    log_info "Sending a verification email via wp_mail() to: $admin_email..."
    # Execute wp_mail() via wp eval. We escape the double quotes for PHP and single quotes for Bash.
    if _prod_wp "$ssh_target" "$wp_root" eval "exit(wp_mail('$admin_email', '[wpsite] E-Mail-Funktionstest nach Wartung', 'Hallo, dies ist eine automatisierte Test-E-Mail von wpsite, um die Funktion des Mail-Versands (z.B. WP Mail SMTP) auf Ihrer Website nach den durchgeführten Wartungsarbeiten zu verifizieren. Alles laeuft stabil!') ? 0 : 1);" >/dev/null 2>&1; then
      log_ok "  Verification email sent successfully!"
    else
      log_warn "  Test email sending FAILED! Please verify your SMTP plugin settings on the site."
    fi
  fi

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
