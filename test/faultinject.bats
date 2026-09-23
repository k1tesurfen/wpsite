#!/usr/bin/env bats
# Fault injection over EVERY remote call of `wpsite apply` (HARDENING-PLAN.md Phase 6).
# The bug class: a helper whose failure makes `set -euo pipefail` abort the command
# SILENTLY — twice in September 2026 (`wpsite test` after [4/4]; apply leaving
# maintenance ON after one failing `plugin list`). bats' own `run` disables errexit, so
# the harness (fixtures/apply-harness.sh) runs apply in a real strict-mode process.
#
# A clean run counts its N remote calls; then call i = 1..N is made to fail. For every i:
#   1. never silent  — exit 0 with the verified-success line, or non-zero with an ✗ error;
#   2. never stranded — maintenance files remain ONLY when apply says so out loud
#      (deliberate hold of a broken site, or "still on" with the manual command);
#   3. verified      — once maintenance went on, the final check ran;
#   4. nothing written before the typed confirmation (the preflight runs first and is
#      read-only apart from its probe files).
# New remote calls are covered automatically: the harness counts, it doesn't list.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  CFG="$BATS_TEST_TMPDIR/wpsite.yml"
  printf 'base_dir: %s/root\nclients:\n  acme:\n    ssh: u@acme\n    wp_root: %s/server\n' \
    "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > "$CFG"
  export WPSITE_CONFIG="$CFG" WPSITE_TEAM_CONFIG="$CFG" MANDOS_STUB_CONFIG="$CFG"
  export MANDOS_BIN="$REPO/test/fixtures/mandos-stub"
  export FI_ROOT="$BATS_TEST_TMPDIR/server"
}

_fi_run() { # fail_at
  rm -rf "$FI_ROOT"; mkdir -p "$FI_ROOT/wp-content/plugins" "$FI_ROOT/wp-content/themes"
  export FI_COUNT="$BATS_TEST_TMPDIR/count" FI_LOG="$BATS_TEST_TMPDIR/log" FI_FAIL_AT="$1"
  : > "$FI_COUNT"; : > "$FI_LOG"
  run bash "$REPO/test/fixtures/apply-harness.sh" "$REPO" </dev/null
}

_maint_left() {
  [ -e "$FI_ROOT/.maintenance" ] || [ -e "$FI_ROOT/wp-content/.wpsite-maintenance" ] \
    || [ -e "$FI_ROOT/wp-content/mu-plugins/wpsite-maintenance.php" ] \
    || [ -e "$FI_ROOT/wp-content/maintenance.php" ]
}

@test "clean run: succeeds, verifies, leaves nothing behind" {
  _fi_run 0
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Production upgraded and verified"* ]]
  ! _maint_left
}

@test "every single remote call failing: never silent, never stranded, always verified" {
  _fi_run 0
  [ "$status" -eq 0 ] || { echo "clean run failed: $output"; return 1; }
  local n; n="$(cat "$FI_COUNT")"
  [ "$n" -gt 20 ]                                   # sanity: the harness saw the real flow
  local i problems="" call
  for i in $(seq 1 "$n"); do
    _fi_run "$i"
    call="$(awk -F'\t' -v i="$i" '$1==i {print $2; exit}' "$FI_LOG" | cut -c1-70)"
    # 1. never silent
    if [ "$status" -eq 0 ]; then
      [[ "$output" == *"Production upgraded and verified"* ]] || problems+=$'\n'"#$i ($call): exit 0 without the verified line"
    else
      [[ "$output" == *"✗"* ]] || problems+=$'\n'"#$i ($call): SILENT failure (exit $status, no error line)"
    fi
    # 2. never stranded
    if _maint_left; then
      [[ "$output" == *"MAINTENANCE KEPT ON"* || "$output" == *"MAINTENANCE STILL ON"* || "$output" == *"Could not switch maintenance off"* ]] \
        || problems+=$'\n'"#$i ($call): maintenance files LEFT without saying so"
    fi
    # 3. verified once maintenance went on
    if grep -q 'wp-content/maintenance.php' "$FI_LOG"; then
      [[ "$output" == *"Final check"* ]] || problems+=$'\n'"#$i ($call): maintenance was on but no final check"
    fi
    # 4. nothing written before the confirmation
    if awk -F'\t' '/^CONFIRMED$/ {exit} /(plugin update|theme update|core update|wpsite-maintenance|maintenance\.php|plugin activate|cache flush)/ {bad=1} END {exit !bad}' "$FI_LOG"; then
      problems+=$'\n'"#$i ($call): production written BEFORE the confirmation"
    fi
  done
  [ -z "$problems" ] || { echo "Fault-injection violations over $n calls:$problems"; return 1; }
}

@test "a failure DURING the updates still lifts maintenance and says what happened" {
  _fi_run 0
  local n i
  n="$(awk -F'\t' '/wp plugin update akismet/ {print $1; exit}' "$FI_LOG")"
  [ -n "$n" ]
  _fi_run "$n"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Final check"* ]]
  [[ "$output" == *"with problems"* ]]
  ! _maint_left
}
