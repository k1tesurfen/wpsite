#!/usr/bin/env bats
# `wpsite report` — regenerate a report PDF from its (hand-edited) .txt.
# Everything is local file work, so only cupsfilter/_open_file need stubbing.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_upgrade.sh"   # _report_pdf
  source "$REPO/lib/cmd_report.sh"

  BASE="$BATS_TEST_TMPDIR/base"
  export WPSITE_CONFIG="$BATS_TEST_TMPDIR/wpsite.yml"
  printf 'base_dir: %s\n' "$BASE" > "$WPSITE_CONFIG"
  APPLIES="$BASE/clients/acme/applies"
  mkdir -p "$APPLIES/20260101_120000" "$APPLIES/20260202_120000"
  printf 'alt report\n'  > "$APPLIES/20260101_120000/acme_de-wartungsbericht.txt"
  printf 'new report\n'  > "$APPLIES/20260202_120000/acme_de-wartungsbericht.txt"

  # cupsfilter isn't on Linux CI and we don't want a real PDF anyway.
  cupsfilter() { printf 'PDF of '; cat "${@: -1}"; }
  have() { [ "$1" != docker ]; }
  _open_file() { printf 'OPENED %s\n' "$1"; }
}

@test "report: regenerates the newest apply by default" {
  run cmd_report acme
  [ "$status" -eq 0 ]
  [ -f "$APPLIES/20260202_120000/acme_de-wartungsbericht.pdf" ]
  [ ! -f "$APPLIES/20260101_120000/acme_de-wartungsbericht.pdf" ]
  [[ "$output" == *"OPENED"* ]]
}

@test "report: --no-open and an explicit id pick that run" {
  run cmd_report acme 20260101_120000 --no-open
  [ "$status" -eq 0 ]
  [ -f "$APPLIES/20260101_120000/acme_de-wartungsbericht.pdf" ]
  [[ "$output" != *"OPENED"* ]]
}

@test "report: uses the .txt verbatim — a hand edit lands in the PDF" {
  printf 'HAND EDITED LINE\n' > "$APPLIES/20260202_120000/acme_de-wartungsbericht.txt"
  cupsfilter() { cat "${@: -1}"; }
  run cmd_report acme --no-open
  [ "$status" -eq 0 ]
  grep -q 'HAND EDITED LINE' "$APPLIES/20260202_120000/acme_de-wartungsbericht.pdf"
}

@test "report: --list shows runs newest first, --apply <id> selects one" {
  run cmd_report acme --list
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 20260202_120000 ]
  [ "${lines[1]}" = 20260101_120000 ]

  run cmd_report acme --apply 20260101_120000 --no-open
  [ "$status" -eq 0 ]
  [ -f "$APPLIES/20260101_120000/acme_de-wartungsbericht.pdf" ]
}

@test "report: finds a legacy plain wartungsbericht.txt (upgrade runs)" {
  mkdir -p "$BASE/clients/acme/upgrades/20260303_120000"
  printf 'x\n' > "$BASE/clients/acme/upgrades/20260303_120000/wartungsbericht.txt"
  run cmd_report acme --upgrade 20260303_120000 --no-open
  [ "$status" -eq 0 ]
  [ -f "$BASE/clients/acme/upgrades/20260303_120000/wartungsbericht.pdf" ]
}

@test "report: unknown id and a client with no reports both fail clearly" {
  run cmd_report acme 19990101_000000 --no-open
  [ "$status" -ne 0 ]
  [[ "$output" == *"No such"* ]]

  run cmd_report ghost --no-open
  [ "$status" -ne 0 ]
  [[ "$output" == *"No applies with a report"* ]]
}
