#!/usr/bin/env bats
# Upgrade report rendering. The WP-CLI/Docker path is integration-only; here we test
# the before→after diff logic against synthetic `name,version,update` CSVs.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_upgrade.sh"
  B="$BATS_TEST_TMPDIR/before.csv"
  A="$BATS_TEST_TMPDIR/after.csv"
}

@test "section: lists plugins whose version changed" {
  printf 'name,version,update\nakismet,5.0,none\nyoast,20.1,none\n' > "$B"
  printf 'name,version,update\nakismet,5.3,none\nyoast,20.1,none\n' > "$A"
  run _report_section "$B" "$A"
  [[ "$output" == *"akismet: 5.0 → 5.3"* ]]
  [[ "$output" != *"yoast"* ]]            # unchanged -> not listed
}

@test "section: flags an update that's still available (premium/manual)" {
  printf 'name,version,update\njetpack,12.0,available\n' > "$B"
  printf 'name,version,update\njetpack,12.0,available\n' > "$A"
  run _report_section "$B" "$A"
  [[ "$output" == *"jetpack (12.0)"* ]]
  [[ "$output" == *"not applied"* ]]
}

@test "section: nothing changed" {
  printf 'name,version,update\nakismet,5.0,none\n' > "$B"
  printf 'name,version,update\nakismet,5.0,none\n' > "$A"
  run _report_section "$B" "$A"
  [[ "$output" == *"(none updated)"* ]]
}

@test "section: handles empty plugin set" {
  printf 'name,version,update\n' > "$B"
  printf 'name,version,update\n' > "$A"
  run _report_section "$B" "$A"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(none updated)"* ]]
}

@test "full report: core change shown" {
  printf 'name,version,update\n' > "$BATS_TEST_TMPDIR/plugins.before.csv"
  printf 'name,version,update\n' > "$BATS_TEST_TMPDIR/plugins.after.csv"
  printf 'name,version,update\n' > "$BATS_TEST_TMPDIR/themes.before.csv"
  printf 'name,version,update\n' > "$BATS_TEST_TMPDIR/themes.after.csv"
  run _upgrade_report acme 20260101_000000 6.4.2 6.5.0 "$BATS_TEST_TMPDIR"
  [[ "$output" == *"6.4.2 → 6.5.0"* ]]
}

@test "full report: core unchanged shown as (no change)" {
  for s in plugins themes; do
    printf 'name,version,update\n' > "$BATS_TEST_TMPDIR/$s.before.csv"
    printf 'name,version,update\n' > "$BATS_TEST_TMPDIR/$s.after.csv"
  done
  run _upgrade_report acme 20260101_000000 6.5.0 6.5.0 "$BATS_TEST_TMPDIR"
  [[ "$output" == *"(no change)"* ]]
}

@test "german report: section listing and available updates" {
  printf 'name,version,update\nakismet,5.0,none\nyoast,20.1,none\n' > "$B"
  printf 'name,version,update\nakismet,5.3,none\nyoast,20.1,none\n' > "$A"
  run _report_section_de "$B" "$A"
  [[ "$output" == *"akismet: 5.0 —> 5.3"* ]]
  [[ "$output" != *"yoast"* ]]
  [[ "$output" == *"✓"* ]]
}

@test "german client report: formats header and client text" {
  for s in plugins themes; do
    printf 'name,version,update\n' > "$BATS_TEST_TMPDIR/$s.before.csv"
    printf 'name,version,update\n' > "$BATS_TEST_TMPDIR/$s.after.csv"
  done
  run _client_report_de bluebase5.com 20260101_123045 6.5.0 6.5.0 "$BATS_TEST_TMPDIR"
  [[ "$output" == *"01.01.2026 um 12:30 Uhr"* ]]
  [[ "$output" == *"WARTUNGSBERICHT"* ]]
  [[ "$output" == *"bluebase5.com"* ]]
  [[ "$output" == *"Keine Änderungen"* ]]
}

