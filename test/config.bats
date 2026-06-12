#!/usr/bin/env bats
# Config helpers against a fixture wpsite.yml (requires mikefarah yq).

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  export WPSITE_CONFIG="$REPO/test/fixtures/wpsite.yml"
  source "$REPO/lib/common.sh"
}

@test "config_base_dir expands ~/" {
  run config_base_dir
  [ "$output" = "$HOME/wpsite-test-root" ]
}

@test "config_clients lists every client" {
  run config_clients
  [[ "$output" == *acme* ]]
  [[ "$output" == *baker* ]]
}

@test "client_get reads nested keys" {
  run client_get acme ssh
  [ "$output" = "ubuntu@acme.example" ]
  run client_get baker wp_root
  [ "$output" = "/var/www/html" ]
}

@test "client_get missing key is empty (not the literal 'null')" {
  run client_get acme local_host
  [ -z "$output" ]
}

@test "client_local_host defaults to <client>.test" {
  run client_local_host acme
  [ "$output" = "acme.test" ]
}

@test "client_local_host honors an override" {
  run client_local_host baker
  [ "$output" = "baker-custom.test" ]
}

@test "config_has_client: true for known, false for unknown" {
  run config_has_client acme
  [ "$status" -eq 0 ]
  run config_has_client ghost
  [ "$status" -ne 0 ]
}

@test "client_get reads a list value (deactivate_plugins)" {
  run client_get baker deactivate_plugins
  [[ "$output" == *some-prod-plugin* ]]
}

@test "derived backup/docker dirs are under base_dir" {
  run client_backup_dir acme
  [ "$output" = "$HOME/wpsite-test-root/acme/backups" ]
  run client_docker_dir acme
  [ "$output" = "$HOME/wpsite-test-root/acme/docker" ]
}
