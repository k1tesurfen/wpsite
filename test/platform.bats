#!/usr/bin/env bats
# Platform shims (common.sh) + the platform-aware doctor / proxy install-dns.
#
# The shims detect by CAPABILITY, never by `uname`, which is exactly what makes them
# testable: a curated PATH lets BOTH branches run on either OS. `sandbox_path` builds a
# PATH holding only the real tools the code under test needs, plus whatever fake
# binaries a case wants present — so `open`/`brew`/`dscacheutil` really are absent even
# on macOS, and `xdg-open`/`apt-get`/`getent` can be made to exist.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  source "$REPO/lib/common.sh"
}

# Symlink real coreutils into the sandbox so stripped-PATH runs still work.
sandbox_path() { # tool...
  local t
  for t in grep find cut tr sed date sort head uniq cat tee mktemp dirname basename id uname printf; do
    [ -e "$BIN/$t" ] || ln -sf "$(command -v "$t" 2>/dev/null || true)" "$BIN/$t" 2>/dev/null || true
  done
  for t in "$@"; do printf '#!/bin/sh\necho "STUB:%s $*"\n' "$t" > "$BIN/$t"; chmod +x "$BIN/$t"; done
  printf '%s' "$BIN"
}

# --- _pkg_hint -------------------------------------------------------------------

@test "_pkg_hint: Homebrew host -> brew install <brew name>" {
  PATH="$(sandbox_path brew)" run _pkg_hint gnu-tar tar
  [ "$output" = "brew install gnu-tar" ]
}

@test "_pkg_hint: Debian host -> sudo apt install <apt name>" {
  PATH="$(sandbox_path apt-get)" run _pkg_hint gnu-tar tar
  [ "$output" = "sudo apt install tar" ]
}

@test "_pkg_hint: neither package manager -> a neutral hint, never a brew lie" {
  PATH="$(sandbox_path)" run _pkg_hint gnu-tar tar
  [ "$output" = "install tar" ]
  [[ "$output" != *brew* ]]
}

@test "_pkg_hint: apt name defaults to the brew name when only one is given" {
  PATH="$(sandbox_path apt-get)" run _pkg_hint ffmpeg
  [ "$output" = "sudo apt install ffmpeg" ]
}

@test "require: error message follows the host's package manager" {
  PATH="$(sandbox_path apt-get)" run require definitely-not-a-real-binary yq yq
  [ "$status" -ne 0 ]
  [[ "$output" == *"sudo apt install yq"* ]]
}

# --- _open_file ------------------------------------------------------------------

@test "_open_file: prefers xdg-open when present" {
  PATH="$(sandbox_path xdg-open open)" run _open_file /tmp/x.html
  [ "$status" -eq 0 ]
  [[ "$output" != *"Open manually"* ]]
}

@test "_open_file: falls back to open (macOS) when xdg-open is absent" {
  PATH="$(sandbox_path open)" run _open_file /tmp/x.html
  [ "$status" -eq 0 ]
  [[ "$output" != *"Open manually"* ]]
}

@test "_open_file: headless (neither) -> prints the target, still succeeds" {
  PATH="$(sandbox_path)" run _open_file "http://localhost:8080/?wpsite_server=wp_x_db"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Open manually: http://localhost:8080/?wpsite_server=wp_x_db"* ]]
}

@test "_open_file: a failing opener degrades to the printed target" {
  # Build the failing stub BEFORE narrowing PATH (chmod would be gone afterwards).
  printf '#!/bin/sh\nexit 3\n' > "$BIN/xdg-open"; chmod +x "$BIN/xdg-open"
  PATH="$(sandbox_path)" run _open_file /tmp/x.html
  [ "$status" -eq 0 ]
  [[ "$output" == *"Open manually: /tmp/x.html"* ]]
}

@test "_open_file: bare statement under set -euo pipefail does not abort" {
  run env REPO="$REPO" BIN="$BIN" /bin/bash -c 'set -euo pipefail
    source "$REPO/lib/common.sh"; PATH="$BIN"
    _open_file /tmp/nope.html
    echo __REACHED__'
  [ "$status" -eq 0 ]; [[ "$output" == *__REACHED__* ]]
}

# --- resolver shim ---------------------------------------------------------------

@test "wpsite_resolver_file: default and override" {
  [ "$(wpsite_resolver_file)" = "/etc/resolver/test" ]
  [ "$(WPSITE_RESOLVER=/tmp/r wpsite_resolver_file)" = "/tmp/r" ]
}