# The apply report goes to the customer: it is named after, and headed with, the
# site's DOMAIN — the internal client id must not appear anywhere in it. The local
# upgrade rehearsal keeps the plain name + the id (nobody sends that one out).
@test "client report: apply mode names + heads the file with the domain, not the id" {
  for s in plugins themes; do
    printf 'name,version,update\n' > "$BATS_TEST_TMPDIR/$s.before.csv"
    printf 'name,version,update\n' > "$BATS_TEST_TMPDIR/$s.after.csv"
  done
  client_domain() { printf '%s' bluebase5.com; }
  _report_pdf() { :; }
  run _write_client_report_de bluebase "20260101_123045" 6.5.0 6.5.0 "$BATS_TEST_TMPDIR" domain
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/bluebase5_com-wartungsbericht.txt" ]
  grep -q 'bluebase5\.com' "$BATS_TEST_TMPDIR/bluebase5_com-wartungsbericht.txt"
  ! grep -qi 'bluebase[^5]' "$BATS_TEST_TMPDIR/bluebase5_com-wartungsbericht.txt"
}

@test "client report: default (upgrade) mode keeps the plain name + client id" {
  for s in plugins themes; do
    printf 'name,version,update\n' > "$BATS_TEST_TMPDIR/$s.before.csv"
    printf 'name,version,update\n' > "$BATS_TEST_TMPDIR/$s.after.csv"
  done
  client_domain() { printf '%s' bluebase5.com; }   # must NOT be consulted
  _report_pdf() { :; }
  run _write_client_report_de bluebase "20260101_123045" 6.5.0 6.5.0 "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/wartungsbericht.txt" ]
  grep -q 'bluebase$' "$BATS_TEST_TMPDIR/wartungsbericht.txt"
}

@test "client_domain: falls back to the client id with no backup" {
  WPSITE_CONFIG="$BATS_TEST_DIRNAME/fixtures/wpsite.yml"
  run client_domain acme
  [ "$status" -eq 0 ]
  [[ "$output" == *acme ]]
}

# --- Active-plugin reconciliation -------------------------------------------
# Regression cover for the shipped bug: wp-mail-smtp silently went INACTIVE during
# a production apply and nothing noticed, because the CSVs carried no `status` and
# every update call discarded stdout+stderr.

@test "active_from_csv: reads status, unquotes names, ignores inactive/dropin" {
  printf 'name,version,update,status\nakismet,5.0,none,active\nfoo,1.0,none,inactive\n"bar (old)",2.0,none,active\nmaintenance.php,,none,dropin\nnet,1.0,none,active-network\n' > "$B"
  run _active_plugins_from_csv "$B"
  [ "$status" -eq 0 ]
  [[ "$output" == *"akismet"* ]]
  [[ "$output" == *"bar (old)"* ]]      # surrounding quotes stripped
  [[ "$output" == *"net"* ]]
  [[ "$output" != *"foo"* ]]            # inactive -> not tracked
  [[ "$output" != *"maintenance.php"* ]]
}

