# shellcheck shell=bash
# Cloud backup sync — mirror local backups to a mounted Google Drive folder.
#
# Model: the CLOUD is the single source of truth; local is a fast cache. Backups
# mirror by the YYYYMMDD_HHMMSS(-permanent)? folder pattern ONLY — any other file
# in the client's Drive folder (.wpstg archives, assets, …) is invisible here and
# never touched. A per-client MANIFEST (local, never in Drive) records which backup
# ids were known-synced at the last run; it lets sync tell a NEW offline backup
# (upload it) apart from one DELETED on the cloud (delete it locally), and doubles
# as a human-readable audit log. See CLAUDE.md "Cloud backup sync".
#
# Sourced by bin/wpsite (explicitly — the cmd_*.sh glob doesn't catch it). Helpers
# here are reused by both `backup` (push/sync) and `prune` (cloud-aware delete).

# Manifest + audit-log paths (under the client's local base, NOT in Drive).
_manifest_file()     { printf '%s/.cloud-sync-state' "$(client_base "$1")"; }
_manifest_log_file() { printf '%s/.cloud-sync.log'  "$(client_base "$1")"; }

# Read the synced-id set (one id per line). Empty/missing → nothing.
_manifest_read() { # client
  local f; f="$(_manifest_file "$1")"
  [ -f "$f" ] && cat "$f"
  return 0
}

# Is <id> in the manifest? (status helper — use in `if`.)
_manifest_has() { # client id
  local f; f="$(_manifest_file "$1")"
  [ -f "$f" ] || return 1
  grep -qxF "$2" "$f"
}

_manifest_add() { # client id
  local f; f="$(_manifest_file "$1")"
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  { [ -f "$f" ] && cat "$f"; printf '%s\n' "$2"; } | sort -u > "$f.tmp" && mv "$f.tmp" "$f"
  return 0
}

_manifest_remove() { # client id
  local f; f="$(_manifest_file "$1")"
  [ -f "$f" ] || return 0
  grep -vxF "$2" "$f" > "$f.tmp" 2>/dev/null || true
  mv "$f.tmp" "$f" 2>/dev/null || true
  return 0
}

# Append a timestamped audit line. Best-effort; never fails the caller.
_audit_log() { # client action id
  local f; f="$(_manifest_log_file "$1")"
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  printf '%s  %-8s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$2" "$3" >> "$f" 2>/dev/null || true
  return 0
}

# Complete backup folder ids (basenames), local side. Skips temp/partial/unrelated
# dirs: must match the id pattern AND contain all core artifacts.
_local_backup_ids() { # client
  local bd d name; bd="$(client_backup_dir "$1")"
  [ -d "$bd" ] || return 0
  for d in "$bd"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"; name="$(basename "$d")"
    _is_backup_id "$name" || continue
    _is_complete_backup "$d" || continue
    printf '%s\n' "$name"
  done
  return 0
}

# Complete backup folder ids, cloud side (only the ids matching our naming pattern).
_cloud_backup_ids() { # client
  local cd d name; cd="$(client_cloud_dir "$1")"
  [ -n "$cd" ] && [ -d "$cd" ] || return 0
  for d in "$cd"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"; name="$(basename "$d")"
    _is_backup_id "$name" || continue
    _is_complete_backup "$d" || continue
    printf '%s\n' "$name"
  done
  return 0
}

# Atomic directory copy onto the Drive mount: stage to a sibling .tmp then rename,
# so an interrupted copy never leaves a folder that looks "complete".
_cloud_copy_in() { # src_dir dest_dir
  local src="$1" dest="$2" tmp="$2.tmp.$$"
  rm -rf "$tmp"
  if have rsync; then
    rsync -a "$src/" "$tmp/" || { rm -rf "$tmp"; return 1; }
  else
    mkdir -p "$tmp" || { rm -rf "$tmp"; return 1; }
    cp -R "$src/." "$tmp/" || { rm -rf "$tmp"; return 1; }
  fi
  rm -rf "$dest"
  mv "$tmp" "$dest" || { rm -rf "$tmp"; return 1; }
  return 0
}

# Push ONE local backup to the cloud (used by auto-push after `backup`, and by the
# upload branch of sync). Returns non-zero (no die) if the cloud is unavailable or
# the copy fails — callers warn and carry on.
_cloud_push_one() { # client id
  local client="$1" id="$2" bd cd src
  cloud_available "$client" || return 1
  bd="$(client_backup_dir "$client")"; src="$bd/$id"
  _is_complete_backup "$src" || { log_warn "$client: skipping cloud push of $id (incomplete)."; return 1; }
  cd="$(client_cloud_dir "$client")"
  mkdir -p "$cd" 2>/dev/null || { log_warn "$client: cannot create cloud dir $cd"; return 1; }
  if _cloud_copy_in "$src" "$cd/$id"; then
    _manifest_add "$client" "$id"
    _audit_log "$client" push "$id"
    return 0
  fi
  log_warn "$client: cloud push of $id failed."
  return 1
}

