# shellcheck shell=bash
# wpsite setup — onboard THIS machine for the team.
#
# Creates the LOCAL config (base_dir + cloud_base + a team_config pointer at the
# shared client definitions in Google Drive), then optionally installs your SSH key
# on every client in that shared config so you get access to all existing sites in
# one pass. Run once on a new machine / for a new team member; safe to re-run (each
# prompt defaults to the current value).
#
# Non-interactive: provide --base-dir and --team-config (and optionally --cloud-base).
# Reuses _prompt (cmd_new), _ensure_base_layout (common), _client_setup_ssh_key
# (cmd_client) and cmd_test (cmd_test) — all already sourced by bin/wpsite.

cmd_setup() {
  require yq

  local base_dir="" cloud_base="" team_config="" key=""
  local do_keys=1 do_test=1 keys_only=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --base-dir)      base_dir="${2:-}"; shift 2 ;;
      --base-dir=*)    base_dir="${1#*=}"; shift ;;
      --cloud-base)    cloud_base="${2:-}"; shift 2 ;;
      --cloud-base=*)  cloud_base="${1#*=}"; shift ;;
      --team-config)   team_config="${2:-}"; shift 2 ;;
      --team-config=*) team_config="${1#*=}"; shift ;;
      --key)           key="${2:-}"; shift 2 ;;
      --key=*)         key="${1#*=}"; shift ;;
      --keys-only)     keys_only=1; shift ;;   # skip config writing; just (re)install keys
      --no-keys)       do_keys=0; shift ;;
      --no-test)       do_test=0; shift ;;
      -*) die "Unknown flag: $1" ;;
      *) die "Unexpected argument: $1" ;;
    esac
  done

  local cfg="$WPSITE_CONFIG"

  # Current values (if any) — used as interactive defaults so re-running is painless.
  local cur_base="" cur_cloud="" cur_team=""
  if [ -f "$cfg" ]; then
    cur_base="$(yq -r '.base_dir // ""' "$cfg" 2>/dev/null || true)"
    cur_cloud="$(yq -r '.cloud_base // ""' "$cfg" 2>/dev/null || true)"
    cur_team="$(yq -r '.team_config // ""' "$cfg" 2>/dev/null || true)"
  fi

  if [ "$keys_only" = 0 ]; then
    # Fill any missing field interactively (needs a TTY to read answers).
    if [ -z "$base_dir" ] || [ -z "$team_config" ]; then
      [ -t 0 ] || die "Non-interactive: pass --base-dir and --team-config (optionally --cloud-base), or run in a terminal for the wizard."
      log_info "wpsite setup — configure this machine. Press Enter to accept the [default]."
      [ -n "$base_dir" ]    || base_dir="$(_prompt "Local data dir (base_dir)" "${cur_base:-~/websites}")"
      [ -n "$team_config" ] || team_config="$(_prompt "Shared team config path (in your Google Drive)" "$cur_team")"
      [ -n "$cloud_base" ]  || cloud_base="$(_prompt "Cloud backup root (cloud_base; blank = no cloud sync)" "$cur_cloud")"
    fi

    [ -n "$base_dir" ]    || die "base_dir is required."
    [ -n "$team_config" ] || die "team_config is required (path to the shared client config in Drive)."

    # Write the local config via yq (never text edits). A fresh file starts empty.
    mkdir -p "$(dirname "$cfg")"
    [ -f "$cfg" ] || : > "$cfg"
    yq -i ".base_dir = \"$base_dir\"" "$cfg"
    yq -i ".team_config = \"$team_config\"" "$cfg"
    if [ -n "$cloud_base" ]; then yq -i ".cloud_base = \"$cloud_base\"" "$cfg"; fi
    log_ok "Wrote local config: $cfg"
    log_info "  base_dir:     $base_dir"
    log_info "  team_config:  $team_config"
    log_info "  cloud_base:   ${cloud_base:-(none — cloud sync off)}"

    # Create the local data layout (clients/ + dev/).
    _ensure_base_layout
  fi

  # From here we need the team config reachable to install keys.
  local team_resolved; team_resolved="$(_team_config_path)"
  if [ -z "$team_resolved" ]; then
    log_warn "No team_config set — nothing to onboard. Re-run without --keys-only to configure it."
    return 0
  fi
  if [ ! -f "$team_resolved" ]; then
    log_warn "Team config not found at:"
    log_warn "  $team_resolved"
    log_warn "Is your Google Drive mounted? Once it is, run: wpsite setup --keys-only"
    return 0
  fi

  if [ "$do_keys" = 0 ]; then
    log_ok "Setup complete (SSH key install skipped)."
    return 0
  fi

  # Install your SSH key on every client, so you can back up all existing sites.
  require ssh
  _ensure_ssh_key || log_warn "Continuing without a local SSH key — key install will be skipped."
  local clients=() c
  while IFS= read -r c; do [ -n "$c" ] && clients+=("$c"); done < <(config_clients)
  if [ "${#clients[@]}" -eq 0 ]; then
    log_info "No clients in the team config yet — nothing to set up keys for."
    return 0
  fi

  log_info "Installing your SSH key on ${#clients[@]} client(s) from the team config..."
  local ok=0 failed=() target
  for c in "${clients[@]}"; do
    echo
    log_info "━━ $c ━━"
    target="$(client_get "$c" ssh)"
    if [ -z "$target" ]; then
      log_warn "  $c has no ssh target in the team config — skipping."
      failed+=("$c"); continue
    fi
    if _client_setup_ssh_key "$target" "$key"; then
      log_ok "  SSH key access ready for $c."
    else
      log_warn "  Could not set up SSH access for $c — fix manually, then: wpsite test $c"
      failed+=("$c"); continue
    fi
    if [ "$do_test" = 1 ]; then
      # cmd_test die/exits on failure; subshell so a bad client only warns here.
      if ( cmd_test "$c" ); then ok=$((ok + 1)); else
        log_warn "  Readiness test FAILED for $c (see above) — fix, then: wpsite test $c"
        failed+=("$c")
      fi
    else
      ok=$((ok + 1))
    fi
  done

  echo
  if [ "${#failed[@]}" -gt 0 ]; then
    log_warn "Setup finished: $ok ready, ${#failed[@]} need attention: ${failed[*]}"
    return 1
  fi
  log_ok "Setup complete — all ${#clients[@]} client(s) ready. Try: wpsite backup <client>"
  return 0
}