@test "active_from_csv: tolerates an OLD 3-field csv (no status column)" {
  printf 'name,version,update\nakismet,5.0,none\n' > "$B"
  run _active_plugins_from_csv "$B"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "reconcile: no-op when every active plugin survived" {
  printf 'name,version,update,status\nakismet,5.0,none,active\n' > "$B"
  printf 'name,version,update,status\nakismet,5.3,none,active\n' > "$A"
  RUNNER() { echo "CALLED $*" >> "$BATS_TEST_TMPDIR/calls"; }
  : > "$BATS_TEST_TMPDIR/calls"
  run _reconcile_active_plugins "$B" "$A" "$BATS_TEST_TMPDIR/log" "$BATS_TEST_TMPDIR/out" RUNNER
  [ "$status" -eq 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/out" ]
  [ ! -s "$BATS_TEST_TMPDIR/calls" ]     # nothing was touched
}

@test "reconcile: reactivates a plugin that went inactive and still boots" {
  printf 'name,version,update,status\nwp-mail-smtp,4.8.0,available,active\n' > "$B"
  printf 'name,version,update,status\nwp-mail-smtp,4.9.0,none,inactive\n' > "$A"
  RUNNER() { echo "$*" >> "$BATS_TEST_TMPDIR/calls"; return 0; }   # activate + boot both OK
  : > "$BATS_TEST_TMPDIR/calls"
  run _reconcile_active_plugins "$B" "$A" "$BATS_TEST_TMPDIR/log" "$BATS_TEST_TMPDIR/out" RUNNER
  [ "$status" -eq 0 ]
  grep -q 'plugin activate wp-mail-smtp' "$BATS_TEST_TMPDIR/calls"
  grep -q 'eval' "$BATS_TEST_TMPDIR/calls"                       # boot check ran
  ! grep -q 'plugin deactivate' "$BATS_TEST_TMPDIR/calls"
  grep -q '^REACTIVATED	wp-mail-smtp' "$BATS_TEST_TMPDIR/out"
}

@test "reconcile: a plugin that fatals on boot is left DEACTIVATED and reported" {
  printf 'name,version,update,status\nbroken,1.0,available,active\n' > "$B"
  printf 'name,version,update,status\nbroken,2.0,none,inactive\n' > "$A"
  # Baseline boot succeeds (the site was fine); only the check AFTER reactivation fatals.
  RUNNER() {
    echo "$*" >> "$BATS_TEST_TMPDIR/calls"
    case "$*" in eval*)
      [ -f "$BATS_TEST_TMPDIR/baseline" ] && return 1
      : > "$BATS_TEST_TMPDIR/baseline"; return 0 ;;
    esac
    return 0
  }
  : > "$BATS_TEST_TMPDIR/calls"
  run _reconcile_active_plugins "$B" "$A" "$BATS_TEST_TMPDIR/log" "$BATS_TEST_TMPDIR/out" RUNNER
  [ "$status" -ne 0 ]                                            # signals the caller
  grep -q 'plugin deactivate broken --skip-plugins' "$BATS_TEST_TMPDIR/calls"
  grep -q '^FAILED	broken' "$BATS_TEST_TMPDIR/out"
  [[ "$output" == *"fatals on load"* ]]
}

@test "reconcile: activation refused is reported without a boot check" {
  printf 'name,version,update,status\ngone,1.0,none,active\n' > "$B"
  printf 'name,version,update,status\ngone,1.0,none,inactive\n' > "$A"
  RUNNER() { echo "$*" >> "$BATS_TEST_TMPDIR/calls"; return 1; }
  : > "$BATS_TEST_TMPDIR/calls"
  run _reconcile_active_plugins "$B" "$A" "$BATS_TEST_TMPDIR/log" "$BATS_TEST_TMPDIR/out" RUNNER
  [ "$status" -ne 0 ]
  grep -q '^FAILED	gone' "$BATS_TEST_TMPDIR/out"
  # Only the one baseline boot check — none after a refused activation.
  [ "$(grep -c 'eval' "$BATS_TEST_TMPDIR/calls")" -eq 1 ]
}

@test "reconcile: a network-active plugin is restored with --network" {
  printf 'name,version,update,status\nnetplug,1.0,none,active-network\n' > "$B"
  printf 'name,version,update,status\nnetplug,2.0,none,inactive\n' > "$A"
  RUNNER() { echo "$*" >> "$BATS_TEST_TMPDIR/calls"; return 0; }
  : > "$BATS_TEST_TMPDIR/calls"
  run _reconcile_active_plugins "$B" "$A" "$BATS_TEST_TMPDIR/log" "$BATS_TEST_TMPDIR/out" RUNNER
  [ "$status" -eq 0 ]
  grep -q 'plugin activate netplug --network' "$BATS_TEST_TMPDIR/calls"
}

@test "reconcile: network-active downgraded to plain active is NOT a loss" {
  printf 'name,version,update,status\nnetplug,1.0,none,active-network\n' > "$B"
  printf 'name,version,update,status\nnetplug,2.0,none,active\n' > "$A"
  RUNNER() { echo "$*" >> "$BATS_TEST_TMPDIR/calls"; return 0; }
  : > "$BATS_TEST_TMPDIR/calls"
  run _reconcile_active_plugins "$B" "$A" "$BATS_TEST_TMPDIR/log" "$BATS_TEST_TMPDIR/out" RUNNER
  [ "$status" -eq 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/calls" ]
}

@test "report: reconciliation block renders both outcomes, silent when clean" {
  R="$BATS_TEST_TMPDIR/plugins.reconcile.txt"
  printf 'REACTIVATED\twp-mail-smtp\tno error on boot\nFAILED\tbroken\tfatal error on boot\n' > "$R"
  run _report_reconcile "$R"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wp-mail-smtp"* ]]
  [[ "$output" == *"reactivated OK"* ]]
  [[ "$output" == *"broken"* ]]
  [[ "$output" == *"could NOT be restored"* ]]
  : > "$R"
  run _report_reconcile "$R"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "reconcile: a PRE-EXISTING boot failure is not blamed on the reactivated plugin" {
  printf 'name,version,update,status\nvictim,1.0,none,active\n' > "$B"
  printf 'name,version,update,status\nvictim,2.0,none,inactive\n' > "$A"
  # The site was already broken before we touched anything: every boot check fails.
  RUNNER() {
    echo "$*" >> "$BATS_TEST_TMPDIR/calls"
    case "$*" in eval*) return 1 ;; esac
    return 0
  }
  : > "$BATS_TEST_TMPDIR/calls"
  run _reconcile_active_plugins "$B" "$A" "$BATS_TEST_TMPDIR/log" "$BATS_TEST_TMPDIR/out" RUNNER
  [ "$status" -ne 0 ]                                       # still surfaced to the caller
  grep -q 'plugin activate victim' "$BATS_TEST_TMPDIR/calls" # prior state restored
  ! grep -q 'plugin deactivate victim' "$BATS_TEST_TMPDIR/calls"   # but NOT blamed
  grep -q '^UNVERIFIED	victim' "$BATS_TEST_TMPDIR/out"
  [[ "$output" == *"does NOT boot cleanly before reconciliation"* ]]
}

@test "report: an unverified plugin renders as needing a manual check" {
  R="$BATS_TEST_TMPDIR/plugins.reconcile.txt"
  printf 'UNVERIFIED\tvictim\treactivated, but the site already failed to boot beforehand\n' > "$R"
  run _report_reconcile "$R"
  [ "$status" -eq 0 ]
  [[ "$output" == *"victim"* ]]
  [[ "$output" == *"verify by hand"* ]]
}

# --- Plugins excluded from auto-update ---------------------------------------
# One shared list drives both the local rehearsal and the production apply; a slug
# silently dropping out of it would let the updater touch a plugin we ship ourselves.

@test "skip list: aule and wp-staging-pro are never auto-updated" {
  run _plugin_update_skip_reason aule
  [ -n "$output" ]
  run _plugin_update_skip_reason wp-staging-pro
  [ -n "$output" ]
}

@test "skip list: an ordinary plugin (and the free wp-staging) IS updated" {
  run _plugin_update_skip_reason akismet
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run _plugin_update_skip_reason wp-staging      # different plugin from the -pro one
  [ -z "$output" ]
}

# --- Update plan + log --------------------------------------------------------
# Regression cover: on bauklimaneutral (apply 20260923_105427) the before-snapshot
# flagged 9 plugins as updatable, but the post-core-update `--update=available`
# query returned only the greyd plugins (their updater injects data live), so six
# wp.org plugins were never attempted — and update.log could not show why.

_stub_runner() {  # before-snapshot says available; the fresh query misses wordfence
  RUNLOG="$BATS_TEST_TMPDIR/runs"; : > "$RUNLOG"
  runner() {
    printf '%s\n' "$*" >> "$RUNLOG"
    case "$*" in
      "plugin list --update=available --field=name") printf 'Notice: early textdomain\ngreyd-plugin\n' ;;
      "theme list --update=available --field=name")  : ;;
      "plugin update fail-me") echo "Error: boom"; return 1 ;;
      *) echo "ok: $*" ;;
    esac
  }
  D="$BATS_TEST_TMPDIR/run"; mkdir -p "$D"
  printf 'name,version,update,status\ngreyd-plugin,2.20.2,available,active\nwordfence,8.2.2,available,active\nwp-staging-pro,6.7.2,available,active\nquery-monitor,4.0.7,none,active\n' > "$D/plugins.before.csv"
  printf 'name,version,update\ngreyd_suite,1.33.0,available\n' > "$D/themes.before.csv"
}

