#!/usr/bin/env bats
# apply's maintenance mode (HARDENING-PLAN.md Phase 2). WordPress's own updater deletes
# `.maintenance` after every update (arbeitsplatz-erde: the site was live for most of the
# run), so apply holds its OWN flag + mu-plugin gate with a dead-man expiry. The PHP gate
# and page are exercised with the local php CLI (skipped without it); the remote commands
# run against a local directory standing in for the server.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_upgrade.sh"
  source "$REPO/lib/cmd_apply.sh"
  ROOT="$BATS_TEST_TMPDIR/site"; mkdir -p "$ROOT/wp-content"
  # "Remote" = run the command locally (the paths are all absolute).
  wpsite_ssh() { shift; bash -c "$1"; }
}

# Run the gate like WordPress would (mu-plugins load with WP_CONTENT_DIR defined).
# Prints the response body; "PASSED" means the gate let the request through.
_gate() { # [bypass_header_value] [wp_cli]
  php -r '
    define("WP_CONTENT_DIR", getenv("WPC"));
    if (getenv("IS_CLI") === "1") { define("WP_CLI", true); }
    if (getenv("BYPASS") !== "") { $_SERVER["HTTP_X_WPSITE_BYPASS"] = getenv("BYPASS"); }
    include getenv("WPC") . "/mu-plugins/wpsite-maintenance.php";
    echo "PASSED";' 2>&1
}

@test "on: installs page + gate + both locks; the page is German and marked" {
  _prod_maintenance_on u@h "$ROOT" tok123
  [ -f "$ROOT/wp-content/maintenance.php" ]
  [ -f "$ROOT/wp-content/mu-plugins/wpsite-maintenance.php" ]
  [ -f "$ROOT/.maintenance" ]
  read -r until token < "$ROOT/wp-content/.wpsite-maintenance"
  [ "$token" = tok123 ]
  [ "$until" -gt "$(date +%s)" ]                          # dead-man expiry in the future
  grep -q 'Wartungsarbeiten' "$ROOT/wp-content/maintenance.php"
  grep -q 'lang="de"' "$ROOT/wp-content/maintenance.php"
  grep -q "$WPSITE_MAINT_MARKER" "$ROOT/wp-content/maintenance.php"
}

@test "refresh re-creates .maintenance after WordPress's updater deleted it" {
  _prod_maintenance_on u@h "$ROOT" tok
  rm -f "$ROOT/.maintenance"                              # what WP_Upgrader does
  _prod_maintenance_refresh u@h "$ROOT"
  grep -q '\$upgrading = [0-9]' "$ROOT/.maintenance"      # a literal time → WP expires it
}

@test "hold makes both locks permanent; off removes all four files" {
  _prod_maintenance_on u@h "$ROOT" tok
  _prod_maintenance_hold u@h "$ROOT"
  read -r until _ < "$ROOT/wp-content/.wpsite-maintenance"; [ "$until" = 0 ]
  grep -q 'time()' "$ROOT/.maintenance"
  _prod_maintenance_off u@h "$ROOT"
  [ ! -e "$ROOT/.maintenance" ]; [ ! -e "$ROOT/wp-content/.wpsite-maintenance" ]
  [ ! -e "$ROOT/wp-content/mu-plugins/wpsite-maintenance.php" ]
  [ ! -e "$ROOT/wp-content/maintenance.php" ]             # no more leftover page
}

@test "gate: serves the 503 page to visitors, lets WP-CLI and the bypass token through" {
  command -v php >/dev/null 2>&1 || skip "php not installed"
  _prod_maintenance_on u@h "$ROOT" tok123
  export WPC="$ROOT/wp-content"
  BYPASS="" IS_CLI=0 run _gate
  [[ "$output" == *Wartungsarbeiten* ]]; [[ "$output" != *PASSED* ]]
  BYPASS="" IS_CLI=1 run _gate;   [ "$output" = PASSED ]
  BYPASS=tok123 IS_CLI=0 run _gate; [ "$output" = PASSED ]
  BYPASS=wrong IS_CLI=0 run _gate;  [[ "$output" != *PASSED* ]]
}