# Delete a backup from local and/or cloud + drop it from the manifest. scope is
# both (default) | local | cloud. Returns non-zero if any removal failed.
_do_delete_backup() { # client id [scope]
  local client="$1" id="$2" scope="${3:-both}" bd cd ok=1
  bd="$(client_backup_dir "$client")"
  if [ "$scope" != cloud ] && [ -d "$bd/$id" ]; then
    rm -rf "${bd:?}/${id:?}" || { log_warn "$client: failed to delete local $id"; ok=0; }
  fi
  if [ "$scope" != local ] && cloud_available "$client"; then
    cd="$(client_cloud_dir "$client")"
    [ -d "$cd/$id" ] && { rm -rf "${cd:?}/${id:?}" || { log_warn "$client: failed to delete cloud $id"; ok=0; }; }
  fi
  _manifest_remove "$client" "$id"
  _audit_log "$client" delete "$id"
  [ "$ok" = 1 ]
}

# Mirror a local rename (persist on/off) to the cloud + manifest. Best-effort.
_cloud_rename() { # client oldid newid
  cloud_available "$1" || return 0
  local cd; cd="$(client_cloud_dir "$1")"
  [ -d "$cd/$2" ] || { _manifest_remove "$1" "$2"; _manifest_add "$1" "$3"; return 0; }
  rm -rf "${cd:?}/${3:?}"
  if mv "$cd/$2" "$cd/$3" 2>/dev/null; then
    _manifest_remove "$1" "$2"; _manifest_add "$1" "$3"
  else
    log_warn "$1: cloud rename $2→$3 failed."
  fi
  return 0
}

# Reconcile ONE client against its cloud dir (cloud = truth, with an upload branch
# for backups born locally). dry=1 only prints the plan. Always returns 0 unless a
# fatal config problem — individual transfer failures warn and continue.
_cloud_sync_client() { # client [dry]
  local client="$1" dry="${2:-0}"
  if ! cloud_available "$client"; then
    log_warn "$client: cloud not configured/mounted — skipping."
    return 0
  fi
  local cd bd; cd="$(client_cloud_dir "$client")"; bd="$(client_backup_dir "$client")"
  mkdir -p "$cd" 2>/dev/null || { log_warn "$client: cannot create cloud dir $cd"; return 0; }
  mkdir -p "$bd" 2>/dev/null || true

  local L C id pushed=0 pulled=0 deleted=0
  L="$(_local_backup_ids "$client")"
  C="$(_cloud_backup_ids "$client")"

  # Local-only ids: deleted-on-cloud (was in manifest → delete local) vs new
  # offline backup (never in cloud → upload).
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if printf '%s\n' "$C" | grep -qxF "$id"; then continue; fi   # in both
    if _manifest_has "$client" "$id"; then
      if [ "$dry" = 1 ]; then log_info "  would DELETE local  $id (removed from cloud)"
      else log_info "  delete local  $id (removed from cloud)"; _do_delete_backup "$client" "$id" local || true; fi
      deleted=$((deleted + 1))
    else
      if [ "$dry" = 1 ]; then log_info "  would UPLOAD        $id"
      else log_info "  upload        $id"; _cloud_push_one "$client" "$id" || true; fi
      pushed=$((pushed + 1))
    fi
  done < <(printf '%s\n' "$L")

  # Cloud-only ids → download (cloud is truth: new elsewhere, or locally pruned).
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if printf '%s\n' "$L" | grep -qxF "$id"; then continue; fi
    if [ "$dry" = 1 ]; then log_info "  would DOWNLOAD      $id"
    else
      log_info "  download      $id"
      if _cloud_copy_in "$cd/$id" "$bd/$id"; then _audit_log "$client" pull "$id"
      else log_warn "  download of $id failed"; fi
    fi
    pulled=$((pulled + 1))
  done < <(printf '%s\n' "$C")

  # Manifest now reflects the cloud (the truth) as it stands post-sync.
  if [ "$dry" != 1 ]; then
    _cloud_backup_ids "$client" | sort -u > "$(_manifest_file "$client")" 2>/dev/null || true
  fi

  if [ $((pushed + pulled + deleted)) -eq 0 ]; then
    log_ok "$client: already in sync."
  else
    log_ok "$client: ↑$pushed ↓$pulled ✗$deleted$([ "$dry" = 1 ] && echo '  [dry-run]')"
  fi
  return 0
}

# Sync every configured client.
_cloud_sync_all() { # [dry]
  local dry="${1:-0}" c rc=0
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    log_info "━━ $c ━━"
    _cloud_sync_client "$c" "$dry" || rc=1
  done < <(config_clients)
  return $rc
}
