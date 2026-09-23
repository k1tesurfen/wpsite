#!/usr/bin/env bats
# `wpsite apply` (production) orchestration. EVERYTHING that touches a server/network
# is stubbed — no SSH, no production. Verifies guards + step sequencing only.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  export WPSITE_CONFIG="$REPO/test/fixtures/wpsite.yml"   # acme: ssh/wp_root set
  export MANDOS_BIN="$BATS_TEST_DIRNAME/fixtures/mandos-stub"   # client registry via stub
  export WPSITE_TEAM_CONFIG="${MANDOS_STUB_CONFIG:-$WPSITE_CONFIG}"   # wpsite registry = same fixture
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_backup.sh"
  source "$REPO/lib/cmd_upgrade.sh"
  source "$REPO/lib/cmd_apply.sh"
  # neutralise infra
  require()          { :; }
  ssh_setup_mux()    { :; }
  ssh_close_mux()    { :; }
  _backup_cleanup()  { :; }
  _latest_upgrade_dir() { printf '/tmp/rehearsed'; }   # pretend a rehearsal exists
  curl()             { echo 200; }                     # verify OK by default
  _confirm_prod()    { return 0; }                     # confirmed by default
  _prod_maintenance_on()  { echo "maintenance ON" >> "$CALLS"; }
  _prod_maintenance_off() { echo "maintenance OFF" >> "$CALLS"; }
  _prod_maintenance_refresh() { echo "maintenance REFRESH" >> "$CALLS"; }
  _prod_maintenance_hold()    { echo "maintenance HOLD" >> "$CALLS"; }
  _prod_maintenance_lift_wp() { echo "maintenance LIFT_WP" >> "$CALLS"; }
  _remote_wp_prepare() { :; }
  _apply_preflight() { echo "PREFLIGHT" >> "$CALLS"; return 0; }   # own tests: preflight.bats
  # Safety net: nothing in these tests may ever reach a real server.
  wpsite_ssh() { printf 'SSH %s\n' "$*" >> "$CALLS"; return 0; }
  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  # default prod wp stub: record commands, answer the read-only ones
  _prod_wp() {
    shift 2; printf '%s\n' "$*" >> "$CALLS"
    case "$*" in
      *"core version"*)   echo "6.5" ;;
      *"option get home"*) echo "https://acme.example" ;;
      *"option get admin_email"*) echo "admin@example.com" ;;
      *"plugin list"*field=name*) echo "akismet" ;;
      *"theme list"*field=name*)  echo "twentytwentyfour" ;;
      *WPSITE_BOOT_OK*)   echo "WPSITE_BOOT_OK" ;;
      *"post list"*)      echo "https://acme.example/kontakt/" ;;
      *list*)             echo "name,version,update" ;;
    esac
  }
}

# Note: bats never captures what an EXIT trap prints to stderr (plain bash does), so the
# ABORT path is asserted through its effects (CALLS, exit status) and the summary text is
# asserted on _apply_finish directly.
apply_run() { cmd_apply "$@"; }

@test "apply: aborts and runs NOTHING when confirmation fails" {
  _confirm_prod() { return 1; }
  _backup_one_client() { echo BACKUP_RAN >> "$CALLS"; return 0; }
  run apply_run acme
  [ "$status" -ne 0 ]
  [[ "$output" == *"Aborted"* ]]
  ! grep -q BACKUP_RAN "$CALLS"
}

@test "apply: a failed preflight stops BEFORE the confirmation and the backup" {
  _apply_preflight() { echo "PREFLIGHT" >> "$CALLS"; return 1; }
  _confirm_prod() { echo CONFIRM_ASKED >> "$CALLS"; return 0; }
  _backup_one_client() { echo BACKUP_RAN >> "$CALLS"; return 0; }
  run apply_run acme
  [ "$status" -ne 0 ]; [[ "$output" == *"fix the preflight failures"* ]]
  ! grep -q CONFIRM_ASKED "$CALLS"; ! grep -q BACKUP_RAN "$CALLS"
}

@test "apply --check: runs only the preflight" {
  _confirm_prod() { echo CONFIRM_ASKED >> "$CALLS"; return 0; }
  run apply_run acme --check
  [ "$status" -eq 0 ]
  grep -q PREFLIGHT "$CALLS"; ! grep -q CONFIRM_ASKED "$CALLS"
}

