# shellcheck shell=bash
# wpsite client <subcommand> — manage SSH-backed production clients in the config.
#
#   wpsite client add    [<name>] [flags]   Onboard a client: prompt, ssh-copy-id, test.
#   wpsite client edit    <name>  [flags]   Change a client's fields (interactive or flags).
#   wpsite client remove  <name>  [--purge] Remove a client (config + replica; --purge = data).
#
# Config writes go through client_set / client_unset / config_remove_client (yq -i),
# never text edits.

_client_usage() {
  cat >&2 <<'EOF'
Usage:
  wpsite client add    [<name>] [flags]   Onboard a new SSH-backed client
  wpsite client edit    <name>  [flags]   Change an existing client's fields
  wpsite client remove  <name>  [flags]   Remove a client (alias: rm, delete)

  add — wizard when fields are missing on a TTY, else fully flag-driven:
    --ssh <user@host>     Production SSH target
    --wp-root <path>      Absolute path to the WordPress install on that server
    --local-host <host>   Local .test hostname (default: <name>.test)
    --remote-tmp <path>   Remote backup staging dir (default: /tmp)
    --cloud-dir <path>    Full absolute path override for cloud backups (machine-specific)
    --cloud-folder <name> Project-folder NAME under cloud_base (portable; use when the
                          backup domain differs from the Drive folder name)
    --key <path>          SSH identity to install (default: your agent/default key)
    --no-copy-id          Skip ssh-copy-id (assume key access already works)
    --no-test             Skip the post-add `wpsite test` readiness check

  edit — same field flags as add, plus:
    --unset <key>         Clear an optional key (local_host|remote_tmp|cloud_dir|cloud_folder)
    --copy-id             Re-run ssh-copy-id for the (new) SSH target
    --no-test             Skip the readiness test after an ssh/wp_root change
    (no field flags on a TTY → interactive; Enter keeps each [current] value)

  remove:
    --purge               Also delete ALL local data (backups + docker) — irreversible
    --yes, -y             Skip the confirmation prompt
    (never touches cloud backups)
EOF
}

cmd_client() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    add)              _client_add "$@" ;;
    edit|update)      _client_edit "$@" ;;
    remove|rm|delete) _client_remove "$@" ;;
    ""|-h|--help)     _client_usage ;;
    *) log_error "Unknown 'client' subcommand: $sub"; _client_usage; return 1 ;;
  esac
}

# Warn (non-fatally) if a chosen cloud_folder doesn't exist under cloud_base yet —
# catches typos at onboarding. Backups only ever write INTO an existing project folder
# (wpsite never creates one), so a missing folder means cloud sync would be skipped.
_client_check_cloud_folder() { # folder
  local folder="$1" cb
  [ -n "$folder" ] || return 0
  cb="$(config_cloud_base)"
  [ -n "$cb" ] || return 0
  if [ -d "$cb" ] && [ ! -d "$cb/$folder" ]; then
    log_warn "  '$folder' not found under cloud_base yet — create it in Drive, or fix the name."
  fi
  return 0
}

# Install the user's SSH key on a client's server — delegated to mandos, which owns
# key onboarding: it probes (BatchMode) and skips if access already works, else runs
# ssh-copy-id (or a manual authorized_keys append on macOS), and generates a local
# ed25519 key first if you have none. Takes the CLIENT NAME (mandos resolves the
# current ssh target from the registry). Returns non-zero on failure — callers warn.
_client_setup_ssh_key() { # name [identity]
  local name="$1" identity="${2:-}"
  local -a idopt=()
  [ -n "$identity" ] && idopt=(--identity "$identity")
  # "${idopt[@]:+...}" so an EMPTY array doesn't trip `set -u` on macOS's bash 3.2.
  "$MANDOS_BIN" client setup-key "$name" "${idopt[@]:+"${idopt[@]}"}"
}