@test "_resolves_loopback: no resolution tool -> returns non-zero, never aborts" {
  run env REPO="$REPO" BIN="$BIN" /bin/bash -c 'set -euo pipefail
    source "$REPO/lib/common.sh"; PATH="$BIN"
    if _resolves_loopback something.test; then echo RESOLVED; else echo UNKNOWN; fi
    echo __REACHED__'
  [ "$status" -eq 0 ]; [[ "$output" == *UNKNOWN* ]]; [[ "$output" == *__REACHED__* ]]
}

# --- doctor ----------------------------------------------------------------------

doctor_run() { # extra_path_stubs...
  run env REPO="$REPO" WPSITE_CONFIG="$CFG" MANDOS_BIN="$MANDOS" \
      WPSITE_RESOLVER="$BATS_TEST_TMPDIR/no-resolver" WPSITE_DEV_SUFFIX="${SFX:-}" \
      PATH="$(sandbox_path "$@")" \
      /bin/bash -c 'set -uo pipefail
        source "$REPO/lib/common.sh"; source "$REPO/lib/cmd_doctor.sh"
        source "$REPO/lib/cmd_proxy.sh"; source "$REPO/lib/cmd_mail.sh"
        cmd_doctor' 2>&1
}

setup_cfg() {
  CFG="$BATS_TEST_TMPDIR/wpsite.yml"
  printf 'base_dir: %s/root\ndev:\n  myshop:\n    host: myshop.test\n' "$BATS_TEST_TMPDIR" > "$CFG"
}

@test "doctor: dev box (no mandos) reports role and does NOT fail on it" {
  setup_cfg; MANDOS="$BATS_TEST_TMPDIR/absent-mandos"
  doctor_run yq docker tar ffmpeg ssh magick apt-get getent
  [[ "$output" == *"role: dev box"* ]]
  [[ "$output" == *"gateway-only"* ]]
  # A missing registry must never be a dependency failure on a dev box.
  [[ "$output" != *"Some dependencies are missing"* ]]
}

@test "doctor: gateway (mandos present) reports the gateway role" {
  setup_cfg; MANDOS="$BIN/mandos"
  doctor_run yq docker tar ffmpeg ssh magick mandos brew
  [[ "$output" == *"role: gateway"* ]]
}

@test "doctor: install hints follow the package manager, not always brew" {
  setup_cfg; MANDOS="$BATS_TEST_TMPDIR/absent-mandos"
  doctor_run apt-get getent          # every dependency missing
  [ "$status" -ne 0 ]
  [[ "$output" == *"sudo apt install yq"* ]]
  [[ "$output" == *"sudo apt install docker-ce"* ]]
  [[ "$output" != *"brew install"* ]]
}

@test "doctor: no dscacheutil/brew -> Linux DNS wording, no Homebrew advice" {
  setup_cfg; MANDOS="$BATS_TEST_TMPDIR/absent-mandos"
  doctor_run yq docker tar ffmpeg ssh magick apt-get getent
  [[ "$output" == *"not configured"* ]]
  [[ "$output" != *"brew services"* ]]
}

@test "doctor: Homebrew host with no resolver -> points at proxy install-dns" {
  setup_cfg; MANDOS="$BIN/mandos"
  doctor_run yq docker tar ffmpeg ssh magick mandos brew dscacheutil
  [[ "$output" == *"wpsite proxy install-dns"* ]]
}

@test "doctor: reports the dev-site host suffix a dev box would use" {
  setup_cfg; MANDOS="$BATS_TEST_TMPDIR/absent-mandos"; SFX=dev.test
  doctor_run yq docker tar ffmpeg ssh magick
  [[ "$output" == *"suffix: .dev.test"* ]]
}

# --- proxy install-dns -----------------------------------------------------------

dns_run() {
  run env REPO="$REPO" PATH="$(sandbox_path "$@")" /bin/bash -c 'set -uo pipefail
    source "$REPO/lib/common.sh"; source "$REPO/lib/cmd_proxy.sh"
    _proxy_install_dns' 2>&1
}

@test "proxy install-dns: no Homebrew -> refuses, changes nothing, prints the recipe" {
  dns_run apt-get
  [ "$status" -ne 0 ]
  [[ "$output" == *"macOS/Homebrew only"* ]]
  [[ "$output" == *"Nothing was changed"* ]]
  [[ "$output" == *"apt install dnsmasq"* ]]
  [[ "$output" == *"resolved.conf.d"* ]]
  # The old behaviour was a bare "Homebrew required for dnsmasq setup." with no way out.
  [[ "$output" == *"/etc/hosts"* ]]
}

