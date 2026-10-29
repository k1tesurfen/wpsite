#!/usr/bin/env bats
# `wpsite php` (show / switch a built site's PHP) and _wp_image_fresh (always pull the
# newest patch of the chosen series), over a stubbed docker.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"

  BASE="$BATS_TEST_TMPDIR/root"
  CFG="$BATS_TEST_TMPDIR/wpsite.yml"
  cat > "$CFG" <<EOF
base_dir: $BASE
clients:
  acme:
    ssh: u@acme
    wp_root: /var/www/acme
    registered: "2026-01-01"
dev:
  gruen:
    host: gruen.test
    wp_version: ""
    php: "8.2"
EOF
  export WPSITE_CONFIG="$CFG"
  export MANDOS_BIN="$BATS_TEST_DIRNAME/fixtures/mandos-stub"
  export WPSITE_TEAM_CONFIG="${MANDOS_STUB_CONFIG:-$WPSITE_CONFIG}"
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_build.sh"
  source "$REPO/lib/cmd_php.sh"

  require() { :; }
  _wp_image_for_host() { printf '%s' "$1"; }   # the Linux UID remap is build.bats' concern
  _install_sendmail_shim() { echo "shim $1" >> "$CALLS"; }

  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  STATE="$BATS_TEST_TMPDIR/state"; mkdir -p "$STATE"
  echo "8.2.32" > "$STATE/php"; echo "7.0.1" > "$STATE/core"; echo 1 > "$STATE/running"

  # docker stub. PULL_<n>: what `docker pull` of candidate n does — "ok", "missing"
  # (tag not published) or "offline". LOCAL: tags present in `docker image inspect`.
  # A compose `up -d` "recreates" onto the image now in the compose file: its PHP series
  # → x.y.99, its core → IMAGE_CORE (default unchanged).
  docker() {
    echo "docker $*" >> "$CALLS"
    case "$1" in
      pull)
        local tag="${*: -1}" mode
        mode="$(grep -F "$tag=" "$STATE/pulls" 2>/dev/null | head -1 | cut -d= -f2)"
        case "${mode:-ok}" in
          ok)      return 0 ;;
          missing) echo "Error response from daemon: manifest for $tag not found: manifest unknown" >&2; return 1 ;;
          offline) echo "Error response from daemon: dial tcp: lookup registry-1.docker.io: no such host" >&2; return 1 ;;
        esac ;;
      image) [[ " ${LOCAL:-} " == *" $3 "* ]]; return ;;
      compose)
        local img; img="$(_compose_wp_image "$PWD/docker-compose.yml")"
        if [[ "$img" =~ php([0-9]+\.[0-9]+) ]]; then echo "${BASH_REMATCH[1]}.99" > "$STATE/php"; fi
        [ -n "${IMAGE_CORE:-}" ] && echo "$IMAGE_CORE" > "$STATE/core"
        echo 1 > "$STATE/running"; return 0 ;;
      exec)
        case "$*" in
          *"echo PHP_VERSION"*) [ "$(cat "$STATE/running")" = 1 ] && cat "$STATE/php"; return 0 ;;
          *"version.php"*)      cat "$STATE/core"; return 0 ;;
          *"core download"*)    [ "${CORE_DL:-ok}" = ok ] || return 1
                                local a="$*"; a="${a##*--version=}"; echo "${a%% *}" > "$STATE/core"; return 0 ;;
          *"wpsite-boot-ok"*)   [ "${BOOT:-ok}" = ok ] && echo wpsite-boot-ok; return 0 ;;
          *) return 0 ;;
        esac ;;
    esac
    return 0
  }

  mkdir -p "$BASE/.cache"; echo phar > "$BASE/.cache/wp-cli.phar"
  DEV_DIR="$(dev_docker_dir gruen)"; mkdir -p "$DEV_DIR"
  _render_compose wp_gruen_db wp_gruen_app wordpress:php8.2-apache gruen gruen.test \
    "define('X', \$\$_SERVER['HTTP_HOST']);" > "$DEV_DIR/docker-compose.yml"
}

pulls() { printf '%s\n' "$@" > "$STATE/pulls"; }

# --- _wp_image_fresh ---------------------------------------------------------------

@test "_wp_image_fresh: pulls the php-pinned series tag (never a PHP-less fallback)" {
  [ "$(_wp_image_fresh "" 8.4 2>/dev/null)" = "wordpress:php8.4-apache" ]
  grep -q "docker pull -q wordpress:php8.4-apache" "$CALLS"
  ! grep -q "wordpress:latest" "$CALLS"
}

@test "_wp_image_fresh: unpublished exact tag -> next php-pinned candidate" {
  pulls "wordpress:7.0.1-php8.4-apache=missing"
  [ "$(_wp_image_fresh 7.0.1 8.4 2>/dev/null)" = "wordpress:7.0-php8.4-apache" ]
}

@test "_wp_image_fresh: offline -> cached series image, with a stale-patch warning" {
  pulls "wordpress:php8.4-apache=offline"
  LOCAL="wordpress:php8.4-apache"
  [ "$(_wp_image_fresh "" 8.4 2>/dev/null)" = "wordpress:php8.4-apache" ]
  run _wp_image_fresh "" 8.4
  [[ "$output" == *"may predate the newest release"* ]]
}