_client_add() {
  local name="" ssh_target="" wp_root="" local_host="" remote_tmp="" cloud_dir="" cloud_folder=""
  local key="" do_copyid=1 do_test=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --ssh)            ssh_target="${2:-}"; shift 2 ;;
      --ssh=*)          ssh_target="${1#*=}"; shift ;;
      --wp-root)        wp_root="${2:-}"; shift 2 ;;
      --wp-root=*)      wp_root="${1#*=}"; shift ;;
      --local-host)     local_host="${2:-}"; shift 2 ;;
      --local-host=*)   local_host="${1#*=}"; shift ;;
      --remote-tmp)     remote_tmp="${2:-}"; shift 2 ;;
      --remote-tmp=*)   remote_tmp="${1#*=}"; shift ;;
      --cloud-dir)      cloud_dir="${2:-}"; shift 2 ;;
      --cloud-dir=*)    cloud_dir="${1#*=}"; shift ;;
      --cloud-folder)   cloud_folder="${2:-}"; shift 2 ;;
      --cloud-folder=*) cloud_folder="${1#*=}"; shift ;;
      --key)            key="${2:-}"; shift 2 ;;
      --key=*)          key="${1#*=}"; shift ;;
      --no-copy-id)     do_copyid=0; shift ;;
      --no-test)        do_test=0; shift ;;
      -*) die "Unknown flag: $1" ;;
      *) if [ -z "$name" ]; then name="$1"; else die "Unexpected argument: $1"; fi; shift ;;
    esac
  done

  config_require
  require ssh

  # Any required field missing → interactive wizard (needs a TTY to read answers).
  if [ -z "$name" ] || [ -z "$ssh_target" ] || [ -z "$wp_root" ]; then
    [ -t 0 ] || die "Missing required fields. Provide a name plus --ssh and --wp-root, or run interactively for the wizard."

    log_info "Add-client wizard — press Enter to accept the [default]."
    if [ -z "$name" ]; then
      while :; do
        name="$(_prompt "Client name (letters, digits, hyphens)")"
        if ! _valid_site_name "$name"; then log_warn "Invalid name. Use lowercase letters, digits and hyphens."; continue; fi
        if [ -n "$(target_kind "$name")" ]; then log_warn "'$name' already exists as a $(target_kind "$name"). Pick another."; continue; fi
        break
      done
    fi
    if [ -z "$ssh_target" ]; then
      while :; do
        ssh_target="$(_prompt "SSH target (user@host)")"
        if [ -n "$ssh_target" ]; then break; fi
        log_warn "SSH target is required."
      done
    fi
    if [ -z "$wp_root" ]; then
      while :; do
        wp_root="$(_prompt "Remote WordPress root (absolute path)")"
        case "$wp_root" in /*) break ;; *) log_warn "Must be an absolute path (leading /)." ;; esac
      done
    fi

    # Cloud project folder: backups sync to <cloud_base>/<folder>/100_Backup. By default
    # <folder> is derived from the site's own domain on first backup — correct for a live
    # site. But a site still under construction lives on *.wird.cool, whose backups belong
    # under the FINAL client-domain folder in LIVE_WEB. Since cloud_base is a per-user LOCAL
    # path, we only store the portable folder NAME (cloud_folder), never an absolute path.
    if [ -z "$cloud_folder" ]; then
      local cb; cb="$(config_cloud_base)"
      if [ -n "$cb" ]; then
        log_info "Backups sync to <cloud_base>/<folder>/100_Backup."
        log_info "  For a site still on *.wird.cool, enter its FINAL client-domain folder."
        cloud_folder="$(_prompt "Cloud project folder (blank = derive from the site's domain)")"
        _client_check_cloud_folder "$cloud_folder"   # typo/missing-folder warning (non-fatal)
      fi
    fi

    # Advanced overrides — gated so the common path stays short. (Retention is a fixed
    # team policy of 5 — see WPSITE_KEEP_BACKUPS — so there's no keep_backups prompt.)
    local adv; adv="$(_prompt "Set advanced options (local_host, remote_tmp)? [y/N]" "N")"
    case "$adv" in
      [yY]*)
        local d_host="$name.test"
        local_host="$(_prompt "  Local host" "$d_host")"
        if [ "$local_host" = "$d_host" ]; then local_host=""; fi   # default → leave unset
        remote_tmp="$(_prompt "  Remote temp dir (blank = /tmp)")"
        ;;
    esac
  fi

  # Final validation (also covers flag-only, non-interactive invocation).
  _valid_site_name "$name" || die "Invalid client name '$name' (use lowercase letters, digits, hyphens)."
  [ -z "$(target_kind "$name")" ] || die "'$name' already exists as a $(target_kind "$name"). Choose another name."
  [ -n "$ssh_target" ] || die "SSH target is required (--ssh user@host)."
  [ -n "$wp_root" ]    || die "Remote WordPress root is required (--wp-root /path)."
  case "$wp_root" in /*) : ;; *) die "wp_root must be an absolute path: $wp_root" ;; esac

  # Write the config entry first, so `wpsite test` reads the real entry and the client
  # is recoverable/editable even if the key setup or test below fails. client_set writes
  # to the shared TEAM config (or the local file when no team config is set up).
  local cfg_where; cfg_where="$(_team_config_path)"; [ -n "$cfg_where" ] || cfg_where="$WPSITE_CONFIG"
  log_info "Adding client '$name' to $cfg_where"
  _ensure_base_layout
  client_set "$name" ssh "$ssh_target"
  client_set "$name" wp_root "$wp_root"
  if [ -n "$local_host" ];    then client_set "$name" local_host    "$local_host";    fi
  if [ -n "$remote_tmp" ];    then client_set "$name" remote_tmp    "$remote_tmp";    fi
  if [ -n "$cloud_dir" ];     then client_set "$name" cloud_dir     "$cloud_dir";     fi
  if [ -n "$cloud_folder" ];  then client_set "$name" cloud_folder  "$cloud_folder";  fi
  log_ok "  Config entry written."

  echo
  if [ "$do_copyid" = 1 ]; then
    log_info "Setting up key-based SSH access via mandos..."
    if _client_setup_ssh_key "$name" "$key"; then
      log_ok "  SSH key access ready."
    else
      log_warn "  Could not set up the SSH key automatically — fix access, then: wpsite test $name"
    fi
  else
    log_info "Skipping SSH key setup (--no-copy-id)."
  fi

  if [ "$do_test" = 1 ]; then
    echo
    log_info "Running readiness test (wpsite test $name)..."
    # cmd_test calls die/exit on failure; run it in a subshell so a failing test only
    # warns here — the entry stays (per design: keep on fail, fix + re-run).
    if ( cmd_test "$name" ); then
      log_ok "Client '$name' added and verified."
    else
      log_warn "Client '$name' was added, but the readiness test FAILED (see above)."
      log_warn "Correct ssh / wp_root in $WPSITE_CONFIG, then re-run: wpsite test $name"
    fi
  else
    log_ok "Client '$name' added (test skipped). Verify anytime with: wpsite test $name"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# client edit — change fields on an existing client. Interactive when no field
# flags are given on a TTY (Enter keeps each current value); otherwise sets only
# the fields passed. Renaming is NOT supported (it would have to move data dirs +
# cloud) — the name is the config key. Re-tests only when ssh/wp_root changed.
# ---------------------------------------------------------------------------
_client_edit() {
  local name="" key="" do_test=1 do_copyid=0 any_flag=0
  local ssh_new="" wp_new="" lh_new="" rt_new="" cd_new="" cf_new=""
  local ssh_set=0 wp_set=0 lh_set=0 rt_set=0 cd_set=0 cf_set=0
  local -a unset_keys=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --ssh)            ssh_new="${2:-}"; ssh_set=1; any_flag=1; shift 2 ;;
      --ssh=*)          ssh_new="${1#*=}"; ssh_set=1; any_flag=1; shift ;;
      --wp-root)        wp_new="${2:-}"; wp_set=1; any_flag=1; shift 2 ;;
      --wp-root=*)      wp_new="${1#*=}"; wp_set=1; any_flag=1; shift ;;
      --local-host)     lh_new="${2:-}"; lh_set=1; any_flag=1; shift 2 ;;
      --local-host=*)   lh_new="${1#*=}"; lh_set=1; any_flag=1; shift ;;
      --remote-tmp)     rt_new="${2:-}"; rt_set=1; any_flag=1; shift 2 ;;
      --remote-tmp=*)   rt_new="${1#*=}"; rt_set=1; any_flag=1; shift ;;
      --cloud-dir)      cd_new="${2:-}"; cd_set=1; any_flag=1; shift 2 ;;
      --cloud-dir=*)    cd_new="${1#*=}"; cd_set=1; any_flag=1; shift ;;
      --cloud-folder)   cf_new="${2:-}"; cf_set=1; any_flag=1; shift 2 ;;
      --cloud-folder=*) cf_new="${1#*=}"; cf_set=1; any_flag=1; shift ;;
      --unset)          unset_keys+=("${2:-}"); any_flag=1; shift 2 ;;
      --unset=*)        unset_keys+=("${1#*=}"); any_flag=1; shift ;;
      --key)            key="${2:-}"; shift 2 ;;
      --key=*)          key="${1#*=}"; shift ;;
      --copy-id)        do_copyid=1; shift ;;
      --no-test)        do_test=0; shift ;;
      -*) die "Unknown flag: $1" ;;
      *) if [ -z "$name" ]; then name="$1"; else die "Unexpected argument: $1 (rename is not supported)."; fi; shift ;;
    esac
  done

  config_require
  [ -n "$name" ] || die "Usage: wpsite client edit <name> [flags]"
  [ "$(target_kind "$name")" = "dev" ] && die "'$name' is a dev site, not a client (edit dev sites by rebuilding)."
  require_client "$name"

  # No flags on a TTY → interactive; each prompt defaults to the current value.
  if [ "$any_flag" = 0 ]; then
    [ -t 0 ] || die "Nothing to change. Pass fields (--ssh, --wp-root, ...) / --unset, or run interactively."
    log_info "Editing client '$name' — press Enter to keep the [current] value."
    local c
    c="$(client_get "$name" ssh)";          ssh_new="$(_prompt "SSH target (user@host)" "$c")"; ssh_set=1
    c="$(client_get "$name" wp_root)";       wp_new="$(_prompt "Remote WordPress root (absolute path)" "$c")"; wp_set=1
    c="$(client_get "$name" local_host)";    lh_new="$(_prompt "Local host (blank = default <name>.test)" "$c")"; lh_set=1
    c="$(client_get "$name" remote_tmp)";    rt_new="$(_prompt "Remote temp dir (blank = /tmp)" "$c")"; rt_set=1
    c="$(client_get "$name" cloud_dir)";     cd_new="$(_prompt "Cloud backup dir override (blank = default)" "$c")"; cd_set=1
    c="$(client_get "$name" cloud_folder)";  cf_new="$(_prompt "Cloud project-folder name (blank = derive from domain)" "$c")"; cf_set=1
  fi

  local changed=0 ssh_changed=0 wp_changed=0

  # Required fields: reject empty; write only when different.
  if [ "$ssh_set" = 1 ]; then
    [ -n "$ssh_new" ] || die "SSH target cannot be empty."
    if [ "$ssh_new" != "$(client_get "$name" ssh)" ]; then
      client_set "$name" ssh "$ssh_new"; log_ok "  ssh → $ssh_new"; changed=1; ssh_changed=1
    fi
  fi
  if [ "$wp_set" = 1 ]; then
    [ -n "$wp_new" ] || die "wp_root cannot be empty."
    case "$wp_new" in /*) : ;; *) die "wp_root must be an absolute path: $wp_new" ;; esac
    if [ "$wp_new" != "$(client_get "$name" wp_root)" ]; then
      client_set "$name" wp_root "$wp_new"; log_ok "  wp_root → $wp_new"; changed=1; wp_changed=1
    fi
  fi

  # Optionals: an empty value here means "leave as-is" (clear with --unset instead).
  if _client_edit_opt "$name" local_host    "$lh_set" "$lh_new"; then changed=1; fi
  if _client_edit_opt "$name" remote_tmp    "$rt_set" "$rt_new"; then changed=1; fi
  if _client_edit_opt "$name" cloud_dir     "$cd_set" "$cd_new"; then changed=1; fi
  if _client_edit_opt "$name" cloud_folder  "$cf_set" "$cf_new"; then changed=1; fi

  # Unsets (optional keys only).
  local k
  for k in "${unset_keys[@]:+"${unset_keys[@]}"}"; do
    case "$k" in
      local_host|remote_tmp|cloud_dir|cloud_folder) ;;
      ssh|wp_root) die "Refusing to unset required key '$k'." ;;
      "") die "--unset needs a key name." ;;
      *) die "Cannot unset unknown key '$k' (local_host|remote_tmp|cloud_dir|cloud_folder)." ;;
    esac
    if [ -n "$(client_get "$name" "$k")" ]; then
      client_unset "$name" "$k"; log_ok "  unset $k"; changed=1
    fi
  done

  if [ "$changed" = 0 ]; then
    log_info "No changes made to '$name'."
    return 0
  fi
  log_ok "Updated client '$name'."

  # Re-establish key access for a new target if asked.
  if [ "$do_copyid" = 1 ]; then
    log_info "Setting up key-based SSH access via mandos..."
    _client_setup_ssh_key "$name" "$key" \
      || log_warn "  Key setup failed — fix access, then: wpsite test $name"
  fi

  # Only worth a remote test when connection-relevant fields changed.
  if [ "$do_test" = 1 ] && { [ "$ssh_changed" = 1 ] || [ "$wp_changed" = 1 ] || [ "$do_copyid" = 1 ]; }; then
    echo
    log_info "Re-testing readiness (wpsite test $name)..."
    if ( cmd_test "$name" ); then
      log_ok "Client '$name' verified."
    else
      log_warn "Readiness test FAILED (see above). Correct ssh / wp_root, then: wpsite test $name"
    fi
  fi
  return 0
}

# Set one optional client key during edit. Returns 0 (with a log line) only when it
# actually wrote a new value, so the caller can track whether anything changed. An
# unset flag or an empty value is a no-op → returns non-zero (nothing changed).
_client_edit_opt() { # name key isset newval
  local name="$1" key="$2" isset="$3" val="$4" cur
  [ "$isset" = 1 ] || return 1
  [ -n "$val" ]    || return 1        # empty = keep current (clear via --unset)
  cur="$(client_get "$name" "$key")"
  [ "$val" != "$cur" ] || return 1
  client_set "$name" "$key" "$val"
  log_ok "  $key → $val"
  return 0
}

# ---------------------------------------------------------------------------
# client remove — delete a client. Tears down its replica (containers + DB volume +
# docker dir + proxy route), removes the config entry, and KEEPS local backups unless
# --purge is given. NEVER touches cloud backups (cloud is the source of truth; delete
# those explicitly). Confirmation: typed-name for --purge (irreversible), else [y/N].
# ---------------------------------------------------------------------------
_client_remove() {
  local name="" purge=0 yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --purge)   purge=1; shift ;;
      --yes|-y)  yes=1; shift ;;
      -*) die "Unknown flag: $1" ;;
      *) if [ -z "$name" ]; then name="$1"; else die "Unexpected argument: $1"; fi; shift ;;
    esac
  done

  config_require
  [ -n "$name" ] || die "Usage: wpsite client remove <name> [--purge] [--yes]"
  [ "$(target_kind "$name")" = "dev" ] && die "'$name' is a dev site — remove it with: wpsite destroy $name"
  require_client "$name"

  local docker_dir project base
  docker_dir="$(client_docker_dir "$name")"
  project="wpsite_${name}"
  base="$(client_base "$name")"

  log_warn "About to remove client '$name':"
  log_warn "  • its config entry in $WPSITE_CONFIG"
  log_warn "  • its containers + DB volume + $docker_dir"
  if [ "$purge" = 1 ]; then
    local sz; sz="$(du -sh "$base" 2>/dev/null | cut -f1 || true)"
    log_warn "  • ALL local data under $base (${sz:-?}) — INCLUDING BACKUPS (irreversible)"
  else
    log_warn "  • local backups under $base are KEPT (add --purge to delete them too)"
  fi
  log_warn "  Cloud backups (if any) are NOT touched."

  if [ "$yes" != 1 ]; then
    local ans=""
    if [ "$purge" = 1 ]; then
      printf 'Type the client name (%s) to permanently delete it AND its backups: ' "$name" >&2
      read -r ans 2>/dev/null < /dev/tty || read -r ans 2>/dev/null || ans=""
      [ "$ans" = "$name" ] || die "Aborted (name did not match)."
    else
      printf 'Remove this client? [y/N] ' >&2
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

  config_remove_client "$name"
  log_ok "Removed client '$name' from config."

  if [ "$purge" = 1 ]; then
    rm -rf "$base"
    log_ok "Purged local data under $base."
  elif [ -d "$base" ]; then
    log_info "Kept local data at $base (delete it by hand if you don't need the backups)."
  fi
  return 0
}
