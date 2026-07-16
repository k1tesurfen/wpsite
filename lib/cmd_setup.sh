# shellcheck shell=bash
# wpsite setup — onboard THIS machine for the team (single entry point).
#
# Three things, in order:
#   1. Write the wpsite LOCAL config — just `base_dir` (+ its data layout). Client
#      identity, SSH keys and Drive paths are NOT wpsite's anymore.
#   2. Point the `mandos` CLI at the shared client registry + Google Drive root, by
#      shelling out to `mandos config init` (mandos owns clients/SSH/cloud).
#   3. Optionally install your SSH key on every client (via `mandos client setup-key`)
#      so you get access to all existing sites in one pass.
# Run once on a new machine; safe to re-run (each prompt defaults to the current value).
#
# Non-interactive: provide --base-dir and --team-config (and optionally --cloud-base).
# `--keys-only` skips steps 1–2 and just (re)installs keys. Reuses _prompt (cmd_new),
# _ensure_base_layout (common), _client_setup_ssh_key (cmd_client) and cmd_test.

cmd_setup() {
  require yq
  require "$MANDOS_BIN"

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
      --keys-only)     keys_only=1; shift ;;   # skip config; just (re)install keys
      --no-keys)       do_keys=0; shift ;;
      --no-test)       do_test=0; shift ;;
      -*) die "Unknown flag: $1" ;;
      *) die "Unexpected argument: $1" ;;
    esac
  done

  local cfg="$WPSITE_CONFIG"

  if [ "$keys_only" = 0 ]; then
    # Interactive defaults: base_dir from the wpsite config; the team file + cloud_base
    # from mandos's CURRENT config (setup delegates those to `mandos config init`).
    local cur_base="" cur_team="" cur_cloud=""
    [ -f "$cfg" ] && cur_base="$(yq -r '.base_dir // ""' "$cfg" 2>/dev/null || true)"
    cur_team="$("$MANDOS_BIN" config get team-config 2>/dev/null || true)"
    cur_cloud="$("$MANDOS_BIN" cloud base 2>/dev/null || true)"

    if [ -z "$base_dir" ] || [ -z "$team_config" ]; then
      [ -t 0 ] || die "Non-interactive: pass --base-dir and --team-config (optionally --cloud-base), or run in a terminal for the wizard."
      log_info "wpsite setup — configure this machine. Press Enter to accept the [default]."
      [ -n "$base_dir" ]    || base_dir="$(_prompt "Local data dir (base_dir)" "${cur_base:-~/websites}")"
      [ -n "$team_config" ] || team_config="$(_prompt "Shared client registry (mandos team file, in your Google Drive)" "$cur_team")"
      [ -n "$cloud_base" ]  || cloud_base="$(_prompt "Cloud backup root (cloud_base; blank = no cloud sync)" "$cur_cloud")"
    fi

    [ -n "$base_dir" ]    || die "base_dir is required."
    [ -n "$team_config" ] || die "team_config is required (path to the shared client registry in Drive)."

    # (1) wpsite's own config holds ONLY base_dir (+ dev sites). yq, never text edits.
    mkdir -p "$(dirname "$cfg")"
    [ -f "$cfg" ] || : > "$cfg"
    yq -i ".base_dir = \"$base_dir\"" "$cfg"
    log_ok "Wrote wpsite config: $cfg  (base_dir: $base_dir)"

    # (2) Point mandos at the shared registry + Drive root (mandos owns clients/SSH/cloud).
    local -a init_args=(config init --team-config "$team_config")
    [ -n "$cloud_base" ] && init_args+=(--cloud-base "$cloud_base")
    "$MANDOS_BIN" "${init_args[@]}"
    log_ok "Configured mandos:"
    log_info "  client registry: $team_config"
    log_info "  cloud_base:      ${cloud_base:-(none — cloud sync off)}"

    # Create the local data layout (clients/ + dev/).
    _ensure_base_layout
  fi

  # From here we need the client registry reachable to install keys.
  local team_resolved; team_resolved="$(_team_config_path)"
  if [ -z "$team_resolved" ]; then
    log_warn "mandos has no client registry configured — nothing to onboard. Re-run without --keys-only."
    return 0
  fi
  if [ ! -f "$team_resolved" ]; then
    log_warn "Client registry not found at:"
    log_warn "  $team_resolved"
    log_warn "Is your Google Drive mounted? Once it is, run: wpsite setup --keys-only"
    return 0
  fi

  if [ "$do_keys" = 0 ]; then
    log_ok "Setup complete (SSH key install skipped)."
    return 0
  fi

  # (3) Install your SSH key on every client (via mandos), so you can back up all sites.
  require ssh
  local clients=() c
  while IFS= read -r c; do [ -n "$c" ] && clients+=("$c"); done < <(config_clients)
  if [ "${#clients[@]}" -eq 0 ]; then
    log_info "No clients in the registry yet — nothing to set up keys for."
    return 0
  fi

  log_info "Installing your SSH key on ${#clients[@]} client(s) from the registry..."
  local ok=0 failed=() target
  for c in "${clients[@]}"; do
    echo
    log_info "━━ $c ━━"
    target="$(client_get "$c" ssh)"
    if [ -z "$target" ]; then
      log_warn "  $c has no ssh target in the registry — skipping."
      failed+=("$c"); continue
    fi
    if _client_setup_ssh_key "$c" "$key"; then
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
