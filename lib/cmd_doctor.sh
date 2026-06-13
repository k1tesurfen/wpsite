# shellcheck shell=bash
# wpsite doctor — verify dependencies and environment.

cmd_doctor() {
  local fail=0

  _check() { # cmd brew-pkg "purpose"
    local cmd="$1" pkg="$2" purpose="$3"
    if have "$cmd"; then
      log_ok "$cmd — $purpose"
    else
      log_error "$cmd missing ($purpose) → brew install $pkg"
      fail=1
    fi
  }

  log_info "Checking local dependencies..."
  _check yq      yq          "config parsing"
  _check docker  --cask\ docker "containers"
  _check tar     gnu-tar     "downloading backup artifacts"
  _check ffmpeg  ffmpeg      "video placeholders"
  _check ssh     openssh     "remote access"

  if have magick || have convert; then
    log_ok "imagemagick — image placeholders"
  else
    log_error "imagemagick missing (image placeholders) → brew install imagemagick"
    fail=1
  fi

  # Docker daemon
  if have docker; then
    if docker info >/dev/null 2>&1; then
      log_ok "docker daemon is running"
    else
      log_error "docker daemon not reachable — start Docker Desktop"
      fail=1
    fi
  fi

  # Config
  if [ -f "$WPSITE_CONFIG" ]; then
    log_ok "config present at $WPSITE_CONFIG"
    if have yq; then
      local n; n="$(config_clients 2>/dev/null | grep -c . || true)"
      log_info "  $n client(s) configured"
    fi
  else
    log_warn "no config at $WPSITE_CONFIG (copy wpsite.yml.example to start)"
  fi

  # Multi-site (optional — replicas still work via /etc/hosts without it)
  echo >&2
  log_info "Multi-site (optional)..."
  if _proxy_running 2>/dev/null; then
    log_ok "reverse proxy running"
  else
    log_info "reverse proxy not running (auto-starts on 'wpsite build')"
  fi
  if _mail_running 2>/dev/null; then
    log_ok "Mailpit running (inbox: http://localhost:${WPSITE_MAIL_UI_PORT:-8025})"
  else
    log_info "Mailpit not running (auto-starts on 'wpsite build')"
  fi
  if [ -f /etc/resolver/test ]; then
    if dscacheutil -q host -a name "wpsite-doctor.test" 2>/dev/null | grep -q '127.0.0.1'; then
      log_ok "wildcard *.test DNS resolves to 127.0.0.1"
    else
      log_warn "/etc/resolver/test exists but *.test doesn't resolve — is dnsmasq running? (sudo brew services restart dnsmasq)"
    fi
  else
    log_info "wildcard DNS not set up — 'wpsite proxy install-dns' removes the per-build sudo (otherwise /etc/hosts is used)"
  fi

  echo >&2
  if [ "$fail" = "0" ]; then
    log_ok "All required dependencies present."
  else
    die "Some dependencies are missing (see above)."
  fi
}
