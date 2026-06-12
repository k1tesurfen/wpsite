# shellcheck shell=bash
# wpsite backup <client> — snapshot a remote WordPress site to local artifacts.
#
# Produces, under <base_dir>/<client>/backups/<timestamp>/:
#   db.sql            full database export
#   wp-content.tar.gz wp-content WITHOUT uploads
#   media_map.txt     filepath|width|height for every upload (for placeholders)
#   meta.env          source siteurl/home + WP/PHP versions (consumed by `up`)

# EXIT-trap cleanup. Reads globals (not cmd_backup's locals, which are gone by
# the time the trap fires) and tolerates them being unset under `set -u`.
_backup_cleanup() {
  if [ -n "${_WPSITE_CLEAN_TMP:-}" ]; then
    log_debug "Cleaning up remote temp dir ${_WPSITE_CLEAN_TMP}..."
    wpsite_ssh "${_WPSITE_CLEAN_TARGET:-}" "rm -rf '${_WPSITE_CLEAN_TMP}'" 2>/dev/null || true
  fi
  ssh_close_mux
}

# The remote payload, piped to the server's `bash -s` over stdin. Single-quoted
# heredoc: expanded on the SERVER, not here. Required env (prepended by the
# caller as %q-quoted assignments): WP_ROOT, REMOTE_TMP.
_backup_remote_script() {
  cat <<'REMOTE_EOF'
    set -e
    # identify (ImageMagick) is only needed to measure media for placeholders.
    REQUIRED="wp tar"; [ -z "$FULL_BACKUP" ] && REQUIRED="$REQUIRED identify"
    for cmd in $REQUIRED; do
      command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd is not installed on the remote server." >&2; exit 1; }
    done

    cd "$WP_ROOT" || { echo "ERROR: cannot cd to $WP_ROOT" >&2; exit 1; }
    mkdir -p "$REMOTE_TMP"

    echo "Capturing site metadata..."
    {
      echo "SOURCE_SITEURL=$(wp option get siteurl --allow-root 2>/dev/null)"
      echo "SOURCE_HOME=$(wp option get home --allow-root 2>/dev/null)"
      echo "WP_VERSION=$(wp core version --allow-root 2>/dev/null)"
      echo "PHP_VERSION=$(wp eval 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' --allow-root 2>/dev/null)"
      echo "BACKUP_MODE=${BACKUP_MODE:-placeholder}"
    } > "$REMOTE_TMP/meta.env"

    echo "Exporting database..."
    wp db export "$REMOTE_TMP/db.sql" --allow-root

    # Regenerable caches + other backup/staging plugins' archive output (WP Staging
    # .wpstg files, UpdraftPlus, All-in-One WP Migration, WPvivid …). These are
    # backups-of-the-site — huge and never wanted in a dev replica — so they're
    # dropped in BOTH modes. The */ variants also catch multisite
    # (wp-content/uploads/sites/<id>/...).
    PRUNE_DIRS="cache et-cache wphb-cache endurance-page-cache updraft ai1wm-backups wpvivid wp-staging"
    # In placeholder mode this list drives BOTH the dimension map and the tar
    # excludes, so they can't drift. In full mode media is kept, so neither runs.
    MEDIA_EXTS="jpg jpeg png gif webp mp4 mov webm pdf"

    if [ -n "$FULL_BACKUP" ]; then
      echo "Full backup: including all media files (no placeholders, no media map)."
    else
      echo "Mapping media file dimensions (images, videos, PDFs)..."
      : > "$REMOTE_TMP/media_map.txt"
      if [ -d "wp-content/uploads" ]; then
        # Build a case-insensitive find expression from MEDIA_EXTS. find recurses
        # into multisite sites/<id>/... automatically — no special-casing needed.
        find_expr=(); first=1
        for ext in $MEDIA_EXTS; do
          if [ "$first" = 1 ]; then find_expr+=( -iname "*.$ext" ); first=0
          else find_expr+=( -o -iname "*.$ext" ); fi
        done
        find wp-content/uploads -type f \( "${find_expr[@]}" \) -print0 |
        while IFS= read -r -d '' file; do
          ext_lower=$(printf '%s' "${file##*.}" | tr '[:upper:]' '[:lower:]')
          case "$ext_lower" in
            pdf) DIM="0|0" ;;   # PDFs become empty placeholders; no dimensions needed
            # [0] reads only the first video frame so this stays fast.
            *)   DIM=$(identify -format "%w|%h" "${file}[0]" 2>/dev/null || echo "800|600") ;;
          esac
          echo "$file|$DIM" >> "$REMOTE_TMP/media_map.txt"
        done
      fi
    fi

    echo "Archiving wp-content..."
    tar_excludes=()
    # Placeholder mode only: exclude media FILES by extension wherever they live
    # under uploads (tar's * matches /, so one pattern covers every depth incl.
    # multisite). Full mode keeps all media, so these excludes are skipped.
    if [ -z "$FULL_BACKUP" ]; then
      for ext in $MEDIA_EXTS; do
        ext_up=$(printf '%s' "$ext" | tr '[:lower:]' '[:upper:]')   # cover .JPG etc.
        tar_excludes+=( --exclude="wp-content/uploads/*.$ext" --exclude="wp-content/uploads/*.$ext_up" )
      done
    fi
    for d in $PRUNE_DIRS; do
      tar_excludes+=( --exclude="wp-content/uploads/$d" --exclude="wp-content/uploads/*/$d" )
    done
    # Top-level wp-content page caches + env-specific config: regenerable, often
    # huge (WP Rocket can be tens of MB), and full of HARDCODED absolute production
    # URLs that search-replace can't fix (they live in files, not the DB).
    for d in cache wp-rocket-config w3tc-config litespeed; do
      tar_excludes+=( --exclude="wp-content/$d" )
    done
    # Caching/DB drop-ins break a local clone (point at Redis / WP Rocket / etc.)
    # and are recreated by their plugins anyway — never ship them.
    for f in advanced-cache.php object-cache.php db.php; do
      tar_excludes+=( --exclude="wp-content/$f" )
    done
    tar -czf "$REMOTE_TMP/wp-content.tar.gz" "${tar_excludes[@]}" wp-content
    echo "BACKUP_SUCCESSFUL"
