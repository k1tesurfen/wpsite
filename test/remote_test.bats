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
  export MANDOS_BIN="$BATS_TEST_DIRNAME/fixtures/mandos-stub"   # client registry via stub
  export WPSITE_TEAM_CONFIG="${MANDOS_STUB_CONFIG:-$WPSITE_CONFIG}"   # wpsite registry = same fixture
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_build.sh"
  source "$REPO/lib/cmd_upgrade.sh"
  source "$REPO/lib/cmd_apply.sh"     # _prod_wp + _site_boots: step 4 runs apply's boot check
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
      *"eval --skip-wordpress"*)
        echo "WPSITE ARGS OK"
        ;;
      *"core is-installed"*)
        return 0
        ;;
      *WPSITE_BOOT_OK*)
        echo "WPSITE_BOOT_OK"
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
  [[ "$output" == *"WP-CLI runs. WordPress Version: 6.5"* ]]
  [[ "$output" == *"WordPress boots with all plugins"* ]]
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

# Regression (gerfin): under the CLI's real `set -euo pipefail`, a remote wp that
# fatals (Plesk WP-Toolkit wrapper, exit 255) aborted the test SILENTLY right after
# the [4/4] header — no error, no verdict. bats' `run` disables errexit, which is why
# the test above never saw it; this one runs the command in a strict shell.
@test "test: a fataling remote wp is REPORTED under set -euo pipefail, not a silent abort" {
  run env REPO="$REPO" WPSITE_CONFIG="$WPSITE_CONFIG" MANDOS_BIN="$MANDOS_BIN" bash -c '
    set -euo pipefail
    source "$REPO/lib/common.sh"; source "$REPO/lib/cmd_test.sh"
    ssh_setup_mux() { :; }; ssh_close_mux() { :; }
    wpsite_ssh() { shift; case "$*" in
      *SSH_OK*)        echo SSH_OK ;;
      *"for cmd in"*)  printf "tar: OK\nphp: OK\nmysql: OK\nmysqldump: OK\n" ;;
      *"[ -d "*)       return 0 ;;
      *"which wp"*)    echo /usr/local/bin/wp ;;
      *"2>&1"*)        echo "PHP Fatal error:  Failed opening required wpt-wp-cli.php"; return 255 ;;
      *"wp core version"*) return 255 ;;
    esac; }
    cmd_test acme'
  [ "$status" -ne 0 ]
  [[ "$output" == *"WP-CLI failed to execute"* ]]
  [[ "$output" == *"wpt-wp-cli.php"* ]]
  [[ "$output" == *"has missing dependencies"* ]]
}

@test "test: broken host wp (Plesk WP-Toolkit) -> falls back to the bundled phar, READY" {
  _wp_cli_cache()      { printf '%s' "$BATS_TEST_TMPDIR/c.phar"; }
  _wp_cli_cache_warm() { echo phar > "$BATS_TEST_TMPDIR/c.phar"; }
  wpsite_ssh() { shift; case "$*" in
    *SSH_OK*)       echo SSH_OK ;;
    *"for cmd in"*) printf "tar: OK\nphp: OK\n" ;;
    *"[ -d "*)      return 0 ;;
    cksum*)         return 1 ;;
    *"cat >"*)      cat >/dev/null ;;
    *"wp-cli.phar\" core version --allow-root 2>/dev/null"*) echo "7.0.6" ;;
    *"wp-cli.phar\" core version"*) return 0 ;;
    *"wp-cli.phar\" eval --skip-wordpress"*) echo "WPSITE ARGS OK" ;;
    *"wp-cli.phar\" core is-installed"*) return 0 ;;
    *"wp-cli.phar\" eval"*WPSITE_BOOT_OK*) echo "WPSITE_BOOT_OK" ;;
    *)              echo "PHP Fatal error: Failed opening required wpt-wp-cli.php"; return 255 ;;
  esac; }
  run cmd_test acme
  [ "$status" -eq 0 ]
  [[ "$output" == *"using bundled wp-cli"* ]]
  [[ "$output" == *"WordPress Version: 7.0.6"* ]]
  [[ "$output" == *"100% READY"* ]]
}

# Regression (ksk, maute-areal): Mittwald's old wrapper ends in `php_cli wp-cli.phar $@`
# (unquoted), so `wp core version` works but `wp eval 'echo "…";'` is re-split and dies.
# `test` used to say READY while apply's preflight refused the site. Here no bundled phar
# can take over (no cache), so the split must surface as a FAILED test with the error.
@test "test: wp runs but WordPress doesn't boot via WP-CLI (split args) -> FAILS like apply's preflight" {
  _wp_cli_cache_warm() { return 1; }
  wpsite_ssh() { shift; case "$*" in
    *SSH_OK*)       echo SSH_OK ;;
    *"for cmd in"*) printf "tar: OK\nphp: OK\n" ;;
    *"[ -d "*)      return 0 ;;
    # wp-cli writes its errors to STDERR (as on ksk) — _site_boots discards them.
    *" eval "*)     echo 'Error: Too many positional arguments: "WPSITE_BOOT_OK";' >&2; return 1 ;;
    *"core is-installed"*) return 0 ;;
    *"which wp"*)   echo /usr/local/bin/wp ;;
    *"wp core version"*) echo "7.1.2" ;;
  esac; }
  run cmd_test acme
  [ "$status" -ne 0 ]
  [[ "$output" == *"splits arguments at spaces"* ]]
  [[ "$output" == *"WP-CLI runs. WordPress Version: 7.1.2"* ]]
  [[ "$output" == *"WordPress does NOT boot via WP-CLI"* ]]
  [[ "$output" == *"Too many positional arguments"* ]]
  [[ "$output" != *"100% READY"* ]]
}
