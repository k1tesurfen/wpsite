#!/usr/bin/env bats
# Remote readiness tests (wpsite test <client>).

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
EOF
  export WPSITE_CONFIG="$CFG"
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_test.sh"

  # Stub SSH setup/closing helpers
  ssh_setup_mux() { :; }
  ssh_close_mux() { :; }
  
  # Stub requirements/commands
  require()          { :; }
  
  CALLS="$BATS_TEST_TMPDIR/calls"
  : > "$CALLS"
}

@test "test: happy path detects all dependencies, exists and connects successfully" {
  wpsite_ssh() {
    local t="$1"; shift
    echo "ssh $t: $*" >> "$CALLS"
    case "$*" in
      *"echo 'SSH_OK'"*)
        echo "SSH_OK"
        ;;
      *"for cmd in tar php mysql mysqldump"*)
        echo "tar: OK"
        echo "php: OK"
        echo "mysql: OK"
        echo "mysqldump: OK"
        ;;
      *"[ -d '/var/www/acme' ]"*)
        return 0
        ;;
      *"which wp"*)
        echo "/usr/local/bin/wp"
        ;;
      *"wp core version"*)
        echo "6.5"
        ;;
    esac
  }
  
  run cmd_test acme
  [ "$status" -eq 0 ]
  [[ "$output" == *"SSH Connection: SUCCESSFUL"* ]]
  [[ "$output" == *"tar: OK"* ]]
  [[ "$output" == *"Directory '/var/www/acme' exists on remote."* ]]
  [[ "$output" == *"WP-CLI can boot and connect to DB. WordPress Version: 6.5"* ]]
  [[ "$output" == *"100% READY for backup and apply"* ]]
}

@test "test: fails when SSH connection is offline" {
  wpsite_ssh() {
    return 1
  }
  
  run cmd_test acme
  [ "$status" -ne 0 ]
  [[ "$output" == *"SSH Connection: FAILED"* ]]
}

@test "test: fails when mandatory remote tools (like tar) are missing" {
  wpsite_ssh() {
    local t="$1"; shift
    case "$*" in
      *"echo 'SSH_OK'"*)
        echo "SSH_OK"
        ;;
      *"for cmd in tar php mysql mysqldump"*)
        echo "tar: MISSING"
        echo "php: OK"
        echo "mysql: OK"
        echo "mysqldump: OK"
        ;;
      *"[ -d '/var/www/acme' ]"*)
        return 0
        ;;
      *"which wp"*)
        echo "/usr/local/bin/wp"
        ;;
      *"wp core version"*)
        echo "6.5"
        ;;
    esac
  }
  
  run cmd_test acme
  [ "$status" -ne 0 ]
  [[ "$output" == *"tar: MISSING"* ]]
  [[ "$output" == *"has missing dependencies"* ]]
}

@test "test: fails when remote WordPress directory is missing" {
  wpsite_ssh() {
    local t="$1"; shift
    case "$*" in
      *"echo 'SSH_OK'"*)
        echo "SSH_OK"
        ;;
      *"for cmd in tar php mysql mysqldump"*)
        echo "tar: OK"
        echo "php: OK"
        echo "mysql: OK"
        echo "mysqldump: OK"
        ;;
      *"[ -d '/var/www/acme' ]"*)
        return 1
        ;;
      *"which wp"*)
        echo "/usr/local/bin/wp"
        ;;
      *"wp core version"*)
        echo "6.5"
        ;;
    esac
  }
  
  run cmd_test acme
  [ "$status" -ne 0 ]
  [[ "$output" == *"does NOT exist on remote"* ]]
}

@test "test: fails and logs raw errors when remote WP-CLI database boot fails" {
  wpsite_ssh() {
    local t="$1"; shift
    case "$*" in
      *"echo 'SSH_OK'"*)
        echo "SSH_OK"
        ;;
      *"for cmd in tar php mysql mysqldump"*)
        echo "tar: OK"
        echo "php: OK"
        echo "mysql: OK"
        echo "mysqldump: OK"
        ;;
      *"[ -d '/var/www/acme' ]"*)
        return 0
        ;;
      *"which wp"*)
        echo "/usr/local/bin/wp"
        ;;
      *"wp core version --allow-root 2>/dev/null"*)
        return 1
        ;;
      *"wp core version --allow-root 2>&1"*)
        echo "Error: Database connection failed!"
        ;;
    esac
  }
  
  run cmd_test acme
  [ "$status" -ne 0 ]
  [[ "$output" == *"WP-CLI failed to execute or connect to WordPress database"* ]]
  [[ "$output" == *"Error: Database connection failed!"* ]]
}
