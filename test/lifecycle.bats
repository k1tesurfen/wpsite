#!/usr/bin/env bats
# Lifecycle helpers (start, stop, stop --all).

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"

  # A throwaway base_dir + config for this test.
  BASE="$BATS_TEST_TMPDIR/root"
  CFG="$BATS_TEST_TMPDIR/wpsite.yml"
  cat > "$CFG" <<EOF
base_dir: $BASE
clients:
  acme:
    ssh: u@acme
    wp_root: /var/www/acme
  baker:
    ssh: u@baker
    wp_root: /var/www/html
EOF
  export WPSITE_CONFIG="$CFG"
  export MANDOS_BIN="$BATS_TEST_DIRNAME/fixtures/mandos-stub"   # client registry via stub
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_build.sh"        # provides _ensure_wp_cli (start reinstalls it)
  source "$REPO/lib/cmd_lifecycle.sh"

  # Stub requirements/commands
  require()          { :; }

  CALLS="$BATS_TEST_TMPDIR/calls"
  : > "$CALLS"

  # Stub docker command to record calls. WP_RC drives the wp-cli presence check
  # (0 = already installed, so the reinstall is skipped).
  docker() {
    if [ "$1" = "compose" ]; then
      shift
      echo "compose $*" >> "$CALLS"
      return 0
    fi
    if [ "$1" = "cp" ]; then shift; echo "cp $*" >> "$CALLS"; return 0; fi
    if [ "$1" = "exec" ]; then
      case "$*" in
        *"-x /usr/local/bin/wp"*) return "${WP_RC:-0}" ;;
        *) return 0 ;;
      esac
    fi
    return 0
  }

  # Warm host wp-cli cache so a reinstall takes the offline `docker cp` path.
  mkdir -p "$BASE/.cache"; echo "phar" > "$BASE/.cache/wp-cli.phar"
}

@test "stop: stops single client" {
  # Mock docker-compose.yml file presence for acme
  local d
  d="$(client_docker_dir acme)"
  mkdir -p "$d"
  touch "$d/docker-compose.yml"
  
  run cmd_stop acme
  [ "$status" -eq 0 ]
  grep -q "compose -p wpsite_acme stop" "$CALLS"
  [[ "$output" == *"Stopping 'acme' replica"* ]]
}

@test "stop: stops --all client replicas with compose files" {
  # Mock docker-compose.yml for acme, but NOT baker
  local d_acme d_baker
  d_acme="$(client_docker_dir acme)"
  d_baker="$(client_docker_dir baker)"
  mkdir -p "$d_acme" "$d_baker"
  touch "$d_acme/docker-compose.yml" # acme is built
  # baker is NOT built
  
  run cmd_stop --all
  [ "$status" -eq 0 ]
  grep -q "compose -p wpsite_acme stop" "$CALLS"
  ! grep -q "compose -p wpsite_baker stop" "$CALLS"
  [[ "$output" == *"Stopping 'acme'"* ]]
  [[ "$output" == *"Stopped all built sites"* ]]
}

@test "start: fails when no compose file exists" {
  local d
  d="$(client_docker_dir acme)"
  rm -f "$d/docker-compose.yml"
  
  run cmd_start acme
  [ "$status" -ne 0 ]
  [[ "$output" == *"Nothing built"* ]]
}

@test "start: runs docker compose up when compose file exists" {
  local d
  d="$(client_docker_dir acme)"
  mkdir -p "$d"
  touch "$d/docker-compose.yml"
  
  run cmd_start acme
  [ "$status" -eq 0 ]
  grep -q "compose -p wpsite_acme up -d" "$CALLS"
  [[ "$output" == *"Starting 'acme' replica"* ]]
}

# `up -d` recreates a removed container (or one whose compose config changed), which
# wipes the wp-cli phar from the container layer — start must put it back.

@test "start: reinstalls wp-cli when the container came back without it" {
  local d; d="$(client_docker_dir acme)"
  mkdir -p "$d"; touch "$d/docker-compose.yml"

  WP_RC=1 run cmd_start acme
  [ "$status" -eq 0 ]
  grep -qF "cp $BASE/.cache/wp-cli.phar wp_acme_app:/usr/local/bin/wp" "$CALLS"
  [[ "$output" == *"Started"* ]]
}

@test "start: skips the wp-cli install when it is already present" {
  local d; d="$(client_docker_dir acme)"
  mkdir -p "$d"; touch "$d/docker-compose.yml"

  WP_RC=0 run cmd_start acme
  [ "$status" -eq 0 ]
  ! grep -q "^cp " "$CALLS"
}

@test "start: warns but still succeeds when wp-cli cannot be installed" {
  local d; d="$(client_docker_dir acme)"
  mkdir -p "$d"; touch "$d/docker-compose.yml"

  rm -f "$BASE/.cache/wp-cli.phar"
  have() { return 1; }                    # no curl → cache stays empty
  docker() {
    if [ "$1" = compose ]; then shift; echo "compose $*" >> "$CALLS"; return 0; fi
    if [ "$1" = exec ]; then return 1; fi # presence check AND the php download fail
    return 0
  }
  run cmd_start acme
  [ "$status" -eq 0 ]
  [[ "$output" == *"wp-cli could not be (re)installed"* ]]
  [[ "$output" == *"Started"* ]]
}
