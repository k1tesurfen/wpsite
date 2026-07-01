# shellcheck shell=bash
# wpsite start/stop <site> — pause and resume a built replica or dev site WITHOUT
# rebuilding. Both preserve the containers, the DB volume and the local files.
# <site> is any client or dev site.

cmd_start() {
  local client="${1:-}"
  config_require
  require_target "$client"
  require docker

  local docker_dir project local_host
  docker_dir="$(target_docker_dir "$client")"
  project="wpsite_${client}"
  local_host="$(target_local_host "$client")"

  [ -f "$docker_dir/docker-compose.yml" ] \
    || die "Nothing built for '$client'. Build a client with 'wpsite build $client', or create a dev site with 'wpsite new'."

  log_info "Starting '$client' replica..."
  # `up -d` (not `start`) so it also recreates any containers that were removed,
  # reusing the existing DB volume — never re-imports or rebuilds.
  ( cd "$docker_dir" && docker compose -p "$project" up -d )
  log_ok "Started: http://$local_host"
}

cmd_stop() {
  local client="${1:-}"
  config_require
  require docker

  if [ "$client" = "--all" ]; then
    log_info "Stopping ALL running replicas + dev sites..."
    local c d project
    for c in $(config_all_targets); do
      d="$(target_docker_dir "$c")"
      project="wpsite_${c}"
      if [ -f "$d/docker-compose.yml" ]; then
        log_info "Stopping '$c' (data preserved)..."
        ( cd "$d" && docker compose -p "$project" stop )
        log_ok "Stopped '$c'."
      fi
    done
    log_ok "Stopped all built sites."
    return 0
  fi

  require_target "$client"

  local docker_dir project
  docker_dir="$(target_docker_dir "$client")"
  project="wpsite_${client}"

  log_info "Stopping '$client' replica (data preserved)..."
  if [ -f "$docker_dir/docker-compose.yml" ]; then
    ( cd "$docker_dir" && docker compose -p "$project" stop )
  else
    docker compose -p "$project" stop 2>/dev/null || true
  fi
  log_ok "Stopped '$client'. Resume with: wpsite start $client"
}
