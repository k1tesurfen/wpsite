#!/usr/bin/env bash
# Fault-injection harness for `wpsite apply` (test/faultinject.bats). Runs cmd_apply the
# way bin/wpsite does — `set -euo pipefail`, a real process, so EXIT traps and silent
# aborts behave exactly as in production — against a fake server:
#   * the "remote" filesystem is a local dir ($FI_ROOT); wpsite_ssh runs commands there,
#     so the REAL maintenance functions write real files we can inspect afterwards;
#   * _prod_wp answers wp-cli calls from a tiny fake WordPress;
#   * curl sees the fake site: 503 + marker while a lock is up, else 200.
# Every remote call (_prod_wp or wpsite_ssh) increments $FI_COUNT; call number $FI_FAIL_AT
# fails (exit 255, no output). Call log → $FI_LOG.
set -euo pipefail
exec 2>&1
REPO="$1"
# shellcheck source=/dev/null
for f in common.sh cloud.sh cmd_backup.sh cmd_build.sh cmd_upgrade.sh cmd_apply.sh; do source "$REPO/lib/$f"; done

require() { :; }; ssh_setup_mux() { :; }; ssh_close_mux() { :; }
_latest_upgrade_dir() { printf '/tmp/rehearsed'; }
_remote_wp_prepare() { :; }
_write_client_report_de() { :; }
_confirm_prod() { echo "CONFIRMED" >> "$FI_LOG"; return 0; }
_backup_one_client() { _fi_call "backup" || return 1; mkdir -p "$(client_backup_dir "$1")/20260101_000000"; return 0; }

# Count this call; fail it if it's the chosen one.
_fi_call() {
  local n; n=$(( $(cat "$FI_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FI_COUNT"
  printf '%s\t%s\n' "$n" "$*" >> "$FI_LOG"
  [ "$n" != "${FI_FAIL_AT:-0}" ]
}

wpsite_ssh() {
  shift
  _fi_call "ssh $1" || return 255
  bash -c "$1"
}

_prod_wp() {
  shift 2
  _fi_call "wp $*" || return 255
  case "$*" in
    *"core version"*)                     echo "6.5" ;;
    *"option get home"*)                  echo "https://acme.example" ;;
    *wp_remote_head*)                     echo "HTTP 200" ;;
    *"core is-installed"*)                : ;;
    *"--status=active"*)                  echo "wp-mail-smtp" ;;
    *"post list"*)                        echo "https://acme.example/kontakt/" ;;
    *"plugin list --update=available"*)   echo "akismet" ;;
    *"theme list --update=available"*)    echo "twentytwentyfour" ;;
    *update_package*)                     printf 'name,version,update,update_version,update_package\nakismet,5.0,available,5.1,https://x/akismet.zip\n' ;;
    *"plugin list"*)                      printf 'name,version,update,status\nakismet,5.0,available,active\n' ;;
    *"theme list"*)                       printf 'name,version,update\ntwentytwentyfour,1.0,available\n' ;;
    *is_multisite*)                       echo 0 ;;
    *WPSITE_BOOT_OK*)                     echo WPSITE_BOOT_OK ;;
    *) echo "Success" ;;
  esac
}

curl() {
  local out="" bypass=0
  while [ $# -gt 0 ]; do
    case "$1" in -o) out="$2"; shift ;; -H) case "$2" in X-Wpsite-Bypass:*) bypass=1 ;; esac; shift ;; esac
    shift
  done
  if [ -e "$FI_ROOT/.maintenance" ] || { [ -e "$FI_ROOT/wp-content/.wpsite-maintenance" ] && [ "$bypass" = 0 ]; }; then
    printf '<!-- wpsite-maintenance-page -->' > "$out"; printf 503
  else
    printf '<html>ok</html>' > "$out"; printf 200
  fi
}

cmd_apply acme
