# shellcheck shell=bash
# wpsite migrate-registry [--apply] — one-off split of the old shared registry.
#
# Before: wpsite read ALL per-client settings from mandos's registry. After: mandos keeps
# access only (ssh, wp_root, cloud_folder); WordPress settings live in wpsite's own file
# (wpsite_team_file). This command
#   1. registers every client mandos knows in wpsite's registry (they're all in use), and
#   2. MOVES the WordPress keys (WPSITE_MIGRATE_KEYS) from mandos into wpsite's file:
#      written + read back in wpsite first, only then unset in mandos, and
#   3. DROPS stale access copies (ssh, wp_root, cloud_folder) from wpsite's file — the
#      derived path is where the PRE-mandos wpsite team file lived, which still carries
#      them. Only for clients mandos holds (mandos is authoritative for access); the old
#      file is copied to <file>.pre-split-<stamp> before the first write.
# Default is a DRY RUN that prints exactly what would change. Idempotent: re-running
# after --apply finds nothing left to do.

WPSITE_MIGRATE_KEYS="remote_tmp deactivate_plugins review_pages review_dismiss local_host cloud_dir login_path"
WPSITE_ACCESS_KEYS="ssh wp_root cloud_folder"
WPSITE_REGISTRY_HEADER="wpsite client registry — WordPress/maintenance settings per client, keyed by
client ID (hold_plugins, manual_updates, deactivate_plugins, review_pages, …).
Access (ssh, wp_root, Drive project folder) lives in mandos, NOT here.
Edited by wpsite (yq -i keeps comments); hand edits are fine."

cmd_migrate_registry() {
  local apply=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) apply=1; shift ;;
      *) die "Usage: wpsite migrate-registry [--apply]" ;;
    esac
  done
  config_require
  require "$MANDOS_BIN"

  local f dir; f="$(wpsite_team_file)"
  [ -n "$f" ] || die "Cannot resolve wpsite's registry path (configure mandos, or set team_config: in $WPSITE_CONFIG)."
  dir="$(dirname "$f")"
  [ -d "$dir" ] || [ -d "$(dirname "$dir")" ] || die "Neither $dir nor its parent exists (is Google Drive mounted?)"

  log_info "mandos registry: $(_team_config_path)"
  log_info "wpsite registry: $f$([ -f "$f" ] || echo '  (will be created)')"
  echo >&2

  local c k v changes=0 moves=() regs=()
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    wclient_has "$c" || { regs+=("$c"); changes=$((changes + 1)); }
    for k in $WPSITE_MIGRATE_KEYS; do
      v="$(client_get "$c" "$k")"
      [ -n "$v" ] || continue
      moves+=("$c"$'\t'"$k"$'\t'"$v"); changes=$((changes + 1))
    done
  done < <(access_clients)

  # Stale access copies left in wpsite's file (pre-mandos layout).
  local drops=()
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    for k in $WPSITE_ACCESS_KEYS; do
      v="$(wclient_get "$c" "$k")"
      [ -n "$v" ] || continue
      if access_has "$c"; then drops+=("$c"$'\t'"$k"); changes=$((changes + 1))
      else log_warn "$c.$k is in wpsite's file but $c is NOT in mandos — left in place (add the client to mandos first)."
      fi
    done
  done < <(wclient_list)

  if [ "$changes" = 0 ]; then log_ok "Nothing to migrate — registries are already split."; return 0; fi

  local m
  [ "${#regs[@]}" -gt 0 ] && log_info "Register in wpsite (${#regs[@]}): ${regs[*]}"
  if [ "${#moves[@]}" -gt 0 ]; then
    log_info "Move from mandos → wpsite (${#moves[@]}):"
    for m in "${moves[@]}"; do log_info "  $(printf '%s' "$m" | cut -f1): $(printf '%s' "$m" | cut -f2) = $(printf '%s' "$m" | cut -f3-)"; done
  fi
  if [ "${#drops[@]}" -gt 0 ]; then
    log_info "Drop stale access copies from wpsite's file (${#drops[@]}; mandos keeps them):"
    for m in "${drops[@]}"; do log_info "  $(printf '%s' "$m" | cut -f1).$(printf '%s' "$m" | cut -f2)"; done
  fi
  if [ "$apply" != 1 ]; then
    echo >&2; log_warn "Dry run — nothing changed. Re-run with --apply to perform exactly this."
    return 0
  fi

  mkdir -p "$dir"
  if [ -f "$f" ]; then
    local bak; bak="$f.pre-split-$(date +%Y%m%d_%H%M%S)"
    cp -p "$f" "$bak" || die "Could not back up $f — nothing changed."
    log_ok "Backed up the current file: $bak"
  fi
  for m in "${drops[@]+"${drops[@]}"}"; do
    C="$(printf '%s' "$m" | cut -f1)" K="$(printf '%s' "$m" | cut -f2)" _wq_write 'del(.clients[strenv(C)][strenv(K)])'
  done
  for c in "${regs[@]+"${regs[@]}"}"; do wclient_register "$c"; done
  local ck
  for m in "${moves[@]+"${moves[@]}"}"; do
    c="$(printf '%s' "$m" | cut -f1)"; k="$(printf '%s' "$m" | cut -f2)"; v="$(printf '%s' "$m" | cut -f3-)"
    wclient_register "$c"
    wclient_set "$c" "$k" "$v"
    ck="$(wclient_get "$c" "$k")"
    [ "$ck" = "$v" ] || die "Read-back mismatch for $c.$k in $f — mandos left untouched for it."
    client_unset "$c" "$k" || die "Could not unset $c.$k in mandos (value is already in wpsite; unset it by hand)."
  done
  H="$WPSITE_REGISTRY_HEADER" _wq_write '. head_comment = strenv(H)'
  log_ok "Registry split done: ${#regs[@]} registered, ${#moves[@]} key(s) moved, ${#drops[@]} stale access copies dropped — $f"
  return 0
}
