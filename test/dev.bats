#!/usr/bin/env bats
# Dev sites: config helpers (.dev section), the target resolver, name validation,
# and the new/clone command guards. Uses a writable temp config so dev_set/yq -i
# can mutate it without touching the committed fixture.

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
  source "$REPO/lib/cmd_new.sh"
  source "$REPO/lib/cmd_clone.sh"

  # Stub external requirements so command guards run without docker/yq-deps.
  require() { :; }
}

# --- config helpers --------------------------------------------------------

@test "config_dev_sites is empty (not an error) when no .dev section" {
  run config_dev_sites
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "dev_set / dev_get round-trips and config_has_dev sees it" {
  dev_set myshop host myshop.test
  dev_set myshop wp_version 6.7
  run dev_get myshop host
  [ "$output" = "myshop.test" ]
  run dev_get myshop wp_version
  [ "$output" = "6.7" ]
  run config_has_dev myshop
  [ "$status" -eq 0 ]
  run config_has_dev ghost
  [ "$status" -ne 0 ]
}

@test "config_remove_dev deletes the entry" {
  dev_set myshop host myshop.test
  config_remove_dev myshop
  run config_has_dev myshop
  [ "$status" -ne 0 ]
}

@test "config_all_targets lists clients + dev sites" {
  dev_set myshop host myshop.test
  run config_all_targets
  [[ "$output" == *acme* ]]
  [[ "$output" == *myshop* ]]
}

# --- resolver --------------------------------------------------------------

@test "target_kind: client vs dev vs unknown" {
  dev_set myshop host myshop.test
  run target_kind acme
  [ "$output" = "client" ]
  run target_kind myshop
  [ "$output" = "dev" ]
  run target_kind ghost
  [ -z "$output" ]
}

@test "target_local_host: stored host, then <name>.test fallback" {
  dev_set myshop host custom-dev.test
  run target_local_host myshop
  [ "$output" = "custom-dev.test" ]
  dev_set hostless wp_version 6.7      # entry exists but no host key
  run target_local_host hostless
  [ "$output" = "hostless.test" ]
}

@test "target_docker_dir resolves per kind" {
  dev_set myshop host myshop.test
  run target_docker_dir acme
  [ "$output" = "$BASE/clients/acme/docker" ]
  run target_docker_dir myshop
  [ "$output" = "$BASE/dev/myshop/docker" ]
}

# --- command guards --------------------------------------------------------

@test "new: rejects an invalid site name" {
  run cmd_new "Bad_Name"
  [ "$status" -ne 0 ]
  [[ "$output" == *Invalid* ]]
}

@test "new: refuses a name already used by a client" {
  run cmd_new acme
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "new: refuses a name already used by a dev site" {
  dev_set myshop host myshop.test
  run cmd_new myshop
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "clone: refuses an unknown source client" {
  run cmd_clone ghost myshop
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "clone: refuses a devname that already exists" {
  dev_set myshop host myshop.test
  run cmd_clone acme myshop
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "clone: rejects --light and --full together" {
  run cmd_clone acme myshop --light --full
  [ "$status" -ne 0 ]
  [[ "$output" == *"not both"* ]]
}

# --- set -e regression guards for new bare-statement helpers ---------------

strict() { run env REPO="$REPO" WPSITE_CONFIG="$WPSITE_CONFIG" bash -c "set -euo pipefail
source \"\$REPO/lib/common.sh\"
source \"\$REPO/lib/cmd_list.sh\"
$1
echo __REACHED__"; }

@test "_ensure_base_layout: bare statement does not abort" {
  strict '_ensure_base_layout'
  [ "$status" -eq 0 ]
  [[ "$output" == *__REACHED__* ]]
}

@test "_list_dev_sites: no dev section, bare statement does not abort" {
  strict '_list_dev_sites'
  [ "$status" -eq 0 ]
  [[ "$output" == *__REACHED__* ]]
}

@test "config_remove_dev: removing a non-existent entry does not abort" {
  strict 'config_remove_dev nope'
  [ "$status" -eq 0 ]
  [[ "$output" == *__REACHED__* ]]
}
