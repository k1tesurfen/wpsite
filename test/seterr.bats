#!/usr/bin/env bats
# Regression guard for the recurring `set -e` foot-gun: a helper called as a bare
# statement whose last command is a falsy test / failed-glob / empty-grep returns
# non-zero and SILENTLY aborts the whole run. Each test runs the helper inside a
# fresh `set -euo pipefail` shell and asserts execution continues past it.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

# Run a snippet under strict mode with the lib loaded; REPO passed via env so the
# snippet can stay single-quoted (no escaping).
strict() { run env REPO="$REPO" bash -c "set -euo pipefail
source \"\$REPO/lib/common.sh\"
source \"\$REPO/lib/cmd_build.sh\"
source \"\$REPO/lib/cmd_list.sh\"
$1
echo __REACHED__"; }

@test "_strip_dropins: no drop-ins present -> does not abort" {
  strict 'd="$(mktemp -d)"; mkdir -p "$d"; _strip_dropins "$d"'
  [ "$status" -eq 0 ]
  [[ "$output" == *__REACHED__* ]]
}

@test "_strip_dropins: removes drop-ins + cache, still returns 0" {
  strict '
    d="$(mktemp -d)"
    : > "$d/advanced-cache.php"; : > "$d/object-cache.php"; mkdir -p "$d/cache"
    _strip_dropins "$d"
    [ ! -e "$d/advanced-cache.php" ] && [ ! -e "$d/cache" ] || exit 99
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *__REACHED__* ]]
}

@test "_rebuild_media: missing map -> returns 0" {
  strict '_rebuild_media "/no/such/map.txt" "$(command -v magick || command -v convert)"'
  [ "$status" -eq 0 ]
  [[ "$output" == *__REACHED__* ]]
}

@test "_rebuild_media: empty (present) map -> 'No media' not a pipefail abort" {
  # Shipped bug: `total="$(grep -c . map | head -1)"` on an EMPTY map made grep exit 1,
  # pipefail propagated it, and set -e silently aborted the whole build after teardown.
  strict '
    m="$(mktemp)"; : > "$m"      # present but zero lines (SVG-only site)
    _rebuild_media "$m" "$(command -v magick || command -v convert || echo magick)"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *__REACHED__* ]]
}

@test "_rebuild_media: all-success map does not abort (fail.* glob fix)" {
  # This is the exact bug we shipped: when nothing fails, the fail.* glob matched
  # nothing and the failed=\$(cat ...) assignment aborted under set -e.
  strict '
    work="$(mktemp -d)"; cd "$work"
    printf "wp-content/uploads/a-100x80.png|100|80\n"  >  map.txt
    printf "wp-content/uploads/b-120x90.png|120|90\n"  >> map.txt
    printf "wp-content/uploads/c-64x64.png|64|64\n"    >> map.txt
    _rebuild_media map.txt "$(command -v magick || command -v convert)"
    [ "$(find wp-content -type f | wc -l | tr -d " ")" = "3" ] || exit 98
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *__REACHED__* ]]
}

@test "_deactivate_matching: no matching plugins -> does not abort" {
  run env REPO="$REPO" bash -c 'set -euo pipefail
    source "$REPO/lib/common.sh"; source "$REPO/lib/cmd_build.sh"
    docker() { echo ""; }; export -f docker      # nothing active
    _deactivate_matching app "wp-rocket w3-total-cache" active ""
    echo __REACHED__'
  [ "$status" -eq 0 ]
  [[ "$output" == *__REACHED__* ]]
}

@test "_placeholder_font: never errors (exit 0 with or without a font)" {
  strict 'f="$(_placeholder_font)"; printf "font=%s\n" "$f"'
  [ "$status" -eq 0 ]
  [[ "$output" == *__REACHED__* ]]
}

@test "_rewrite_urls: no source URLs -> no-op, returns 0" {
  # docker stub so nothing real runs; empty host list must return cleanly.
  run env REPO="$REPO" bash -c 'set -euo pipefail
    source "$REPO/lib/common.sh"; source "$REPO/lib/cmd_build.sh"
    docker() { :; }; export -f docker
    d="$(mktemp -d)"; mkdir -p "$d/wp-content"
    ( cd "$d" && _rewrite_urls app wp-content host.test http://host.test "" "" )
    echo __REACHED__'
  [ "$status" -eq 0 ]
  [[ "$output" == *__REACHED__* ]]
}

# --- cloud sync helpers (set -e bare-statement guards) ---------------------

# Strict-mode runner with a minimal config + the cloud lib loaded.
cstrict() {
  run env REPO="$REPO" TMP="$BATS_TEST_TMPDIR" bash -c 'set -euo pipefail
    printf "base_dir: %s/root\nclients:\n  acme:\n    ssh: u@h\n    wp_root: /v\n" "$TMP" > "$TMP/c.yml"
    export WPSITE_CONFIG="$TMP/c.yml"
    source "$REPO/lib/common.sh"
    source "$REPO/lib/cloud.sh"
    source "$REPO/lib/cmd_backup.sh"
    '"$1"'
    echo __REACHED__'
}

@test "_cloud_sync_client: cloud unconfigured -> warns, does not abort" {
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  cstrict '_cloud_sync_client acme'
  [ "$status" -eq 0 ]; [[ "$output" == *__REACHED__* ]]
}

@test "_local_backup_ids / _cloud_backup_ids: no dirs -> do not abort" {
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  cstrict '_local_backup_ids acme; _cloud_backup_ids acme'
  [ "$status" -eq 0 ]; [[ "$output" == *__REACHED__* ]]
}

@test "_audit_log / _manifest_add / _manifest_remove: bare statements safe" {
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  cstrict '_manifest_add acme 20260101_120000; _manifest_remove acme 20260101_120000; _audit_log acme push 20260101_120000'
  [ "$status" -eq 0 ]; [[ "$output" == *__REACHED__* ]]
}

@test "_backup_autoprune: cloud unmounted -> warns, does not abort" {
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  cstrict '_backup_autoprune acme'
  [ "$status" -eq 0 ]; [[ "$output" == *__REACHED__* ]]
}

@test "_backup_post_cloud: no cloud configured -> does not abort" {
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  cstrict '_backup_post_cloud acme 20260101_120000'
  [ "$status" -eq 0 ]; [[ "$output" == *__REACHED__* ]]
}
