#!/usr/bin/env bats
# The registry split (HARDENING-PLAN.md Phase 1): mandos holds ACCESS only (ssh, wp_root,
# cloud_folder); wpsite keeps its own file for everything WordPress. Two SEPARATE files
# here — MANDOS (served by the mandos stub) and WTEAM (wpsite's registry) — so a test
# can't pass by accident because both read the same fixture.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"

  BASE="$BATS_TEST_TMPDIR/root"
  CFG="$BATS_TEST_TMPDIR/wpsite.yml"
  MANDOS="$BATS_TEST_TMPDIR/drive/01_Global/mandos/mandos.team.yml"
  WTEAM="$BATS_TEST_TMPDIR/drive/01_Global/wpsite/wpsite.team.yml"
  mkdir -p "$(dirname "$MANDOS")" "$(dirname "$WTEAM")"
  printf 'base_dir: %s\n' "$BASE" > "$CFG"
  cat > "$MANDOS" <<EOF
clients:
  acme:
    ssh: u@acme
    wp_root: /var/www/acme
  newco:
    ssh: u@newco
    wp_root: /var/www/newco
    remote_tmp: ~/.wpsite_tmp
    login_path: /geheim
EOF
  cat > "$WTEAM" <<EOF
# team comment that must survive edits
clients:
  acme:
    registered: 2026-01-01
    deactivate_plugins:
      - some-prod-plugin
  orphan:
    registered: 2026-01-01
EOF
  export WPSITE_CONFIG="$CFG"
  export MANDOS_BIN="$REPO/test/fixtures/mandos-stub" MANDOS_STUB_CONFIG="$MANDOS"
  unset WPSITE_TEAM_CONFIG
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_forget.sh"
  source "$REPO/lib/cmd_hold.sh"
  source "$REPO/lib/cmd_migrate.sh"
  require() { :; }
  _compose_down() { :; }; _proxy_remove_route() { :; }; docker() { :; }
}

# --- location ------------------------------------------------------------------------

@test "location: derived next to mandos's team file (…/mandos/ → …/wpsite/)" {
  [ "$(wpsite_team_file)" = "$WTEAM" ]
}

@test "location: team_config in the local config, then WPSITE_TEAM_CONFIG, override it" {
  yq -i '.team_config = "/elsewhere/w.yml"' "$CFG"
  [ "$(wpsite_team_file)" = "/elsewhere/w.yml" ]
  WPSITE_TEAM_CONFIG=/env/w.yml; [ "$(wpsite_team_file)" = "/env/w.yml" ]
}

@test "wteam_require: unreachable file is a hard error, never 'empty'" {
  WPSITE_TEAM_CONFIG="$BATS_TEST_TMPDIR/unmounted/x/w.yml"
  run wteam_require
  [ "$status" -ne 0 ]; [[ "$output" == *"not reachable"* ]]
  WPSITE_TEAM_CONFIG="$BATS_TEST_TMPDIR/drive/01_Global/wpsite/missing.yml"
  run wteam_require
  [ "$status" -ne 0 ]; [[ "$output" == *"migrate-registry"* ]]
}

# --- the two registries --------------------------------------------------------------

@test "clients = wpsite's registry; access = mandos; they are independent" {
  run config_clients;  [ "$output" = $'acme\norphan' ]
  run access_clients;  [ "$output" = $'acme\nnewco' ]
  config_has_client orphan; ! access_has orphan      # in wpsite, no access
  access_has newco; ! config_has_client newco        # access, not in wpsite yet
}

@test "wclient_get: scalars, lists one per line, missing → empty" {
  [ "$(wclient_get acme registered)" = "2026-01-01" ]
  [ "$(wclient_get acme deactivate_plugins)" = "some-prod-plugin" ]
  [ -z "$(wclient_get acme nope)" ]; [ -z "$(wclient_get zed registered)" ]
}

@test "WordPress keys are read from wpsite, NOT from mandos" {
  wclient_register newco
  [ -z "$(wclient_get newco remote_tmp)" ]           # only in mandos → invisible to wpsite
  wclient_set newco remote_tmp "~/w"
  [ "$(wclient_get newco remote_tmp)" = "~/w" ]
}

