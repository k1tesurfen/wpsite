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

@test "client_get reads optional remote_tmp (set vs unset)" {
  run client_get baker remote_tmp
  [ "$output" = "~/.wpsite_tmp" ]
  run client_get acme remote_tmp
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

@test "client_local_host dynamically extracts from meta.env when backup exists" {
  local d
  d="$(client_backup_dir acme)/20260101_120000"
  mkdir -p "$d"
  echo "SOURCE_HOME=https://www.buy-my-site.co.uk" > "$d/meta.env"
  
  run client_local_host acme
  [ "$output" = "buy-my-site.test" ]
  
  # Clean up the mocked backup directory
  rm -rf "$(client_base acme)"
}

@test "_local_host_from_url parses complex URLs" {
  run _local_host_from_url "https://buy-my-site.de"
  [ "$output" = "buy-my-site.test" ]
  run _local_host_from_url "http://sub.domain.co.uk/some/path?query=1"
  [ "$output" = "sub.domain.test" ]
  run _local_host_from_url "https://www.example.com"
  [ "$output" = "example.test" ]
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

@test "derived client dirs are under base_dir/clients" {
  run client_backup_dir acme
  [ "$output" = "$HOME/wpsite-test-root/clients/acme/backups" ]
  run client_docker_dir acme
  [ "$output" = "$HOME/wpsite-test-root/clients/acme/docker" ]
}

@test "dev dirs are under base_dir/dev (no backups)" {
  run dev_base myshop
  [ "$output" = "$HOME/wpsite-test-root/dev/myshop" ]
  run dev_docker_dir myshop
  [ "$output" = "$HOME/wpsite-test-root/dev/myshop/docker" ]
}

@test "target_kind classifies clients (dev resolved in dev.bats)" {
  run target_kind acme
  [ "$output" = "client" ]
  run target_kind ghost
  [ -z "$output" ]
}

@test "config_cloud_base expands ~/" {
  run config_cloud_base
  [ "$output" = "$HOME/wpsite-cloud" ]
}

@test "keep_backups: global default + per-client override" {
  run config_keep_backups
  [ "$output" = "3" ]
  run client_keep_backups baker     # explicit override
  [ "$output" = "6" ]
  run client_keep_backups acme      # inherits global
  [ "$output" = "3" ]
}

@test "client_cloud_dir: explicit override is used verbatim" {
  run client_cloud_dir baker
  [ "$output" = "/Volumes/Drive/clients/baker-final.com" ]
}

@test "client_cloud_dir: default is <cloud_base>/<production-domain>" {
  local d
  d="$(client_backup_dir acme)/20260101_120000"
  mkdir -p "$d"
  echo "SOURCE_HOME=https://www.acme-corp.com/foo" > "$d/meta.env"
  run client_cloud_dir acme
  [ "$output" = "$HOME/wpsite-cloud/acme-corp.com" ]
  run _cloud_domain_from_meta acme
  [ "$output" = "acme-corp.com" ]
  rm -rf "$(client_base acme)"
}

@test "_valid_site_name accepts dns-safe names, rejects others" {
  _valid_site_name my-shop
  _valid_site_name shop123
  run bash -c "source '$REPO/lib/common.sh'; _valid_site_name 'Bad_Name'"
  [ "$status" -ne 0 ]
  run bash -c "source '$REPO/lib/common.sh'; _valid_site_name '-lead'"
  [ "$status" -ne 0 ]
  run bash -c "source '$REPO/lib/common.sh'; _valid_site_name ''"
  [ "$status" -ne 0 ]
}