@test "proxy install-dns: Homebrew host routes to the brew implementation" {
  # brew present -> _proxy_install_dns_brew runs; stubbed brew/sudo keep it inert.
  dns_run brew sudo dnsmasq
  [[ "$output" != *"macOS/Homebrew only"* ]]
}

# --- mandos-absent quietness (dev box) -------------------------------------------

@test "registry adapters are SILENT when mandos isn't installed at all" {
  # Regression: the shell's own "No such file or directory" leaked to stderr on every
  # registry read, so a clean dev-box clone printed three exec errors.
  run env REPO="$REPO" MANDOS_BIN="$BATS_TEST_TMPDIR/absent" /bin/bash -c 'set -uo pipefail
    source "$REPO/lib/common.sh"
    config_clients; config_has_client acme; client_get acme ssh
    config_cloud_base; _team_config_path
    echo __REACHED__' 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *__REACHED__* ]]
  [[ "$output" != *"No such file"* ]]
  [[ "$output" != *"not found"* ]]
}

@test "require_access explains a missing mandos instead of a confusing exec error" {
  run env REPO="$REPO" MANDOS_BIN="$BATS_TEST_TMPDIR/absent" /bin/bash -c '
    source "$REPO/lib/common.sh"; require_access acme' 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"mandos is not installed"* ]]
}

@test "an INSTALLED mandos still reaches the real binary (adapters not short-circuited)" {
  printf '#!/bin/sh
case "$1 $2" in "client list") echo acme;; "client has") exit 0;; esac
' > "$BIN/mandos"
  chmod +x "$BIN/mandos"
  run env REPO="$REPO" MANDOS_BIN="$BIN/mandos" /bin/bash -c 'set -uo pipefail
    source "$REPO/lib/common.sh"; access_clients; access_has acme && echo HAS'
  [ "$status" -eq 0 ]
  [[ "$output" == *acme* ]]; [[ "$output" == *HAS* ]]
}

# --- _mtime (GNU stat -c %Y vs BSD stat -f %m) -----------------------------------

@test "_mtime: matches the platform's own stat on a real file" {
  local f="$BATS_TEST_TMPDIR/f"; : > "$f"
  local got expect; got="$(_mtime "$f")"
  expect="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")"
  [ -n "$got" ]; [ "$got" = "$expect" ]
}

@test "_mtime: numeric-only, so a wrong-flavour stat can never leak garbage" {
  local f="$BATS_TEST_TMPDIR/f2"; : > "$f"
  run _mtime "$f"
  [[ "$output" =~ ^[0-9]+$ ]]
}

@test "_mtime: missing path -> empty, and does not abort under set -e" {
  run env REPO="$REPO" /bin/bash -c 'set -euo pipefail
    source "$REPO/lib/common.sh"
    out="$(_mtime /no/such/path)"; [ -z "$out" ]
    echo __REACHED__'
  [ "$status" -eq 0 ]; [[ "$output" == *__REACHED__* ]]
}

@test "_mtime: no usable stat at all -> empty, still no abort" {
  run env REPO="$REPO" BIN="$BIN" /bin/bash -c 'set -euo pipefail
    source "$REPO/lib/common.sh"; PATH="$BIN"
    out="$(_mtime /etc/hosts)"; [ -z "$out" ]
    echo __REACHED__'
  [ "$status" -eq 0 ]; [[ "$output" == *__REACHED__* ]]
}

# --- _port_spec (WPSITE_BIND_ADDR) ------------------------------------------------

@test "_port_spec: default publishes on all interfaces (unchanged behaviour)" {
  [ "$(_port_spec 80 80)" = "80:80" ]
  [ "$(_port_spec 8025 8025)" = "8025:8025" ]
}

@test "_port_spec: WPSITE_BIND_ADDR confines the publish to one address" {
  [ "$(WPSITE_BIND_ADDR=127.0.0.1 _port_spec 80 80)" = "127.0.0.1:80:80" ]
  [ "$(WPSITE_BIND_ADDR=100.64.0.5 _port_spec 8080 8080)" = "100.64.0.5:8080:8080" ]
}

@test "_port_spec: empty WPSITE_BIND_ADDR is treated as unset, not as a blank address" {
  [ "$(WPSITE_BIND_ADDR= _port_spec 80 80)" = "80:80" ]
}

# --- config_role + the dispatcher's role guard ------------------------------------

@test "config_role: env wins, then config, else empty (unrestricted)" {
  local cfg="$BATS_TEST_TMPDIR/role.yml"
  printf 'base_dir: /tmp/x\n' > "$cfg"
  [ -z "$(WPSITE_CONFIG=$cfg config_role)" ]
  printf 'base_dir: /tmp/x\nrole: dev\n' > "$cfg"
  [ "$(WPSITE_CONFIG=$cfg config_role)" = "dev" ]
  [ "$(WPSITE_CONFIG=$cfg WPSITE_ROLE=gateway config_role)" = "gateway" ]
}

