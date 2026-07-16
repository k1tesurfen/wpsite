#!/usr/bin/env bats
# Config helpers against a fixture wpsite.yml (requires mikefarah yq).

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  export WPSITE_CONFIG="$REPO/test/fixtures/wpsite.yml"
  # The client registry + cloud_base now come from `mandos`; in tests we point
  # MANDOS_BIN at a stub that serves them from MANDOS_STUB_CONFIG (defaults to
  # WPSITE_CONFIG — so the fixture's clients:/cloud_base: are served transparently).
  export MANDOS_BIN="$REPO/test/fixtures/mandos-stub"
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

@test "keep_backups: fixed constant of 5, not configurable" {
  # Retention is a fixed team policy — config values are ignored, even a per-client
  # keep_backups (baker: 6 in the fixture) or a global one.
  run config_keep_backups
  [ "$output" = "5" ]
  run client_keep_backups baker
  [ "$output" = "5" ]
  run client_keep_backups acme
  [ "$output" = "5" ]
}

@test "client_cloud_dir: explicit override is used verbatim" {
  run client_cloud_dir baker
  [ "$output" = "/Volumes/Drive/clients/baker-final.com" ]
}

@test "client_cloud_dir: cloud_folder overrides the derived domain (portable)" {
  local cfg="$BATS_TEST_TMPDIR/cf.yml"
  cat > "$cfg" <<YAML
base_dir: $BATS_TEST_TMPDIR/root
cloud_base: $BATS_TEST_TMPDIR/cloud
clients:
  greyda:
    ssh: u@g
    wp_root: /var/www/g
    cloud_folder: greyder-live.de
YAML
  WPSITE_CONFIG="$cfg"
  # A backup exists with a STAGING domain that must be ignored in favour of cloud_folder.
  local d; d="$(client_backup_dir greyda)/20260101_120000"; mkdir -p "$d"
  echo "SOURCE_HOME=https://greyd.artismedia.de/" > "$d/meta.env"
  run client_cloud_dir greyda
  [ "$output" = "$BATS_TEST_TMPDIR/cloud/greyder-live.de/100_Backup" ]
}

@test "cloud_available: requires the domain project folder to pre-exist" {
  # Self-contained config so we never touch the real cloud_base.
  local cfg="$BATS_TEST_TMPDIR/cl.yml"
  cat > "$cfg" <<YAML
base_dir: $BATS_TEST_TMPDIR/root
cloud_base: $BATS_TEST_TMPDIR/cloud
clients:
  acme:
    ssh: u@a
    wp_root: /var/www/a
YAML
  WPSITE_CONFIG="$cfg"
  local d; d="$(client_backup_dir acme)/20260101_120000"; mkdir -p "$d"
  echo "SOURCE_HOME=https://acme-corp.com/" > "$d/meta.env"

  run client_cloud_dir acme
  [ "$output" = "$BATS_TEST_TMPDIR/cloud/acme-corp.com/100_Backup" ]

  # Drive/domain folder absent → not available (wpsite must NOT create it).
  run cloud_available acme
  [ "$status" -ne 0 ]

  # Once the domain project folder exists, it's available (100_Backup gets created
  # by the push, inside the existing project folder).
  mkdir -p "$BATS_TEST_TMPDIR/cloud/acme-corp.com"
  run cloud_available acme
  [ "$status" -eq 0 ]
}

@test "client_cloud_dir: default is <cloud_base>/<domain>/100_Backup" {
  local d
  d="$(client_backup_dir acme)/20260101_120000"
  mkdir -p "$d"
  echo "SOURCE_HOME=https://www.acme-corp.com/foo" > "$d/meta.env"
  run client_cloud_dir acme
  [ "$output" = "$HOME/wpsite-cloud/acme-corp.com/100_Backup" ]
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

# NOTE: the two-layer local/team routing (team-file resolution, unreachable-Drive
# degrade, solo fallback) moved OUT of wpsite into mandos, so those tests live with
# mandos now. Here we only verify wpsite's adapters read/write via the mandos stub.

@test "list --names: machine-readable client names, one per line" {
  source "$REPO/lib/cmd_list.sh"
  run cmd_list --names
  [ "$status" -eq 0 ]
  [[ "$output" == *acme* ]]
  [[ "$output" == *baker* ]]
  # no table header (that goes to the human listing, not --names)
  [[ "$output" != *CLIENT* ]]
  [[ "$output" != *BACKUPS* ]]
}

@test "keep_backups fixed: config values in the fixture are ignored" {
  # (defends the constant even if someone re-adds a keep_backups key anywhere)
  run config_keep_backups
  [ "$output" = "5" ]
}
