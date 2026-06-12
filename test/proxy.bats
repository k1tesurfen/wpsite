#!/usr/bin/env bats
# Multi-site: compose rendering (no host port, joins proxy net) + Traefik file-provider
# route generation + DNS fallback logic. Docker/dnsmasq/sudo paths are integration-only.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_proxy.sh"
  source "$REPO/lib/cmd_build.sh"
  export WPSITE_PROXY_DIR="$BATS_TEST_TMPDIR/proxy"
}

@test "compose: no published host port (proxy routes instead)" {
  run _render_compose db app img acme acme.test
  [[ "$output" != *"ports:"* ]]
}

@test "compose: WordPress joins the external proxy network" {
  run _render_compose db app img acme acme.test
  [[ "$output" == *"external: true"* ]]
  [[ "$output" == *"name: wpsite_proxy"* ]]
  [[ "$output" == *"- proxy"* ]]
}

@test "compose: no Docker-socket / label routing (file provider only)" {
  run _render_compose db app img acme acme.test
  [[ "$output" != *"traefik"* ]]
  [[ "$output" != *"docker.sock"* ]]
}

@test "_proxy_write_route: writes a Host rule -> container URL" {
  _proxy_write_route acme acme.test
  f="$(_proxy_dynamic_dir)/acme.yml"
  [ -f "$f" ]
  grep -q 'Host(`acme.test`)' "$f"
  grep -q 'http://wp_acme_app:80' "$f"
  grep -q 'service: acme' "$f"
}

@test "_proxy_write_route: honours a custom host" {
  _proxy_write_route baker baker-custom.test
  grep -q 'Host(`baker-custom.test`)' "$(_proxy_dynamic_dir)/baker.yml"
}

@test "_proxy_remove_route: deletes the route file" {
  _proxy_write_route acme acme.test
  [ -f "$(_proxy_dynamic_dir)/acme.yml" ]
  _proxy_remove_route acme
  [ ! -f "$(_proxy_dynamic_dir)/acme.yml" ]
}

@test "_ensure_local_dns: wildcard DNS present -> does NOT touch /etc/hosts" {
  run env REPO="$REPO" RESOLVER="$BATS_TEST_TMPDIR/resolver" bash -c '
    set -euo pipefail
    source "$REPO/lib/common.sh"; source "$REPO/lib/cmd_proxy.sh"; source "$REPO/lib/cmd_build.sh"
    export WPSITE_RESOLVER="$RESOLVER"; : > "$WPSITE_RESOLVER"
    _add_hosts_entry() { echo "HOSTS_CALLED"; }
    _ensure_local_dns x.test
    echo DONE'
  [ "$status" -eq 0 ]
  [[ "$output" != *HOSTS_CALLED* ]]
  [[ "$output" == *DONE* ]]
}

@test "_ensure_local_dns: no wildcard DNS -> falls back to /etc/hosts" {
  run env REPO="$REPO" RESOLVER="$BATS_TEST_TMPDIR/none" bash -c '
    set -euo pipefail
    source "$REPO/lib/common.sh"; source "$REPO/lib/cmd_proxy.sh"; source "$REPO/lib/cmd_build.sh"
    export WPSITE_RESOLVER="$RESOLVER"
    _add_hosts_entry() { echo "HOSTS_CALLED:$1"; }
    _ensure_local_dns x.test'
  [ "$status" -eq 0 ]
  [[ "$output" == *"HOSTS_CALLED:x.test"* ]]
}

@test "cmd_proxy: unknown subcommand errors" {
  run env REPO="$REPO" bash -c '
    source "$REPO/lib/common.sh"; source "$REPO/lib/cmd_proxy.sh"
    cmd_proxy bogus'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown"* ]]
}
