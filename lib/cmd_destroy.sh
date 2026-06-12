# shellcheck shell=bash
# wpsite destroy <client> — full teardown: remove containers, network, the DB
# volume, and the local working dir. The inverse of `wpsite build`.
# To only pause a replica (keeping data), use `wpsite stop`.

cmd_destroy() {
  local client="${1:-}"
  config_require
  require_client "$client"
  require docker

  local docker_dir project
  docker_dir="$(client_docker_dir "$client")"
  project="wpsite_${client}"

  log_info "Destroying '$client' replica (containers + DB volume + files)..."
  _compose_down "$project" "$docker_dir"
  rm -rf "$docker_dir"
  _proxy_remove_route "$client"   # drop its proxy route
  log_ok "Destroyed '$client'. Rebuild with: wpsite build $client"
}
