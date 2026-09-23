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
  # Host wp unusable → our uploaded phar (see _remote_wp_prepare); no sniffing needed.
  if [ "${_WPSITE_WP_BUNDLED:-0}" = 1 ]; then
    wpsite_ssh "$t" "cd '$root' && $(_remote_wp_cmd) $escaped_args --allow-root"
    return
  fi
  remote_cmd="wp_bin=\$(which wp 2>/dev/null || echo wp); if [ -f \"\$wp_bin\" ] && head -n1 \"\$wp_bin\" 2>/dev/null | grep -qE \"sh|bash\"; then wp $escaped_args --allow-root; else php -d memory_limit=512M -d max_execution_time=300 \"\$wp_bin\" $escaped_args --allow-root; fi"
  wpsite_ssh "$t" "cd '$root' && $remote_cmd"
}

# --- Maintenance mode that survives WordPress's own updater --------------------------
# WordPress's upgrader writes AND DELETES `.maintenance` around every single update
# (Core_Upgrader / WP_Upgrader::maintenance_mode(false)), so a lock set once at the start
# is gone after the first plugin — seen on arbeitsplatz-erde, where the site was live and
# unprotected for most of the run. So we hold TWO locks:
#   1. our own flag  wp-content/.wpsite-maintenance  ("<until-epoch> <token>") + a tiny
#      mu-plugin that serves the 503 page while it exists. WordPress never touches it.
#   2. `.maintenance`, re-written after EVERY update step (covers core mid-update, before
#      mu-plugins load).
# Dead-man switch: both carry a short expiry (WPSITE_MAINT_TTL), refreshed per step — if
# wpsite dies or SSH drops, the site comes back by itself. `hold` makes both permanent
# (the site is broken: a clean 503 beats a fatal). The token lets wpsite look at the REAL
# site through the gate (X-Wpsite-Bypass header) before lifting it.
WPSITE_MAINT_TTL="${WPSITE_MAINT_TTL:-900}"
WPSITE_MAINT_MARKER="wpsite-maintenance-page"

