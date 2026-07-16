#!/usr/bin/env bats
# `wpsite setup` — onboard a machine: write the wpsite local config (`base_dir` only),
# point mandos at the shared registry (`mandos config init`), and install SSH keys on
# every client. mandos is the stub (test/fixtures/mandos-stub): `config init` is recorded
# to MANDOS_STUB_INITLOG, `client setup-key <name>` to MANDOS_STUB_KEYLOG, and the client
# list is served from MANDOS_STUB_CONFIG (the TEAM file). Non-interactive throughout.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"

  BASE="$BATS_TEST_TMPDIR/root"
  CFG="$BATS_TEST_TMPDIR/local.yml"          # wpsite local config: created by setup
  TEAM="$BATS_TEST_TMPDIR/team.yml"          # shared client registry (mandos team file)
  KEYLOG="$BATS_TEST_TMPDIR/keys.log"        # stub records `client setup-key <name>` here
  INITLOG="$BATS_TEST_TMPDIR/init.log"       # stub records `config init …` here
  : > "$KEYLOG"; : > "$INITLOG"
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
  export MANDOS_BIN="$REPO/test/fixtures/mandos-stub"
  export MANDOS_STUB_CONFIG="$TEAM"          # stub serves clients + config get from here
  export MANDOS_STUB_KEYLOG="$KEYLOG" MANDOS_STUB_INITLOG="$INITLOG"
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_new.sh"       # _prompt
  source "$REPO/lib/cmd_client.sh"    # _client_setup_ssh_key (→ mandos client setup-key)
  source "$REPO/lib/cmd_setup.sh"

  require() { :; }
  cmd_test() { echo "TEST_RAN $1"; return 0; }
}

@test "setup: writes only base_dir to the wpsite config, delegates the rest to mandos" {
  run cmd_setup --base-dir "$BASE" --cloud-base /drive/cloud --team-config "$TEAM"
  [ "$status" -eq 0 ]
  # wpsite config: base_dir only — NOT team_config / cloud_base (those are mandos's now).
  run yq -r '.base_dir' "$CFG";  [ "$output" = "$BASE" ]
  run yq -e '.team_config' "$CFG"; [ "$status" -ne 0 ]
  run yq -e '.cloud_base' "$CFG";  [ "$status" -ne 0 ]
  # mandos was configured via `config init` with the team file + cloud base.
  run cat "$INITLOG"
  [[ "$output" == *"--team-config $TEAM"* ]]
  [[ "$output" == *"--cloud-base /drive/cloud"* ]]
}

@test "setup: installs the SSH key on every client (via mandos) + runs test" {
  run cmd_setup --base-dir "$BASE" --team-config "$TEAM"
  [ "$status" -eq 0 ]
  run cat "$KEYLOG"
  [[ "$output" == *alpha* ]]
  [[ "$output" == *bravo* ]]
  [ "$(grep -c . "$KEYLOG")" -eq 2 ]
}

@test "setup: --no-keys configures but installs no keys" {
  run cmd_setup --base-dir "$BASE" --team-config "$TEAM" --no-keys
  [ "$status" -eq 0 ]
  [ ! -s "$KEYLOG" ]
  run yq -r '.base_dir' "$CFG"; [ "$output" = "$BASE" ]
  [ -s "$INITLOG" ]                     # mandos config init still ran
}

@test "setup: --keys-only skips config writing + mandos init" {
  printf 'base_dir: %s\n' "$BASE" > "$CFG"   # pre-existing wpsite config
  run cmd_setup --keys-only
  [ "$status" -eq 0 ]
  [ "$(grep -c . "$KEYLOG")" -eq 2 ]
  [ ! -s "$INITLOG" ]                   # no `config init` on --keys-only
}

@test "setup: creates the local data layout (clients/ + dev/)" {
  run cmd_setup --base-dir "$BASE" --team-config "$TEAM" --no-keys
  [ "$status" -eq 0 ]
  [ -d "$BASE/clients" ]
  [ -d "$BASE/dev" ]
}

@test "setup: registry unreachable -> warns, installs nothing, still exits 0" {
  export MANDOS_STUB_CONFIG="$BATS_TEST_TMPDIR/gone.yml"   # team file doesn't exist
  run cmd_setup --base-dir "$BASE" --team-config "$BATS_TEST_TMPDIR/gone.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not found"* ]]
  [ ! -s "$KEYLOG" ]
}

@test "setup: non-interactive without required fields fails" {
  run cmd_setup --cloud-base /drive/cloud </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"Non-interactive"* ]]
}
