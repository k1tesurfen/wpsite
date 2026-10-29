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

@test "compose: sets WORDPRESS_TABLE_PREFIX when a custom prefix is given" {
  run _render_compose db app img acme acme.test "" hfm3_
  [[ "$output" == *'WORDPRESS_TABLE_PREFIX: "hfm3_"'* ]]
}

@test "compose: omits WORDPRESS_TABLE_PREFIX when no prefix given (image default)" {
  run _render_compose db app img acme acme.test
  [[ "$output" != *"WORDPRESS_TABLE_PREFIX"* ]]
}

@test "_detect_table_prefix: reads the global <prefix>users table from a dump" {
  local f="$BATS_TEST_TMPDIR/db.sql"
  printf 'CREATE TABLE `hfm3_usermeta` (...);\nCREATE TABLE `hfm3_users` (...);\n' > "$f"
  run _detect_table_prefix "$f"
  [ "$output" = "hfm3_" ]
}

@test "_detect_table_prefix: empty for a missing file (set -e safe)" {
  run _detect_table_prefix "$BATS_TEST_TMPDIR/nope.sql"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_sanitize_plugins: multisite also deactivates network-activated plugins (--network)" {
  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  # Stub wp: report wp-rocket per-site active, w3-total-cache network active, multisite=1.
  docker() {
    shift 2                                  # drop: exec <container>
    local args="$*"
    printf '%s\n' "$args" >> "$CALLS"
    case "$args" in
      *"plugin list --status=active "*)         echo wp-rocket ;;
      *"plugin list --status=active-network"*)  echo w3-total-cache ;;
      *"is_multisite()"*)                       echo 1 ;;
    esac
    return 0
  }
  run _sanitize_plugins app
  [ "$status" -eq 0 ]
  grep -q 'plugin deactivate wp-rocket --quiet'              "$CALLS"   # per-site, no --network
  grep -q 'plugin deactivate w3-total-cache --network --quiet' "$CALLS" # network-wide
}

@test "_sanitize_plugins: single-site never passes --network" {
  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  docker() {
    shift 2; local args="$*"; printf '%s\n' "$args" >> "$CALLS"
    case "$args" in
      *"plugin list --status=active "*) echo wp-rocket ;;
      *"is_multisite()"*)               echo 0 ;;
    esac
    return 0
  }
  run _sanitize_plugins app
  [ "$status" -eq 0 ]
  grep -q 'plugin deactivate wp-rocket --quiet' "$CALLS"
  ! grep -q -- '--network' "$CALLS"
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

# --- Wordfence: silence notifications, keep it active ----------------------

@test "_silence_wordfence: installed -> blanks alerts + drops Central (honours prefix)" {
  OUT="$BATS_TEST_TMPDIR/sql"; : > "$OUT"
  docker() {
    case "$*" in
      *"SHOW TABLES"*) echo "hfm3_wfconfig"; return 0 ;;   # Wordfence present
      *) cat > "$OUT"; return 0 ;;                          # capture the SQL heredoc
    esac
  }
  run _silence_wordfence db hfm3_
  [ "$status" -eq 0 ]
  grep -q 'hfm3_wfconfig' "$OUT"          # never assumes wp_
  grep -q "name='alertEmails'" "$OUT"     # blank the recipients
  grep -q "alertOn" "$OUT"                # switch alerts off
  grep -q "wordfenceCentral%" "$OUT"      # drop the Central link (HTTPS bypass)
}

@test "_silence_wordfence: not installed -> no-op, no SQL executed" {
  RAN="$BATS_TEST_TMPDIR/ran"; : > "$RAN"
  docker() {
    case "$*" in
      *"SHOW TABLES"*) return 0 ;;                       # prints nothing -> absent
      *) echo ran >> "$RAN"; cat >/dev/null; return 0 ;;
    esac
  }
  run _silence_wordfence db wp_
  [ "$status" -eq 0 ]
  [ ! -s "$RAN" ]                          # the UPDATE/DELETE exec never ran
}

@test "compose: multisite sets a host-only COOKIE_DOMAIN that survives Compose interpolation" {
  source "$REPO/lib/cmd_build_multisite.sh"
  run _render_compose db app img acme main.test "$(_ms_config_extra main.test 1)"
  [[ "$output" == *"define('DOMAIN_CURRENT_SITE', 'main.test');"* ]]
  # $$ in the YAML = a literal $ after Compose interpolation.
  [[ "$output" == *"define('COOKIE_DOMAIN', isset(\$\$_SERVER['HTTP_HOST']) ? \$\$_SERVER['HTTP_HOST'] : '');"* ]]
  if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    d="$BATS_TEST_TMPDIR/c"; mkdir -p "$d"; printf '%s\n' "$output" > "$d/docker-compose.yml"
    run docker compose -f "$d/docker-compose.yml" config
    # (config re-escapes $ as $$ in its output; an UNescaped $_SERVER would be gone.)
    [ "$status" -eq 0 ]
    [[ "$output" == *"_SERVER['HTTP_HOST']) ?"* ]]
  fi
}

@test "compose: single site gets no COOKIE_DOMAIN" {
  run _render_compose db app img acme acme.test
  [[ "$output" != *COOKIE_DOMAIN* ]]
}
