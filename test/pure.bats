#!/usr/bin/env bats
# Pure helper logic — no Docker/SSH, no side effects.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_build.sh"
}

@test "_wp_image_tag: wp + php" {
  run _wp_image_tag 6.4 8.3
  [ "$output" = "wordpress:6.4-php8.3-apache" ]
}

@test "_wp_image_tag: php only" {
  run _wp_image_tag "" 8.3
  [ "$output" = "wordpress:php8.3-apache" ]
}

@test "_wp_image_tag: wp only" {
  run _wp_image_tag 6.4 ""
  [ "$output" = "wordpress:6.4-apache" ]
}

@test "_wp_image_tag: neither -> latest" {
  run _wp_image_tag "" ""
  [ "$output" = "wordpress:latest" ]
}

@test "_wp_image_candidates: ordered, WP version kept before PHP" {
  run _wp_image_candidates 7.0 8.1
  [ "${lines[0]}" = "wordpress:7.0-php8.1-apache" ]
  [ "${lines[1]}" = "wordpress:7.0-apache" ]
  [ "${lines[2]}" = "wordpress:php8.1-apache" ]
  [ "${lines[3]}" = "wordpress:latest" ]
}

# The resolver probes via `docker manifest inspect`; we stub `docker` so no real
# registry call happens (still side-effect free).
@test "_resolve_wp_image: picks the exact prod tag when it's published" {
  docker() { [ "$3" = "wordpress:7.0-php8.3-apache" ]; }
  run _resolve_wp_image 7.0 8.3
  [ "$output" = "wordpress:7.0-php8.3-apache" ]
}

@test "_resolve_wp_image: falls back to <wp>-apache when the PHP combo is missing" {
  docker() { [ "$3" = "wordpress:7.0-apache" ]; }   # the drfroehlich case (7.0 + php8.1)
  run _resolve_wp_image 7.0 8.1
  [ "$output" = "wordpress:7.0-apache" ]
}

@test "_resolve_wp_image: returns the preferred tag when nothing resolves (offline)" {
  docker() { return 1; }
  # With no patch component the fallback IS the preferred tag; stdout only, since the
  # "cannot probe" notice goes to stderr and `run` would merge the two.
  local tag; tag="$(_resolve_wp_image 7.0 8.1 2>/dev/null)"
  [ "$tag" = "wordpress:7.0-php8.1-apache" ]
}

@test "expand_tilde: expands leading ~/" {
  run expand_tilde "~/websites"
  [ "$output" = "$HOME/websites" ]
}

@test "expand_tilde: leaves absolute paths" {
  run expand_tilde "/var/www/x"
  [ "$output" = "/var/www/x" ]
}

@test "expand_tilde: does not touch ~ mid-string" {
  run expand_tilde "/a/~/b"
  [ "$output" = "/a/~/b" ]
}

@test "_meta_get: reads a present key" {
  printf 'WP_VERSION=6.4\nSOURCE_HOME=https://x.de\n' > "$BATS_TEST_TMPDIR/meta.env"
  run _meta_get SOURCE_HOME "$BATS_TEST_TMPDIR/meta.env"
  [ "$output" = "https://x.de" ]
}

@test "_meta_get: value containing = is preserved" {
  printf 'K=a=b=c\n' > "$BATS_TEST_TMPDIR/meta.env"
  run _meta_get K "$BATS_TEST_TMPDIR/meta.env"
  [ "$output" = "a=b=c" ]
}

