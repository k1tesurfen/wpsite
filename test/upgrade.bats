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
