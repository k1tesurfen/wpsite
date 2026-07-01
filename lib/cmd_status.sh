# shellcheck shell=bash
# wpsite status — show running replicas and their URLs.

cmd_status() {
  config_require
  require docker
  local name kind app_c state host any=0
  printf '%-16s %-8s %-12s %s\n' "SITE" "KIND" "STATE" "URL" >&2
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    app_c="wp_${name}_app"
    state="$(docker inspect -f '{{.State.Status}}' "$app_c" 2>/dev/null || true)"
    [ -n "$state" ] || continue
    any=1
    kind="$(target_kind "$name")"
    host="$(target_local_host "$name")"
    printf '%-16s %-8s %-12s %s\n' "$name" "$kind" "$state" "http://$host"
  done < <(config_all_targets)
  [ "$any" = "1" ] || log_info "No sites are currently running."
}
