# shellcheck shell=bash
# Per-client lists in wpsite's registry (see common.sh — never in mandos):
#
#   wpsite hold   <c>                                 list held plugins
#   wpsite hold   <c> <slug> [--reason "…"]           never auto-update <slug> (plugin OR
#                                                     theme) for <c>
#   wpsite hold   <c> <plugin> --remove               release it again
#   wpsite manual <c> [<item> [--reason "…"] [--remove]]
#                   items WP-CLI can't update/see (e.g. greyd_suite): upgrade/apply
#                   remind you to update them by hand in wp-admin
#   wpsite show   <c> [<key>]                          everything wpsite knows about <c>
#                   (or one value, porcelain — the GUI reads login_path this way)
#
# Held plugins are skipped by BOTH `upgrade` and `apply`; manual items are reminders only.

# Map names: registry key per list.
WPSITE_HOLD_MAP="hold_plugins"
WPSITE_MANUAL_MAP="manual_updates"

# Slugs as WP-CLI prints them (plugin/theme directory names).
_valid_slug() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

# Shared implementation for hold + manual.
_client_list_cmd() { # verb map noun args...
  local verb="$1" map="$2" noun="$3"; shift 3
  local client="" item="" reason="" remove=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason) [ $# -ge 2 ] || die "--reason needs a value"; reason="$2"; shift 2 ;;
      --remove|--off) remove=1; shift ;;
      -*) die "Unknown flag: $1" ;;
      *) if [ -z "$client" ]; then client="$1"
         elif [ -z "$item" ]; then item="$1"
         else die "Unexpected argument: $1"; fi; shift ;;
    esac
  done
  [ -n "$client" ] || die "Usage: wpsite $verb <client> [<$noun> [--reason \"…\"] [--remove]]"
  config_require_registry
  require_client "$client"

  if [ -z "$item" ]; then
    local n=0 k
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      printf '%s\t%s\n' "$k" "$(wclient_map_get "$client" "$map" "$k")"
      n=$((n + 1))
    done < <(wclient_map_keys "$client" "$map")
    [ "$n" -gt 0 ] || log_info "No ${noun}s on the $verb list for '$client'."
    return 0
  fi

  _valid_slug "$item" || die "Not a valid $noun slug: '$item'"
  if [ "$remove" = 1 ]; then
    if ! wclient_map_has "$client" "$map" "$item"; then
      log_info "'$item' is not on the $verb list for '$client'."; return 0
    fi
    wclient_map_del "$client" "$map" "$item"
    log_ok "Removed '$item' from the $verb list for '$client'."
    return 0
  fi
  local value; value="${reason:-$verb}"
  value="$value ($(date +%Y-%m-%d))"
  wclient_map_set "$client" "$map" "$item" "$value"
  log_ok "'$item' is on the $verb list for '$client': $value"
  return 0
}

cmd_hold()   { _client_list_cmd hold   "$WPSITE_HOLD_MAP"   slug   "$@"; }
cmd_manual() { _client_list_cmd manual "$WPSITE_MANUAL_MAP" item   "$@"; }

# Access fields live in mandos; everything else in wpsite's registry.
_show_value() { # client key
  case "$2" in
    ssh|wp_root|cloud_folder) client_get "$1" "$2" ;;
    *) wclient_get "$1" "$2" ;;
  esac
  return 0
}

cmd_show() {
  local client="${1:-}" key="${2:-}"
  [ -n "$client" ] || die "Usage: wpsite show <client> [<key>]"
  config_require_registry
  require_client "$client"
  if [ -n "$key" ]; then _show_value "$client" "$key"; return 0; fi

  local k v
  printf 'Client: %s\n' "$client"
  printf '\nAccess (mandos):\n'
  if access_has "$client"; then
    for k in ssh wp_root cloud_folder; do
      v="$(client_get "$client" "$k")"; [ -n "$v" ] && printf '  %-14s %s\n' "$k" "$v"
    done
  else
    printf '  (none — no production access; local commands still work)\n'
  fi
  printf '\nwpsite (%s):\n' "$(wpsite_team_file)"
  while IFS= read -r k; do
    case "$k" in ''|"$WPSITE_HOLD_MAP"|"$WPSITE_MANUAL_MAP") continue ;; esac
    printf '  %-14s %s\n' "$k" "$(wclient_get "$client" "$k" | tr '\n' ' ' | sed 's/ *$//')"
  done < <(C="$client" _wq '(.clients[strenv(C)] // {}) | keys | .[]')
  local map title
  for map in "$WPSITE_HOLD_MAP" "$WPSITE_MANUAL_MAP"; do
    title="Held (never auto-updated)"; [ "$map" = "$WPSITE_MANUAL_MAP" ] && title="Manual updates (reminders)"
    printf '\n%s:\n' "$title"
    local any=0
    while IFS= read -r k; do
      [ -n "$k" ] || continue; any=1
      printf '  %-28s %s\n' "$k" "$(wclient_map_get "$client" "$map" "$k")"
    done < <(wclient_map_keys "$client" "$map")
    [ "$any" = 1 ] || printf '  (none)\n'
  done
  return 0
}