@test "dispatcher: role=dev refuses every gateway command" {
  local c
  local cfg="$BATS_TEST_TMPDIR/dispatch.yml"
  printf 'base_dir: %s/root\n' "$BATS_TEST_TMPDIR" > "$cfg"
  for c in apply redirect backup push test prune forget hold manual migrate-registry maintenance; do
    run env WPSITE_ROLE=dev WPSITE_CONFIG="$cfg" "$REPO/bin/wpsite" "$c" somearg
    [ "$status" -ne 0 ]
    [[ "$output" == *"gateway command"* ]] || { echo "not guarded: $c -- $output"; return 1; }
  done
}

@test "dispatcher: role=dev still allows the dev-box commands" {
  # These must get past the guard; they may then fail on their own preconditions,
  # but never with the role message.
  #
  # WPSITE_CONFIG is MANDATORY here even though this only checks dispatch: these are
  # real subprocesses, so without it they read the developer's OWN config. `db` with
  # no args is the one that bites — it reopens the last-used site, which launched
  # Adminer in a real browser on every single test run.
  local c cfg="$BATS_TEST_TMPDIR/dispatch.yml"
  printf 'base_dir: %s/root\n' "$BATS_TEST_TMPDIR" > "$cfg"
  for c in clone new inject start stop destroy db status list; do
    run env WPSITE_ROLE=dev WPSITE_CONFIG="$cfg" "$REPO/bin/wpsite" "$c"
    [[ "$output" != *"gateway command"* ]] || { echo "wrongly guarded: $c"; return 1; }
  done
}

@test "dispatcher: unset role leaves every command reachable (default is unrestricted)" {
  local cfg="$BATS_TEST_TMPDIR/dispatch.yml"
  printf 'base_dir: %s/root\n' "$BATS_TEST_TMPDIR" > "$cfg"
  run env WPSITE_CONFIG="$cfg" "$REPO/bin/wpsite" push
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage: wpsite push"* ]]
}

# --- push: argument + configuration guards ----------------------------------------

@test "push: no dev box configured -> explains how to configure one" {
  local cfg="$BATS_TEST_TMPDIR/push.yml"
  printf 'base_dir: %s/root\nclients:\n  acme:\n    ssh: u@h\n    wp_root: /v\n' "$BATS_TEST_TMPDIR" > "$cfg"
  run env WPSITE_CONFIG="$cfg" WPSITE_TEAM_CONFIG="$cfg" MANDOS_BIN="$REPO/test/fixtures/mandos-stub" \
      MANDOS_STUB_CONFIG="$cfg" "$REPO/bin/wpsite" push acme
  [ "$status" -ne 0 ]
  [[ "$output" == *"No dev box configured"* ]]
  [[ "$output" == *"devbox:"* ]]
}

@test "push: invalid dev-site name is rejected before anything is transferred" {
  local cfg="$BATS_TEST_TMPDIR/push2.yml"
  printf 'base_dir: %s/root\ndevbox:\n  host: nowhere\nclients:\n  acme:\n    ssh: u@h\n    wp_root: /v\n' "$BATS_TEST_TMPDIR" > "$cfg"
  run env WPSITE_CONFIG="$cfg" WPSITE_TEAM_CONFIG="$cfg" MANDOS_BIN="$REPO/test/fixtures/mandos-stub" \
      MANDOS_STUB_CONFIG="$cfg" "$REPO/bin/wpsite" push acme "Bad_Name"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid dev site name"* ]]
}

@test "push: config_devbox_host / _base resolve env, config, then default" {
  local cfg="$BATS_TEST_TMPDIR/push3.yml"
  printf 'base_dir: /tmp/x\ndevbox:\n  host: devbox\n  base_dir: /srv/websites\n' > "$cfg"
  [ "$(WPSITE_CONFIG=$cfg config_devbox_host)" = "devbox" ]
  [ "$(WPSITE_CONFIG=$cfg config_devbox_base)" = "/srv/websites" ]
  [ "$(WPSITE_CONFIG=$cfg WPSITE_DEVBOX=other config_devbox_host)" = "other" ]
  printf 'base_dir: /tmp/x\n' > "$cfg"
  [ "$(WPSITE_CONFIG=$cfg config_devbox_base)" = "websites" ]
  [ -z "$(WPSITE_CONFIG=$cfg config_devbox_host)" ]
}
