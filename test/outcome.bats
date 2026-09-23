#!/usr/bin/env bats
# "Why didn't it update?" (HARDENING-PLAN.md Phase 4/5): classification of every plugin/
# theme after a run, the client hold/manual lists in the update loop, the post-upgrade
# briefing, apply-vs-rehearsal, and honest reports. The fixture replays the September
# 2026 round: ACF Pro without a download package, wp-staging-pro (global skip), a
# client-held custom plugin, greyd_suite as a manual theme.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  CFG="$BATS_TEST_TMPDIR/wpsite.yml"
  cat > "$CFG" <<EOF
base_dir: $BATS_TEST_TMPDIR/root
clients:
  acme:
    hold_plugins:
      acme-custom: "Individualentwicklung (2026-09-23)"
    manual_updates:
      greyd_suite: "Updates nur in wp-admin sichtbar (2026-09-23)"
EOF
  export WPSITE_CONFIG="$CFG" WPSITE_TEAM_CONFIG="$CFG" MANDOS_STUB_CONFIG="$CFG"
  export MANDOS_BIN="$REPO/test/fixtures/mandos-stub"
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_upgrade.sh"
  source "$REPO/lib/cmd_hold.sh"
  D="$BATS_TEST_TMPDIR/run"; mkdir -p "$D"
  cat > "$D/plugins.before.csv" <<'EOF'
name,version,update,status
advanced-custom-fields-pro,6.3.11,available,active
akismet,5.0,available,active
wp-staging-pro,6.7.2,available,active
acme-custom,1.0,available,active
stubborn,2.0,available,active
broken-dl,3.0,available,active
fatal-one,4.0,available,active
never-tried,5.0,available,active
query-monitor,4.0.7,none,active
EOF
  cat > "$D/plugins.after.csv" <<'EOF'
name,version,update,status
advanced-custom-fields-pro,6.3.11,available,active
akismet,5.1,none,active
wp-staging-pro,6.7.2,available,active
acme-custom,1.0,available,active
stubborn,2.0,available,active
broken-dl,3.0,available,active
fatal-one,4.0,available,active
never-tried,5.0,available,active
query-monitor,4.0.7,none,active
EOF
  cat > "$D/plugins.packages.csv" <<'EOF'
name,update,update_version,update_package
advanced-custom-fields-pro,available,6.8.10,
akismet,available,5.1,https://downloads.wordpress.org/akismet.zip
wp-staging-pro,available,6.8,https://x/wpstg.zip
acme-custom,available,1.1,https://x/custom.zip
stubborn,available,2.1,https://x/stubborn.zip
broken-dl,available,3.1,https://x/broken.zip
fatal-one,available,4.1,https://x/fatal.zip
never-tried,available,5.1,https://x/never.zip
EOF
  printf 'advanced-custom-fields-pro\t1\t0\tWarning: Das Aktualisierungs-Paket ist nicht verfügbar.\nakismet\t0\t0\t\nstubborn\t0\t0\t\nbroken-dl\t1\t0\tError: Download failed. Not Found\nfatal-one\t255\t1\tPHP Fatal error:  Uncaught Error: boom\n' > "$D/plugins.attempts.tsv"
  printf 'name,version,update\ngreyd_suite,1.33.0,none\n' > "$D/themes.before.csv"
  cp "$D/themes.before.csv" "$D/themes.after.csv"
  printf 'name,update,update_version,update_package\ngreyd_suite,none,,\n' > "$D/themes.packages.csv"
  : > "$D/themes.attempts.tsv"
}

_class() { awk -F'\t' -v n="$1" '$2==n {print $3; exit}' "$D/updates.outcome.tsv"; }

@test "classify: one class per item, from versions / exit codes / packages — never wording" {
  _classify_updates "$D" acme
  [ "$(_class akismet)" = updated ]
  [ "$(_class advanced-custom-fields-pro)" = no-package ]     # the arbeitsplatz-erde case
  [ "$(_class wp-staging-pro)" = held ]                       # global skip
  [ "$(_class acme-custom)" = held ]                          # client hold list
  [ "$(_class stubborn)" = refused ]
  [ "$(_class broken-dl)" = error ]
  [ "$(_class fatal-one)" = fatal ]
  [ "$(_class never-tried)" = not-attempted ]                 # the bauklimaneutral shape
  [ "$(_class greyd_suite)" = manual ]
  [ -z "$(_class query-monitor)" ]                            # no update → not listed
}

@test "classify: held items keep their reason and the pending version" {
  _classify_updates "$D" acme
  grep -q $'acme-custom\theld\t1.0\t1.1\theld: Individualentwicklung' "$D/updates.outcome.tsv"
}

@test "report: every class is explained, with the hold command for no-package" {
  _classify_updates "$D" acme
  run _upgrade_report "acme (PRODUCTION)" 20260923_130045 7.0.6 7.1.2 "$D"
  [[ "$output" == *"• akismet: 5.0 → 5.1"* ]]
  [[ "$output" == *"advanced-custom-fields-pro (6.3.11 → 6.8.10) — NO download package"*"wpsite hold acme advanced-custom-fields-pro"* ]]
  [[ "$output" == *"⊘ acme-custom (1.0) — held: Individualentwicklung"*"1.1 available"* ]]
  [[ "$output" == *"✗ broken-dl (3.0) — FAILED: Error: Download failed"* ]]
  [[ "$output" == *"PHP FATAL during the update"* ]]
  [[ "$output" == *"✎ greyd_suite (currently 1.33.0)"* ]]
  [[ "$output" != *"premium? handle manually"* ]]             # the old, misleading line
}