@test "_meta_get: missing key is empty and exit 0 (set -e safe)" {
  printf 'A=1\n' > "$BATS_TEST_TMPDIR/meta.env"
  run _meta_get NOPE "$BATS_TEST_TMPDIR/meta.env"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_meta_get: missing file is empty and exit 0" {
  run _meta_get A "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_inject_wpsite_compat_muplugin: writes compatibility helper" {
  d="$BATS_TEST_TMPDIR/wp-content"
  mkdir -p "$d"
  _inject_wpsite_compat_muplugin "$d"
  [ -f "$d/mu-plugins/wpsite-compat.php" ]
  grep -q 'include_once.*template.php' "$d/mu-plugins/wpsite-compat.php"
}

@test "_is_backup_id: matches timestamps + optional -permanent, rejects junk" {
  _is_backup_id 20260101_120000
  _is_backup_id 20260101_120000-permanent
  run _is_backup_id 20260101            ; [ "$status" -ne 0 ]
  run _is_backup_id 20260101_120000.tmp ; [ "$status" -ne 0 ]
  run _is_backup_id fresh               ; [ "$status" -ne 0 ]
  run _is_backup_id ''                  ; [ "$status" -ne 0 ]
}

@test "_is_persistent_backup: true only for the -permanent suffix" {
  _is_persistent_backup 20260101_120000-permanent
  _is_persistent_backup /some/path/20260101_120000-permanent
  run _is_persistent_backup 20260101_120000 ; [ "$status" -ne 0 ]
}

# --- backup age arithmetic (no `date -d`/`date -j`: those are the GNU/BSD split) ---

@test "_days_from_civil: epoch and known dates" {
  [ "$(_days_from_civil 1970 01 01)" = "0" ]
  [ "$(_days_from_civil 1970 01 02)" = "1" ]
  [ "$(_days_from_civil 2000 03 01)" = "11017" ]
}

@test "_days_from_civil: leap day and 08/09 are not read as octal" {
  # 2024 is a leap year: Feb 29 exists and Mar 1 is the next day.
  [ "$(( $(_days_from_civil 2024 03 01) - $(_days_from_civil 2024 02 29) ))" = "1" ]
  # 08 and 09 would be invalid octal without 10# — these must not error.
  [ "$(( $(_days_from_civil 2026 09 08) - $(_days_from_civil 2026 08 09) ))" = "30" ]
}

@test "_backup_age_days: tolerates the -permanent suffix, empty when unparseable" {
  local today; today="$(date +%Y%m%d)"
  [ "$(_backup_age_days "${today}_120000")" = "0" ]
  [ "$(_backup_age_days "${today}_120000-permanent")" = "0" ]
  [ -z "$(_backup_age_days "not-a-backup")" ]
}

@test "config_dev_suffix: defaults to test, strips a leading dot" {
  [ "$(config_dev_suffix)" = "test" ]
  [ "$(WPSITE_DEV_SUFFIX=dev.test config_dev_suffix)" = "dev.test" ]
  [ "$(WPSITE_DEV_SUFFIX=.dev.test config_dev_suffix)" = "dev.test" ]
}

# --- _wp_minor / image candidate ordering -----------------------------------------
# Regression: a 6.9.8/php8.0 site resolved to wordpress:php8.0-apache, which is frozen
# at WP 6.4.1 — core OLDER than the imported DB, so every frontend page fatalled on a
# post-6.4 core function (Yoast: wp_is_serving_rest_request) while wp-admin still ran.

@test "_wp_minor: strips the patch level, passes a series through" {
  [ "$(_wp_minor 6.9.8)" = "6.9" ]
  [ "$(_wp_minor 6.9)"   = "6.9" ]
  [ "$(_wp_minor 7)"     = "7" ]
}

@test "candidates: WP minor series comes before any PHP-pinned tag" {
  run _wp_image_candidates 6.9.8 8.0
  [ "$status" -eq 0 ]
  local list="$output"
  # both present
  echo "$list" | grep -qx 'wordpress:6.9-apache'
  echo "$list" | grep -qx 'wordpress:php8.0-apache'
  # and the series tag is ranked higher (earlier) than the PHP-only fallback
  local series php_only
  series="$(echo "$list" | grep -nx 'wordpress:6.9-apache'   | cut -d: -f1)"
  php_only="$(echo "$list" | grep -nx 'wordpress:php8.0-apache' | cut -d: -f1)"
  [ "$series" -lt "$php_only" ]
}

@test "candidates: exact match first, latest last, no empty tags without a version" {
  run _wp_image_candidates 6.9.8 8.0
  [ "$(echo "$output" | head -1)" = "wordpress:6.9.8-php8.0-apache" ]
  [ "$(echo "$output" | tail -1)" = "wordpress:latest" ]
  run _wp_image_candidates "" ""
  [ "$output" = "wordpress:latest" ]
}

# --- image resolution: local cache, registry probe, rate-limit fallback -----------
# `docker` is shadowed by a shell function, so these stay hermetic (no daemon, no net).

@test "_wp_image_fallback: never pins a patch tag (may lag WP, e.g. 7.0.5)" {
  [ "$(_wp_image_fallback 7.0.5 8.2)" = "wordpress:7.0-php8.2-apache" ]
  [ "$(_wp_image_fallback 6.9.8 "")"  = "wordpress:6.9-apache" ]
  [ "$(_wp_image_fallback "" 8.2)"    = "wordpress:php8.2-apache" ]
  [ "$(_wp_image_fallback "" "")"     = "wordpress:latest" ]
}

@test "_resolve_wp_image: an already-pulled image wins without any registry call" {
  docker() {
    case "$1 $2" in
      "image inspect") [ "$3" = "wordpress:6.9-apache" ] ;;   # only this one is local
      "manifest inspect") echo "PROBED" >&3; return 0 ;;      # must never run
      *) return 1 ;;
    esac
  }
  run _resolve_wp_image 6.9.8 8.0
  [ "$output" = "wordpress:6.9-apache" ]
}

