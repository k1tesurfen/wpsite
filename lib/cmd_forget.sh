# shellcheck shell=bash
# wpsite forget <client> [--purge] [--yes] — drop a client from WPSITE (not from mandos).
#
# The two registries are not linked (see common.sh): access (ssh key, target) is
# mandos's business and is never touched here. This removes wpsite's registry entry
# and the local replica; local backups are KEPT unless --purge; cloud backups are
# NEVER touched (cloud is the source of truth — delete those explicitly via `prune`).
# The next `wpsite backup <client>` registers it again.

cmd_forget() {
  local name="" purge=0 yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --purge)   purge=1; shift ;;
      --yes|-y)  yes=1; shift ;;
      -*) die "Unknown flag: $1" ;;
      *) if [ -z "$name" ]; then name="$1"; else die "Unexpected argument: $1"; fi; shift ;;
    esac
  done

  config_require_registry
  [ -n "$name" ] || die "Usage: wpsite forget <client> [--purge] [--yes]"
  if config_has_dev "$name"; then die "'$name' is a dev site — remove it with: wpsite destroy $name"; fi
  require_client "$name"

  local docker_dir project base
  docker_dir="$(client_docker_dir "$name")"
  project="wpsite_${name}"
  base="$(client_base "$name")"

  log_warn "About to forget client '$name' in wpsite:"
  log_warn "  • its entry in $(wpsite_team_file) (hold list, settings, …)"
  log_warn "  • its containers + DB volume + $docker_dir"
  if [ "$purge" = 1 ]; then
    local sz; sz="$(du -sh "$base" 2>/dev/null | cut -f1 || true)"
    log_warn "  • ALL local data under $base (${sz:-?}) — INCLUDING BACKUPS (irreversible)"
  else
    log_warn "  • local backups under $base are KEPT (add --purge to delete them too)"
  fi
  log_warn "  NOT touched: production access in mandos, and cloud backups."

  if [ "$yes" != 1 ]; then
    local ans=""
    if [ "$purge" = 1 ]; then
      printf 'Type the client name (%s) to permanently delete it AND its backups: ' "$name" >&2
      read -r ans 2>/dev/null < /dev/tty || read -r ans 2>/dev/null || ans=""
      [ "$ans" = "$name" ] || die "Aborted (name did not match)."
    else
      printf 'Forget this client in wpsite? [y/N] ' >&2
      read -r ans 2>/dev/null < /dev/tty || read -r ans 2>/dev/null || ans=""
      case "$ans" in y|Y|yes|YES) ;; *) log_info "Aborted; nothing removed."; return 0 ;; esac
    fi
  fi

  # Tear down the replica (best-effort; needs docker).
  if have docker; then
    log_info "Tearing down containers for '$name'..."
    _compose_down "$project" "$docker_dir"
    rm -rf "$docker_dir"
    _proxy_remove_route "$name"
  else
    log_warn "docker not found — skipping teardown (remove 'wp_${name}_*' containers manually)."
  fi

  wclient_forget "$name"
  log_ok "Forgot '$name' in wpsite (mandos access unchanged)."

  if [ "$purge" = 1 ]; then
    rm -rf "$base"
    log_ok "Purged local data under $base."
  elif [ -d "$base" ]; then
    log_info "Kept local data at $base (delete it by hand if you don't need the backups)."
  fi
  return 0
}
