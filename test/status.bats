#!/usr/bin/env bats
# wpsite status — coloured STATE column. The colour helper is pure; cmd_status is
# exercised over a temp config + stubbed docker.

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
  baker:
    ssh: u@baker
    wp_root: /var/www/html
EOF
  export WPSITE_CONFIG="$CFG"
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_status.sh"
  require() { :; }
}

@test "_status_color: running->green, exited/dead->red, other->yellow, empty off" {
  _C_GRN=GRN _C_RED=RED _C_YEL=YEL
  [ "$(_status_color running)" = GRN ]
  [ "$(_status_color exited)" = RED ]
  [ "$(_status_color dead)" = RED ]
  [ "$(_status_color paused)" = YEL ]
  [ "$(_status_color created)" = YEL ]
  # Colours off (non-TTY / NO_COLOR): empty string, so output degrades cleanly.
  _C_GRN='' _C_RED='' _C_YEL=''
  [ -z "$(_status_color running)" ]
}

@test "status: wraps running green and exited red without breaking alignment" {
  _C_GRN=$'\033[32m'; _C_RED=$'\033[31m'; _C_YEL=$'\033[33m'; _C_RESET=$'\033[0m'
  docker() {
    case "$*" in
      *wp_acme_app*)  echo running ;;
      *wp_baker_app*) echo exited ;;
    esac
  }
  run cmd_status
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\033[32m'"running"* ]]   # green wraps the running state
  [[ "$output" == *$'\033[31m'"exited"* ]]    # red wraps the exited state
}

@test "status: no colour codes when NO_COLOR disables them (plain, aligned)" {
  _C_GRN='' _C_RED='' _C_YEL='' _C_RESET=''
  docker() { case "$*" in *wp_acme_app*) echo running ;; *) echo "" ;; esac; }
  run cmd_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"running"* ]]
  [[ "$output" != *$'\033['* ]]               # no escape sequences at all
}

@test "status: none running -> friendly message" {
  docker() { echo ""; }                         # inspect returns nothing for all
  run cmd_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"No sites are currently running"* ]]
}

@test "status: SITE column widens to the longest name (columns stay aligned)" {
  cat > "$CFG" <<EOF
base_dir: $BASE
clients:
  a:
    ssh: u@a
    wp_root: /v
  baulandentwicklung:
    ssh: u@b
    wp_root: /v
EOF
  _C_GRN='' _C_RED='' _C_YEL='' _C_RESET=''    # plain, so offsets are exact
  docker() { echo running; }                    # both have a container
  run cmd_status
  [ "$status" -eq 0 ]
  # Both rows are kind=client; the "client" token must start at the same offset
  # (proves alignment) and that offset must clear the 18-char long name (proves
  # the field widened past the old fixed 16).
  la="$(grep '^a ' <<<"$output" | head -1)"
  lb="$(grep '^baulandentwicklung' <<<"$output" | head -1)"
  pa="${la%%client*}"; pb="${lb%%client*}"
  [ "${#pa}" -eq "${#pb}" ]
  [ "${#pa}" -ge 18 ]
}