# The 503 page (German, neutral — no agency name). Served by WP's own .maintenance
# handling (it requires wp-content/maintenance.php) AND by our mu-plugin gate.
_maintenance_page() {
  cat <<'EOF'
<?php
// wpsite-maintenance-page — installed by `wpsite apply`, removed when it finishes.
if ( ! headers_sent() ) {
	header( 'HTTP/1.1 503 Service Temporarily Unavailable' );
	header( 'Status: 503 Service Temporarily Unavailable' );
	header( 'Retry-After: 600' );
	header( 'Cache-Control: no-store' );
}
?><!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Wartungsarbeiten</title>
<style>
  body { margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
         font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
         background: #f5f6f7; color: #2b2f33; text-align: center; padding: 24px; box-sizing: border-box; }
  h1 { font-size: 1.6rem; font-weight: 600; margin: 0 0 12px; }
  p  { margin: 0; line-height: 1.6; color: #555b61; }
</style>
</head>
<body>
<main>
  <h1>Wir führen gerade Wartungsarbeiten durch</h1>
  <p>Diese Website ist in wenigen Minuten wieder erreichbar.<br>Vielen Dank für Ihre Geduld.</p>
</main>
</body>
</html>
EOF
}

# The gate. Never active under WP-CLI (our own calls must work); honours the dead-man
# expiry and the bypass token.
_maintenance_muplugin() {
  cat <<'EOF'
<?php
/**
 * wpsite maintenance gate — installed by `wpsite apply`, removed when it finishes.
 * Keeps visitors on the 503 page for the WHOLE update run (WordPress's updater deletes
 * .maintenance after every single update). Inactive under WP-CLI.
 */
if ( defined( 'WP_CLI' ) && WP_CLI ) { return; }
$wpsite_flag = WP_CONTENT_DIR . '/.wpsite-maintenance';
if ( ! is_readable( $wpsite_flag ) ) { return; }
$wpsite_parts = preg_split( '/\s+/', trim( (string) @file_get_contents( $wpsite_flag ) ) );
$wpsite_until = isset( $wpsite_parts[0] ) ? (int) $wpsite_parts[0] : 0;
$wpsite_token = isset( $wpsite_parts[1] ) ? (string) $wpsite_parts[1] : '';
if ( $wpsite_until > 0 && time() > $wpsite_until ) { return; } // dead-man switch
if ( $wpsite_token !== '' && isset( $_SERVER['HTTP_X_WPSITE_BYPASS'] )
	&& hash_equals( $wpsite_token, (string) $_SERVER['HTTP_X_WPSITE_BYPASS'] ) ) { return; }
if ( is_readable( WP_CONTENT_DIR . '/maintenance.php' ) ) { require WP_CONTENT_DIR . '/maintenance.php'; }
exit;
EOF
}

# A fresh random token for the bypass header (no pipe-to-head: SIGPIPE under pipefail).
_maintenance_token() { od -An -tx1 -N16 /dev/urandom | tr -d ' \n'; }

# Install page + gate, then arm both locks. Non-zero if anything could not be written.
_prod_maintenance_on() { # ssh_target wp_root token
  local t="$1" root="$2" token="$3"
  _maintenance_page | wpsite_ssh "$t" "cat > '$root/wp-content/maintenance.php'" || return 1
  _maintenance_muplugin | wpsite_ssh "$t" "mkdir -p '$root/wp-content/mu-plugins' && cat > '$root/wp-content/mu-plugins/wpsite-maintenance.php'" || return 1
  _WPSITE_MAINT_TOKEN="$token"   # the refresh/hold writers read it
  _prod_maintenance_refresh "$t" "$root"
}

# Re-arm both locks with a fresh expiry (the dead-man switch). Times come from the
# SERVER's clock, so a skewed laptop clock can't make the lock expire early or never.
_prod_maintenance_refresh() { # ssh_target wp_root
  local t="$1" root="$2"
  # shellcheck disable=SC2016  # $(date …) runs on the REMOTE
  wpsite_ssh "$t" "now=\$(date +%s); printf '%s %s\n' \"\$((now + $WPSITE_MAINT_TTL))\" '${_WPSITE_MAINT_TOKEN:-}' > '$root/wp-content/.wpsite-maintenance' && printf '<?php \$upgrading = %s; ?>' \"\$now\" > '$root/.maintenance'"
}

# PERMANENT lock (site broken): no expiry on either. `$upgrading = time()` is evaluated
# per request, so WordPress never considers it stale.
_prod_maintenance_hold() { # ssh_target wp_root
  local t="$1" root="$2"
  wpsite_ssh "$t" "printf '0 %s\n' '${_WPSITE_MAINT_TOKEN:-}' > '$root/wp-content/.wpsite-maintenance' && printf '<?php \$upgrading = time(); ?>' > '$root/.maintenance'"
}

# Remove only WordPress's .maintenance (our gate stays) — lets the final check look at the
# real site through the bypass token before anything is lifted for visitors.
_prod_maintenance_lift_wp() { # ssh_target wp_root
  wpsite_ssh "$1" "rm -f '$2/.maintenance'"
}

# Everything off: both locks, the gate and the page (the page used to be left behind on
# every site since June).
_prod_maintenance_off() { # ssh_target wp_root
  local t="$1" root="$2"
  wpsite_ssh "$t" "rm -f '$root/.maintenance' '$root/wp-content/.wpsite-maintenance' '$root/wp-content/mu-plugins/wpsite-maintenance.php' '$root/wp-content/maintenance.php'"
}

# The exact commands to lift maintenance by hand (printed when wpsite can't).
_maintenance_manual_cmd() { # ssh_target wp_root
  printf "ssh %s \"rm -f '%s/.maintenance' '%s/wp-content/.wpsite-maintenance' '%s/wp-content/mu-plugins/wpsite-maintenance.php' '%s/wp-content/maintenance.php'\"" "$1" "$2" "$2" "$2" "$2"
}

# --- Live verification (on EVERY exit of apply) --------------------------------------

# One URL: "<code>\t<verdict>" where verdict ∈ ok|fatal|maintenance|down. With a token,
# looks through our maintenance gate. Follows redirects (http→https, apex→www).
_site_probe() { # url [bypass_token]
  local url="$1" token="${2:-}" body code verdict
  body="$(mktemp)"
  local args=(-sS -L --max-redirs 5 --max-time 30 -o "$body" -w '%{http_code}')
  [ -n "$token" ] && args+=(-H "X-Wpsite-Bypass: $token")
  code="$(curl "${args[@]}" "$url" 2>/dev/null || true)"
  code="${code:-000}"
  if grep -q "$WPSITE_MAINT_MARKER" "$body" 2>/dev/null || [ "$code" = 503 ]; then verdict=maintenance
  elif grep -qiE 'Fatal error|Parse error|critical error on (this|your) website|kritischer Fehler' "$body" 2>/dev/null; then verdict=fatal
  elif [ "$code" = 200 ]; then verdict=ok
  else verdict=down
  fi
  rm -f "$body"
  printf '%s\t%s\n' "$code" "$verdict"
  return 0
}

# The URLs the final check looks at: home, login, and a few published pages. Collected
# BEFORE maintenance goes on, while the site is known to be healthy.
_apply_collect_verify_urls() { # ssh_target wp_root outfile
  local t="$1" root="$2" out="$3" home
  home="$(_prod_wp "$t" "$root" option get home 2>/dev/null | tr -d '\r' || true)"
  : > "$out"
  [ -n "$home" ] || return 0
  printf '%s\n%s/wp-login.php\n' "$home" "${home%/}" > "$out"
  _prod_wp "$t" "$root" post list --post_type=page --post_status=publish --field=url \
    --posts_per_page=4 2>/dev/null | tr -d '\r' | grep -E '^https?://' | grep -vxF "$home" >> "$out" || true
  return 0
}

# Probe every collected URL; writes "<verdict>\t<code>\t<url>" lines, returns 0 iff all ok.
_apply_probe_all() { # urls_file outfile [bypass_token]
  local urls="$1" out="$2" token="${3:-}" u r bad=0
  : > "$out"
  [ -s "$urls" ] || { printf 'down\t000\t(no URLs — home unknown)\n' > "$out"; return 1; }
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    r="$(_site_probe "$u" "$token")"
    printf '%s\t%s\t%s\n' "$(printf '%s' "$r" | cut -f2)" "$(printf '%s' "$r" | cut -f1)" "$u" >> "$out"
    [ "$(printf '%s' "$r" | cut -f2)" = ok ] || bad=1
  done < "$urls"
  [ "$bad" = 0 ]
}

# Test mail through the site's REAL mailer (wp_mail → its SMTP plugin), always to OUR
# inbox (settings.test_mail_to), never the customer's admin_email.
WPSITE_TEST_MAIL_DEFAULT="admin@artismedia.de"
_apply_test_mail() { # ssh_target wp_root client
  local t="$1" root="$2" client="$3" to
  to="$(wsetting_get test_mail_to)"; to="${to:-$WPSITE_TEST_MAIL_DEFAULT}"
  _APPLY_MAIL_TO="$to"
  # The PHP runs on the SERVER, so values are embedded — only after validating that they
  # can't break out of a single-quoted PHP string (client IDs are DNS labels anyway).
  [[ "$to" =~ ^[^@\'\"\\[:space:]]+@[^@\'\"\\[:space:]]+$ ]] || { log_warn "  settings.test_mail_to is not a plain address: $to"; return 1; }
  _valid_site_name "$client" || return 1
  _prod_wp "$t" "$root" eval "\$ok = wp_mail('$to', '[wpsite] Mail-Test nach Wartung: $client', 'Automatischer Test von wpsite nach dem Wartungslauf auf ' . home_url() . '. Wenn diese Mail ankommt, versendet die Website E-Mails (Double-Opt-in, Formular-Antworten, ...).'); exit(\$ok ? 0 : 1);" >/dev/null 2>&1 < /dev/null
}

# Capture name,version,update for plugins+themes from prod into the given dir.
_prod_versions() { # ssh_target wp_root dir suffix
  local t="$1" root="$2" dir="$3" sfx="$4"
  _prod_wp "$t" "$root" plugin list --fields="$WPSITE_PLUGIN_FIELDS" --format=csv 2>/dev/null | tr -d '\r' > "$dir/plugins.$sfx.csv"
  _prod_wp "$t" "$root" theme  list --fields=name,version,update --format=csv 2>/dev/null | tr -d '\r' > "$dir/themes.$sfx.csv"
}

# --- Preflight gate (HARDENING-PLAN.md Phase 3) ---------------------------------------
# Runs BEFORE the backup and the typed confirmation. Everything that could otherwise only
# fail once maintenance is on is checked here; any hard failure aborts with production
# untouched. Read-only except for creating + deleting one probe file per directory.
# `wpsite apply <c> --check` runs only this (e.g. across all clients before a round).
_PF_FAIL=0
_pf_ok()   { log_ok   "  $*"; }
_pf_info() { log_info "  $*"; }
_pf_fail() { log_error "  $*"; _PF_FAIL=1; }

# Minimum free space (KB) on the WordPress filesystem for downloading + unpacking updates.
WPSITE_PF_MIN_FREE_KB="${WPSITE_PF_MIN_FREE_KB:-204800}"

_apply_preflight() { # client ssh_target wp_root
  local client="$1" t="$2" root="$3" out line
  _PF_FAIL=0
  log_info "Preflight for '$client' ($t:$root) — nothing is changed yet"

  # SSH + wp-cli + boot with every plugin.
  if wpsite_ssh "$t" "echo WPSITE_SSH_OK" </dev/null 2>/dev/null | grep -q WPSITE_SSH_OK; then _pf_ok "SSH works"
  else _pf_fail "SSH to $t fails"; return 1; fi
  [ "${_WPSITE_WP_BUNDLED:-0}" = 1 ] && _pf_info "using wpsite's bundled wp-cli (the host's wp is unusable)"
  if _prod_wp "$t" "$root" core is-installed </dev/null >/dev/null 2>&1 && _site_boots _prod_wp "$t" "$root"; then
    _pf_ok "WP-CLI works and WordPress boots with all plugins"
  else
    _pf_fail "WP-CLI can't boot WordPress on production (see: wpsite test $client)"; return 1
  fi

  # The site must be healthy NOW — otherwise we couldn't tell later whether the updates
  # broke it or it was broken before.
  local home probe
  home="$(_prod_wp "$t" "$root" option get home </dev/null 2>/dev/null | tr -d '\r' || true)"
  if [ -z "$home" ]; then _pf_fail "could not read the site's home URL"
  else
    probe="$(_site_probe "$home")"
    case "$(printf '%s' "$probe" | cut -f2)" in
      ok) _pf_ok "site is live: $home (HTTP $(printf '%s' "$probe" | cut -f1))" ;;
      *)  _pf_fail "site is NOT healthy right now: $home → HTTP $(printf '%s' "$probe" | cut -f1), $(printf '%s' "$probe" | cut -f2) — fix it first" ;;
    esac
  fi

  # Writable: every directory an update (and our maintenance gate) writes to.
  out="$(wpsite_ssh "$t" "cd '$root' || { echo 'NOROOT'; exit 0; }
    for d in . wp-content wp-content/plugins wp-content/themes wp-content/upgrade wp-content/languages wp-content/mu-plugins; do
      if [ -d \"\$d\" ]; then p=\"\$d\"; note=''; else p=\$(dirname \"\$d\"); note=' (absent; parent must allow creating it)'; fi
      f=\"\$p/.wpsite-probe-\$\$\"
      if ( : > \"\$f\" ) 2>/dev/null && rm -f \"\$f\"; then echo \"OK \$d\$note\"; else echo \"FAIL \$d\$note\"; fi
    done
    df -Pk . 2>/dev/null | awk 'NR==2 {print \"FREE \" \$4}'" </dev/null 2>/dev/null || true)"
  if [ -z "$out" ] || printf '%s\n' "$out" | grep -q '^NOROOT'; then
    _pf_fail "could not check write access in $root"
  else
    local bad; bad="$(printf '%s\n' "$out" | grep '^FAIL' | sed 's/^FAIL //' | tr '\n' ',' | sed 's/,$//; s/,/, /g' || true)"
    if [ -n "$bad" ]; then _pf_fail "not writable: $bad"; else _pf_ok "write access: WP root, wp-content, plugins, themes, upgrade, languages, mu-plugins"; fi
    local free; free="$(printf '%s\n' "$out" | awk '/^FREE / {print $2}' || true)"
    if [ -z "$free" ]; then _pf_info "free space on the WordPress filesystem unknown (df unavailable)"
    elif [ "$free" -lt "$WPSITE_PF_MIN_FREE_KB" ]; then _pf_fail "only $((free / 1024)) MB free on the WordPress filesystem (need ≥ $((WPSITE_PF_MIN_FREE_KB / 1024)) MB)"
    else _pf_ok "free space: $((free / 1024)) MB"; fi
  fi

  # The server must be able to download updates (from PHP, as the updater does).
  # shellcheck disable=SC2016  # PHP source
  line="$(_prod_wp "$t" "$root" eval '$r = wp_remote_head("https://downloads.wordpress.org/", array("timeout" => 15)); echo is_wp_error($r) ? "ERR " . $r->get_error_message() : "HTTP " . wp_remote_retrieve_response_code($r);' </dev/null 2>/dev/null | tr -d '\r' | grep -E '^(HTTP|ERR) ' | head -1 || true)"
  case "$line" in
    HTTP*) _pf_ok "server can reach downloads.wordpress.org (${line})" ;;
    ERR*)  _pf_fail "server can NOT download updates: ${line#ERR }" ;;
    *)     _pf_fail "could not check whether the server can download updates" ;;
  esac

  # Backup staging dir (the fresh backup runs first).
  local stage need=""
  stage="$(_remote_staging_base "$client" "$t")"
  local latest; latest="$(latest_backup_dir "$client" 2>/dev/null || true)"
  [ -n "$latest" ] && need="$(du -sk "$latest" 2>/dev/null | cut -f1 || true)"
  out="$(wpsite_ssh "$t" "mkdir -p '$stage' 2>/dev/null; f='$stage/.wpsite-probe-'\$\$; if ( : > \"\$f\" ) 2>/dev/null && rm -f \"\$f\"; then echo OK; else echo FAIL; fi; df -Pk '$stage' 2>/dev/null | awk 'NR==2 {print \"FREE \" \$4}'" </dev/null 2>/dev/null || true)"
  if ! printf '%s\n' "$out" | grep -qx OK; then
    _pf_fail "backup staging dir not writable: $stage (set remote_tmp for $client in wpsite's registry)"
  else
    local sfree; sfree="$(printf '%s\n' "$out" | awk '/^FREE / {print $2}' || true)"
    if [ -n "$sfree" ] && [ -n "$need" ] && [ "$sfree" -lt $((need * 12 / 10)) ]; then
      _pf_fail "backup staging dir $stage has $((sfree / 1024)) MB free, the last backup was $((need / 1024)) MB"
    else
      _pf_ok "backup staging dir: $stage${sfree:+ ($((sfree / 1024)) MB free)}"
    fi
  fi

  # --- Shown, never blocking ---
  _apply_preflight_plan "$client" "$t" "$root"
  local mailers to
  mailers="$(_prod_wp "$t" "$root" plugin list --status=active --field=name </dev/null 2>/dev/null | tr -d '\r' \
    | grep -iE 'smtp|mail|wpo365|sendgrid|mailgun|postmark' | tr '\n' ' ' | sed 's/ *$//' || true)"
  to="$(wsetting_get test_mail_to)"; to="${to:-$WPSITE_TEST_MAIL_DEFAULT}"
  _pf_info "mail: ${mailers:-no SMTP/mail plugin active (PHP mail())} — test mail goes to $to"

  if [ "$_PF_FAIL" = 1 ]; then log_error "Preflight FAILED — production untouched."; return 1; fi
  log_ok "Preflight passed."
  return 0
}

# What the update run will do, per plugin with an update — before anything runs.
_apply_preflight_plan() { # client ssh_target wp_root
  local t="$2" root="$3" csv name ver upd newv pkg skip n=0
  csv="$(_prod_wp "$t" "$root" plugin list --fields=name,version,update,update_version,update_package --format=csv </dev/null 2>/dev/null | tr -d '\r' || true)"
  _pf_info "update plan (plugins with an update available):"
  while IFS=, read -r name ver upd newv pkg; do
    [ "$upd" = available ] || continue
    name="${name//\"/}"; n=$((n + 1))
    skip="$(_update_skip_reason plugin "$name")"
    if [ -n "$skip" ]; then _pf_info "    - $name $ver — skipped ($skip)"
    elif [ -z "$pkg" ]; then _pf_info "    ! $name $ver → $newv — NO download package (licence/pro?) — won't update"
    else _pf_info "    ✓ $name $ver → $newv"; fi
  done < <(printf '%s\n' "$csv" | tail -n +2)
  [ "$n" -gt 0 ] || _pf_info "    (none — core/themes may still have updates)"
  return 0
}

# --- The critical-section guard ---------------------------------------------------------
# From the typed confirmation on, apply keeps its state in _AP_* globals and arms
# EXIT/INT/TERM traps. On ANY exit — normal end, error, Ctrl-C, a silent `set -e` abort
# (the stub repro that left maintenance ON after one failing `plugin list`) — the same
# _apply_finish runs exactly once: decide the end state, verify the live site, send the
# test mail, write whatever reports exist, and say clearly what happened.
_AP_FINISHED=0; _AP_MAINT=0; _AP_UPDATES_DONE=0; _AP_OK=1; _AP_RC=1
_AP_CLIENT=""; _AP_T=""; _AP_ROOT=""; _AP_DIR=""; _AP_STAMP=""; _AP_BACKUP=""; _AP_CORE_BEFORE=""

_apply_step_hook() { _prod_maintenance_refresh "$_AP_T" "$_AP_ROOT" >/dev/null 2>&1 || true; }

_apply_exit_trap() {
  local rc=$?
  if [ "$_AP_FINISHED" != 1 ]; then
    [ "$rc" = 0 ] && rc=1
    _apply_finish abort || true
  fi
  _backup_cleanup
  trap - EXIT INT TERM
  exit "$rc"
}
_apply_signal_trap() {
  log_error "Interrupted — finishing safely (maintenance, verification, report)..."
  _apply_finish abort || true
  _backup_cleanup
  trap - EXIT INT TERM
  exit 130
}

_apply_arm() { # client ssh_target wp_root
  _AP_CLIENT="$1"; _AP_T="$2"; _AP_ROOT="$3"
  _AP_FINISHED=0; _AP_MAINT=0; _AP_UPDATES_DONE=0; _AP_OK=1; _AP_RC=1
  _AP_DIR=""; _AP_STAMP=""; _AP_BACKUP=""; _AP_CORE_BEFORE=""
  trap _apply_exit_trap EXIT
  trap _apply_signal_trap INT TERM
}

# Runs exactly once per apply (normal path and every abort path). Never uses `set -e`.
# Sets _AP_RC: 0 only when the site is live, every check passed and the updates were ok.
_apply_finish() { # normal|abort
  local mode="$1"
  [ "$_AP_FINISHED" = 1 ] && return "$_AP_RC"
  _AP_FINISHED=1
  set +e
  _WPSITE_STEP_HOOK=""
  local t="$_AP_T" root="$_AP_ROOT" dir="$_AP_DIR" state="untouched" live="skipped" mail="skipped" boots=0
  local urls=""; [ -n "$dir" ] && urls="$dir/verify.urls"

  _site_boots _prod_wp "$t" "$root" && boots=1

  # 1) End state. Only relevant once maintenance was switched on.
  if [ "$_AP_MAINT" = 1 ]; then
    log_info "[4/5] Deciding the end state (maintenance is still ON)..."
    local real_ok=0
    if [ "$boots" = 1 ]; then
      _prod_maintenance_lift_wp "$t" "$root"          # our gate stays up for visitors
      if [ -n "$urls" ] && [ -s "$urls" ]; then
        _apply_probe_all "$urls" "$dir/verify.gate.txt" "$_WPSITE_MAINT_TOKEN" && real_ok=1
      else
        real_ok=1                                     # no URLs to look at: boot check only
      fi
    fi
    if [ "$real_ok" = 1 ]; then
      if _prod_maintenance_off "$t" "$root"; then
        state="live"; log_ok "  Site boots and renders — maintenance OFF."
      else
        state="stuck"
        log_error "  Could not switch maintenance off! Do it by hand NOW:"
        log_error "    $(_maintenance_manual_cmd "$t" "$root")"
      fi
    else
      _prod_maintenance_hold "$t" "$root"
      state="held"
      log_error "  The site does NOT $([ "$boots" = 1 ] && echo "render cleanly" || echo "boot") — maintenance stays ON (permanent) so visitors see a clean 503."
      [ -n "$dir" ] && [ -s "$dir/verify.gate.txt" ] && log_error "  What the site returned: $dir/verify.gate.txt"
      log_error "  Lift it by hand once fixed:  $(_maintenance_manual_cmd "$t" "$root")"
    fi
  fi

  # 2) What does a VISITOR see now? (skipped while we deliberately hold maintenance)
  if [ "$state" != "held" ] && [ -n "$urls" ] && [ -s "$urls" ]; then
    log_info "[5/5] Verifying the live site..."
    if _apply_probe_all "$urls" "$dir/verify.txt"; then live="ok"; else live="problems"; fi
  elif [ "$state" != "held" ] && [ -z "$dir" ]; then
    live="skipped"                                    # stopped before anything was collected
  fi

  # 3) Test mail through the site's real mailer (needs a booting site).
  if [ "$boots" = 1 ]; then
    if _apply_test_mail "$t" "$root" "$_AP_CLIENT"; then mail="sent"; else mail="FAILED"; fi
  else
    mail="skipped (site does not boot)"
  fi

  # 4) Reports from whatever exists.
  if [ -n "$dir" ] && [ -f "$dir/plugins.before.csv" ]; then
    if [ ! -s "$dir/plugins.after.csv" ] && [ "$boots" = 1 ]; then
      _prod_versions "$t" "$root" "$dir" after
    fi
    local core_after; core_after="$(_prod_wp "$t" "$root" core version 2>/dev/null | tr -d '\r')"
    [ -s "$dir/updates.outcome.tsv" ] || _classify_updates "$dir" "$_AP_CLIENT"
    _upgrade_report "$_AP_CLIENT (PRODUCTION)" "$_AP_STAMP" "$_AP_CORE_BEFORE" "$core_after" "$dir" > "$dir/report.txt" 2>/dev/null
    _compare_with_rehearsal "$dir" "$_AP_CLIENT" | tee -a "$dir/report.txt" >&2
    _update_briefing "$dir" "$_AP_CLIENT" 0
    # The customer report only describes a COMPLETED run — never a half-applied one.
    if [ "$_AP_UPDATES_DONE" = 1 ] && [ "$state" = "live" ]; then
      _write_client_report_de "$_AP_CLIENT" "$_AP_STAMP" "$_AP_CORE_BEFORE" "$core_after" "$dir" domain
    fi
  fi

  # 5) Summary — the last thing printed, and part of the report.
  local end_txt live_txt
  case "$state" in
    live)      end_txt="live (maintenance off)" ;;
    held)      end_txt="MAINTENANCE KEPT ON — the site does not work (clean 503 for visitors)" ;;
    stuck)     end_txt="MAINTENANCE STILL ON — could not be switched off (see command above)" ;;
    untouched) end_txt="production not modified (stopped before maintenance mode)" ;;
  esac
  case "$live" in
    ok)       live_txt="all $(grep -c . "$urls" 2>/dev/null || echo 0) page(s) OK" ;;
    problems) live_txt="PROBLEMS — $(grep -vc '^ok' "$dir/verify.txt" 2>/dev/null || echo '?') page(s) not OK (see verify.txt)" ;;
    *)        live_txt="$live" ;;
  esac
  local summary
  summary="$(printf '\nFinal check (%s):\n  End state:   %s\n  Live check:  %s\n  Test mail:   %s%s\n  Updates:     %s\n  Rollback:    %s\n' \
    "$([ "$mode" = normal ] && echo "run completed" || echo "APPLY INCOMPLETE — aborted")" \
    "$end_txt" "$live_txt" "$mail" "$([ -n "${_APPLY_MAIL_TO:-}" ] && [ "$mail" != skipped ] && echo " → $_APPLY_MAIL_TO")" \
    "$([ "$_AP_UPDATES_DONE" = 1 ] && { [ "$_AP_OK" = 1 ] && echo ok || echo "with problems (see update.log)"; } || echo "not completed")" \
    "${_AP_BACKUP:-(none taken)}")"
  printf '%s\n' "$summary" >&2
  [ -n "$dir" ] && printf '%s\n' "$summary" >> "$dir/report.txt"
  [ -n "$dir" ] && log_info "Report: $dir/report.txt   WP-CLI log: $dir/update.log"

  if [ "$mode" = normal ] && [ "$state" = live ] && [ "$live" = ok ] && [ "$mail" = sent ] && [ "$_AP_OK" = 1 ]; then
    log_ok "Production upgraded and verified."
    _AP_RC=0
  else
    [ "$mode" = abort ] && log_error "APPLY INCOMPLETE — see the final check above."
    [ "$mode" = normal ] && log_error "Production apply finished WITH PROBLEMS — see the final check above."
    [ -s "$dir/plugins.reconcile.txt" ] && log_error "Plugin activation problems: $dir/plugins.reconcile.txt"
    [ -n "$_AP_BACKUP" ] && log_error "Manual rollback: restore $_AP_BACKUP (db.sql + prior versions from plugins.before.csv)."
    _AP_RC=1
  fi
  return "$_AP_RC"
}