@test "plan: unions the before-snapshot with the fresh query (the bauklimaneutral miss)" {
  _stub_runner
  run _update_plan plugin "$D/plugins.before.csv" "$D/update.log" runner
  [ "$status" -eq 0 ]
  [ "$output" = $'greyd-plugin\nwordfence\nwp-staging-pro' ]      # no notice line, no query-monitor
  grep -q 'plugin plan: wordfence (ONLY in before-snapshot' "$D/update.log"
  grep -q 'plugin plan: greyd-plugin (reported by fresh query)' "$D/update.log"
}

@test "run: updates every planned item, logs skips + labelled sections with exit codes" {
  _stub_runner
  run _run_updates "$D" 0 runner
  [ "$status" -eq 0 ]
  grep -qx 'plugin update wordfence'   "$RUNLOG"
  grep -qx 'plugin update greyd-plugin' "$RUNLOG"
  grep -qx 'theme update greyd_suite'  "$RUNLOG"   # snapshot-only theme is attempted too
  ! grep -q 'plugin update wp-staging-pro' "$RUNLOG"
  grep -q 'plugin skip: wp-staging-pro' "$D/update.log"
  grep -q '=== .*  plugin update wordfence' "$D/update.log"
  grep -q '=== exit 0' "$D/update.log"
  grep -q '=== .*  refresh update cache' "$D/update.log"
}