@test "_wp_image_fresh: offline and nothing cached -> returns 1" {
  pulls "wordpress:php8.4-apache=offline"
  run _wp_image_fresh "" 8.4
  [ "$status" -eq 1 ]
}

# --- compose image line ------------------------------------------------------------

@test "_compose_set_wp_image: rewrites only the wordpress image, keeps everything else" {
  local before; before="$(cat "$DEV_DIR/docker-compose.yml")"
  _compose_set_wp_image "$DEV_DIR/docker-compose.yml" wordpress:php8.4-apache
  [ "$(_compose_wp_image "$DEV_DIR/docker-compose.yml")" = "wordpress:php8.4-apache" ]
  grep -q "image: $WPSITE_DB_IMAGE" "$DEV_DIR/docker-compose.yml"
  grep -qF "\$\$_SERVER" "$DEV_DIR/docker-compose.yml"
  [ "$(diff <(echo "$before") "$DEV_DIR/docker-compose.yml" | grep -c '^[<>]')" -eq 2 ]
}

@test "_compose_set_wp_image: no wordpress service -> 1, file untouched" {
  printf 'services:\n  db:\n    image: x\n' > "$BATS_TEST_TMPDIR/c.yml"
  run _compose_set_wp_image "$BATS_TEST_TMPDIR/c.yml" y
  [ "$status" -eq 1 ]
  grep -q "image: x" "$BATS_TEST_TMPDIR/c.yml"
}

# --- cmd_php -------------------------------------------------------------------------

@test "php: no version shows the image and the exact running PHP" {
  run cmd_php gruen
  [ "$status" -eq 0 ]
  [[ "$output" == *"wordpress:php8.2-apache"* ]]
  [[ "$output" == *"runs PHP 8.2.32"* ]]
  ! grep -q "docker pull" "$CALLS"
}

@test "php: rejects a patch release and garbage" {
  run cmd_php gruen 8.4.27
  [ "$status" -ne 0 ]
  [[ "$output" == *"PHP series (e.g. 8.4)"* ]]
  run cmd_php gruen eight
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid PHP version"* ]]
}

@test "php: unbuilt site and unknown site are refused" {
  run cmd_php nosuch 8.4
  [ "$status" -ne 0 ]
  run cmd_php acme 8.4
  [ "$status" -ne 0 ]
  [[ "$output" == *"Nothing built"* ]]
}

@test "php: dev site switch pulls, recreates, restores layer, records the config" {
  run cmd_php gruen 8.4
  [ "$status" -eq 0 ]
  [ "$(_compose_wp_image "$DEV_DIR/docker-compose.yml")" = "wordpress:7.0.1-php8.4-apache" ]
  grep -q "docker compose -p wpsite_gruen up -d" "$CALLS"
  grep -q "shim wp_gruen_app" "$CALLS"
  [[ "$output" == *"runs PHP 8.4.99 (was 8.2.32)"* ]]
  [[ "$output" == *"boots on PHP 8.4"* ]]
  [ "$(dev_get gruen php)" = "8.4" ]
}

@test "php: keeps the site's WordPress core when the image ships another" {
  IMAGE_CORE="7.1.0"
  run cmd_php gruen 8.4
  [ "$status" -eq 0 ]
  grep -q "core download --version=7.0.1" "$CALLS"
  [ "$(cat "$STATE/core")" = "7.0.1" ]
}

@test "php: core can't be restored offline -> warns, still switches" {
  IMAGE_CORE="7.1.0"; CORE_DL=fail
  run cmd_php gruen 8.4
  [ "$status" -eq 0 ]
  [[ "$output" == *"now runs core 7.1.0"* ]]
}

@test "php: a boot failure warns with the way back" {
  BOOT=fail
  run cmd_php gruen 8.4
  [ "$status" -eq 0 ]
  [[ "$output" == *"does NOT boot"* ]]
  [[ "$output" == *"wpsite php gruen 8.2"* ]]
}

@test "php: nothing pullable or cached -> dies, compose untouched" {
  pulls "wordpress:7.0.1-php8.4-apache=offline"
  run cmd_php gruen 8.4
  [ "$status" -ne 0 ]
  [ "$(_compose_wp_image "$DEV_DIR/docker-compose.yml")" = "wordpress:php8.2-apache" ]
  [ "$(dev_get gruen php)" = "8.2" ]
}

@test "php: client replica switches but warns that build returns to production's PHP" {
  local d; d="$(client_docker_dir acme)"; mkdir -p "$d"
  _render_compose wp_acme_db wp_acme_app wordpress:7.0-php8.2-apache acme acme.test > "$d/docker-compose.yml"
  run cmd_php acme 8.4
  [ "$status" -eq 0 ]
  [ "$(_compose_wp_image "$d/docker-compose.yml")" = "wordpress:7.0.1-php8.4-apache" ]
  [[ "$output" == *"until its next 'wpsite build'"* ]]
  [ -z "$(yq '.dev.acme' "$CFG" | grep -v null)" ]
}

@test "php: a stopped site is started first to read its versions" {
  echo 0 > "$STATE/running"
  run cmd_php gruen 8.4
  [ "$status" -eq 0 ]
  [[ "$output" == *"Starting 'gruen'"* ]]
  [ "$(grep -c "compose -p wpsite_gruen up -d" "$CALLS")" -eq 2 ]
}
