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
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_lifecycle.sh"

  # Stub requirements/commands
  require()          { :; }
  
  CALLS="$BATS_TEST_TMPDIR/calls"
  : > "$CALLS"
  
  # Stub docker command to record calls
  docker() {
    if [ "$1" = "compose" ]; then
      shift
      echo "compose $*" >> "$CALLS"
    fi
  }
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