@test "writes keep comments and refuse when the Drive is unmounted" {
  wclient_map_set acme hold_plugins acf "Pro"
  grep -q '# team comment that must survive edits' "$WTEAM"
  WPSITE_TEAM_CONFIG="$BATS_TEST_TMPDIR/unmounted/w.yml"
  run wclient_set acme x y
  [ "$status" -ne 0 ]; [[ "$output" == *"Google Drive"* ]]
}

@test "require_client: unknown-but-in-mandos points at backup; unknown everywhere says so" {
  run require_client newco
  [ "$status" -ne 0 ]; [[ "$output" == *"wpsite backup newco"* ]]
  run require_client ghost
  [ "$status" -ne 0 ]; [[ "$output" == *"neither in wpsite nor in mandos"* ]]
  require_client acme
}

@test "require_access: a wpsite client without mandos access is refused for production" {
  run require_access orphan
  [ "$status" -ne 0 ]; [[ "$output" == *"No production access"* ]]
}

@test "_name_taken: wpsite client, dev site, or mandos-only ID are all taken" {
  yq -i '.dev.sandbox.host = "sandbox.test"' "$CFG"
  _name_taken acme; _name_taken sandbox; _name_taken newco
  ! _name_taken fresh
}

# --- backup is the ONLY registration path ------------------------------------------

@test "backup: a mandos-only client is registered after its first successful backup" {
  source "$REPO/lib/cmd_backup.sh"
  ssh_setup_mux() { :; }; ssh_close_mux() { :; }; _backup_cleanup() { :; }
  _backup_one_client() { return 0; }
  run cmd_backup newco
  [ "$status" -eq 0 ]; [[ "$output" == *"Registered 'newco'"* ]]
  config_has_client newco
}

@test "backup: a FAILED first backup does not register the client" {
  source "$REPO/lib/cmd_backup.sh"
  ssh_setup_mux() { :; }; ssh_close_mux() { :; }; _backup_cleanup() { :; }
  _backup_one_client() { return 1; }
  run cmd_backup newco
  [ "$status" -ne 0 ]
  ! config_has_client newco
}

@test "backup: an ID unknown to both registries is refused" {
  source "$REPO/lib/cmd_backup.sh"
  run cmd_backup ghost
  [ "$status" -ne 0 ]; [[ "$output" == *"neither in wpsite nor in mandos"* ]]
}

# --- forget ----------------------------------------------------------------------------

@test "forget --yes: drops the wpsite entry, keeps backups, leaves mandos alone" {
  mkdir -p "$(client_base acme)/backups"; : > "$(client_base acme)/backups/keep"
  run cmd_forget acme --yes
  [ "$status" -eq 0 ]; [[ "$output" == *"mandos access unchanged"* ]]
  ! config_has_client acme
  access_has acme                                      # mandos untouched
  [ -f "$(client_base acme)/backups/keep" ]
}

@test "forget --purge --yes deletes local data" {
  mkdir -p "$(client_base acme)/backups"
  run cmd_forget acme --purge --yes
  [ "$status" -eq 0 ]; [ ! -d "$(client_base acme)" ]
}

@test "forget without --yes and no TTY aborts; dev sites and unknowns are refused" {
  run cmd_forget acme </dev/null
  [[ "$output" == *"Aborted"* ]]; config_has_client acme
  yq -i '.dev.sandbox.host = "sandbox.test"' "$CFG"
  run cmd_forget sandbox --yes; [ "$status" -ne 0 ]; [[ "$output" == *"wpsite destroy"* ]]
  run cmd_forget ghost --yes;   [ "$status" -ne 0 ]
}

# --- hold / manual / show --------------------------------------------------------------

@test "hold: add with reason, list, remove" {
  run cmd_hold acme advanced-custom-fields-pro --reason "Pro, Lizenz beim Kunden"
  [ "$status" -eq 0 ]
  run cmd_hold acme
  [[ "$output" == *"advanced-custom-fields-pro"*"Pro, Lizenz beim Kunden ("*")"* ]]
  cmd_hold acme advanced-custom-fields-pro --remove
  ! wclient_map_has acme hold_plugins advanced-custom-fields-pro
}

