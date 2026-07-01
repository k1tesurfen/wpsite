#!/usr/bin/env bats
# `wpsite client add`: config write helpers, name/collision/field guards, the
# happy path, and keep-on-test-failure. SSH + `wpsite test` are stubbed (no
# network). Uses a writable temp config so client_set/yq -i can mutate it.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"

  BASE="$BATS_TEST_TMPDIR/root"
  CFG="$BATS_TEST_TMPDIR/wpsite.yml"
  cat > "$CFG" <<EOF
base_dir: $BASE
clients:
  acme:
    ssh: u@acme
    wp_root: /var/www/acme
EOF
  export WPSITE_CONFIG="$CFG"
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_new.sh"      # provides the shared _prompt helper
  source "$REPO/lib/cmd_client.sh"

  # Neutralise externals: dep checks, SSH key install, teardown, and the readiness test.
  require() { :; }
  _client_setup_ssh_key() { return 0; }
  cmd_test() { echo "TEST_RAN"; return 0; }   # marker so tests can assert it (didn't) run
  _compose_down() { :; }
  _proxy_remove_route() { :; }
  docker() { :; }
}

# --- config write helpers --------------------------------------------------

@test "client_set / client_get round-trips and config_has_client sees it" {
  client_set newco ssh u@newco
  client_set newco wp_root /var/www/newco
  run client_get newco ssh
  [ "$output" = "u@newco" ]
  run client_get newco wp_root
  [ "$output" = "/var/www/newco" ]
  run config_has_client newco
  [ "$status" -eq 0 ]
}

@test "config_remove_client deletes the entry" {
  client_set newco ssh u@newco
  config_remove_client newco
  run config_has_client newco
  [ "$status" -ne 0 ]
}

# --- add: field / name guards ----------------------------------------------

@test "client add: rejects an invalid client name" {
  run cmd_client add "Bad_Name" --ssh u@h --wp-root /var/www/x
  [ "$status" -ne 0 ]
  [[ "$output" == *Invalid* ]]
}

@test "client add: refuses a name already used by a client" {
  run cmd_client add acme --ssh u@h --wp-root /var/www/x
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "client add: refuses a name already used by a dev site" {
  dev_set myshop host myshop.test
  run cmd_client add myshop --ssh u@h --wp-root /var/www/x
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "client add: non-interactive with missing --ssh aborts (no TTY)" {
  run cmd_client add newco --wp-root /var/www/newco </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"Missing required fields"* ]]
}

@test "client add: rejects a non-absolute wp_root" {
  run cmd_client add newco --ssh u@h --wp-root relative/path
  [ "$status" -ne 0 ]
  [[ "$output" == *"absolute path"* ]]
}

@test "client add: unknown subcommand fails with usage" {
  run cmd_client frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown 'client' subcommand"* ]]
}

# --- add: happy path + optional fields -------------------------------------

@test "client add: writes required + optional fields and verifies" {
  run cmd_client add newco --ssh u@newco --wp-root /var/www/newco \
    --local-host newco-dev.test --remote-tmp '~/.wpsite_tmp' \
    --cloud-dir /drive/newco.com --keep-backups 6
  [ "$status" -eq 0 ]
  [[ "$output" == *"added and verified"* ]]

  run client_get newco ssh;          [ "$output" = "u@newco" ]
  run client_get newco wp_root;       [ "$output" = "/var/www/newco" ]
  run client_get newco local_host;    [ "$output" = "newco-dev.test" ]
  run client_get newco remote_tmp;    [ "$output" = "~/.wpsite_tmp" ]
  run client_get newco cloud_dir;     [ "$output" = "/drive/newco.com" ]
  run client_get newco keep_backups;  [ "$output" = "6" ]
}

@test "client add: omitted optionals are not written" {
  run cmd_client add newco --ssh u@newco --wp-root /var/www/newco
  [ "$status" -eq 0 ]
  run client_get newco local_host
  [ -z "$output" ]        # _yq returns empty for a missing key
}

@test "client add: --no-copy-id skips the key install" {
  # If ssh-copy-id were attempted the stub returns 0 anyway; assert the skip message.
  run cmd_client add newco --ssh u@newco --wp-root /var/www/newco --no-copy-id
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping ssh-copy-id"* ]]
}

# --- add: keep-on-failure --------------------------------------------------

@test "client add: keeps the entry when the readiness test fails" {
  cmd_test() { echo "SSH Connection: FAILED"; return 1; }
  run cmd_client add failco --ssh u@failco --wp-root /var/www/failco
  [ "$status" -eq 0 ]                      # add itself succeeds; test failure only warns
  [[ "$output" == *"test FAILED"* ]]
  run client_get failco ssh                # entry survives for the user to fix + re-test
  [ "$output" = "u@failco" ]
}

# --- _client_find_pubkey ---------------------------------------------------

@test "_client_find_pubkey: default key, explicit identity, and none" {
  home="$BATS_TEST_TMPDIR/h"; mkdir -p "$home/.ssh"; : > "$home/.ssh/id_ed25519.pub"
  HOME="$home" run _client_find_pubkey
  [ "$status" -eq 0 ]
  [ "$output" = "$home/.ssh/id_ed25519.pub" ]

  : > "$BATS_TEST_TMPDIR/mykey.pub"
  run _client_find_pubkey "$BATS_TEST_TMPDIR/mykey"   # identity without .pub suffix
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/mykey.pub" ]

  HOME="$BATS_TEST_TMPDIR/empty" run _client_find_pubkey
  [ "$status" -ne 0 ]
}

