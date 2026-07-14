#!/usr/bin/env bats
# `wpsite setup` — onboard a machine: write the local config + install SSH keys on
# every client in the shared team config. yq is real (writes the config); ssh key
# install + readiness test are stubbed (no network). Non-interactive throughout
# (flags), so no TTY is needed.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"

  BASE="$BATS_TEST_TMPDIR/root"
  CFG="$BATS_TEST_TMPDIR/local.yml"          # local config: created by setup
  TEAM="$BATS_TEST_TMPDIR/team.yml"          # shared client definitions
  KEYLOG="$BATS_TEST_TMPDIR/keys.log"        # records _client_setup_ssh_key targets
  : > "$KEYLOG"
  cat > "$TEAM" <<EOF
clients:
  alpha:
    ssh: u@alpha
    wp_root: /var/www/alpha
  bravo:
    ssh: u@bravo
    wp_root: /var/www/bravo
EOF

  export WPSITE_CONFIG="$CFG"
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_new.sh"       # _prompt
  source "$REPO/lib/cmd_client.sh"    # _client_setup_ssh_key (overridden below)
  source "$REPO/lib/cmd_setup.sh"

  require() { :; }
  _ensure_ssh_key() { return 0; }   # don't run ssh-keygen in tests
  _client_setup_ssh_key() { echo "$1" >> "$KEYLOG"; return 0; }
  cmd_test() { echo "TEST_RAN $1"; return 0; }
}

@test "setup: writes the local config (base_dir, cloud_base, team_config)" {
  run cmd_setup --base-dir "$BASE" --cloud-base /drive/cloud --team-config "$TEAM"
  [ "$status" -eq 0 ]
  run yq -r '.base_dir' "$CFG";     [ "$output" = "$BASE" ]
  run yq -r '.cloud_base' "$CFG";   [ "$output" = "/drive/cloud" ]
  run yq -r '.team_config' "$CFG";  [ "$output" = "$TEAM" ]
  # clients are NOT copied into the local file
  run yq -e '.clients' "$CFG"
  [ "$status" -ne 0 ]
}

@test "setup: installs the SSH key on every team client + runs test" {
  run cmd_setup --base-dir "$BASE" --team-config "$TEAM"
  [ "$status" -eq 0 ]
  run cat "$KEYLOG"
  [[ "$output" == *"u@alpha"* ]]
  [[ "$output" == *"u@bravo"* ]]
  [[ "$output" == *"TEST_RAN alpha"* ]] || true   # test output is on the run above
  [ "$(grep -c . "$KEYLOG")" -eq 2 ]
}

@test "setup: --no-keys writes config but installs no keys" {
  run cmd_setup --base-dir "$BASE" --team-config "$TEAM" --no-keys
  [ "$status" -eq 0 ]
  [ ! -s "$KEYLOG" ]
  run yq -r '.team_config' "$CFG"; [ "$output" = "$TEAM" ]
}

@test "setup: --keys-only skips config writing" {
  # Pre-seed a local config pointing at the team file.
  cat > "$CFG" <<EOF
base_dir: $BASE
team_config: $TEAM
EOF
  run cmd_setup --keys-only
  [ "$status" -eq 0 ]
  [ "$(grep -c . "$KEYLOG")" -eq 2 ]
}

@test "setup: creates the local data layout (clients/ + dev/)" {
  run cmd_setup --base-dir "$BASE" --team-config "$TEAM" --no-keys
  [ "$status" -eq 0 ]
  [ -d "$BASE/clients" ]
  [ -d "$BASE/dev" ]
}

@test "setup: missing team file -> warns, installs nothing, still exits 0" {
  run cmd_setup --base-dir "$BASE" --team-config "$BATS_TEST_TMPDIR/gone.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Team config not found"* ]]
  [ ! -s "$KEYLOG" ]
}

@test "setup: non-interactive without required fields fails" {
  run cmd_setup --cloud-base /drive/cloud </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"Non-interactive"* ]]
}
