# shellcheck shell=bash
# wpsite destroy <site> — full teardown: remove containers, network, the DB
# volume, and the local working dir. The inverse of `wpsite build` / `wpsite new`.
# For a dev site it also removes its .dev config entry. To only pause (keeping
# data), use `wpsite stop`. <site> is any client or dev site.

cmd_destroy() {
  local client="${1:-}"
  config_require
  require_target "$client"
  require docker

  local kind docker_dir project
  kind="$(target_kind "$client")"
  docker_dir="$(target_docker_dir "$client")"
  project="wpsite_${client}"

  log_info "Destroying '$client' (containers + DB volume + files)..."
  _compose_down "$project" "$docker_dir"
  rm -rf "$docker_dir"
  _proxy_remove_route "$client"   # drop its proxy route

  if [ "$kind" = "dev" ]; then
    config_remove_dev "$client"
    log_ok "Destroyed dev site '$client' (removed from config). Recreate with: wpsite new $client"
  else
    log_ok "Destroyed '$client'. Rebuild with: wpsite build $client"
  fi
}
