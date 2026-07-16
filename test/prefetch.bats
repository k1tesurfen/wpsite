#!/usr/bin/env bats
# `wpsite prefetch` — the --check marker gate + the warm/pull/mark flow. docker and the
# wp-cli download are stubbed (the cache is pre-seeded so _wp_cli_cache_warm needs no net).

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"

  BASE="$BATS_TEST_TMPDIR/root"
  CFG="$BATS_TEST_TMPDIR/w.yml"
  printf 'base_dir: %s\n' "$BASE" > "$CFG"
  export WPSITE_CONFIG="$CFG"
  export MANDOS_BIN="$REPO/test/fixtures/mandos-stub"
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_build.sh"    # _wp_cli_cache(_warm), WPSITE_DB_IMAGE
  source "$REPO/lib/cmd_proxy.sh"    # WPSITE_PROXY_IMAGE
  source "$REPO/lib/cmd_mail.sh"     # WPSITE_MAIL_IMAGE
  source "$REPO/lib/cmd_prefetch.sh"

  require() { :; }
  # docker stub: `pull` succeeds; `image inspect` outcome is INSPECT_RC (default 0).
  docker() {
    case "$1" in
      pull)  return 0 ;;
      image) [ "$2" = inspect ] && return "${INSPECT_RC:-0}" ;;
    esac
    return 0
  }
}

@test "prefetch --check: non-zero without marker, zero with it" {
  run cmd_prefetch --check
  [ "$status" -ne 0 ]
  mkdir -p "$BASE/.cache"; touch "$BASE/.cache/.prefetched"
  run cmd_prefetch --check
  [ "$status" -eq 0 ]
}

@test "prefetch: warms cache + pulls + writes the marker when everything is present" {
  mkdir -p "$BASE/.cache"; echo phar > "$BASE/.cache/wp-cli.phar"   # already warm (no download)
  run cmd_prefetch
  [ "$status" -eq 0 ]
  [ -f "$BASE/.cache/.prefetched" ]
  run cmd_prefetch --check
  [ "$status" -eq 0 ]
}

@test "prefetch: does NOT mark when an image is missing (offline)" {
  mkdir -p "$BASE/.cache"; echo phar > "$BASE/.cache/wp-cli.phar"
  INSPECT_RC=1 run cmd_prefetch
  [ "$status" -ne 0 ]
  [ ! -f "$BASE/.cache/.prefetched" ]
}
