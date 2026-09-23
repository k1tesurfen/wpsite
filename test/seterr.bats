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

@test "_write_php_ini: writes the ini file, returns 0" {
  strict '
    d="$(mktemp -d)"; cd "$d"
    _write_php_ini php-wpsite.ini
    grep -q "upload_max_filesize" php-wpsite.ini || exit 97
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
  run env REPO="$REPO" TMP="$BATS_TEST_TMPDIR" \
    MANDOS_BIN="$REPO/test/fixtures/mandos-stub" bash -c 'set -euo pipefail
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

@test "_backup_track_domain: bare statement safe (no cloud_base / unpinned)" {
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  cstrict '_backup_track_domain acme 20260101_120000'
  [ "$status" -eq 0 ]; [[ "$output" == *__REACHED__* ]]
}

@test "_client_check_cloud_folder: bare statement safe (no cloud_base + missing folder)" {
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  run env REPO="$REPO" TMP="$BATS_TEST_TMPDIR" \
    MANDOS_BIN="$REPO/test/fixtures/mandos-stub" bash -c 'set -euo pipefail
    printf "base_dir: %s/root\ncloud_base: %s/cloud\n" "$TMP" "$TMP" > "$TMP/c.yml"
    mkdir -p "$TMP/cloud"
    export WPSITE_CONFIG="$TMP/c.yml"
    source "$REPO/lib/common.sh"
    source "$REPO/lib/cmd_new.sh"
    source "$REPO/lib/cmd_client.sh"
    _client_check_cloud_folder ""            # early return (empty)
    _client_check_cloud_folder does-not-exist  # warn path, still returns 0
    echo __REACHED__'
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

# --- db / Adminer helpers --------------------------------------------------

@test "_silence_wordfence: wordfence absent -> no-op, does not abort" {
  run env REPO="$REPO" bash -c 'set -euo pipefail
    source "$REPO/lib/common.sh"; source "$REPO/lib/cmd_build.sh"
    docker() { :; }; export -f docker
    _silence_wordfence db wp_
    echo __REACHED__'
  [ "$status" -eq 0 ]
  [[ "$output" == *__REACHED__* ]]
}

@test "_install_sendmail_shim: bare statement safe (stubbed docker)" {
  run env REPO="$REPO" bash -c 'set -euo pipefail
    source "$REPO/lib/common.sh"; source "$REPO/lib/cmd_mail.sh"; source "$REPO/lib/cmd_build.sh"
    docker() { cat >/dev/null 2>&1 || true; return 0; }; export -f docker
    _install_sendmail_shim app
    echo __REACHED__'
  [ "$status" -eq 0 ]
  [[ "$output" == *__REACHED__* ]]
}

@test "_adminer_attach: bare statement safe (empty networks, stubbed docker)" {
  # Ends in a for-loop over a possibly-empty network list — must not abort.
  run env REPO="$REPO" bash -c 'set -euo pipefail
    source "$REPO/lib/common.sh"; source "$REPO/lib/cmd_db.sh"
    docker() { :; }; export -f docker
    _adminer_attach wp_acme_db
    echo __REACHED__'
  [ "$status" -eq 0 ]
  [[ "$output" == *__REACHED__* ]]
}

# --- redirect helpers (pure transforms, bare-statement guards) -------------

# Strict-mode runner with just the redirect lib loaded.
rstrict() { run env REPO="$REPO" bash -c 'set -euo pipefail
    source "$REPO/lib/common.sh"; source "$REPO/lib/cmd_redirect.sh"
    '"$1"'
    echo __REACHED__'; }

@test "_redirect_extract_rules / _redirect_strip_block: empty input -> no abort" {
  rstrict 'printf "" | _redirect_extract_rules; printf "" | _redirect_strip_block'
  [ "$status" -eq 0 ]; [[ "$output" == *__REACHED__* ]]
}

@test "_redirect_merge: two empty rule sets -> no abort" {
  rstrict 'a="$(mktemp)"; b="$(mktemp)"; _redirect_merge "$a" "$b"'
  [ "$status" -eq 0 ]; [[ "$output" == *__REACHED__* ]]
}

@test "_redirect_parse_csv: empty file -> no abort" {
  rstrict 'f="$(mktemp)"; s="$(mktemp)"; _redirect_parse_csv "$f" "$s"'
  [ "$status" -eq 0 ]; [[ "$output" == *__REACHED__* ]]
}

@test "_redirect_filter_out / _redirect_print_rules: empty rules -> no abort" {
  rstrict 'f="$(mktemp)"; _redirect_filter_out "$f" /x; _redirect_print_rules "$f"'
  [ "$status" -eq 0 ]; [[ "$output" == *__REACHED__* ]]
}

@test "_redirect_build_block: empty rules -> no abort" {
  rstrict 'f="$(mktemp)"; _redirect_build_block "$f" >/dev/null'
  [ "$status" -eq 0 ]; [[ "$output" == *__REACHED__* ]]
}

@test "_redirect_regex_escape / _redirect_pattern / _redirect_target: bare-safe" {
  rstrict '_redirect_regex_escape "a.b?c"; _redirect_pattern "/x/" 0; _redirect_pattern "^/y" 1; _redirect_target "z"'
  [ "$status" -eq 0 ]; [[ "$output" == *__REACHED__* ]]
}

# --- P0 dev-box helpers: all called as bare statements / in $() under set -e --------

@test "latest_backup_dir: no backups dir at all -> does not abort" {
  cstrict 'latest_backup_dir acme; latest_backup_dir nosuchclient'
  [ "$status" -eq 0 ]; [[ "$output" == *__REACHED__* ]]
}

@test "latest_backup_dir: only an INCOMPLETE backup -> empty, does not abort" {
  cstrict 'mkdir -p "$TMP/root/clients/acme/backups/20260101_000000"
           : > "$TMP/root/clients/acme/backups/20260101_000000/db.sql"
           out="$(latest_backup_dir acme)"; [ -z "$out" ]'
  [ "$status" -eq 0 ]; [[ "$output" == *__REACHED__* ]]
}

@test "latest_backup_dir: picks the newest COMPLETE one by id name" {
  cstrict 'b="$TMP/root/clients/acme/backups"
           for id in 20260101_000000 20260615_120000; do
             mkdir -p "$b/$id"
             for f in db.sql wp-content.tar.gz meta.env; do echo x > "$b/$id/$f"; done
           done
           mkdir -p "$b/20261231_235959"; : > "$b/20261231_235959/db.sql"   # incomplete, newer
           [ "$(basename "$(latest_backup_dir acme)")" = "20260615_120000" ]'
  [ "$status" -eq 0 ]; [[ "$output" == *__REACHED__* ]]
}

@test "_backup_age_days / _days_from_civil / config_dev_suffix: bare-safe" {
  cstrict '_backup_age_days 20260101_000000; _backup_age_days garbage
           _days_from_civil 2026 09 05; config_dev_suffix'
  [ "$status" -eq 0 ]; [[ "$output" == *__REACHED__* ]]
}

@test "_wp_image_for_host: bare statement safe, returns a tag" {
  strict 'out="$(_wp_image_for_host wordpress:6.7-php8.3-apache)"; [ -n "$out" ]'
  [ "$status" -eq 0 ]; [[ "$output" == *__REACHED__* ]]
}

# _warn_if_core_older is called as a BARE statement at the end of a build. Its
# docker exec fails for an absent container and its version compare is a falsy
# test — both must degrade to 0, not abort the run.
@test "_warn_if_core_older: absent container / empty version -> does not abort" {
  strict '_warn_if_core_older "wp_nope_$$_app" "6.9.8"; _warn_if_core_older "wp_nope_$$_app" ""'
  [ "$status" -eq 0 ]
  [[ "$output" == *__REACHED__* ]]
}

# --- upgrade/apply reconciliation helpers ------------------------------------
# Both are called as BARE statements (_report_reconcile is the last line of
# _upgrade_report), so a falsy last command would abort the whole run right
# before the report is written.
ustrict() { run env REPO="$REPO" TMP="$BATS_TEST_TMPDIR" bash -c 'set -euo pipefail
source "$REPO/lib/common.sh"
source "$REPO/lib/cmd_upgrade.sh"
'"$1"'
echo __REACHED__'; }

@test "_active_plugins_from_csv: missing file / no active rows -> does not abort" {
  ustrict '_active_plugins_from_csv "$TMP/nope.csv"
printf "name,version,update,status\nfoo,1.0,none,inactive\n" > "$TMP/c.csv"
_active_plugins_from_csv "$TMP/c.csv"'
  [ "$status" -eq 0 ]
  [[ "$output" == *__REACHED__* ]]
}

@test "_report_reconcile: absent / empty file -> does not abort" {
  ustrict '_report_reconcile "$TMP/nope.txt"; : > "$TMP/e.txt"; _report_reconcile "$TMP/e.txt"'
  [ "$status" -eq 0 ]
  [[ "$output" == *__REACHED__* ]]
}

@test "_reconcile_active_plugins: nothing lost -> clean exit, no runner calls" {
  ustrict 'printf "name,version,update,status\na,1,none,active\n" > "$TMP/b.csv"
cp "$TMP/b.csv" "$TMP/a.csv"
R() { echo "RAN" >> "$TMP/ran"; }
_reconcile_active_plugins "$TMP/b.csv" "$TMP/a.csv" "$TMP/log" "$TMP/out" R
[ ! -f "$TMP/ran" ]'
  [ "$status" -eq 0 ]
  [[ "$output" == *__REACHED__* ]]
}

@test "_reconcile_active_plugins: EVERY active plugin lost -> still detected" {
  # Guards the empty-after-set awk trap: NR==FNR would swallow this case entirely.
  ustrict 'printf "name,version,update,status\na,1,none,active\n" > "$TMP/b.csv"
printf "name,version,update,status\na,2,none,inactive\n" > "$TMP/a.csv"
R() { return 0; }
_reconcile_active_plugins "$TMP/b.csv" "$TMP/a.csv" "$TMP/log" "$TMP/out" R
grep -q REACTIVATED "$TMP/out"'
  [ "$status" -eq 0 ]
  [[ "$output" == *__REACHED__* ]]
}

# --- report PDF helpers -------------------------------------------------------
# _report_pdf is a bare statement at the end of _write_client_report_de, and
# _report_txt's last command is a falsy `[ -f … ]` glob test whenever a run dir
# holds no report — either one would abort apply right after the update.
repstrict() { run env REPO="$REPO" TMP="$BATS_TEST_TMPDIR" bash -c 'set -euo pipefail
source "$REPO/lib/common.sh"
source "$REPO/lib/cmd_upgrade.sh"
source "$REPO/lib/cmd_report.sh"
'"$1"'
echo __REACHED__'; }

@test "_report_pdf: no cupsfilter / a failing cupsfilter -> warns, does not abort" {
  repstrict 'printf x > "$TMP/r.txt"
have() { return 1; }
_report_pdf "$TMP/r.txt"
have() { return 0; }
cupsfilter() { return 1; }
_report_pdf "$TMP/r.txt"
[ ! -e "$TMP/r.pdf" ]'
  [ "$status" -eq 0 ]
  [[ "$output" == *__REACHED__* ]]
}

@test "_report_txt: run dir with no report -> empty, does not abort" {
  repstrict 'mkdir -p "$TMP/run"; out="$(_report_txt "$TMP/run")"; [ -z "$out" ]'
  [ "$status" -eq 0 ]
  [[ "$output" == *__REACHED__* ]]
}

@test "_report_runs: missing kind dir -> empty, does not abort" {
  repstrict 'WPSITE_CONFIG="$TMP/none.yml"; printf "base_dir: %s\n" "$TMP/base" > "$WPSITE_CONFIG"
out="$(_report_runs ghost applies)"; [ -z "$out" ]'
  [ "$status" -eq 0 ]
  [[ "$output" == *__REACHED__* ]]
}

# --- Update-run helpers (cmd_upgrade.sh) --------------------------------------
# All called as bare statements inside apply/upgrade; each must survive strict mode
# with a failing runner / missing CSVs / an empty plan.

@test "update helpers: failing runner, missing CSVs, empty plan -> do not abort" {
  strict '
    source "$REPO/lib/cmd_upgrade.sh"
    d="$(mktemp -d)"; fail() { return 1; }
    _refresh_update_cache "$d/update.log" fail
    _ulog_note "$d/update.log" "note"
    plan="$(_update_plan plugin "$d/none.csv" "$d/update.log" fail)"
    [ -z "$plan" ] || exit 98
    _report_missed_updates "$d"
    printf "name,version,update\nfoo,1.0,available\n" > "$d/plugins.before.csv"
    cp "$d/plugins.before.csv" "$d/plugins.after.csv"
    _report_missed_updates "$d" 2>/dev/null
    grep -q "NOT UPDATED: plugin foo" "$d/update.log" || exit 99
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *__REACHED__* ]]
}
