#!/usr/bin/env bats
# `wpsite backup --all` orchestration: client selection, sequential loop, failure
# handling. The actual per-client SSH work (_backup_one_client) is stubbed.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  export WPSITE_CONFIG="$REPO/test/fixtures/wpsite.yml"   # clients: acme, baker
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_backup.sh"
  # neutralise everything that would touch the network/filesystem
  require()        { :; }
  ssh_setup_mux()  { :; }
  ssh_close_mux()  { :; }
}

@test "--all backs up every client, in config order, sequentially" {
  CALLED="$BATS_TEST_TMPDIR/called"; : > "$CALLED"
  _backup_one_client() { printf '%s\n' "$1" >> "$CALLED"; return 0; }
  run cmd_backup --all
  [ "$status" -eq 0 ]
  [ "$(tr '\n' ' ' < "$CALLED")" = "acme baker " ]
  [[ "$output" == *"Backed up all 2 client"* ]]
}

@test "--all passes the --full flag through to each client" {
  CALLED="$BATS_TEST_TMPDIR/called"; : > "$CALLED"
  _backup_one_client() { printf '%s:%s\n' "$1" "$2" >> "$CALLED"; return 0; }
  run cmd_backup --all --full
  [ "$status" -eq 0 ]
  grep -q 'acme:1' "$CALLED"
  grep -q 'baker:1' "$CALLED"
}

@test "--all keeps going after a failure and reports it (non-zero exit)" {
  _backup_one_client() { [ "$1" = acme ] && return 1 || return 0; }
  run cmd_backup --all
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed: acme"* ]]
  [[ "$output" == *"Backed up 1/2"* ]]
}

@test "single client still works (no --all)" {
  CALLED="$BATS_TEST_TMPDIR/called"; : > "$CALLED"
  _backup_one_client() { printf '%s\n' "$1" >> "$CALLED"; return 0; }
  run cmd_backup acme
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLED")" = "acme" ]
}

@test "rejects no client and no --all" {
  run cmd_backup
  [ "$status" -ne 0 ]
  [[ "$output" == *"Specify a <client>"* ]]
}

@test "rejects both a client and --all" {
  run cmd_backup acme --all
  [ "$status" -ne 0 ]
  [[ "$output" == *"not both"* ]]
}
