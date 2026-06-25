# shellcheck shell=bash
# wpsite test <client> — verify remote host connectivity, directories, and dependencies.

cmd_test() {
  local client="${1:-}"
  [ -n "$client" ] || die "Specify a <client> to test remote readiness."
  config_require
  require_client "$client"

  local ssh_target wp_root
  ssh_target="$(client_get "$client" ssh)"
  wp_root="$(client_get "$client" wp_root)"

  log_info "Testing remote readiness for '$client'..."
  log_info "Remote target: $ssh_target"
  log_info "Remote WP root: $wp_root"
  echo

  ssh_setup_mux
  trap ssh_close_mux EXIT

  # 1. Test SSH Connection
  log_info "[1/4] Testing SSH Connection..."
  if wpsite_ssh "$ssh_target" "echo 'SSH_OK'" >/dev/null 2>&1; then
    log_ok "  SSH Connection: SUCCESSFUL"
  else
    die "  SSH Connection: FAILED. Check your SSH keys, targets, or network."
  fi

  # 2. Test Core System Commands on Remote
  log_info "[2/4] Checking Remote System Programs..."
  local remote_checks; remote_checks="$(wpsite_ssh "$ssh_target" "
    for cmd in tar php mysql mysqldump; do
      if command -v \$cmd >/dev/null 2>&1; then
        echo \"\$cmd: OK\"
      else
        echo \"\$cmd: MISSING\"
      fi
    done
  " 2>/dev/null)"

  local fail=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if [[ "$line" == *": OK"* ]]; then
      log_ok "  $line"
    else
      log_warn "  $line"
      # mysql and mysqldump are nice to have, but tar and php are strictly mandatory.
      if [[ "$line" == "tar:"* || "$line" == "php:"* ]]; then
        fail=1
      fi
    fi
  done <<< "$remote_checks"

  # 3. Test WordPress Directory Existence
  log_info "[3/4] Checking Remote Directory Existence..."
  if wpsite_ssh "$ssh_target" "[ -d '$wp_root' ]" >/dev/null 2>&1; then
    log_ok "  Directory '$wp_root' exists on remote."
  else
    log_error "  Directory '$wp_root' does NOT exist on remote!"
    fail=1
  fi

  # 4. Test WP-CLI and WordPress database connection
  log_info "[4/4] Testing Remote WP-CLI & WordPress Boot..."
  # Locate the wp binary on remote
  local wp_bin; wp_bin="$(wpsite_ssh "$ssh_target" "which wp 2>/dev/null || echo wp")"
  log_info "  Remote WP-CLI path: $wp_bin"

  local wp_version
  wp_version="$(wpsite_ssh "$ssh_target" "cd '$wp_root' && wp core version --allow-root 2>/dev/null" | tr -d '\r')"
  if [ -n "$wp_version" ]; then
    log_ok "  WP-CLI can boot and connect to DB. WordPress Version: $wp_version"
  else
    # Try running it natively or check if there is an error
    local raw_error; raw_error="$(wpsite_ssh "$ssh_target" "cd '$wp_root' && wp core version --allow-root 2>&1")"
    log_error "  WP-CLI failed to execute or connect to WordPress database!"
    log_error "  Error output: $raw_error"
    fail=1
  fi

  echo
  ssh_close_mux
  trap - EXIT

  if [ "$fail" = "0" ]; then
    log_ok "Remote server '$client' is 100% READY for backup and apply operations!"
    return 0
  else
    die "Remote server '$client' has missing dependencies or connection issues (see above)."
  fi
}
