#!/usr/bin/env bats
# apply's preflight gate (HARDENING-PLAN.md Phase 3): everything that could otherwise only
# fail once maintenance is on is checked BEFORE the backup and the confirmation. A local
# directory stands in for the server (wpsite_ssh runs there); wp-cli and curl are stubbed.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  CFG="$BATS_TEST_TMPDIR/wpsite.yml"
  printf 'base_dir: %s/root\nclients:\n  acme:\n    remote_tmp: %s/stage\n' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > "$CFG"
  export WPSITE_CONFIG="$CFG" WPSITE_TEAM_CONFIG="$CFG" MANDOS_STUB_CONFIG="$CFG"
  export MANDOS_BIN="$REPO/test/fixtures/mandos-stub"
  source "$REPO/lib/common.sh"
  for f in cmd_backup.sh cmd_build.sh cmd_upgrade.sh cmd_apply.sh; do source "$REPO/lib/$f"; done
  ROOT="$BATS_TEST_TMPDIR/server"; mkdir -p "$ROOT/wp-content/plugins" "$ROOT/wp-content/themes"
  wpsite_ssh() { shift; bash -c "$1"; }
  HOME_CODE=200; DL="HTTP 200"; PKG="https://x/a.zip"
  curl() { local o=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && o="$2"; shift; done; printf 'ok' > "$o"; printf '%s' "$HOME_CODE"; }
  _prod_wp() {
    shift 2
    case "$*" in
      *"core is-installed"*) : ;;
      *WPSITE_BOOT_OK*)      echo WPSITE_BOOT_OK ;;
      *"option get home"*)   echo "https://acme.example" ;;
      *wp_remote_head*)      echo "$DL" ;;
      *update_package*)      printf 'name,version,update,update_version,update_package\nacf-pro,6.3,available,6.8,%s\nwp-staging-pro,6.7,available,6.8,x\nfresh,1.0,none,,\n' "$PKG" ;;
      *"--status=active"*)   echo "wp-mail-smtp" ;;
    esac
  }
}

@test "healthy server: passes and shows the plan + mail target" {
  run _apply_preflight acme u@h "$ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"Preflight passed"* ]]
  [[ "$output" == *"acf-pro 6.3 → 6.8"* ]]
  [[ "$output" == *"wp-staging-pro 6.7 — skipped"* ]]
  [[ "$output" == *"test mail goes to admin@artismedia.de"* ]]
  [ -z "$(find "$ROOT" -name '.wpsite-probe-*')" ]          # probe files cleaned up
}

@test "an update without a download package is flagged up front (the ACF Pro case)" {
  PKG=""
  run _apply_preflight acme u@h "$ROOT"
  [ "$status" -eq 0 ]                                         # informational, not blocking
  [[ "$output" == *"acf-pro 6.3 → 6.8 — NO download package"* ]]
}

@test "site already broken before the apply → abort (fix first)" {
  HOME_CODE=500
  run _apply_preflight acme u@h "$ROOT"
  [ "$status" -ne 0 ]; [[ "$output" == *"NOT healthy right now"* ]]
}

@test "WordPress doesn't boot → abort" {
  _prod_wp() { shift 2; case "$*" in *"core is-installed"*) return 1 ;; esac; }
  run _apply_preflight acme u@h "$ROOT"
  [ "$status" -ne 0 ]; [[ "$output" == *"can't boot WordPress"* ]]
}

@test "an unwritable plugins dir → abort, named" {
  [ "$(id -u)" = 0 ] && skip "root ignores permissions"
  chmod 555 "$ROOT/wp-content/plugins"
  run _apply_preflight acme u@h "$ROOT"
  chmod 755 "$ROOT/wp-content/plugins"
  [ "$status" -ne 0 ]; [[ "$output" == *"not writable: wp-content/plugins"* ]]
}

@test "server can't download updates → abort" {
  DL="ERR cURL error 6: Could not resolve host"
  run _apply_preflight acme u@h "$ROOT"
  [ "$status" -ne 0 ]; [[ "$output" == *"can NOT download updates"* ]]
}

@test "too little free space on the WordPress filesystem → abort" {
  WPSITE_PF_MIN_FREE_KB=999999999999
  run _apply_preflight acme u@h "$ROOT"
  [ "$status" -ne 0 ]; [[ "$output" == *"MB free on the WordPress filesystem"* ]]
}

@test "unwritable backup staging dir → abort with the remote_tmp hint" {
  [ "$(id -u)" = 0 ] && skip "root ignores permissions"
  mkdir -p "$BATS_TEST_TMPDIR/stage"; chmod 555 "$BATS_TEST_TMPDIR/stage"
  run _apply_preflight acme u@h "$ROOT"
  chmod 755 "$BATS_TEST_TMPDIR/stage"
  [ "$status" -ne 0 ]; [[ "$output" == *"staging dir not writable"* ]]
}

@test "SSH down → abort immediately" {
  wpsite_ssh() { return 255; }
  run _apply_preflight acme u@h "$ROOT"
  [ "$status" -ne 0 ]; [[ "$output" == *"SSH to u@h fails"* ]]
}
