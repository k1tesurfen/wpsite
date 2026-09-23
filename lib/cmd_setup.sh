# shellcheck shell=bash
# wpsite setup — onboard THIS machine (single entry point).
#
#   1. Write the wpsite LOCAL config — just `base_dir` (+ its data layout).
#   2. Convenience: point the `mandos` CLI at the shared ACCESS registry + Drive root by
#      shelling out to `mandos config init` (mandos stays the owner of that config).
#   3. Report whether BOTH registries are reachable: mandos (access) and wpsite's own
#      (WordPress settings, derived next to mandos's file — see wpsite_team_file).
# SSH keys are NOT wpsite's business any more (mandos is the keyholder):
#   mandos client setup-key <client>
# Run once on a new machine; safe to re-run (each prompt defaults to the current value).
# Non-interactive: provide --base-dir and --team-config (optionally --cloud-base).
# --no-keys / --no-test are accepted as no-ops (the GUI's first-run screen passes them).

cmd_setup() {
  require yq
  require "$MANDOS_BIN"

  local base_dir="" cloud_base="" team_config=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --base-dir)      base_dir="${2:-}"; shift 2 ;;
      --base-dir=*)    base_dir="${1#*=}"; shift ;;
      --cloud-base)    cloud_base="${2:-}"; shift 2 ;;
      --cloud-base=*)  cloud_base="${1#*=}"; shift ;;
      --team-config)   team_config="${2:-}"; shift 2 ;;
      --team-config=*) team_config="${1#*=}"; shift ;;
      --key|--key=*|--keys-only)
        die "SSH keys are mandos's job now: mandos client setup-key <client>" ;;
      --no-keys|--no-test) shift ;;            # no-ops, kept for the GUI's first-run call
      -*) die "Unknown flag: $1" ;;
      *) die "Unexpected argument: $1" ;;
    esac
  done

  local cfg="$WPSITE_CONFIG"

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

  # (3) Both registries reachable?
  local team_resolved wfile; team_resolved="$(_team_config_path)"
  if [ -n "$team_resolved" ] && [ -f "$team_resolved" ]; then
    log_ok "mandos access registry: $team_resolved"
  else
    log_warn "mandos access registry not reachable${team_resolved:+: $team_resolved} (is Google Drive mounted?)"
  fi
  wfile="$(wpsite_team_file)"
  if wteam_readable; then
    log_ok "wpsite registry:        $wfile ($(wclient_list | grep -c . || true) client(s))"
  elif [ -n "$wfile" ] && [ -d "$(dirname "$(dirname "$wfile")")" ]; then
    log_warn "wpsite registry not created yet: $wfile"
    log_warn "  First machine of the team? Run: wpsite migrate-registry   (dry run, then --apply)"
  else
    log_warn "wpsite registry not reachable${wfile:+: $wfile} (is Google Drive mounted?)"
  fi
  log_info "SSH access is managed by mandos: mandos client setup-key <client>"
  log_ok "Setup complete."
  return 0
}
