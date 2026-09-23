# shellcheck shell=bash
# wpsite maintenance <client> [off|status] — the maintenance lock `apply` puts on
# PRODUCTION, by hand.
#
#   wpsite maintenance <client>            status (the default)
#   wpsite maintenance <client> status     which lock files exist + what visitors see
#   wpsite maintenance <client> off        lift it: remove all four files, then verify
#   (--off / --status work too)
#
# apply keeps maintenance ON on purpose when the site is really broken at the end (see
# _apply_finish) and prints this command; it's also the fix when a run was interrupted
# and the dead-man switch hasn't expired yet. Writes to production, but only ever
# REMOVES apply's own lock files (_prod_maintenance_off) — nothing else is touched.

cmd_maintenance() {
  local client="" action=""
  while [ $# -gt 0 ]; do
    case "$1" in
      off|--off)       action=off; shift ;;
      status|--status) action=status; shift ;;
      on|--on) die "Turning maintenance ON by hand isn't supported — apply manages it. (Only: off | status)" ;;
      -*) die "Unknown flag: $1 (usage: wpsite maintenance <client> [off|status])" ;;
      *) [ -z "$client" ] || die "Unexpected argument: $1"; client="$1"; shift ;;
    esac
  done
  [ -n "$client" ] || die "Usage: wpsite maintenance <client> [off|status]"
  action="${action:-status}"

  config_require_registry
  require_client "$client"
  require_access "$client"

  local t root
  t="$(client_get "$client" ssh)"; root="$(client_get "$client" wp_root)"
  ssh_setup_mux
  trap ssh_close_mux EXIT

  if [ "$action" = off ]; then
    log_info "Lifting maintenance on '$client' ($t:$root)..."
    _prod_maintenance_off "$t" "$root" \
      || die "Could not remove the lock files — do it by hand: $(_maintenance_manual_cmd "$t" "$root")"
    log_ok "Maintenance lock removed."
  fi
  local rc=0
  _maintenance_report "$client" "$t" "$root" "$action" || rc=$?
  ssh_close_mux; trap - EXIT
  return "$rc"
}

# Which of apply's lock files exist on the server, and what does a visitor see?
# Returns non-zero when (after `off`) visitors still get the maintenance page.
_maintenance_report() { # client ssh_target wp_root action
  local client="$1" t="$2" root="$3" action="$4" files home probe verdict
  # shellcheck disable=SC2016  # $now etc. are the REMOTE shell's
  files="$(wpsite_ssh "$t" "cd '$root' 2>/dev/null || exit 0
    [ -e .maintenance ] && echo 'lock   .maintenance (WordPress)'
    if [ -e wp-content/.wpsite-maintenance ]; then
      read -r until _ ids < wp-content/.wpsite-maintenance 2>/dev/null
      now=\$(date +%s)
      if [ \"\${until:-0}\" = 0 ] && [ -n \"\$ids\" ]; then echo \"lock   wp-content/.wpsite-maintenance (held — no expiry — ONLY sites with blog ID \$ids)\"
      elif [ \"\${until:-0}\" = 0 ]; then echo 'lock   wp-content/.wpsite-maintenance (held — no expiry)'
      elif [ \"\$until\" -gt \"\$now\" ]; then echo \"lock   wp-content/.wpsite-maintenance (expires in \$(( (until - now) / 60 )) min)\"
      else echo 'file   wp-content/.wpsite-maintenance (expired — no longer blocks)'; fi
    fi
    [ -e wp-content/mu-plugins/wpsite-maintenance.php ] && echo 'file   wp-content/mu-plugins/wpsite-maintenance.php (the gate)'
    [ -e wp-content/maintenance.php ] && echo 'file   wp-content/maintenance.php (the 503 page)'
    true" </dev/null 2>/dev/null || true)"
  if [ -n "$files" ]; then
    log_info "On the server:"
    printf '%s\n' "$files" | sed 's/^/  /' >&2
  else
    log_ok "No maintenance files on the server."
  fi

  home="$(_prod_wp "$t" "$root" option get home </dev/null 2>/dev/null | tr -d '\r' | head -1 || true)"
  [ -n "$home" ] || { log_warn "Could not read the home URL to check what visitors see."; return 0; }
  probe="$(_site_probe "$home")"; verdict="$(printf '%s' "$probe" | cut -f2)"
  case "$verdict" in
    ok)          log_ok "Visitors see the live site: $home (HTTP $(printf '%s' "$probe" | cut -f1))" ;;
    maintenance) log_warn "Visitors see the MAINTENANCE page: $home"
                 [ "$action" = off ] && { log_error "Still in maintenance after lifting — a cache (e.g. WP Rocket, a CDN) may serve the old 503 page; purge it."; return 1; }
                 [ "$action" = status ] && log_info "Lift it with: wpsite maintenance $client off" ;;
    *)           log_warn "Visitors get: $home → HTTP $(printf '%s' "$probe" | cut -f1) ($verdict)" ;;
  esac
  return 0
}
