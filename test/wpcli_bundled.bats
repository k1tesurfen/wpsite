#!/usr/bin/env bats
# Bundled wp-cli fallback: when the host's `wp` cannot boot the site from our SSH login,
# wpsite uploads its own wp-cli.phar to the remote $HOME and runs `php <phar>` instead.
# Seen on gerfin (checkdomain/Plesk): /usr/local/bin/wp is WP-Toolkit's wrapper and
# fatals inside the chrooted SSH shell. All SSH is stubbed; a local file stands in for
# the remote phar. HOST_WP_OK / PHAR_OK drive whether each wp-cli boots.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_build.sh"
  source "$REPO/lib/cmd_apply.sh"
  CACHE="$BATS_TEST_TMPDIR/cache.phar"; echo "phar-v1" > "$CACHE"
  REMOTE="$BATS_TEST_TMPDIR/remote.phar"
  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
  HOST_WP_OK=1; PHAR_OK=1
  client_get() { case "$2" in ssh) echo u@h ;; wp_root) echo /var/www/x ;; esac; }
  _wp_cli_cache()      { printf '%s' "$CACHE"; }
  _wp_cli_cache_warm() { [ -s "$CACHE" ]; }
  wpsite_ssh() {
    shift; printf '%s\n' "$*" >> "$CALLS"
    case "$*" in
      cksum*)                      if [ -f "$REMOTE" ]; then cksum < "$REMOTE"; fi ;;
      *"cat >"*)                   cat > "$REMOTE" ;;
      *"wp-cli.phar\" core version"*) [ "$PHAR_OK" = 1 ] ;;
      *"&& wp core version"*)      [ "$HOST_WP_OK" = 1 ] ;;
      *)                           echo "ran: $*" ;;
    esac
  }
}

@test "prepare: host wp boots -> host wp, nothing uploaded" {
  _remote_wp_prepare acme
  [ "$_WPSITE_WP_BUNDLED" = 0 ]
  [ "$(_remote_wp_cmd)" = wp ]
  [ ! -e "$REMOTE" ]
}

@test "prepare: host wp broken -> uploads the phar, verifies it, switches to it (loudly)" {
  HOST_WP_OK=0
  run _remote_wp_prepare acme
  [[ "$output" == *"using bundled wp-cli"* ]]
  _WPSITE_WP_PREPARED=""; _remote_wp_prepare acme 2>/dev/null
  [ "$_WPSITE_WP_BUNDLED" = 1 ]
  cmp -s "$CACHE" "$REMOTE"
}

@test "prepare: re-uploads only when the phar changed; repeat calls are free" {
  HOST_WP_OK=0
  _remote_wp_prepare acme 2>/dev/null
  : > "$CALLS"
  _remote_wp_prepare acme 2>/dev/null
  [ ! -s "$CALLS" ]                               # same client, same process → no probe
  _WPSITE_WP_PREPARED=""; _remote_wp_prepare acme 2>/dev/null
  ! grep -q 'cat >' "$CALLS"                      # unchanged → no re-upload
  echo "phar-v2" > "$CACHE"
  _WPSITE_WP_PREPARED=""; _remote_wp_prepare acme 2>/dev/null
  grep -q 'cat >' "$CALLS"                        # cache changed → re-upload
  cmp -s "$CACHE" "$REMOTE"
}

@test "prepare: neither wp-cli boots -> stays on host wp (real error surfaces later)" {
  HOST_WP_OK=0; PHAR_OK=0
  _remote_wp_prepare acme 2>/dev/null
  [ "$_WPSITE_WP_BUNDLED" = 0 ]
}

@test "prepare: no local phar -> stays on host wp, hints prefetch" {
  HOST_WP_OK=0; rm -f "$CACHE"
  run _remote_wp_prepare acme
  [ "$status" -eq 0 ]
  [[ "$output" == *"wpsite prefetch"* ]]
}

@test "prepare: survives set -euo pipefail on first upload (no remote phar, cksum fails)" {
  run env REPO="$REPO" CACHE="$CACHE" REMOTE="$REMOTE" bash -c '
    set -euo pipefail
    source "$REPO/lib/common.sh"; source "$REPO/lib/cmd_build.sh"
    client_get() { case "$2" in ssh) echo u@h ;; wp_root) echo /r ;; esac; }
    _wp_cli_cache() { printf "%s" "$CACHE"; }; _wp_cli_cache_warm() { [ -s "$CACHE" ]; }
    wpsite_ssh() { shift; case "$*" in
      cksum*) return 1 ;; *"cat >"*) cat > "$REMOTE" ;;
      *"wp-cli.phar\" core version"*) return 0 ;; *) return 255 ;; esac; }
    _remote_wp_prepare acme; echo "bundled=$_WPSITE_WP_BUNDLED"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"bundled=1"* ]]
}

@test "_prod_wp: bundled runs php + the phar, host wp otherwise" {
  _WPSITE_WP_BUNDLED=1
  _prod_wp u@h /var/www/x option get home >/dev/null
  grep -q "cd '/var/www/x' && php .*\"\$HOME/.wpsite/wp-cli.phar\" option get home  *--allow-root" "$CALLS"
  : > "$CALLS"; _WPSITE_WP_BUNDLED=0
  _prod_wp u@h /var/www/x option get home >/dev/null
  ! grep -q 'wp-cli.phar' "$CALLS"
}