@test "German customer report: only what was updated, never 'bereits aktuell'" {
  run _report_section_de "$D/plugins.before.csv" "$D/plugins.after.csv"
  [[ "$output" == *"akismet: 5.0 —> 5.1"* ]]
  [[ "$output" != *"advanced-custom-fields-pro"* ]]
  [[ "$output" != *"ausstehend"* ]]
  run _report_section_de "$D/themes.before.csv" "$D/themes.after.csv"
  [ "$output" = "    Keine Änderungen" ]
}

@test "briefing: lists what didn't update; offers hold only for no-package/refused" {
  _classify_updates "$D" acme
  run _update_briefing "$D" acme 0
  [[ "$output" == *"not updated (7)"* ]]
  [[ "$output" == *"wpsite hold acme advanced-custom-fields-pro"* ]]
  [[ "$output" == *"wpsite hold acme stubborn"* ]]
  [[ "$output" != *"wpsite hold acme broken-dl"* ]]           # bugs aren't hold candidates
  [[ "$output" != *"wpsite hold acme fatal-one"* ]]
  [[ "$output" == *"greyd_suite"* ]]
}

@test "briefing: silent success when everything updated" {
  printf 'plugin\takismet\tupdated\t5.0\t5.1\t\n' > "$D/updates.outcome.tsv"
  run _update_briefing "$D" acme 0
  [[ "$output" == *"Everything with an update was updated"* ]]
}

@test "the update loop skips client-held plugins (and themes) but attempts no-package ones" {
  RUNLOG="$BATS_TEST_TMPDIR/runs"; : > "$RUNLOG"
  runner() {
    printf '%s\n' "$*" >> "$RUNLOG"
    case "$*" in
      *"--update=available --field=name") case "$*" in plugin*) printf 'acme-custom\nadvanced-custom-fields-pro\n' ;; esac ;;
      *update_package*) : ;;
      eval*WPSITE_BOOT_OK*) echo WPSITE_BOOT_OK ;;
      "plugin update advanced-custom-fields-pro") echo "Warning: Das Aktualisierungs-Paket ist nicht verfügbar."; return 1 ;;
      *) echo ok ;;
    esac
  }
  _WPSITE_RUN_CLIENT=acme
  _run_updates "$D" 0 runner 2>/dev/null || true
  ! grep -q 'plugin update acme-custom' "$RUNLOG"
  grep -q 'plugin update advanced-custom-fields-pro' "$RUNLOG"
  grep -q 'plugin skip: acme-custom (held: Individualentwicklung' "$D/update.log"
  grep -q $'advanced-custom-fields-pro\t1\t0\tWarning: Das Aktualisierungs-Paket' "$D/plugins.attempts.tsv"
}

@test "apply vs rehearsal: differences + production drift are reported, never a gate" {
  _classify_updates "$D" acme
  R="$BATS_TEST_TMPDIR/rehearsal"; mkdir -p "$R"
  sed 's/^broken-dl\tplugin/x/' "$D/updates.outcome.tsv" | awk -F'\t' 'BEGIN{OFS="\t"} $2=="broken-dl" {$3="updated"} {print}' > "$R/updates.outcome.tsv"
  sed 's/^akismet,5.0,/akismet,4.9,/' "$D/plugins.before.csv" > "$R/plugins.before.csv"
  _latest_upgrade_dir() { printf '%s' "$R"; }
  run _compare_with_rehearsal "$D" acme
  [ "$status" -eq 0 ]
  [[ "$output" == *"plugin broken-dl: rehearsal updated, production error"* ]]
  [[ "$output" == *"akismet: 4.9 in the rehearsal, 5.0 on production now"* ]]
}

@test "missed-updates warning ignores held items (they're on purpose)" {
  run _report_missed_updates "$D"
  [[ "$output" != *"acme-custom"* ]] || [ -z "$_WPSITE_RUN_CLIENT" ]
  _WPSITE_RUN_CLIENT=acme run _report_missed_updates "$D"
  [[ "$output" != *"plugin:acme-custom"* ]]
  [[ "$output" == *"plugin:advanced-custom-fields-pro"* ]]
}

@test "packages.csv never stores the download URL (it can carry a licence token)" {
  runner() {
    case "$*" in
      *update_package*) printf 'name,update,update_version,update_package\naule,available,2.3.82,https://aule-cloud.example/dl?token=SECRET123\nacf,available,6.8,\n' ;;
      eval*WPSITE_BOOT_OK*) echo WPSITE_BOOT_OK ;;
      *) : ;;
    esac
  }
  _run_updates "$D" 0 runner 2>/dev/null || true
  ! grep -rq SECRET123 "$D"
  grep -qx 'aule,available,2.3.82,yes' "$D/plugins.packages.csv"
  grep -qx 'acf,available,6.8,' "$D/plugins.packages.csv"
}
