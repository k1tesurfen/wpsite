# shellcheck shell=bash
# wpsite status — show running replicas and their URLs.

cmd_status() {
  config_require
  require docker
  local client app_c state host any=0
  printf '%-16s %-12s %s\n' "CLIENT" "STATE" "URL" >&2
  while IFS= read -r client; do
    [ -n "$client" ] || continue
    app_c="wp_${client}_app"
    state="$(docker inspect -f '{{.State.Status}}' "$app_c" 2>/dev/null || true)"
    [ -n "$state" ] || continue
    any=1
    host="$(client_local_host "$client")"
    printf '%-16s %-12s %s\n' "$client" "$state" "http://$host"
  done < <(config_clients)
  [ "$any" = "1" ] || log_info "No replicas are currently running."
}
