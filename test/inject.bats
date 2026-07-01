#!/usr/bin/env bats
# wpsite inject — live-mount a local plugin into a dev site (docker stubbed).

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
dev:
  myshop:
    host: myshop.test
EOF
  export WPSITE_CONFIG="$CFG"
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_build.sh"     # provides _ensure_wp_cli (used by --activate)
  source "$REPO/lib/cmd_inject.sh"

  require() { :; }
  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  # docker stub: record `compose` verbs; answer `exec` calls the activation path makes.
  # MS_RC controls multisite detection (0 = multisite); ACT_RC the activate outcome.
  docker() {
    if [ "$1" = compose ]; then shift; echo "compose $*" >> "$CALLS"; return 0; fi
    if [ "$1" = exec ]; then
      local all="$*"
      case "$all" in
        *"core is-installed --network"*) return "${MS_RC:-1}" ;;          # is it multisite?
        *"plugin activate"*) echo "activate: $all" >> "$CALLS"; return "${ACT_RC:-0}" ;;
        *) return 0 ;;                                                     # wp-presence check etc.
      esac
    fi
    return 0
  }

  # A fake plugin checkout to mount.
  SRC="$BATS_TEST_TMPDIR/git/aule"
  mkdir -p "$SRC"; echo "<?php" > "$SRC/aule.php"

  # A "built" dev site with an existing aule plugin folder.
  DDIR="$(dev_docker_dir myshop)"
  mkdir -p "$DDIR/wp-content/plugins/aule"
  touch "$DDIR/docker-compose.yml"
  echo "original" > "$DDIR/wp-content/plugins/aule/aule.php"
}

@test "inject writes the override mount, preserves the original, restarts" {
  run cmd_inject myshop --from "$SRC"
  [ "$status" -eq 0 ]
  local ov="$DDIR/docker-compose.override.yml"
  [ -f "$ov" ]
  grep -qF "$SRC:/var/www/html/wp-content/plugins/aule" "$ov"
  # original renamed, mount point cleaned
  [ -f "$DDIR/wp-content/plugins/aule-alt/aule.php" ]
  [ ! -d "$DDIR/wp-content/plugins/aule" ]
  grep -q "compose -p wpsite_myshop up -d" "$CALLS"
}

@test "inject defaults --from to ~/git/aule" {
  # Override HOME so the default resolves into our fixture.
  HOME="$BATS_TEST_TMPDIR" run cmd_inject myshop
  [ "$status" -eq 0 ]
  grep -qF "$BATS_TEST_TMPDIR/git/aule:/var/www/html/wp-content/plugins/aule" \
    "$DDIR/docker-compose.override.yml"
}

@test "inject honours --slug" {
  run cmd_inject myshop --from "$SRC" --slug my-plugin
  [ "$status" -eq 0 ]
  grep -qF ":/var/www/html/wp-content/plugins/my-plugin" "$DDIR/docker-compose.override.yml"
}

@test "inject refuses a client (dev sites only)" {
  run cmd_inject acme --from "$SRC"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a dev site"* ]]
}

@test "inject refuses an unbuilt dev site" {
  rm -f "$DDIR/docker-compose.yml"
  run cmd_inject myshop --from "$SRC"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Nothing built"* ]]
}

@test "inject rejects a missing plugin source" {
  run cmd_inject myshop --from "$BATS_TEST_TMPDIR/nope"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "inject rejects an invalid slug" {
  run cmd_inject myshop --from "$SRC" --slug "bad/slug"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid --slug"* ]]
}

# --- activation ------------------------------------------------------------

@test "inject without --activate does not activate" {
  run cmd_inject myshop --from "$SRC"
  [ "$status" -eq 0 ]
  ! grep -q "activate:" "$CALLS"
}

@test "inject --activate activates the plugin (single site: no --network/--url)" {
  MS_RC=1 run cmd_inject myshop --from "$SRC" --activate
  [ "$status" -eq 0 ]
  grep -q "plugin activate aule" "$CALLS"
  ! grep -q "plugin activate aule --network" "$CALLS"
  ! grep -q -- "--url=" "$CALLS"
}

@test "inject --network network-activates on a multisite" {
  MS_RC=0 run cmd_inject myshop --from "$SRC" --network
  [ "$status" -eq 0 ]
  grep -q "plugin activate aule --network" "$CALLS"
}

@test "inject --activate on a multisite targets the main-site url" {
  MS_RC=0 run cmd_inject myshop --from "$SRC" --activate
  [ "$status" -eq 0 ]
  grep -qF "plugin activate aule --url=myshop.test" "$CALLS"
}

@test "inject --network on a non-multisite warns and activates normally" {
  MS_RC=1 run cmd_inject myshop --from "$SRC" --network
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a multisite"* ]]
  grep -q "plugin activate aule" "$CALLS"
  ! grep -q "plugin activate aule --network" "$CALLS"
}

@test "inject activation failure warns but does not fail the inject" {
  ACT_RC=1 MS_RC=1 run cmd_inject myshop --from "$SRC" --activate
  [ "$status" -eq 0 ]
  [[ "$output" == *"Could not activate"* ]]
}