@test "apply: refuses to upgrade if the fresh backup fails" {
  _backup_one_client() { return 1; }
  run apply_run acme
  [ "$status" -ne 0 ]
  [[ "$output" == *"without a rollback point"* ]]
  ! grep -q 'core update' "$CALLS"   # never reached the upgrade
}

@test "apply: happy path runs the full prod sequence + verifies 200" {
  _backup_one_client() { return 0; }
  run apply_run acme
  [ "$status" -eq 0 ]
  grep -q 'maintenance ON'            "$CALLS"
  grep -q 'core update'               "$CALLS"
  grep -q 'core update-db'            "$CALLS"
  grep -q 'plugin update akismet'     "$CALLS"
  grep -q 'theme update twentytwentyfour' "$CALLS"
  grep -q 'maintenance OFF'           "$CALLS"
  grep -q 'eval.*wp_mail'             "$CALLS"
  [[ "$output" == *"Production upgraded"* ]]
}

@test "apply: single-site uses plain update-db" {
  _backup_one_client() { return 0; }   # _prod_wp default: is_multisite -> "" -> not multisite
  run apply_run acme
  [ "$status" -eq 0 ]
  grep -qx 'core update-db' "$CALLS"
  ! grep -q 'core update-db --network' "$CALLS"
}

@test "apply: multisite uses update-db --network + warns" {
  _backup_one_client() { return 0; }
  _prod_wp() {
    shift 2; printf '%s\n' "$*" >> "$CALLS"
    case "$*" in
      *is_multisite*)      echo 1 ;;
      *WPSITE_BOOT_OK*)    echo WPSITE_BOOT_OK ;;
      *"site list"*"--field=url"*)  printf 'https://acme.example/\nhttps://shop.example.de/\n' ;;
      *"core version"*)    echo 6.5 ;;
      *"option get home"*) echo "https://acme.example" ;;
      *list*)              echo "name,version,update" ;;
    esac
  }
  run apply_run acme
  [ "$status" -eq 0 ]
  grep -q 'core update-db --network' "$CALLS"
  [[ "$output" == *"Multisite network: 2 site(s)"* ]]
  [[ "$output" != *"does not yet cover multisite"* ]]   # the outdated warning is gone
}

@test "apply: site renders broken through the gate at the end -> maintenance KEPT ON (hold)" {
  _backup_one_client() { return 0; }
  curl() { echo 502; }
  run apply_run acme
  [ "$status" -ne 0 ]
  grep -q 'maintenance HOLD' "$CALLS"            # clean 503 instead of a broken site
  ! grep -q 'maintenance OFF' "$CALLS"
  [[ "$output" == *"MAINTENANCE KEPT ON"* ]]
}