@test "gate: dead-man switch — an expired flag no longer blocks; a held (0) one always does" {
  command -v php >/dev/null 2>&1 || skip "php not installed"
  _prod_maintenance_on u@h "$ROOT" tok
  export WPC="$ROOT/wp-content"
  printf '%s tok\n' "$(( $(date +%s) - 5 ))" > "$ROOT/wp-content/.wpsite-maintenance"
  BYPASS="" IS_CLI=0 run _gate; [ "$output" = PASSED ]
  printf '0 tok\n' > "$ROOT/wp-content/.wpsite-maintenance"
  BYPASS="" IS_CLI=0 run _gate; [[ "$output" == *Wartungsarbeiten* ]]
}

@test "the PHP files are syntactically valid" {
  command -v php >/dev/null 2>&1 || skip "php not installed"
  _maintenance_page > "$BATS_TEST_TMPDIR/p.php"; _maintenance_muplugin > "$BATS_TEST_TMPDIR/m.php"
  php -l "$BATS_TEST_TMPDIR/p.php"; php -l "$BATS_TEST_TMPDIR/m.php"
}

@test "token: 32 hex chars, different every time" {
  local a b; a="$(_maintenance_token)"; b="$(_maintenance_token)"
  [[ "$a" =~ ^[0-9a-f]{32}$ ]]; [ "$a" != "$b" ]
}

# --- _site_probe: what a visitor sees ---------------------------------------------------

@test "_site_probe classifies ok / fatal / maintenance / down" {
  curl() { local o=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && o="$2"; shift; done
           printf '%s' "$BODY" > "$o"; printf '%s' "$CODE"; }
  CODE=200 BODY="<html>fine</html>"                          run _site_probe http://x; [ "$output" = $'200\tok' ]
  CODE=200 BODY="There has been a critical error on this website." run _site_probe http://x; [ "$output" = $'200\tfatal' ]
  CODE=500 BODY="Fatal error: Uncaught Error"                 run _site_probe http://x; [ "$output" = $'500\tfatal' ]
  CODE=503 BODY="<!-- $WPSITE_MAINT_MARKER -->"               run _site_probe http://x; [ "$output" = $'503\tmaintenance' ]
  CODE=404 BODY="nope"                                        run _site_probe http://x; [ "$output" = $'404\tdown' ]
}

# --- _run_updates: the stop rule --------------------------------------------------------

_runner_setup() { # boots_after_failure: 1|0
  RUNLOG="$BATS_TEST_TMPDIR/runs"; : > "$RUNLOG"; BOOTS="$1"
  runner() {
    printf '%s\n' "$*" >> "$RUNLOG"
    case "$*" in
      "plugin list --update=available --field=name") printf 'bad-plugin\ngood-plugin\n' ;;
      "theme list --update=available --field=name")  echo some-theme ;;
      "plugin update bad-plugin") echo "PHP Fatal error: boom"; return 255 ;;
      eval*WPSITE_BOOT_OK*) [ "$BOOTS" = 1 ] && echo WPSITE_BOOT_OK; return 0 ;;
      *) echo ok ;;
    esac
  }
  D="$BATS_TEST_TMPDIR/run"; mkdir -p "$D"
  printf 'name,version,update,status\n' > "$D/plugins.before.csv"
  printf 'name,version,update\n' > "$D/themes.before.csv"
}

@test "stop rule: failed update but the site still boots → carry on with the rest" {
  _runner_setup 1
  run _run_updates "$D" 0 runner
  [ "$status" -eq 1 ]
  grep -qx 'plugin update good-plugin' "$RUNLOG"
  grep -qx 'theme update some-theme' "$RUNLOG"
  grep -q 'site still boots — continuing' "$D/update.log"
}

@test "stop rule: failed update and the site no longer boots → STOP, nothing else updated" {
  _runner_setup 0
  run _run_updates "$D" 0 runner
  [ "$status" -eq 2 ]
  ! grep -q 'plugin update good-plugin' "$RUNLOG"
  ! grep -q 'theme update' "$RUNLOG"
  grep -q 'STOP: site does not boot' "$D/update.log"
}

@test "step hook runs after every update step (apply re-arms maintenance there)" {
  _runner_setup 1
  HOOKS=0; hook() { HOOKS=$((HOOKS + 1)); }
  _WPSITE_STEP_HOOK=hook
  _run_updates "$D" 0 runner 2>/dev/null || true
  _WPSITE_STEP_HOOK=""
  [ "$HOOKS" -ge 5 ]      # core, update-db, 2 plugins, 1 theme
}
