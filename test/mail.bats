#!/usr/bin/env bats
# Mailpit: mu-plugin generation + injection. Container/docker paths are integration-only.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_proxy.sh"
  source "$REPO/lib/cmd_mail.sh"
}

@test "_mail_muplugin: routes wp_mail through Mailpit SMTP" {
  run _mail_muplugin
  [[ "$output" == *"phpmailer_init"* ]]
  [[ "$output" == *"isSMTP()"* ]]
  [[ "$output" == *"'wpsite-mail'"* ]]   # hyphen, not underscore (PHPMailer rejects '_')
  [[ "$output" != *"'wpsite_mail'"* ]]
  [[ "$output" == *"1025"* ]]
}

@test "_mail_muplugin: guards against direct access" {
  run _mail_muplugin
  [[ "$output" == *"ABSPATH"* ]]
}

@test "_inject_mailpit_muplugin: creates mu-plugins dir + file" {
  d="$BATS_TEST_TMPDIR/wp-content"
  mkdir -p "$d"
  _inject_mailpit_muplugin "$d"
  [ -f "$d/mu-plugins/wpsite-mailpit.php" ]
  grep -q 'wpsite-mail' "$d/mu-plugins/wpsite-mailpit.php"
}

@test "_inject_mailpit_muplugin: coexists with existing mu-plugins" {
  d="$BATS_TEST_TMPDIR/wp-content"
  mkdir -p "$d/mu-plugins"
  echo "<?php // existing" > "$d/mu-plugins/other.php"
  _inject_mailpit_muplugin "$d"
  [ -f "$d/mu-plugins/other.php" ]          # not clobbered
  [ -f "$d/mu-plugins/wpsite-mailpit.php" ]
}

@test "cmd_mail: unknown subcommand errors" {
  run env REPO="$REPO" bash -c '
    source "$REPO/lib/common.sh"; source "$REPO/lib/cmd_proxy.sh"; source "$REPO/lib/cmd_mail.sh"
    cmd_mail bogus'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown"* ]]
}

@test "sanitize list includes mail/SMTP plugins (catch-all)" {
  source "$REPO/lib/cmd_build.sh"
  local def; def="$(declare -f _sanitize_plugins)"
  [[ "$def" == *"wp-mail-smtp"* ]]
  [[ "$def" == *"fluent-smtp"* ]]
  [[ "$def" == *"post-smtp"* ]]
}
