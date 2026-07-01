# shellcheck shell=bash
# wpsite inject <devsite> [--from <path>] [--slug <name>] [--activate [--network]]
#
# Live-mount a local plugin checkout into a DEV site so edits on disk are reflected
# in the running container immediately (the symlink-into-Docker approach doesn't
# work; a bind mount does). Defaults to the Aule plugin at ~/git/aule.
#
# How it works:
#   1. Renames the dev site's existing wp-content/plugins/<slug> → <slug>-alt so the
#      mount point is clean and the original copy is preserved (inactive).
#   2. Writes docker-compose.override.yml adding a bind mount
#      <path> → /var/www/html/wp-content/plugins/<slug>. Compose auto-merges the
#      override (volumes are concatenated, so ./wp-content survives).
#   3. Recreates the container (`up -d`) to apply the mount.
#   4. --activate: activate the plugin via wp-cli after the mount. On a multisite
#      dev site, --network activates it network-wide (--network implies --activate);
#      without --network on a multisite it activates on the network's main site.
#
# Inject-only by design: to revert, `wpsite build`/rebuild the dev site (which wipes
# the docker dir and re-extracts a fresh plugin), or delete docker-compose.override.yml
# and restore <slug>-alt yourself.

cmd_inject() {
  local site="" from="" slug="aule" activate=0 network=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --from)     from="${2:-}"; shift 2 ;;
      --from=*)   from="${1#*=}"; shift ;;
      --slug)     slug="${2:-}"; shift 2 ;;
      --slug=*)   slug="${1#*=}"; shift ;;
      --activate) activate=1; shift ;;
      --network)  network=1; activate=1; shift ;;   # network-wide implies activation
      -*) die "Unknown flag: $1" ;;
      *)  site="$1"; shift ;;
    esac
  done

  config_require
  require docker
  [ -n "$site" ] || die "Usage: wpsite inject <devsite> [--from <path>] [--slug <name>]"

  # Dev sites only — client replicas mirror production; don't live-mount dev code there.
  require_target "$site"
  config_has_dev "$site" || die "'$site' is not a dev site. inject only works on dev sites (see: wpsite list)."

  # Resolve + validate the plugin source (must be an absolute dir; Docker bind
  # mounts require absolute paths).
  [ -n "$from" ] || from="$HOME/git/aule"
  from="$(expand_tilde "$from")"
  [ -d "$from" ] || die "Plugin source not found: $from"
  case "$from" in /*) ;; *) from="$(cd "$from" && pwd)" ;; esac
  ls "$from"/*.php >/dev/null 2>&1 || log_warn "No top-level .php in $from — is this a plugin folder?"

  # Slug becomes a plugins/<slug> folder name — keep it filesystem-safe.
  [[ "$slug" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid --slug '$slug' (letters, digits, . _ - only)."

  local docker_dir project plugins_dir
  docker_dir="$(target_docker_dir "$site")"
  project="wpsite_${site}"
  [ -f "$docker_dir/docker-compose.yml" ] \
    || die "Nothing built for '$site' yet. Create it with 'wpsite new' or 'wpsite clone' first."
  plugins_dir="$docker_dir/wp-content/plugins"
  mkdir -p "$plugins_dir"

  # Preserve any real existing plugin folder as <slug>-alt (so the mount overlays a
  # clean path and the original stays around, inactive). Skip if it's already just
  # the empty mount point from a previous inject.
  local target="$plugins_dir/$slug" alt="$plugins_dir/$slug-alt"
  if [ -d "$target" ] && [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
    if [ -e "$alt" ]; then
      log_warn "$slug-alt already exists — leaving it; removing the stale $slug folder."
      rm -rf "${target:?}"
    else
      log_info "Renaming existing plugins/$slug → $slug-alt (preserved, inactive)."
      mv "$target" "$alt"
    fi
  fi
  # Drop any leftover empty mount-point dir so Docker recreates it cleanly.
  [ -d "$target" ] && rmdir "$target" 2>/dev/null || true

  # Write the override (overwritten on every inject — last --from/--slug wins).
  cat > "$docker_dir/docker-compose.override.yml" <<EOF
# Written by \`wpsite inject\` — live-mounts a local plugin into this dev site.
# Delete this file (and rebuild) to revert. Compose auto-merges it on up/start.
services:
  wordpress:
    volumes:
      - $from:/var/www/html/wp-content/plugins/$slug
EOF

  log_info "Injecting $from → plugins/$slug in '$site'..."
  ( cd "$docker_dir" && docker compose -p "$project" up -d )
  log_ok "Injected. Edits in $from are now live at http://$(target_local_host "$site")"

  if [ "$activate" = 1 ]; then
    _activate_injected "wp_${site}_app" "$slug" "$network" "$(target_local_host "$site")"
  fi
}

# Activate the just-injected plugin via wp-cli in the (recreated) app container.
# Detects multisite from the running site (not stored metadata). Network-wide when
# requested; otherwise per-site (main site on a multisite). Never fatal — a failed
# activation warns with the manual command so the mount itself still counts as done.
_activate_injected() { # app_container slug network main_host
  local app_c="$1" slug="$2" network="$3" main_host="$4"
  if ! _ensure_wp_cli "$app_c"; then
    log_warn "wp-cli unavailable in $app_c — skipping activation; activate manually."
    return 0
  fi
  local wpc=(docker exec "$app_c" wp --allow-root --path=/var/www/html)
  local manual="docker exec $app_c wp --allow-root --path=/var/www/html plugin activate $slug"

  local is_ms=0
  if "${wpc[@]}" core is-installed --network >/dev/null 2>&1; then is_ms=1; fi

  if [ "$network" = 1 ] && [ "$is_ms" != 1 ]; then
    log_warn "This dev site is not a multisite — ignoring --network, activating normally."
    network=0
  fi

  if [ "$network" = 1 ]; then
    log_info "Network-activating '$slug' across the multisite..."
    if "${wpc[@]}" plugin activate "$slug" --network >/dev/null 2>&1; then
      log_ok "'$slug' network-activated."
    else
      log_warn "Could not network-activate '$slug'. Try: $manual --network"
    fi
    return 0
  fi

  # Per-site: on a multisite, target the network's main host explicitly.
  local -a urlopt=()
  if [ "$is_ms" = 1 ] && [ -n "$main_host" ]; then
    urlopt=(--url="$main_host")
    log_info "Activating '$slug' on the main site ($main_host)..."
  else
    log_info "Activating '$slug'..."
  fi
  if "${wpc[@]}" plugin activate "$slug" "${urlopt[@]:+"${urlopt[@]}"}" >/dev/null 2>&1; then
    log_ok "'$slug' activated."
  else
    log_warn "Could not activate '$slug'. Try: $manual"
  fi
  return 0
}
