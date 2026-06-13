#!/usr/bin/env bats
# Sanitization extras: WP_DEBUG in the generated compose + known admin login.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_proxy.sh"
  source "$REPO/lib/cmd_build.sh"
}

@test "compose: enables WP debug logging + local environment" {
  run _render_compose db app img acme acme.test
  [[ "$output" == *'WORDPRESS_DEBUG: "1"'* ]]
  [[ "$output" == *"WP_DEBUG_LOG', true"* ]]
  [[ "$output" == *"WP_DEBUG_DISPLAY', false"* ]]
  [[ "$output" == *"WP_ENVIRONMENT_TYPE', 'local'"* ]]
}

@test "_set_known_admin: creates the user when absent + prints credentials" {
  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  docker() { shift 2; printf '%s\n' "$*" >> "$CALLS"; case "$*" in *"user get"*) return 1 ;; esac; return 0; }
  run _set_known_admin app http://acme.test
  [ "$status" -eq 0 ]
  grep -q 'user create wpsite' "$CALLS"
  ! grep -q 'user update' "$CALLS"
  [[ "$output" == *"wpsite / wpsite"* ]]
  [[ "$output" == *"http://acme.test/wp-admin/"* ]]
}

@test "_set_known_admin: updates the password when the user already exists" {
  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  docker() { shift 2; printf '%s\n' "$*" >> "$CALLS"; return 0; }   # user get succeeds
  run _set_known_admin app http://acme.test
  [ "$status" -eq 0 ]
  grep -q 'user update wpsite' "$CALLS"
  ! grep -q 'user create' "$CALLS"
}

@test "_set_known_admin: honours WPSITE_ADMIN_USER / WPSITE_ADMIN_PASS overrides" {
  docker() { shift 2; case "$*" in *"user get"*) return 1 ;; esac; return 0; }
  WPSITE_ADMIN_USER=dev WPSITE_ADMIN_PASS=s3cret run _set_known_admin app http://acme.test
  [[ "$output" == *"dev / s3cret"* ]]
}
