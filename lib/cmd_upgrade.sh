# shellcheck shell=bash
# wpsite upgrade <client> — run WP-CLI core/plugin/theme updates on the RUNNING
# replica and write a before→after report. Local only; never touches production.
# Fully reversible: a bad upgrade is just `wpsite build <client>` away from a reset.

# wp-cli in a client's app container. --skip-plugins/--skip-themes dodges prod-plugin
# bootstrap fatals (e.g. aule); updating files doesn't need plugins loaded.
_upgrade_wp() { # app_container args...
  local app="$1"; shift
  docker exec "$app" wp --allow-root --path=/var/www/html --skip-plugins --skip-themes "$@"
}

# Render the changed + still-pending items for one section (plugins or themes) by
# diffing two `name,version,update` CSVs (wp-cli --format=csv, header on line 1).
_report_section() { # before.csv after.csv
  local before="$1" after="$2" tmp changed pending
  tmp="$(mktemp -d)"
  tail -n +2 "$before" 2>/dev/null | sort -t, -k1,1 > "$tmp/b"
  tail -n +2 "$after"  2>/dev/null | sort -t, -k1,1 > "$tmp/a"
  # name, before-version, after-version  → list where the version changed
  changed="$(join -t, -j1 -o '1.1,1.2,2.2' "$tmp/b" "$tmp/a" 2>/dev/null \
    | awk -F, '$2!=$3 {printf "  • %s: %s → %s\n",$1,$2,$3}')"
  # after rows still showing an available update → not applied (premium / failed)
  pending="$(awk -F, '$3=="available" {printf "  ! %s (%s) — update still available, not applied (premium? handle manually)\n",$1,$2}' "$tmp/a")"
  rm -rf "$tmp"
  if [ -n "$changed" ]; then printf '%s\n' "$changed"; else echo "  (none updated)"; fi
  [ -n "$pending" ] && printf '%s\n' "$pending"
  return 0
}

# Human-readable report to stdout (also tee'd to report.txt by the caller).
_upgrade_report() { # client stamp core_before core_after dir
  local client="$1" stamp="$2" cb="$3" ca="$4" dir="$5"
  echo "wpsite upgrade report — $client — $stamp"
  echo "=================================================================="
  echo
  if [ "$cb" = "$ca" ]; then
    echo "WordPress core:  $cb  (no change)"
  else
    echo "WordPress core:  $cb → $ca"
  fi
  echo
  echo "Plugins:"
  _report_section "$dir/plugins.before.csv" "$dir/plugins.after.csv"
  echo
  echo "Themes:"
  _report_section "$dir/themes.before.csv" "$dir/themes.after.csv"
}