@test "apply: site does not boot at the end -> hold, no mail attempt, loud" {
  _backup_one_client() { return 0; }
  local inner; inner="$(declare -f _prod_wp)"
  eval "_prod_wp() {
    case \"\$*\" in *WPSITE_BOOT_OK*) printf '%s\n' \"\$*\" >> \"\$CALLS\"; return 1 ;; esac
    ${inner#*\{}"
  run apply_run acme
  [ "$status" -ne 0 ]
  grep -q 'maintenance HOLD' "$CALLS"
  ! grep -q 'wp_mail' "$CALLS"
  [[ "$output" == *"skipped (site does not boot)"* ]]
}

@test "apply: lifts only after looking at the REAL site through the gate (bypass token)" {
  _backup_one_client() { return 0; }
  curl() { printf '%s\n' "curl $*" >> "$CALLS"; echo 200; }
  run apply_run acme
  [ "$status" -eq 0 ]
  local lift gate off
  lift="$(grep -n 'maintenance LIFT_WP' "$CALLS" | head -1 | cut -d: -f1)"
  gate="$(grep -n 'X-Wpsite-Bypass' "$CALLS" | head -1 | cut -d: -f1)"
  off="$(grep -n 'maintenance OFF' "$CALLS" | cut -d: -f1)"
  [ "$lift" -lt "$gate" ]; [ "$gate" -lt "$off" ]
}

@test "apply: the maintenance locks are re-armed after update steps (WP deletes .maintenance)" {
  _backup_one_client() { return 0; }
  run apply_run acme
  [ "$status" -eq 0 ]
  [ "$(grep -c 'maintenance REFRESH' "$CALLS")" -ge 3 ]
}

@test "apply: the test mail goes to OUR inbox, never the customer's admin_email" {
  _backup_one_client() { return 0; }
  run apply_run acme
  grep -q "wp_mail('admin@artismedia.de'" "$CALLS"
  ! grep -q 'option get admin_email' "$CALLS"
  [[ "$output" == *"Test mail:   sent"* ]]
}

@test "apply: a failed test mail makes the run non-zero (forms/double opt-in would be down)" {
  _backup_one_client() { return 0; }
  local inner; inner="$(declare -f _prod_wp)"
  eval "_prod_wp() {
    case \"\$*\" in *wp_mail*) printf '%s\n' \"\$*\" >> \"\$CALLS\"; return 1 ;; esac
    ${inner#*\{}"
  run apply_run acme
  [ "$status" -ne 0 ]
  [[ "$output" == *"Test mail:   FAILED"* ]]
}

@test "apply: a failed backup still verifies live + sends the mail, and touches nothing" {
  _backup_one_client() { return 1; }
  run apply_run acme
  [ "$status" -ne 0 ]
  ! grep -q 'maintenance ON' "$CALLS"
  grep -q 'wp_mail' "$CALLS"
}

@test "_apply_finish abort before maintenance: says so, never claims success" {
  _prod_wp() { shift 2; printf '%s\n' "$*" >> "$CALLS"; case "$*" in *WPSITE_BOOT_OK*) echo WPSITE_BOOT_OK ;; esac; }
  _AP_CLIENT=acme; _AP_T=u@h; _AP_ROOT=/r; _AP_FINISHED=0; _AP_MAINT=0; _AP_DIR=""
  run _apply_finish abort
  [ "$status" -ne 0 ]
  [[ "$output" == *"APPLY INCOMPLETE"* ]]
  [[ "$output" == *"production not modified"* ]]
  [[ "$output" == *"Test mail:   sent"* ]]
  ! grep -q 'maintenance' "$CALLS"
}

@test "_apply_finish runs only once (trap + normal path can't double-lift or double-mail)" {
  _prod_wp() { shift 2; printf '%s\n' "$*" >> "$CALLS"; case "$*" in *WPSITE_BOOT_OK*) echo WPSITE_BOOT_OK ;; esac; }
  _AP_CLIENT=acme; _AP_T=u@h; _AP_ROOT=/r; _AP_FINISHED=0; _AP_MAINT=1; _AP_DIR=""
  _apply_finish normal 2>/dev/null || true
  _apply_finish abort 2>/dev/null || true
  [ "$(grep -c 'maintenance OFF' "$CALLS")" -eq 1 ]
  [ "$(grep -c 'wp_mail' "$CALLS")" -eq 1 ]
}

# --- Active-plugin reconciliation on production ------------------------------
# Regression cover: on maute-areal, wp-mail-smtp updated fine but ended up INACTIVE,
# and apply neither noticed nor recorded it (no `status` field, output → /dev/null).

# Stateful prod stub: the first plugin-list snapshot reports the plugin active,
# every later one reports it inactive — i.e. the update knocked it out.
_stub_prod_drops_plugin() {
  PHASE="$BATS_TEST_TMPDIR/phase"; echo 0 > "$PHASE"
  _prod_wp() {
    shift 2; printf '%s\n' "$*" >> "$CALLS"
    case "$*" in
      *"core version"*)           echo "6.5" ;;
      *WPSITE_BOOT_OK*)           echo "WPSITE_BOOT_OK" ;;
      *"option get home"*)        echo "https://acme.example" ;;
      *"option get admin_email"*) echo "admin@example.com" ;;
      *"plugin list"*field=name*) echo "wp-mail-smtp" ;;
      *"theme list"*field=name*)  : ;;
      *"plugin list"*fields=*)
        local n; n="$(cat "$PHASE")"; echo $((n + 1)) > "$PHASE"
        if [ "$n" = 0 ]; then
          printf 'name,version,update,status\nwp-mail-smtp,4.8.0,available,active\n'
        else
          printf 'name,version,update,status\nwp-mail-smtp,4.9.0,none,inactive\n'
        fi ;;
      *list*)                     echo "name,version,update" ;;
    esac
  }
}

