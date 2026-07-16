#!/usr/bin/env bats
# wpsite db — the shared Adminer DB browser. Covers the sub-dispatcher
# (start/stop/status + usage/flag guards) and the open flow (target resolution,
# db-running guard, and the auto-login URL handed to `open`). Docker + `open`
# are stubbed so nothing real runs.

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
EOF
  export WPSITE_CONFIG="$CFG"
  export MANDOS_BIN="$BATS_TEST_DIRNAME/fixtures/mandos-stub"   # client registry via stub
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_db.sh"

  require() { :; }

  CALLS="$BATS_TEST_TMPDIR/calls"
  : > "$CALLS"

  # docker stub: State.Running -> "true"; network list -> a project net; everything
  # else (image/network inspect, run, connect) succeeds. Records mutating calls.
  ADMINER_RUNNING="true"
  DB_RUNNING="true"
  docker() {
    case "$1 $2" in
      "inspect -f")
        case "$3" in
          *State.Running*)
            case "$4" in
              "$WPSITE_ADMINER_CONTAINER") printf '%s\n' "$ADMINER_RUNNING" ;;
              *)                           printf '%s\n' "$DB_RUNNING" ;;
            esac ;;
          *NetworkSettings*) printf '%s\n' "wpsite_acme_default " ;;
        esac ;;
      "image inspect") return 0 ;;
      "network inspect") return 0 ;;
      "network connect") echo "connect $*" >> "$CALLS"; return 0 ;;
      "rm -f") echo "rm $*" >> "$CALLS"; return 1 ;;   # default: nothing to remove
      *) echo "docker $*" >> "$CALLS"; return 0 ;;
    esac
  }

  # Capture the URL that would be opened in the browser.
  open() { echo "open $*" >> "$CALLS"; }
}

# --- sub-dispatcher guards -------------------------------------------------

@test "db: unknown flag -> error" {
  run cmd_db --nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown flag"* ]]
}

@test "db status: not running -> info, exit 0" {
  ADMINER_RUNNING="false"
  run cmd_db status
  [ "$status" -eq 0 ]
  [[ "$output" == *"not running"* ]]
}

@test "db status: running -> reports URL" {
  run cmd_db status
  [ "$status" -eq 0 ]
  [[ "$output" == *"$WPSITE_ADMINER_PORT"* ]]
}

@test "db stop: nothing running -> 'was not running', exit 0" {
  run cmd_db stop
  [ "$status" -eq 0 ]
  [[ "$output" == *"was not running"* ]]
}

@test "db down: still accepted as an alias for stop" {
  run cmd_db down
  [ "$status" -eq 0 ]
  [[ "$output" == *"was not running"* ]]
}

# --- open flow -------------------------------------------------------------

@test "db <client>: opens the auto-login URL for the site's db container" {
  run cmd_db acme
  [ "$status" -eq 0 ]
  grep -q "open http://localhost:${WPSITE_ADMINER_PORT}/?wpsite_server=wp_acme_db" "$CALLS"
  [[ "$output" == *"root/root"* ]]
}

@test "db <client>: attaches Adminer to the site's project network" {
  run cmd_db acme
  [ "$status" -eq 0 ]
  grep -q "connect network connect wpsite_acme_default $WPSITE_ADMINER_CONTAINER" "$CALLS"
}

@test "db: unknown site -> resolver error (not a client or dev site)" {
  run cmd_db ghost
  [ "$status" -ne 0 ]
  [[ "$output" == *"No client or dev site named 'ghost'"* ]]
}

@test "db <client>: db container not running -> actionable error" {
  DB_RUNNING="false"
  run cmd_db acme
  [ "$status" -ne 0 ]
  [[ "$output" == *"No running database for 'acme'"* ]]
  [[ "$output" == *"wpsite build acme"* ]]
}

# --- last-used shortcut (wpsite db, no arg) --------------------------------

@test "db <client>: records the site as last-used" {
  run cmd_db acme
  [ "$status" -eq 0 ]
  [ "$(cat "$(dirname "$CFG")/last-db")" = "acme" ]
}

@test "db (no arg): reopens the last-used site" {
  printf 'acme\n' > "$(dirname "$CFG")/last-db"
  run cmd_db
  [ "$status" -eq 0 ]
  [[ "$output" == *"Reopening last-used site: acme"* ]]
  grep -q "open http://localhost:${WPSITE_ADMINER_PORT}/?wpsite_server=wp_acme_db" "$CALLS"
}

@test "db (no arg): no history -> guidance, exit non-zero" {
  run cmd_db
  [ "$status" -ne 0 ]
  [[ "$output" == *"No previous site to reopen"* ]]
}

@test "db (no arg): last-used site offline -> names it, does not start anything" {
  printf 'acme\n' > "$(dirname "$CFG")/last-db"
  DB_RUNNING="false"
  run cmd_db
  [ "$status" -ne 0 ]
  [[ "$output" == *"Reopening last-used site: acme"* ]]
  [[ "$output" == *"No running database for 'acme'"* ]]
  ! grep -q "compose up" "$CALLS"        # never auto-starts the site
}

@test "db (no arg): last-used site gone from config -> guidance" {
  printf 'ghost\n' > "$(dirname "$CFG")/last-db"
  run cmd_db
  [ "$status" -ne 0 ]
  [[ "$output" == *"no longer exists"* ]]
}
