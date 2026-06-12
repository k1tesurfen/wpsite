# shellcheck shell=bash
# wpsite proxy <up|down|status|install-dns> — the shared reverse proxy + wildcard
# DNS that let every client replica run at once, each on its own <client>.test URL.
#
# Traefik routes via its FILE provider (not the Docker socket — that needs socket
# access that Docker Desktop doesn't grant containers reliably). Each replica drops
# a small route file into a watched dir; Traefik reaches the container by name over
# the shared `wpsite_proxy` network. The proxy auto-starts on `wpsite build`.

WPSITE_PROXY_NET="wpsite_proxy"
WPSITE_PROXY_CONTAINER="wpsite_proxy"
WPSITE_PROXY_IMAGE="traefik:v3"
WPSITE_PROXY_DIR="${WPSITE_PROXY_DIR:-$HOME/.config/wpsite/proxy}"

_proxy_dynamic_dir() { printf '%s/dynamic' "$WPSITE_PROXY_DIR"; }

_proxy_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$WPSITE_PROXY_CONTAINER" 2>/dev/null)" = "true" ]
}

# Ensure the shared network + Traefik (file provider) are up. Idempotent.
_proxy_ensure() {
  require docker
  local dyn; dyn="$(_proxy_dynamic_dir)"; mkdir -p "$dyn"
  docker network inspect "$WPSITE_PROXY_NET" >/dev/null 2>&1 \
    || docker network create "$WPSITE_PROXY_NET" >/dev/null
  _proxy_running && return 0
  docker rm -f "$WPSITE_PROXY_CONTAINER" >/dev/null 2>&1 || true   # clear a dead leftover
  log_info "Starting shared reverse proxy (Traefik) on :80..."
  docker run -d --name "$WPSITE_PROXY_CONTAINER" --restart unless-stopped \
    -p 80:80 \
    -v "$dyn":/etc/traefik/dynamic:ro \
    --network "$WPSITE_PROXY_NET" \
    "$WPSITE_PROXY_IMAGE" \
    --entrypoints.web.address=:80 \
    --providers.file.directory=/etc/traefik/dynamic \
    --providers.file.watch=true >/dev/null \
    || die "Could not start the proxy — is port 80 already taken? Check: lsof -nP -i :80"
}

# Write/remove a replica's route (Host(<host>) -> http://wp_<client>_app:80).
_proxy_write_route() { # client local_host
  local client="$1" host="$2" dyn; dyn="$(_proxy_dynamic_dir)"; mkdir -p "$dyn"
  cat > "$dyn/$client.yml" <<EOF
http:
  routers:
    $client:
      rule: "Host(\`$host\`)"
      entryPoints: [web]
      service: $client
  services:
    $client:
      loadBalancer:
        servers:
          - url: "http://wp_${client}_app:80"
EOF
}

_proxy_remove_route() { # client
  rm -f "$(_proxy_dynamic_dir)/${1:?}.yml"
}

cmd_proxy() {
  local sub="${1:-status}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    up)              _proxy_ensure; log_ok "Proxy is up on http://localhost (routes *.test)." ;;
    down)            require docker
                     if docker rm -f "$WPSITE_PROXY_CONTAINER" >/dev/null 2>&1; then
                       log_ok "Proxy stopped."
                     else
                       log_info "Proxy was not running."
                     fi ;;
    status)          _proxy_status ;;
    install-dns|dns) _proxy_install_dns ;;
    *) die "Unknown: wpsite proxy $sub (expected up|down|status|install-dns)" ;;
  esac
}

_proxy_status() {
  require docker
  if _proxy_running; then
    log_ok "Reverse proxy running ($WPSITE_PROXY_CONTAINER) on :80"
  else
    log_info "Reverse proxy not running (starts automatically on 'wpsite build')."
  fi
  if [ -f /etc/resolver/test ]; then
    log_ok "Wildcard DNS configured (/etc/resolver/test → 127.0.0.1)"
  else
    log_warn "Wildcard *.test DNS not set up — run 'wpsite proxy install-dns' to drop the per-build sudo."
  fi
  config_require 2>/dev/null || return 0
  local c state host
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    state="$(docker inspect -f '{{.State.Status}}' "wp_${c}_app" 2>/dev/null || true)"
    [ -n "$state" ] || continue
    host="$(client_local_host "$c")"
    printf '  %-16s %-10s http://%s\n' "$c" "$state" "$host"
  done < <(config_clients)
}

# One-time wildcard DNS: dnsmasq answers *.test with 127.0.0.1, and a macOS
# resolver routes the .test TLD to it. Needs sudo (port 53 + /etc/resolver).
_proxy_install_dns() {
  command -v brew >/dev/null 2>&1 || die "Homebrew required for dnsmasq setup."
  if ! command -v dnsmasq >/dev/null 2>&1; then
    log_info "Installing dnsmasq..."; brew install dnsmasq
  fi
  local conf; conf="$(brew --prefix)/etc/dnsmasq.conf"
  if ! grep -q '^address=/test/127.0.0.1' "$conf" 2>/dev/null; then
    log_info "Configuring dnsmasq: address=/test/127.0.0.1"
    printf '\naddress=/test/127.0.0.1\n' >> "$conf"
  fi
  log_info "Starting dnsmasq as a system service (sudo — binds port 53)..."
  sudo brew services restart dnsmasq
  log_info "Routing the .test TLD to dnsmasq (sudo)..."
  sudo mkdir -p /etc/resolver
  echo "nameserver 127.0.0.1" | sudo tee /etc/resolver/test >/dev/null
  log_ok "Wildcard DNS ready. Test it:  ping -c1 anything.test   (expect 127.0.0.1)"
  log_info "Future 'wpsite build' runs no longer touch /etc/hosts."
}