@test "_resolve_wp_image: rate-limited probe falls back to the series tag, not the patch tag" {
  docker() {
    case "$1 $2" in
      "image inspect") return 1 ;;
      "manifest inspect") echo "toomanyrequests: You have reached your unauthenticated pull rate limit." >&2; return 1 ;;
      *) return 1 ;;
    esac
  }
  # this path logs to stderr, which `run` would merge into $output — capture stdout only
  local tag; tag="$(_resolve_wp_image 7.0.5 8.2 2>/dev/null)"
  [ "$tag" = "wordpress:7.0-php8.2-apache" ]
}

@test "_resolve_wp_image: a genuinely absent tag just moves to the next candidate" {
  docker() {
    case "$1 $2" in
      "image inspect") return 1 ;;
      "manifest inspect")
        if [ "$3" = "wordpress:7.0-apache" ]; then return 0; fi
        echo "manifest unknown" >&2; return 1 ;;
      *) return 1 ;;
    esac
  }
  run _resolve_wp_image 7.0.5 ""
  [ "$output" = "wordpress:7.0-apache" ]
}

# --- Rehearsal fidelity (HARDENING-PLAN.md Phase 7) ----------------------------------
# arbeitsplatz-erde: the replica carried akismet/hello/twentytwenty* that production
# doesn't have (copied in by the image's entrypoint) — only what APPEARED is removed.

@test "_strip_image_extras: removes only what appeared after the snapshot" {
  source "$REPO/lib/cmd_build.sh"
  local d="$BATS_TEST_TMPDIR/wpc"
  mkdir -p "$d/plugins/acf" "$d/themes/greyd_suite"
  _content_snapshot "$d" > "$BATS_TEST_TMPDIR/snap"
  mkdir -p "$d/plugins/akismet" "$d/themes/twentytwentyfour"; : > "$d/plugins/hello.php"
  run _strip_image_extras "$d" "$BATS_TEST_TMPDIR/snap"
  [ "$status" -eq 0 ]
  [ -d "$d/plugins/acf" ]; [ -d "$d/themes/greyd_suite" ]
  [ ! -e "$d/plugins/akismet" ]; [ ! -e "$d/plugins/hello.php" ]; [ ! -e "$d/themes/twentytwentyfour" ]
}

@test "_strip_image_extras: a production akismet (in the backup) is kept" {
  source "$REPO/lib/cmd_build.sh"
  local d="$BATS_TEST_TMPDIR/wpc2"; mkdir -p "$d/plugins/akismet"
  _content_snapshot "$d" > "$BATS_TEST_TMPDIR/snap2"
  _strip_image_extras "$d" "$BATS_TEST_TMPDIR/snap2"
  [ -d "$d/plugins/akismet" ]
}

@test "_pin_core_version: downloads the exact version only when it differs; offline warns" {
  source "$REPO/lib/cmd_build.sh"
  CORE=7.0; DL_OK=1; LOG="$BATS_TEST_TMPDIR/dl"; : > "$LOG"
  docker() { case "$*" in *"core version"*) echo "$CORE" ;; *"core download"*) echo "$*" >> "$LOG"; [ "$DL_OK" = 1 ] ;; esac; }
  run _pin_core_version app 7.0.6
  grep -q -- '--version=7.0.6 --force --skip-content' "$LOG"
  : > "$LOG"; CORE=7.0.6
  run _pin_core_version app 7.0.6
  [ ! -s "$LOG" ]
  CORE=7.0; DL_OK=0
  run _pin_core_version app 7.0.6
  [ "$status" -eq 0 ]; [[ "$output" == *"keeps core 7.0"* ]]
}
