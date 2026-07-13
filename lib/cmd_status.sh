# shellcheck shell=bash
# wpsite status — show running replicas and their URLs.

# Colour a docker container state so it's scannable at a glance: running → green,
# exited/dead → red, transitional (paused/restarting/created/…) → yellow. Returns an
# empty string when colours are off (non-TTY / NO_COLOR), so callers degrade cleanly.
_status_color() { # state
  case "$1" in
    running)     printf '%s' "$_C_GRN" ;;
    exited|dead) printf '%s' "$_C_RED" ;;
    *)           printf '%s' "$_C_YEL" ;;
  esac
}

cmd_status() {
  config_require
  require docker
  local name app_c state color i w=4   # 4 = width of the "SITE" header
  local -a s_names=() s_kinds=() s_states=() s_hosts=()
  # First pass: collect the sites that actually have a container, and track the
  # longest name so the SITE column can size to fit (names like
  # "baulandentwicklung" overflow a fixed width and shove the other columns right).
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    app_c="wp_${name}_app"
    state="$(docker inspect -f '{{.State.Status}}' "$app_c" 2>/dev/null || true)"
    [ -n "$state" ] || continue
    s_names+=("$name"); s_kinds+=("$(target_kind "$name")")
    s_states+=("$state"); s_hosts+=("$(target_local_host "$name")")
    [ "${#name}" -gt "$w" ] && w="${#name}"
  done < <(config_all_targets)

  if [ "${#s_names[@]}" -eq 0 ]; then
    log_info "No sites are currently running."
    return 0
  fi

  # Second pass: print, using %-*s so the dynamic width lives in an ARG, not the
  # format string (keeps it a static literal — no SC2059). Header → stderr, rows →
  # stdout, matching the original split.
  printf '%-*s %-8s %-12s %s\n' "$w" "SITE" "KIND" "STATE" "URL" >&2
  for i in "${!s_names[@]}"; do
    color="$(_status_color "${s_states[$i]}")"
    # Pad the plain state INSIDE %-12s; wrap the colour codes OUTSIDE it, or the
    # zero-width escapes get counted in the field width and break alignment.
    printf '%-*s %-8s %s%-12s%s %s\n' \
      "$w" "${s_names[$i]}" "${s_kinds[$i]}" \
      "$color" "${s_states[$i]}" "$_C_RESET" "http://${s_hosts[$i]}"
  done
}