cmd_upgrade() {
  local client="" review=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --review) review=1; shift ;;
      -*) die "Unknown flag: $1" ;;
      *) client="$1"; shift ;;
    esac
  done
  config_require
  require_client "$client"
  require docker

  local app_c="wp_${client}_app"
  [ "$(docker inspect -f '{{.State.Running}}' "$app_c" 2>/dev/null)" = "true" ] \
    || die "Replica '$client' isn't running. Build it first: wpsite build $client"
  _ensure_wp_cli "$app_c" || die "wp-cli unavailable in $app_c."

  local stamp dir
  stamp="$(date +%Y%m%d_%H%M%S)"
  dir="$(client_base "$client")/upgrades/$stamp"
  mkdir -p "$dir"
  log_info "Upgrading '$client' (local replica). Report → $dir"

  # --- Review setup: page list, fatal baseline, BEFORE screenshots ---
  local docker_dir fatal_baseline=0 specs=() shot_hosts="" dismiss=""
  if [ "$review" = 1 ]; then
    docker_dir="$(client_docker_dir "$client")"
    dismiss="$(_review_dismiss "$client")"   # consent banners to hide before each shot
    local u s
    if [ "$(_upgrade_wp "$app_c" eval 'echo is_multisite() ? 1 : 0;' 2>/dev/null | tr -d '[:space:]')" = "1" ]; then
      # Multisite: home + 1 page per subsite, slugs namespaced; shoot every subsite host.
      while IFS= read -r s; do [ -n "$s" ] && specs+=("$s"); done < <(_ms_review_specs "$app_c")
    else
      local local_host local_url
      local_host="$(client_local_host "$client")"
      local_url="http://$local_host"
      while IFS= read -r u; do [ -n "$u" ] && specs+=("$(_url_slug "$u")|$u"); done \
        < <(_review_pages "$client" "$app_c" "$local_url")
    fi
    shot_hosts="$(_specs_hosts "${specs[@]}" | tr '\n' ' ')"
    fatal_baseline="$(_debug_fatal_count "$docker_dir")"
    log_info "Capturing ${#specs[@]} page(s) BEFORE upgrade..."
    _capture_shots "$dir/before" "$shot_hosts" "$dismiss" "${specs[@]}" || log_warn "before-capture had issues"
  fi

  # --- BEFORE versions ---
  local core_before; core_before="$(_upgrade_wp "$app_c" core version 2>/dev/null | tr -d '\r')"
  _upgrade_wp "$app_c" plugin list --fields=name,version,update --format=csv 2>/dev/null | tr -d '\r' > "$dir/plugins.before.csv"
  _upgrade_wp "$app_c" theme  list --fields=name,version,update --format=csv 2>/dev/null | tr -d '\r' > "$dir/themes.before.csv"

  # --- Upgrades (the version diff is the source of truth, so warn-don't-die) ---
  log_info "Updating WordPress core..."
  _upgrade_wp "$app_c" core update    >/dev/null 2>&1 || log_warn "core update reported an issue"
  # Multisite migrates ALL subsites' tables → needs --network (which errors on single sites).
  if [ "$(_upgrade_wp "$app_c" eval 'echo is_multisite() ? 1 : 0;' 2>/dev/null | tr -d '[:space:]')" = "1" ]; then
    _upgrade_wp "$app_c" core update-db --network >/dev/null 2>&1 || log_warn "core update-db --network reported an issue"
  else
    _upgrade_wp "$app_c" core update-db >/dev/null 2>&1 || log_warn "core update-db reported an issue"
  fi
  log_info "Updating plugins..."
  _upgrade_wp "$app_c" plugin update --all >/dev/null 2>&1 || log_warn "some plugins did not update"
  log_info "Updating themes..."
  _upgrade_wp "$app_c" theme update --all  >/dev/null 2>&1 || log_warn "some themes did not update"

  # --- AFTER ---
  local core_after; core_after="$(_upgrade_wp "$app_c" core version 2>/dev/null | tr -d '\r')"
  _upgrade_wp "$app_c" plugin list --fields=name,version,update --format=csv 2>/dev/null | tr -d '\r' > "$dir/plugins.after.csv"
  _upgrade_wp "$app_c" theme  list --fields=name,version,update --format=csv 2>/dev/null | tr -d '\r' > "$dir/themes.after.csv"

  # --- Report ---
  echo >&2
  _upgrade_report "$client" "$stamp" "$core_before" "$core_after" "$dir" | tee "$dir/report.txt" >&2
  log_ok "Report saved: $dir/report.txt   (reset anytime with: wpsite build $client)"

  # --- Review: AFTER screenshots, smoke check, build + open comparison page ---
  if [ "$review" = 1 ]; then
    echo >&2
    log_info "Capturing ${#specs[@]} page(s) AFTER upgrade..."
    _capture_shots "$dir/after" "$shot_hosts" "$dismiss" "${specs[@]}" || log_warn "after-capture had issues"
    _smoke_check "$docker_dir" "$fatal_baseline" "${specs[@]}"
    _render_review_html "$dir" "$client" "$stamp" "${specs[@]}"
    log_ok "Comparison page: $dir/review.html"
    _open_file "$dir/review.html"
  fi
}