@test "hold: invalid slug, unregistered client, and an unreachable registry are refused" {
  run cmd_hold acme 'bad slug';   [ "$status" -ne 0 ]
  run cmd_hold newco some-plugin; [ "$status" -ne 0 ]; [[ "$output" == *"wpsite backup newco"* ]]
  WPSITE_TEAM_CONFIG="$BATS_TEST_TMPDIR/unmounted/w.yml"
  run cmd_hold acme x;            [ "$status" -ne 0 ]
}

@test "manual: a separate list from hold" {
  cmd_manual acme greyd_suite --reason "nur in wp-admin sichtbar"
  wclient_map_has acme manual_updates greyd_suite
  ! wclient_map_has acme hold_plugins greyd_suite
}

@test "show: access from mandos + wpsite settings + lists; one key porcelain" {
  cmd_hold acme acf --reason Pro
  run cmd_show acme
  [[ "$output" == *"u@acme"* ]]; [[ "$output" == *"some-prod-plugin"* ]]; [[ "$output" == *"acf"* ]]
  run cmd_show acme ssh;               [ "$output" = "u@acme" ]
  run cmd_show acme deactivate_plugins; [ "$output" = "some-prod-plugin" ]
  run cmd_show orphan
  [[ "$output" == *"no production access"* ]]
}

# --- migration -------------------------------------------------------------------------

@test "migrate-registry: dry run changes nothing and lists exactly the plan" {
  local before; before="$(cat "$MANDOS" "$WTEAM")"
  run cmd_migrate_registry
  [ "$status" -eq 0 ]
  [[ "$output" == *"Register in wpsite (1): newco"* ]]
  [[ "$output" == *"newco: remote_tmp = ~/.wpsite_tmp"* ]]
  [[ "$output" == *"newco: login_path = /geheim"* ]]
  [ "$(cat "$MANDOS" "$WTEAM")" = "$before" ]
}

@test "migrate-registry --apply: moves WP keys, keeps access in mandos, is idempotent" {
  run cmd_migrate_registry --apply
  [ "$status" -eq 0 ]
  config_has_client newco
  [ "$(wclient_get newco remote_tmp)" = "~/.wpsite_tmp" ]
  [ "$(wclient_get newco login_path)" = "/geheim" ]
  [ -z "$(client_get newco remote_tmp)" ]; [ -z "$(client_get newco login_path)" ]
  [ "$(client_get newco ssh)" = "u@newco" ]            # access stays in mandos
  run cmd_migrate_registry --apply
  [[ "$output" == *"Nothing to migrate"* ]]
}

@test "migrate-registry --apply creates wpsite's file when only its parent exists" {
  rm -rf "$(dirname "$WTEAM")"
  run cmd_migrate_registry --apply
  [ "$status" -eq 0 ]; [ -f "$WTEAM" ]
  [ "$(config_clients | tr '\n' ' ')" = "acme newco " ]
}

@test "migrate-registry: drops stale access copies from a pre-mandos wpsite file, with a backup" {
  yq -i '.clients.acme.ssh = "u@acme" | .clients.acme.wp_root = "/var/www/acme" | .clients.orphan.ssh = "u@orphan"' "$WTEAM"
  run cmd_migrate_registry
  [[ "$output" == *"acme.ssh"* ]]; [[ "$output" == *"acme.wp_root"* ]]
  [[ "$output" == *"orphan is NOT in mandos"* ]]                   # never drop what mandos lacks
  run cmd_migrate_registry --apply
  [ "$status" -eq 0 ]
  [ -z "$(wclient_get acme ssh)" ]; [ -z "$(wclient_get acme wp_root)" ]
  [ "$(wclient_get acme deactivate_plugins)" = "some-prod-plugin" ]  # WP data kept
  [ "$(wclient_get orphan ssh)" = "u@orphan" ]
  ls "$WTEAM".pre-split-* >/dev/null
  head -1 "$WTEAM" | grep -q 'wpsite client registry'
}

@test "list --unregistered: mandos IDs not yet in wpsite (for the GUI's first backup)" {
  source "$REPO/lib/cmd_list.sh"
  run cmd_list --unregistered
  [ "$status" -eq 0 ]; [ "$output" = "newco" ]
  run cmd_list --names
  [ "$output" = $'acme\norphan' ]
}
