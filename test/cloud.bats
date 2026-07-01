#!/usr/bin/env bats
# Cloud backup sync engine: push/pull/delete reconciliation, manifest-driven
# new-vs-deleted detection, completeness gate, persist tolerance. No real Drive —
# a temp dir stands in for the mounted folder.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"

  BASE="$BATS_TEST_TMPDIR/root"
  DRIVE="$BATS_TEST_TMPDIR/drive"          # the "mounted Drive" parent
  CLOUD="$DRIVE/acme"                       # this client's cloud dir
  mkdir -p "$DRIVE"
  CFG="$BATS_TEST_TMPDIR/wpsite.yml"
  cat > "$CFG" <<EOF
base_dir: $BASE
cloud_base: $DRIVE/unused
clients:
  acme:
    ssh: u@acme
    wp_root: /var/www/acme
    cloud_dir: $CLOUD
EOF
  export WPSITE_CONFIG="$CFG"
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cloud.sh"
}

# A complete backup folder (all core artifacts) at <dir>/<id>.
mkbk() { # parent_dir id
  local d="$1/$2"; mkdir -p "$d"
  echo db > "$d/db.sql"; echo wc > "$d/wp-content.tar.gz"; echo "SOURCE_HOME=https://acme.com" > "$d/meta.env"
}
loc() { client_backup_dir acme; }   # local backups dir

@test "cloud_available: true when the Drive parent exists, false otherwise" {
  cloud_available acme                                  # $DRIVE exists
  rm -rf "$DRIVE"
  run cloud_available acme
  [ "$status" -ne 0 ]
}

@test "completeness gate: only complete backups are enumerated" {
  mkbk "$(loc)" 20260101_120000
  mkdir -p "$(loc)/20260102_120000"; echo x > "$(loc)/20260102_120000/db.sql"   # incomplete
  run _local_backup_ids acme
  [[ "$output" == *20260101_120000* ]]
  [[ "$output" != *20260102_120000* ]]
}

@test "sync: new local backup is uploaded to cloud (+ recorded in manifest)" {
  mkbk "$(loc)" 20260101_120000
  run _cloud_sync_client acme
  [ "$status" -eq 0 ]
  [ -f "$CLOUD/20260101_120000/db.sql" ]                # uploaded
  [ -d "$(loc)/20260101_120000" ]                       # local kept
  grep -qxF 20260101_120000 "$(_manifest_file acme)"
}

@test "sync: cloud-only backup is downloaded locally" {
  mkbk "$CLOUD" 20260105_120000
  run _cloud_sync_client acme
  [ "$status" -eq 0 ]
  [ -f "$(loc)/20260105_120000/db.sql" ]                # downloaded
  grep -qxF 20260105_120000 "$(_manifest_file acme)"
}

@test "sync: a backup deleted from cloud is deleted locally (manifest-driven)" {
  # Local has it AND the manifest says it was synced — but it's gone from cloud.
  mkbk "$(loc)" 20260101_120000
  mkdir -p "$(client_base acme)"; echo 20260101_120000 > "$(_manifest_file acme)"
  run _cloud_sync_client acme
  [ "$status" -eq 0 ]
  [ ! -d "$(loc)/20260101_120000" ]                     # removed locally
}

@test "sync: an offline-made backup (not in manifest, not in cloud) is uploaded, NOT deleted" {
  mkbk "$(loc)" 20260109_120000                         # no manifest entry
  run _cloud_sync_client acme
  [ "$status" -eq 0 ]
  [ -d "$(loc)/20260109_120000" ]                       # preserved
  [ -f "$CLOUD/20260109_120000/db.sql" ]                # uploaded, not deleted
}

@test "sync: incomplete cloud folder is skipped (not downloaded)" {
  mkdir -p "$CLOUD/20260106_120000"; echo x > "$CLOUD/20260106_120000/db.sql"   # incomplete
  run _cloud_sync_client acme
  [ "$status" -eq 0 ]
  [ ! -d "$(loc)/20260106_120000" ]
}

@test "sync --dry-run changes nothing on either side" {
  mkbk "$(loc)" 20260101_120000     # would upload
  mkbk "$CLOUD" 20260105_120000     # would download
  run _cloud_sync_client acme 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"would UPLOAD"* ]]
  [[ "$output" == *"would DOWNLOAD"* ]]
  [ ! -e "$CLOUD/20260101_120000" ]                     # not uploaded
  [ ! -e "$(loc)/20260105_120000" ]                     # not downloaded
  [ ! -f "$(_manifest_file acme)" ]                     # manifest untouched
}

@test "_cloud_push_one: uploads one backup + adds to manifest" {
  mkbk "$(loc)" 20260101_120000
  run _cloud_push_one acme 20260101_120000
  [ "$status" -eq 0 ]
  [ -f "$CLOUD/20260101_120000/db.sql" ]
  grep -qxF 20260101_120000 "$(_manifest_file acme)"
}

@test "_cloud_push_one: refuses an incomplete backup" {
  mkdir -p "$(loc)/20260101_120000"; echo x > "$(loc)/20260101_120000/db.sql"
  run _cloud_push_one acme 20260101_120000
  [ "$status" -ne 0 ]
  [ ! -e "$CLOUD/20260101_120000" ]
}

@test "_do_delete_backup both: removes local + cloud + manifest entry" {
  mkbk "$(loc)" 20260101_120000
  mkbk "$CLOUD" 20260101_120000
  mkdir -p "$(client_base acme)"; echo 20260101_120000 > "$(_manifest_file acme)"
  run _do_delete_backup acme 20260101_120000 both
  [ "$status" -eq 0 ]
  [ ! -e "$(loc)/20260101_120000" ]
  [ ! -e "$CLOUD/20260101_120000" ]
  run grep -qxF 20260101_120000 "$(_manifest_file acme)"
  [ "$status" -ne 0 ]
}

@test "resolve_backup_dir: a bare id resolves to its -permanent variant" {
  mkbk "$(loc)" 20260101_120000-permanent
  run resolve_backup_dir acme 20260101_120000
  [ "$output" = "$(loc)/20260101_120000-permanent" ]
}

@test "_cloud_rename mirrors a persist rename onto the cloud + manifest" {
  mkbk "$CLOUD" 20260101_120000
  mkdir -p "$(client_base acme)"; echo 20260101_120000 > "$(_manifest_file acme)"
  run _cloud_rename acme 20260101_120000 20260101_120000-permanent
  [ "$status" -eq 0 ]
  [ -d "$CLOUD/20260101_120000-permanent" ]
  [ ! -e "$CLOUD/20260101_120000" ]
  grep -qxF 20260101_120000-permanent "$(_manifest_file acme)"
}