# --- _client_setup_ssh_key -------------------------------------------------

@test "_client_setup_ssh_key: empty identity does not trip set -u (bash 3.2 array)" {
  # Regression: "${idopt[@]}" on an EMPTY array errors under `set -u` on macOS bash 3.2.
  run env REPO="$REPO" bash -c 'set -euo pipefail
    source "$REPO/lib/common.sh"; source "$REPO/lib/cmd_client.sh"
    ssh() { return 1; }                    # probe fails -> fall through to ssh-copy-id
    ssh-copy-id() { echo "copied: $*"; return 0; }
    _client_setup_ssh_key u@host           # no identity -> idopt is empty
    echo __REACHED__'
  [ "$status" -eq 0 ]
  [[ "$output" == *__REACHED__* ]]
  [[ "$output" == *"copied:"* ]]
}

# --- edit ------------------------------------------------------------------

@test "client edit: changes wp_root via flag and re-tests" {
  run cmd_client edit acme --wp-root /var/www/new
  [ "$status" -eq 0 ]
  [[ "$output" == *"wp_root → /var/www/new"* ]]
  [[ "$output" == *TEST_RAN* ]]                 # connection field changed -> test runs
  run client_get acme wp_root
  [ "$output" = "/var/www/new" ]
}

@test "client edit: setting an optional field does NOT trigger a test" {
  run cmd_client edit acme --local-host acme-dev.test
  [ "$status" -eq 0 ]
  [[ "$output" == *"local_host → acme-dev.test"* ]]
  [[ "$output" != *TEST_RAN* ]]                 # no ssh/wp_root change -> skip test
}

@test "client edit: --unset clears an optional key" {
  client_set acme cloud_dir /drive/acme
  run cmd_client edit acme --unset cloud_dir --no-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"unset cloud_dir"* ]]
  run client_get acme cloud_dir
  [ -z "$output" ]
}

@test "client edit: refuses to --unset a required key" {
  run cmd_client edit acme --unset ssh
  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to unset"* ]]
}

@test "client edit: rejects a non-absolute wp_root" {
  run cmd_client edit acme --wp-root relative
  [ "$status" -ne 0 ]
  [[ "$output" == *"absolute path"* ]]
}

@test "client edit: rejects an empty ssh target" {
  run cmd_client edit acme --ssh ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot be empty"* ]]
}

@test "client edit: no-op change reports 'No changes'" {
  run cmd_client edit acme --wp-root /var/www/acme     # same as current
  [ "$status" -eq 0 ]
  [[ "$output" == *"No changes"* ]]
  [[ "$output" != *TEST_RAN* ]]
}

@test "client edit: no flags, non-interactive -> aborts" {
  run cmd_client edit acme </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"Nothing to change"* ]]
}

@test "client edit: refuses a dev site" {
  dev_set myshop host myshop.test
  run cmd_client edit myshop --wp-root /x
  [ "$status" -ne 0 ]
  [[ "$output" == *"dev site"* ]]
}

@test "client edit: unknown client fails" {
  run cmd_client edit ghost --wp-root /x
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

# --- remove ----------------------------------------------------------------

@test "client remove: --yes removes the config entry, keeps data" {
  mkdir -p "$(client_base acme)/backups"; : > "$(client_base acme)/backups/keep"
  run cmd_client remove acme --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removed client 'acme'"* ]]
  run config_has_client acme
  [ "$status" -ne 0 ]
  [ -f "$(client_base acme)/backups/keep" ]      # data kept
}

@test "client remove: --purge --yes deletes all local data" {
  mkdir -p "$(client_base acme)/backups"; : > "$(client_base acme)/backups/gone"
  run cmd_client remove acme --purge --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Purged local data"* ]]
  [ ! -d "$(client_base acme)" ]
}

@test "client remove: without --yes and no TTY defaults to abort" {
  run cmd_client remove acme </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"Aborted"* ]]
  run config_has_client acme
  [ "$status" -eq 0 ]                            # still present
}

@test "client remove: refuses a dev site (points at destroy)" {
  dev_set myshop host myshop.test
  run cmd_client remove myshop --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"wpsite destroy"* ]]
}

@test "client remove: unknown client fails" {
  run cmd_client remove ghost --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

# --- set -e regression guards for new bare-statement helpers ---------------

strict() { run env REPO="$REPO" WPSITE_CONFIG="$WPSITE_CONFIG" bash -c "set -euo pipefail
source \"\$REPO/lib/common.sh\"
$1
echo __REACHED__"; }

@test "client_set: bare statement does not abort" {
  strict 'client_set newco ssh u@newco'
  [ "$status" -eq 0 ]
  [[ "$output" == *__REACHED__* ]]
}

@test "config_remove_client: removing a non-existent entry does not abort" {
  strict 'config_remove_client nope'
  [ "$status" -eq 0 ]
  [[ "$output" == *__REACHED__* ]]
}

@test "client_unset: removing a non-existent key does not abort" {
  strict 'client_unset acme nope'
  [ "$status" -eq 0 ]
  [[ "$output" == *__REACHED__* ]]
}
