# shellcheck shell=bash
# wpsite doctor — verify dependencies and environment.
#
# Runs on both supported platforms (see CLAUDE.md "What this is"). Everything
# platform-specific goes through a shim in common.sh (_pkg_hint, _resolves_loopback,
# wpsite_resolver_file) rather than a `uname` branch here, and the machine's ROLE is
# reported from capability: mandos present = gateway (registry + production reachable),
# absent = dev box, which is a supported configuration and NOT a failure.

cmd_doctor() {
  local fail=0

  _check() { # cmd brew_pkg apt_pkg "purpose"
    local cmd="$1" brewp="$2" aptp="$3" purpose="$4"
    if have "$cmd"; then
      log_ok "$cmd — $purpose"
    else
      log_error "$cmd missing ($purpose) → $(_pkg_hint "$brewp" "$aptp")"
      fail=1
    fi
  }

  log_info "Checking local dependencies..."
  _check yq     yq             yq       "config parsing"
  _check docker "--cask docker" docker-ce "containers"
  _check tar    gnu-tar        tar      "downloading backup artifacts"
  _check ffmpeg ffmpeg         ffmpeg   "video placeholders"
  _check ssh    openssh        openssh-client "remote access"

  if have magick || have convert; then
    log_ok "imagemagick — image placeholders"
  else
    log_error "imagemagick missing (image placeholders) → $(_pkg_hint imagemagick imagemagick)"
    fail=1
  fi

  # Docker daemon
  if have docker; then
    if docker info >/dev/null 2>&1; then
      log_ok "docker daemon is running"
    else
      if have systemctl; then
        log_error "docker daemon not reachable — sudo systemctl start docker"
      else
        log_error "docker daemon not reachable — start Docker Desktop"
      fi
      fail=1
    fi
  fi

  # --- Role -----------------------------------------------------------------
  # mandos owns the client registry, SSH-key onboarding and the Drive root. A dev box
  # deliberately has none of it and runs clone/new/inject/lifecycle without it, so its
  # absence is informational. See DEVBOX-PLAN.md.
  echo >&2
  local role="dev box"
  if have "$MANDOS_BIN"; then
    role="gateway"
    log_ok "mandos present — client registry available (role: gateway)"
  else
    log_info "mandos not installed → role: dev box"
    log_info "  available: clone, new, inject, start/stop/destroy, db, status, list"
    log_info "  unavailable (gateway-only): backup, build, upgrade, apply, redirect, prune, client, test"
  fi

  # Config
  echo >&2
  if [ -f "$WPSITE_CONFIG" ]; then
    log_ok "config present at $WPSITE_CONFIG"
    log_info "  base_dir: $(config_base_dir)"
    log_info "  dev-site host suffix: .$(config_dev_suffix)"
    if have yq && [ "$role" = "gateway" ]; then
      # Team config (shared client definitions in Drive), when configured.
      local team; team="$(_team_config_path)"
      if [ -n "$team" ]; then
        if [ -f "$team" ]; then
          log_ok "team config reachable at $team"
          # A Drive "conflicted copy" means two people wrote it at once — flag it.
          local conflicts; conflicts="$(find "$(dirname "$team")" -maxdepth 1 -iname '*conflicted*' 2>/dev/null | grep -c . || true)"
          [ "$conflicts" -gt 0 ] && log_warn "  $conflicts 'conflicted copy' file(s) next to it — resolve them (concurrent edits)"
        else
          log_warn "team config set but NOT reachable: $team (is Google Drive mounted?)"
        fi
      fi
      local n; n="$(config_clients 2>/dev/null | grep -c . || true)"
      log_info "  $n client(s) configured"
    fi
    local d; d="$(config_dev_sites 2>/dev/null | grep -c . || true)"
    log_info "  $d dev site(s) configured"
  else
    log_warn "no config at $WPSITE_CONFIG (run 'wpsite setup' or copy wpsite.yml.example)"
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

  local resolver; resolver="$(wpsite_resolver_file)"
  if [ -f "$resolver" ]; then
    if _resolves_loopback "wpsite-doctor.test"; then
      log_ok "wildcard *.test DNS resolves to 127.0.0.1"
    else
      log_warn "$resolver exists but *.test doesn't resolve — is dnsmasq running?"
      have brew && log_warn "  try: sudo brew services restart dnsmasq"
    fi
  elif have brew; then
    log_info "wildcard DNS not set up — 'wpsite proxy install-dns' removes the per-build sudo (otherwise /etc/hosts is used)"
  else
    log_info "wildcard *.test DNS not configured — normal here; per-site /etc/hosts"
    log_info "  entries are added automatically on build (see 'wpsite proxy install-dns')"
  fi

  echo >&2
  if [ "$fail" = "0" ]; then
    log_ok "All required dependencies present."
  else
    die "Some dependencies are missing (see above)."
  fi
}
