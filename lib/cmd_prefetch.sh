# shellcheck shell=bash
# wpsite prefetch — warm the local caches so build/new/clone work OFFLINE later:
#   - download the wp-cli phar into <base_dir>/.cache (host curl)
#   - pull the core Docker images (WordPress latest, MariaDB, Traefik proxy, Mailpit)
# Writes a marker (<base_dir>/.cache/.prefetched) once the essentials are all present
# locally, so it's only done when it actually succeeded (offline runs don't mark).
#
# `wpsite prefetch --check` only tests the marker (exit 0 = done), no side effects — the
# GUI uses it to auto-run prefetch once in the background on first launch.

_prefetch_marker() { printf '%s/.cache/.prefetched' "$(config_base_dir)"; }

cmd_prefetch() {
  config_require

  if [ "${1:-}" = "--check" ]; then
    [ -f "$(_prefetch_marker)" ]
    return
  fi
  [ $# -eq 0 ] || die "Usage: wpsite prefetch [--check]"

  require docker
  mkdir -p "$(config_base_dir)/.cache"

  log_info "Warming local caches for offline use (this can take a few minutes)..."

  # 1) wp-cli phar (host download).
  if _wp_cli_cache_warm; then log_ok "  wp-cli cached."; else log_warn "  Could not cache wp-cli (offline?)."; fi

  # 2) Core Docker images. Keep going on failure so an offline run still tries the rest.
  local img
  for img in "wordpress:latest" "$WPSITE_DB_IMAGE" "$WPSITE_PROXY_IMAGE" "$WPSITE_MAIL_IMAGE"; do
    [ -n "$img" ] || continue
    log_info "  Pulling $img ..."
    if docker pull "$img" >/dev/null 2>&1; then log_ok "    $img ready."; else log_warn "    Could not pull $img (offline?)."; fi
  done

  # Mark done only when everything an offline new/clone needs is present locally.
  if [ -s "$(_wp_cli_cache)" ] \
     && docker image inspect "wordpress:latest"   >/dev/null 2>&1 \
     && docker image inspect "$WPSITE_DB_IMAGE"    >/dev/null 2>&1 \
     && docker image inspect "$WPSITE_PROXY_IMAGE" >/dev/null 2>&1 \
     && docker image inspect "$WPSITE_MAIL_IMAGE"  >/dev/null 2>&1; then
    touch "$(_prefetch_marker)"
    log_ok "Prefetch complete — offline build / new / clone is ready."
    return 0
  fi
  log_warn "Prefetch incomplete (some caches or images are missing). Re-run online to finish."
  return 1
}