cmd_apply() {
  local client="" check_only=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) check_only=1; shift ;;
      -*) die "Unknown flag: $1 (usage: wpsite apply <client> [--check])" ;;
      *) [ -z "$client" ] || die "Unexpected argument: $1"; client="$1"; shift ;;
    esac
  done
  config_require_registry
  require_client "$client"
  require_access "$client"

  local ssh_target wp_root
  ssh_target="$(client_get "$client" ssh)"
  wp_root="$(client_get "$client" wp_root)"
  [ -n "$ssh_target" ] && [ -n "$wp_root" ] || die "No ssh / wp_root for '$client' in mandos."

  # Soft rehearsal check — did they run the local upgrade first?
  if [ -z "$(_latest_upgrade_dir "$client")" ]; then
    log_warn "No local upgrade rehearsal found for $client."
    log_warn "Strongly recommended first: wpsite upgrade $client"
  fi

  ssh_setup_mux
  trap _backup_cleanup EXIT
  _remote_wp_prepare "$client"

  _WPSITE_RUN_CLIENT="$client"          # its hold list applies (preflight plan + updates)

  # Preflight: everything checked BEFORE the backup, the confirmation, anything.
  if ! _apply_preflight "$client" "$ssh_target" "$wp_root"; then
    die "Not applying to '$client' — fix the preflight failures above first."
  fi
  if [ "$check_only" = 1 ]; then
    ssh_close_mux; trap - EXIT
    return 0
  fi

  # Hard confirmation: type the client name. No --yes bypass.
  log_warn "This UPGRADES PRODUCTION for '$client' ($ssh_target:$wp_root)."
  log_warn "It is irreversible. A fresh backup will be taken as a rollback point."
  _confirm_prod "$client" || die "Aborted (confirmation did not match)."

  # From here on, every exit goes through _apply_finish.
  _apply_arm "$client" "$ssh_target" "$wp_root"

  # 1) Fresh backup = rollback point. No backup -> we do not touch production.
  log_info "[1/5] Fresh production backup (rollback point)..."
  _backup_one_client "$client" "0" \
    || die "Backup failed — refusing to upgrade production without a rollback point."
  # shellcheck disable=SC2012  # timestamp dirs; mtime sort via ls is fine
  _AP_BACKUP="$(ls -td "$(client_backup_dir "$client")"/*/ 2>/dev/null | head -1 || true)"
  _AP_BACKUP="${_AP_BACKUP%/}"

  _AP_STAMP="$(date +%Y%m%d_%H%M%S)"
  _AP_DIR="$(client_base "$client")/applies/$_AP_STAMP"
  local dir="$_AP_DIR"
  mkdir -p "$dir"
  _AP_CORE_BEFORE="$(_prod_wp "$ssh_target" "$wp_root" core version 2>/dev/null | tr -d '\r' || true)"
  # Fresh update data first, so the before-snapshot (and thus the plan) isn't stale.
  _refresh_update_cache "$dir/update.log" _prod_wp "$ssh_target" "$wp_root"
  _prod_versions "$ssh_target" "$wp_root" "$dir" before
  _apply_collect_verify_urls "$ssh_target" "$wp_root" "$dir/verify.urls"

  # Multisite networks migrate every subsite's DB → need --network on update-db.
  local is_ms=0
  if [ "$(_prod_wp "$ssh_target" "$wp_root" eval 'echo is_multisite() ? 1 : 0;' 2>/dev/null | tr -d '[:space:]' || true)" = "1" ]; then
    is_ms=1
    log_warn "Multisite network detected — update-db will run --network across all subsites."
    log_warn "Note: the local rehearsal does not yet cover multisite — verify subsites by hand."
  fi

  # 2) Maintenance mode on — and refuse to update production unprotected.
  log_info "[2/5] Maintenance mode ON..."
  _WPSITE_MAINT_TOKEN="$(_maintenance_token)"
  # Mark maintenance as (possibly) on BEFORE switching it on: a half-successful "on" (page
  # uploaded, gate or lock failed) must be cleaned up by _apply_finish like any other exit —
  # the fault-injection harness caught exactly that leaving files behind.
  _AP_MAINT=1
  _prod_maintenance_on "$ssh_target" "$wp_root" "$_WPSITE_MAINT_TOKEN" \
    || die "Could not enable maintenance mode — refusing to update production unprotected."
  _WPSITE_STEP_HOOK=_apply_step_hook

  # 3) The critical section: no `set -e` here — every step is checked explicitly and the
  # run always proceeds to _apply_finish (the traps are only the safety net).
  set +e
  log_info "[3/5] Updating core/plugins/themes on PRODUCTION..."
  _run_updates "$dir" "$is_ms" _prod_wp "$ssh_target" "$wp_root" || _AP_OK=0
  _prod_wp "$ssh_target" "$wp_root" cache flush >/dev/null 2>&1
  _apply_step_hook

  # Restore plugins the update knocked out, while the site is still behind the gate —
  # a reactivation that fatals must not be visible to visitors.
  _prod_versions "$ssh_target" "$wp_root" "$dir" after
  _report_missed_updates "$dir"
  _classify_updates "$dir" "$client"
  _reconcile_active_plugins "$dir/plugins.before.csv" "$dir/plugins.after.csv" \
    "$dir/update.log" "$dir/plugins.reconcile.txt" _prod_wp "$ssh_target" "$wp_root" || _AP_OK=0
  _AP_UPDATES_DONE=1

  _apply_finish normal
  local rc=$?
  set -e
  ssh_close_mux
  trap - EXIT INT TERM
  return "$rc"
}