@test "apply: a plugin knocked out by the update is reactivated" {
  _backup_one_client() { return 0; }
  _stub_prod_drops_plugin
  run apply_run acme
  [ "$status" -eq 0 ]
  grep -q 'plugin update wp-mail-smtp'   "$CALLS"
  grep -q 'plugin activate wp-mail-smtp' "$CALLS"
  [[ "$output" == *"went INACTIVE"* ]]
  [[ "$output" == *"reactivated"* ]]
}

@test "apply: the reactivation happens BEFORE the maintenance page comes down" {
  _backup_one_client() { return 0; }
  _stub_prod_drops_plugin
  run apply_run acme
  [ "$status" -eq 0 ]
  local act off
  act="$(grep -n 'plugin activate wp-mail-smtp' "$CALLS" | head -1 | cut -d: -f1)"
  off="$(grep -n 'maintenance OFF'              "$CALLS" | head -1 | cut -d: -f1)"
  [ -n "$act" ] && [ -n "$off" ]
  [ "$act" -lt "$off" ]   # a reactivation that fatals must not be visible to visitors
}

@test "apply: a plugin that fatals on boot is left off, reported, and fails the run" {
  _backup_one_client() { return 0; }
  _stub_prod_drops_plugin
  # The baseline boot check must PASS (the site was healthy); only the check after
  # the reactivation fatals — otherwise this would test the unverified path instead.
  # Boot checks, in order: reconcile baseline (1, OK), right after reactivating the plugin
  # (2, FATAL — reconcile then deactivates it again), apply's end-state check (3+, OK).
  local inner; inner="$(declare -f _prod_wp)"
  eval "_prod_wp() {
    case \"\$*\" in *WPSITE_BOOT_OK*)
      printf '%s\n' \"\$*\" >> \"\$CALLS\"
      local n; n=\$(( \$(cat \"\$BATS_TEST_TMPDIR/boots\" 2>/dev/null || echo 0) + 1 ))
      echo \"\$n\" > \"\$BATS_TEST_TMPDIR/boots\"
      [ \"\$n\" = 2 ] && return 1
      echo WPSITE_BOOT_OK; return 0 ;;
    esac
    ${inner#*\{}"
  run apply_run acme
  [ "$status" -ne 0 ]
  grep -q 'plugin deactivate wp-mail-smtp --skip-plugins' "$CALLS"
  [[ "$output" == *"fatals on load"* ]]
  grep -q 'maintenance OFF' "$CALLS"     # site boots again after the re-deactivation → lifted
}

# --- The final check compares with a BASELINE taken before maintenance went on ----------
# buymysite: WordPress redirects wp-login.php to /404 on purpose (hidden login). The old
# check counted that 404 as "site broken" and kept a perfectly working site behind the 503.

# curl stub: <url-glob>=<code> rules for BEFORE and AFTER maintenance went on (the phase
# comes from the CALLS log). Default 200.
_curl_phases() { # before_rules after_rules
  CURL_BEFORE="$1"; CURL_AFTER="$2"
  curl() {
    local url="${!#}" rules="$CURL_BEFORE" r pat
    grep -q 'maintenance ON' "$CALLS" && rules="$CURL_AFTER"
    for r in $rules; do pat="${r%=*}"; case "$url" in $pat) printf '%s' "${r##*=}"; return 0 ;; esac; done
    printf 200
  }
}

@test "apply: a page that was ALREADY not ok before (hidden login) is not a failure" {
  _backup_one_client() { return 0; }
  _curl_phases '*wp-login.php=404' '*wp-login.php=404'
  run apply_run acme
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q 'maintenance OFF' "$CALLS"; ! grep -q 'maintenance HOLD' "$CALLS"
  [[ "$output" == *"unchanged from before"* ]]
}

@test "apply: a subpage broken BY the apply is reported and fails the run — but the site goes live" {
  _backup_one_client() { return 0; }
  _curl_phases '' '*kontakt*=404'
  run apply_run acme
  [ "$status" -ne 0 ]
  grep -q 'maintenance OFF' "$CALLS"; ! grep -q 'maintenance HOLD' "$CALLS"
  [[ "$output" == *"kontakt"*"was ok/200, now down/404"* ]]
  [[ "$output" == *"PROBLEMS"* ]]
}

@test "apply: even a subpage 500 doesn't hold a working site (home fine)" {
  _backup_one_client() { return 0; }
  _curl_phases '' '*kontakt*=500'
  run apply_run acme
  [ "$status" -ne 0 ]
  grep -q 'maintenance OFF' "$CALLS"; ! grep -q 'maintenance HOLD' "$CALLS"
}

@test "apply: the HOME page broken after the apply → maintenance KEPT ON" {
  _backup_one_client() { return 0; }
  _curl_phases '' 'https://acme.example=500'
  run apply_run acme
  [ "$status" -ne 0 ]
  grep -q 'maintenance HOLD' "$CALLS"; ! grep -q 'maintenance OFF' "$CALLS"
  [[ "$output" == *"The HOME page is broken"* ]]
}

@test "apply: a custom login_path from wpsite's registry is the login page that's checked" {
  source "$REPO/lib/cmd_apply.sh"
  wclient_get() { [ "$2" = login_path ] && echo "/geheim-login"; return 0; }
  _prod_wp() { shift 2; case "$*" in *"option get home"*) echo https://acme.example ;; esac; }
  _apply_collect_verify_urls u@h /r "$BATS_TEST_TMPDIR/u" acme
  grep -qx 'https://acme.example/geheim-login' "$BATS_TEST_TMPDIR/u"
  ! grep -q 'wp-login.php' "$BATS_TEST_TMPDIR/u"
}

@test "_verify_compare: ok / unchanged / broken / fixed" {
  printf 'ok\t200\thttps://a/\ndown\t404\thttps://a/login\nok\t200\thttps://a/k\ndown\t404\thttps://a/f\n' > "$BATS_TEST_TMPDIR/b"
  printf 'ok\t200\thttps://a/\ndown\t404\thttps://a/login\ndown\t404\thttps://a/k\nok\t200\thttps://a/f\n' > "$BATS_TEST_TMPDIR/a"
  run _verify_compare "$BATS_TEST_TMPDIR/b" "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/c"
  [ "$status" -ne 0 ]
  [ "$(cut -f1 "$BATS_TEST_TMPDIR/c" | tr '\n' ' ')" = "ok unchanged broken fixed " ]
}

# --- multisite: per-site hold, verification + mail per site -------------------------------
_stub_network() {
  _prod_wp() {
    shift 2; printf '%s\n' "$*" >> "$CALLS"
    case "$*" in
      *"core version"*)                 echo "6.5" ;;
      *is_multisite*)                   echo 1 ;;
      *WPSITE_BOOT_OK*)                 echo WPSITE_BOOT_OK ;;
      *"option get home"*)              echo "https://acme.example" ;;
      *"site list"*"--field=url"*)      printf 'https://acme.example/\nhttps://shop.example.de/\n' ;;
      *"site list"*"--format=csv"*)     printf 'blog_id,url\n1,https://acme.example/\n2,https://shop.example.de/\n' ;;
      *"post list"*shop.example.de*)    echo "https://shop.example.de/produkte/" ;;
      *"post list"*)                    echo "https://acme.example/kontakt/" ;;
      *"plugin list"*field=name*)       echo "akismet" ;;
      *list*)                           echo "name,version,update" ;;
    esac
  }
}

@test "apply multisite: a broken SUBSITE is held on its own — the rest of the network goes live" {
  _backup_one_client() { return 0; }
  _stub_network
  _curl_phases '' 'https://shop.example.de/=500 https://shop.example.de=500'
  run apply_run acme
  [ "$status" -ne 0 ]                                  # not a clean run
  ! grep -q 'maintenance OFF' "$CALLS"                 # the lock stays — for ONE site
  [[ "$output" == *"PARTLY LIVE"* ]]; [[ "$output" == *"shop.example.de"* ]]
  [[ "$output" == *"The rest of the network is live"* ]]
  grep -q 'wp_mail' "$CALLS"                           # the live site still got its test mail
  [ "$(grep -c 'wp_mail' "$CALLS")" -eq 1 ]            # …but not the held one
}

@test "apply multisite: every site is verified and gets a test mail" {
  _backup_one_client() { return 0; }
  _stub_network
  run apply_run acme
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep -c 'wp_mail' "$CALLS")" -eq 2 ]
  grep -q -- 'eval --url=https://shop.example.de/' "$CALLS"
  [[ "$output" == *"(2/2 sites)"* ]]
}
