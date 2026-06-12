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
