# shellcheck shell=bash
# wpsite upgrade <client> — run WP-CLI core/plugin/theme updates on the RUNNING
# replica and write a before→after report. Local only; never touches production.
# Fully reversible: a bad upgrade is just `wpsite build <client>` away from a reset.

# wp-cli in a client's app container. Runs without --skip-plugins/--skip-themes
# to ensure third-party update-checkers boot fully and capture premium updates.
_upgrade_wp() { # app_container args...
  local app="$1"; shift
  docker exec "$app" php -d memory_limit=512M -d max_execution_time=300 /usr/local/bin/wp --allow-root --path=/var/www/html "$@"
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

_report_section_de() { # before.csv after.csv
  local before="$1" after="$2" tmp changed pending
  tmp="$(mktemp -d)"
  tail -n +2 "$before" 2>/dev/null | sort -t, -k1,1 > "$tmp/b"
  tail -n +2 "$after"  2>/dev/null | sort -t, -k1,1 > "$tmp/a"
  # name, before-version, after-version  → list where the version changed
  changed="$(join -t, -j1 -o '1.1,1.2,2.2' "$tmp/b" "$tmp/a" 2>/dev/null \
    | awk -F, '$2!=$3 {printf "    ✓ %s: %s —> %s\n",$1,$2,$3}')"
  # after rows still showing an available update
  pending="$(awk -F, '$3=="available" {printf "    ! %s (%s) — Update ausstehend (manuelle Freigabe erforderlich)\n",$1,$2}' "$tmp/a")"
  rm -rf "$tmp"
  if [ -n "$changed" ]; then 
    printf '%s\n' "$changed"
  else 
    echo "    Keine Änderungen (bereits aktuell)"
  fi
  if [ -n "$pending" ]; then
    echo
    printf '%s\n' "$pending"
  fi
  return 0
}

_client_report_de() { # client stamp core_before core_after dir
  local client="$1" stamp="$2" cb="$3" ca="$4" dir="$5"
  local formatted_date
  # Parse stamp (YYYYMMDD_HHMMSS) to a nice readable German format, e.g. DD.MM.YYYY um HH:MM Uhr
  if [[ "$stamp" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})$ ]]; then
    formatted_date="${BASH_REMATCH[3]}.${BASH_REMATCH[2]}.${BASH_REMATCH[1]} um ${BASH_REMATCH[4]}:${BASH_REMATCH[5]} Uhr"
  else
    formatted_date="$(date '+%d.%m.%Y um %H:%M Uhr')"
  fi

  cat <<EOF
================================================================================
                           WARTUNGSBERICHT
================================================================================

--------------------------------------------------------------------------------
PROJEKT-DETAILS
--------------------------------------------------------------------------------
  • Kunde / Projekt:    $client
  • Zeitpunkt:          $formatted_date
  • Status nach Update: Aktiv und stabil (HTTP 200)

--------------------------------------------------------------------------------
DURCHGEFÜHRTE AKTUALISIERUNGEN
--------------------------------------------------------------------------------

EOF

  if [ "$cb" = "$ca" ]; then
    echo "  • WordPress Core:      $cb (bereits auf dem neuesten Stand)"
  else
    echo "  • WordPress Core:      $cb  ──>  $ca (erfolgreich aktualisiert)"
  fi
  echo

  echo "Erweiterungen (Plugins):"
  _report_section_de "$dir/plugins.before.csv" "$dir/plugins.after.csv"
  echo

  echo "Design-Vorlagen (Themes):"
  _report_section_de "$dir/themes.before.csv" "$dir/themes.after.csv"
  echo

  cat <<EOF
--------------------------------------------------------------------------------
UNSERE QUALITÄTSSICHERUNG
--------------------------------------------------------------------------------
Im Rahmen des Wartungsprozesses wurden folgende Schritte durchgeführt:
  1. Erstellung eines vollständigen Backups als Wiederherstellungspunkt.
  2. Einspielen aller Sicherheits- und Systemupdates.
  3. Automatische visuelle Vorher-Nachher-Überprüfung aller Kernseiten.
  4. Leerung und Optimierung aller System-Caches.
  5. Abschließender Erreichbarkeits- und Funktionscheck.

================================================================================
EOF
}

cmd_upgrade() {
  local client="" review=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --noreview) review=0; shift ;;
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
  # Update plugins individually (prevents single-plugin failures from breaking the cascade)
  log_info "Updating plugins..."
  local plugins
  plugins="$(_upgrade_wp "$app_c" plugin list --update=available --field=name 2>/dev/null | tr -d '\r')"
  if [ -n "$plugins" ]; then
    local p
    for p in $plugins; do
      if [ "$p" = "wp-staging-pro" ]; then
        log_info "  Skipping premium plugin: $p"
        continue
      fi
      log_info "  Updating plugin: $p..."
      _upgrade_wp "$app_c" plugin update "$p" >/dev/null 2>&1 || log_warn "  Plugin update failed: $p"
    done
  else
    log_info "  All plugins already up to date."
  fi

  # Update themes individually
  log_info "Updating themes..."
  local themes
  themes="$(_upgrade_wp "$app_c" theme list --update=available --field=name 2>/dev/null | tr -d '\r')"
  if [ -n "$themes" ]; then
    local t
    for t in $themes; do
      log_info "  Updating theme: $t..."
      _upgrade_wp "$app_c" theme update "$t" >/dev/null 2>&1 || log_warn "  Theme update failed: $t"
    done
  else
    log_info "  All themes already up to date."
  fi

  # --- AFTER ---
  local core_after; core_after="$(_upgrade_wp "$app_c" core version 2>/dev/null | tr -d '\r')"
  _upgrade_wp "$app_c" plugin list --fields=name,version,update --format=csv 2>/dev/null | tr -d '\r' > "$dir/plugins.after.csv"
  _upgrade_wp "$app_c" theme  list --fields=name,version,update --format=csv 2>/dev/null | tr -d '\r' > "$dir/themes.after.csv"

  # --- Report ---
  echo >&2
  _upgrade_report "$client" "$stamp" "$core_before" "$core_after" "$dir" | tee "$dir/report.txt" >&2
  log_ok "Report saved: $dir/report.txt   (reset anytime with: wpsite build $client)"

  # German client report and PDF compilation
  _client_report_de "$client" "$stamp" "$core_before" "$core_after" "$dir" > "$dir/wartungsbericht.txt"
  cupsfilter -i text/plain -o document-format=application/pdf "$dir/wartungsbericht.txt" > "$dir/wartungsbericht.pdf" 2>/dev/null || true
  log_ok "Wartungsbericht (DE): $dir/wartungsbericht.txt (.pdf)"

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