REMOTE_EOF
}

cmd_backup() {
  local client="" full=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --full) full=1; shift ;;
      -*) die "Unknown flag: $1" ;;
      *) client="$1"; shift ;;
    esac
  done

  config_require
  require_client "$client"
  require rsync

  local ssh_target wp_root
  ssh_target="$(client_get "$client" ssh)"
  wp_root="$(client_get "$client" wp_root)"
  [ -n "$ssh_target" ] || die "clients.$client.ssh not set in config"
  [ -n "$wp_root" ]    || die "clients.$client.wp_root not set in config"

  local timestamp run_id remote_tmp dest
  timestamp="$(date +%Y%m%d_%H%M%S)"
  run_id="wpsite_${client}_${timestamp}"
  remote_tmp="/tmp/${run_id}"
  dest="$(client_backup_dir "$client")/$timestamp"

  local mode="placeholder" full_flag=""
  [ "$full" = "1" ] && { mode="full"; full_flag="1"; }

  log_info "Client:       $client"
  log_info "Remote:       $ssh_target:$wp_root"
  log_info "Local backup: $dest"
  log_info "Mode:         $mode$([ "$mode" = full ] && echo ' (real media, larger)' || echo ' (media → placeholders)')"

  ssh_setup_mux

  # The EXIT trap fires after this function returns, so it can't read the locals
  # (set -u would trip on the now-unbound names). Stash what cleanup needs in
  # globals and read them defensively.
  _WPSITE_CLEAN_TARGET="$ssh_target"
  _WPSITE_CLEAN_TMP="$remote_tmp"
  trap _backup_cleanup EXIT

  mkdir -p "$dest"

  # The remote script is piped over stdin to `bash -s` — no embedding in a
  # command-line argument, so its single quotes/heredocs can't break anything,
  # and no tmux is required. WP_ROOT/REMOTE_TMP are prepended as assignments,
  # shell-quoted with %q. Output streams live; a non-zero exit means failure.
  log_info "Running remote backup (streaming output)..."
  if ! {
    printf 'WP_ROOT=%q\nREMOTE_TMP=%q\nFULL_BACKUP=%q\nBACKUP_MODE=%q\nexport WP_ROOT REMOTE_TMP FULL_BACKUP BACKUP_MODE\n' \
      "$wp_root" "$remote_tmp" "$full_flag" "$mode"
    _backup_remote_script
  } | wpsite_ssh "$ssh_target" bash -s; then
    die "Remote backup failed (see output above)."
  fi

  log_info "Downloading artifacts..."
  rsync -az -e "ssh -o ControlPath=$WPSITE_SSH_CONTROL_DIR/%C" \
    "$ssh_target:$remote_tmp/" "$dest/"

  log_ok "Backup saved to $dest"
  # Trap handles remote cleanup + mux teardown.
}
