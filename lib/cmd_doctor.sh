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
  _check rsync   rsync       "downloading backup artifacts"
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

  echo >&2
  if [ "$fail" = "0" ]; then
    log_ok "All required dependencies present."
  else
    die "Some dependencies are missing (see above)."
  fi
}
