#!/usr/bin/env bats
# `wpsite apply` (production) orchestration. EVERYTHING that touches a server/network
# is stubbed — no SSH, no production. Verifies guards + step sequencing only.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  export WPSITE_CONFIG="$REPO/test/fixtures/wpsite.yml"   # acme: ssh/wp_root set
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
  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  # default prod wp stub: record commands, answer the read-only ones
  _prod_wp() {
    shift 2; printf '%s\n' "$*" >> "$CALLS"
    case "$*" in
      *"core version"*)   echo "6.5" ;;
      *"option get home"*) echo "https://acme.example" ;;
      *list*)             echo "name,version,update" ;;
    esac
  }
}

@test "apply: aborts and runs NOTHING when confirmation fails" {
  _confirm_prod() { return 1; }
  _backup_one_client() { echo BACKUP_RAN >> "$CALLS"; return 0; }
  run cmd_apply acme
  [ "$status" -ne 0 ]
  [[ "$output" == *"Aborted"* ]]
  ! grep -q BACKUP_RAN "$CALLS"
}

@test "apply: refuses to upgrade if the fresh backup fails" {
  _backup_one_client() { return 1; }
  run cmd_apply acme
  [ "$status" -ne 0 ]
  [[ "$output" == *"without a rollback point"* ]]
  ! grep -q 'core update' "$CALLS"   # never reached the upgrade
}

@test "apply: happy path runs the full prod sequence + verifies 200" {
  _backup_one_client() { return 0; }
  run cmd_apply acme
  [ "$status" -eq 0 ]
  grep -q 'maintenance-mode activate' "$CALLS"
  grep -q 'core update'               "$CALLS"
  grep -q 'core update-db'            "$CALLS"
  grep -q 'plugin update --all'       "$CALLS"
  grep -q 'theme update --all'        "$CALLS"
  grep -q 'maintenance-mode deactivate' "$CALLS"
  [[ "$output" == *"Production upgraded"* ]]
}

@test "apply: always deactivates maintenance mode + flags rollback on non-200" {
  _backup_one_client() { return 0; }
  curl() { echo 502; }
  run cmd_apply acme
  [ "$status" -ne 0 ]
  grep -q 'maintenance-mode deactivate' "$CALLS"   # site not left stranded
  [[ "$output" == *"Rollback point"* ]]
}