@test "run: a failing update is logged with its exit code and fails the run, not the cascade" {
  _stub_runner
  printf 'fail-me,1.0,available,active\n' >> "$D/plugins.before.csv"
  run _run_updates "$D" 0 runner
  [ "$status" -ne 0 ]
  grep -q '=== exit 1' "$D/update.log"
  grep -qx 'theme update greyd_suite' "$RUNLOG"    # kept going after the failure
}

@test "missed updates: warns + logs what was updatable but kept its version" {
  D="$BATS_TEST_TMPDIR/m"; mkdir -p "$D"
  printf 'name,version,update,status\na,1.0,available,active\nb,2.0,available,active\nwp-staging-pro,6.7.2,available,active\n' > "$D/plugins.before.csv"
  printf 'name,version,update,status\na,1.1,none,active\nb,2.0,available,active\nwp-staging-pro,6.7.2,available,active\n' > "$D/plugins.after.csv"
  printf 'name,version,update\nt,1.33.0,available\n' > "$D/themes.before.csv"
  printf 'name,version,update\nt,1.33.0,available\n' > "$D/themes.after.csv"
  run _report_missed_updates "$D"
  [[ "$output" == *"plugin:b"* ]]
  [[ "$output" == *"theme:t"* ]]
  [[ "$output" != *"plugin:a"* ]]
  [[ "$output" != *"wp-staging-pro"* ]]            # a deliberate skip is not a miss
  grep -q 'NOT UPDATED: plugin b still 2.0' "$D/update.log"
}
