#!/usr/bin/env bats
# Pure helper logic — no Docker/SSH, no side effects.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_build.sh"
}

@test "_wp_image_tag: wp + php" {
  run _wp_image_tag 6.4 8.3
  [ "$output" = "wordpress:6.4-php8.3-apache" ]
}

@test "_wp_image_tag: php only" {
  run _wp_image_tag "" 8.3
  [ "$output" = "wordpress:php8.3-apache" ]
}

@test "_wp_image_tag: wp only" {
  run _wp_image_tag 6.4 ""
  [ "$output" = "wordpress:6.4-apache" ]
}

@test "_wp_image_tag: neither -> latest" {
  run _wp_image_tag "" ""
  [ "$output" = "wordpress:latest" ]
}

@test "_wp_image_candidates: ordered, WP version kept before PHP" {
  run _wp_image_candidates 7.0 8.1
  [ "${lines[0]}" = "wordpress:7.0-php8.1-apache" ]
  [ "${lines[1]}" = "wordpress:7.0-apache" ]
  [ "${lines[2]}" = "wordpress:php8.1-apache" ]
  [ "${lines[3]}" = "wordpress:latest" ]
}

# The resolver probes via `docker manifest inspect`; we stub `docker` so no real
# registry call happens (still side-effect free).
@test "_resolve_wp_image: picks the exact prod tag when it's published" {
  docker() { [ "$3" = "wordpress:7.0-php8.3-apache" ]; }
  run _resolve_wp_image 7.0 8.3
  [ "$output" = "wordpress:7.0-php8.3-apache" ]
}

@test "_resolve_wp_image: falls back to <wp>-apache when the PHP combo is missing" {
  docker() { [ "$3" = "wordpress:7.0-apache" ]; }   # the drfroehlich case (7.0 + php8.1)
  run _resolve_wp_image 7.0 8.1
  [ "$output" = "wordpress:7.0-apache" ]
}

@test "_resolve_wp_image: returns the preferred tag when nothing resolves (offline)" {
  docker() { return 1; }
  run _resolve_wp_image 7.0 8.1
  [ "$output" = "wordpress:7.0-php8.1-apache" ]
}

@test "expand_tilde: expands leading ~/" {
  run expand_tilde "~/websites"
  [ "$output" = "$HOME/websites" ]
}

@test "expand_tilde: leaves absolute paths" {
  run expand_tilde "/var/www/x"
  [ "$output" = "/var/www/x" ]
}

@test "expand_tilde: does not touch ~ mid-string" {
  run expand_tilde "/a/~/b"
  [ "$output" = "/a/~/b" ]
}

@test "_meta_get: reads a present key" {
  printf 'WP_VERSION=6.4\nSOURCE_HOME=https://x.de\n' > "$BATS_TEST_TMPDIR/meta.env"
  run _meta_get SOURCE_HOME "$BATS_TEST_TMPDIR/meta.env"
  [ "$output" = "https://x.de" ]
}

@test "_meta_get: value containing = is preserved" {
  printf 'K=a=b=c\n' > "$BATS_TEST_TMPDIR/meta.env"
  run _meta_get K "$BATS_TEST_TMPDIR/meta.env"
  [ "$output" = "a=b=c" ]
}

@test "_meta_get: missing key is empty and exit 0 (set -e safe)" {
  printf 'A=1\n' > "$BATS_TEST_TMPDIR/meta.env"
  run _meta_get NOPE "$BATS_TEST_TMPDIR/meta.env"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_meta_get: missing file is empty and exit 0" {
  run _meta_get A "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_inject_wpsite_compat_muplugin: writes compatibility helper" {
  d="$BATS_TEST_TMPDIR/wp-content"
  mkdir -p "$d"
  _inject_wpsite_compat_muplugin "$d"
  [ -f "$d/mu-plugins/wpsite-compat.php" ]
  grep -q 'include_once.*template.php' "$d/mu-plugins/wpsite-compat.php"
}

@test "_is_backup_id: matches timestamps + optional -permanent, rejects junk" {
  _is_backup_id 20260101_120000
  _is_backup_id 20260101_120000-permanent
  run _is_backup_id 20260101            ; [ "$status" -ne 0 ]
  run _is_backup_id 20260101_120000.tmp ; [ "$status" -ne 0 ]
  run _is_backup_id fresh               ; [ "$status" -ne 0 ]
  run _is_backup_id ''                  ; [ "$status" -ne 0 ]
}

@test "_is_persistent_backup: true only for the -permanent suffix" {
  _is_persistent_backup 20260101_120000-permanent
  _is_persistent_backup /some/path/20260101_120000-permanent
  run _is_persistent_backup 20260101_120000 ; [ "$status" -ne 0 ]
}
