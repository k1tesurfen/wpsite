# shellcheck shell=bash
# wpsite build <client> — (re)build & run the latest backup as a local replica.
# Heavy/destructive: tears down any existing replica (incl. its DB volume) and
# rebuilds from scratch. For pause/resume use `wpsite stop` / `wpsite start`.

# The MariaDB image for replicas (also pulled by `wpsite prefetch`). One place, so the
# compose file and prefetch can't drift.
WPSITE_DB_IMAGE="mariadb:10.11"

# Read a KEY=value from meta.env without sourcing it.
_meta_get() { grep -m1 "^$1=" "$2" 2>/dev/null | cut -d= -f2- || true; }

# Choose a WordPress image tag from captured WP/PHP versions.
_wp_image_tag() { # wp_version php_version
  local wp="$1" php="$2"
  if [ -n "$wp" ] && [ -n "$php" ]; then
    echo "wordpress:${wp}-php${php}-apache"
  elif [ -n "$php" ]; then
    echo "wordpress:php${php}-apache"
  elif [ -n "$wp" ]; then
    echo "wordpress:${wp}-apache"
  else
    echo "wordpress:latest"
  fi
}

# Minor series of a WP version: 6.9.8 -> 6.9 (prints the version unchanged when it
# has no patch component). The official image does NOT publish a tag for every patch
# release — 6.9.8 has none while 6.9 does — so the series tag is the bridge.
_wp_minor() { # wp_version
  case "$1" in
    *.*.*) printf '%s' "${1%.*}" ;;
    *)     printf '%s' "$1" ;;
  esac
}

# Candidate image tags in priority order. The exact prod match is ideal, but the
# official wordpress image doesn't publish every WP×PHP combo (e.g. WP 7.0 ships
# only php8.2/8.3, not php8.1), nor a tag per patch release. For a local replica the
# WP *core* version matters far more than the PHP minor, so we keep WP and let PHP
# float before the reverse — INCLUDING the WP minor series before any PHP-pinned tag.
# That ordering is load-bearing: `wordpress:php8.0-apache` is frozen at WP 6.4.1 (the
# last core built for PHP 8.0), so reaching it from a 6.9 site gives core OLDER than
# the imported DB, and every plugin calling a post-6.4 core function fatals on the
# frontend while wp-admin still loads (seen on a 6.9.8/php8.0 site: Yoast calling
# wp_is_serving_rest_request(), added in 6.5).
_wp_image_candidates() { # wp php
  local wp="$1" php="$2" minor=""
  if [ -n "$wp" ]; then
    minor="$(_wp_minor "$wp")"
    if [ "$minor" = "$wp" ]; then minor=""; fi
  fi
  if [ -n "$wp" ]    && [ -n "$php" ]; then echo "wordpress:${wp}-php${php}-apache"; fi
  if [ -n "$minor" ] && [ -n "$php" ]; then echo "wordpress:${minor}-php${php}-apache"; fi
  if [ -n "$wp" ];                     then echo "wordpress:${wp}-apache"; fi
  if [ -n "$minor" ];                  then echo "wordpress:${minor}-apache"; fi
  if [ -n "$php" ];                    then echo "wordpress:php${php}-apache"; fi
  echo "wordpress:latest"
}

# Core-older-than-the-DB guard. The image resolver can only fall back to tags that
# EXIST, and a PHP-pinned fallback may carry a core years behind the snapshot. WP
# upgrades a DB forward silently, but running OLDER core against a newer DB fatals
# the frontend as soon as a plugin calls a core function that core doesn't have yet
# — and wp-admin often still works, so it looks like "only the frontend is broken".
# Warn loudly instead of leaving that to be discovered in the browser.
# --- Rehearsal fidelity (HARDENING-PLAN.md Phase 7) ---------------------------------
# The replica must start from EXACTLY production's state, or the rehearsal plans a
# different run than apply will do. Two ways the image made it differ (arbeitsplatz-erde:
# replica core 7.0 vs production 7.0.6; akismet/hello/twentytwenty* only on the replica):

# 1. The official image's entrypoint copies its bundled plugins/themes (akismet, hello.php,
#    twentytwenty*) into the bind-mounted wp-content when they are missing. Record what the
#    BACKUP brought before the first `up -d`, and afterwards remove exactly what appeared —
#    only the image can have added it, so nothing from the backup is ever touched.
_content_snapshot() { # wp_content_dir → one "plugins/x" / "themes/y" per line
  local d="$1" k e
  for k in plugins themes; do
    [ -d "$d/$k" ] || continue
    for e in "$d/$k"/*; do [ -e "$e" ] && printf '%s/%s\n' "$k" "$(basename "$e")"; done
  done
  return 0
}

_strip_image_extras() { # wp_content_dir snapshot_file
  local d="$1" snap="$2" e n=0
  [ -f "$snap" ] || return 0
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    grep -qxF "$e" "$snap" && continue
    rm -rf "${d:?}/$e" && n=$((n + 1))
    log_info "  removed image-bundled $e (not on production)"
  done < <(_content_snapshot "$d")
  [ "$n" -gt 0 ] && log_ok "Replica content matches the backup (removed $n image-bundled item(s))."
  return 0
}

# 2. Images exist per minor series (7.0), not for every patch release (7.0.6), so the
#    replica's core could trail production. Download the exact version over it (core files
#    only: --skip-content leaves wp-content alone). Needs the network; offline it warns and
#    keeps the image's core — _warn_if_core_older still flags a real series gap.
_pin_core_version() { # app_container prod_wp_version
  local app="$1" want="$2" have
  [ -n "$want" ] || return 0
  have="$(docker exec "$app" wp --allow-root --path=/var/www/html --skip-plugins --skip-themes \
            core version 2>/dev/null | tr -d '\r' || true)"
  [ -n "$have" ] && [ "$have" != "$want" ] || return 0
  log_info "Pinning replica core to production's exact version: $have → $want..."
  if docker exec "$app" wp --allow-root --path=/var/www/html --skip-plugins --skip-themes \
       core download --version="$want" --force --skip-content >/dev/null 2>&1; then
    log_ok "Replica core is now $want (same as production)."
  else
    log_warn "Could not download WordPress $want (offline?) — the replica keeps core $have."
    log_warn "The rehearsal then starts from $have, not production's $want."
  fi
  return 0
}

_warn_if_core_older() { # app_container prod_wp_version
  local app="$1" want="$2" have
  [ -n "$want" ] || return 0
  have="$(docker exec "$app" wp --allow-root --path=/var/www/html --skip-plugins --skip-themes \
            core version 2>/dev/null | tr -d '\r')" || true
  [ -n "$have" ] || return 0
  # Only a MINOR-series gap matters: the series tag trails the newest patch release
  # by design (6.9 ships 6.9.4 while prod runs 6.9.8) and that is harmless — core
  # within the same series has the same function surface. Warn when the replica's
  # series is genuinely behind, which is the direction that fatals the frontend.
  local have_m want_m
  have_m="$(_wp_minor "$have")"; want_m="$(_wp_minor "$want")"
  if [ "$have_m" != "$want_m" ] && \
     [ "$(printf '%s\n%s\n' "$have_m" "$want_m" | sort -V | head -1)" = "$have_m" ]; then
    log_warn "Replica core is $have but the backup came from WP $want — OLDER core than the DB."
    log_warn "Plugins calling newer core functions will fatal on the frontend (wp-admin may still work)."
    log_warn "No published image matched; consider pinning a newer tag (e.g. wordpress:$(_wp_minor "$want")-apache)."
  fi
  return 0
}


# Best tag to use when the registry CANNOT be consulted (offline, Docker Hub rate
# limit, no docker). Never the exact patch tag: the image build LAGS WordPress, so a
# patch released recently — or a security release on an older branch — often has no tag
# even though its neighbours do (7.0.4 is published, 7.0.5 and 6.9.8 are not). Pinning
# one blind is therefore a coin flip on a failed pull, while the minor series tag is
# always republished for a supported branch. Most specific tag that is a safe guess.
_wp_image_fallback() { # wp php
  local wp="$1" php="$2" minor=""
  [ -n "$wp" ] && minor="$(_wp_minor "$wp")"
  if [ -n "$minor" ] && [ -n "$php" ]; then echo "wordpress:${minor}-php${php}-apache"; return 0; fi
  if [ -n "$minor" ];                  then echo "wordpress:${minor}-apache";          return 0; fi
  if [ -n "$php" ];                    then echo "wordpress:php${php}-apache";         return 0; fi
  echo "wordpress:latest"
}

# Resolve to the first candidate that is usable, cheapest source first:
#   1. an image already on this machine   — no network, no rate limit, offline-correct
#   2. a tag that exists on the registry  — probed with `docker manifest inspect`
#      (metadata only, no pull)
#   3. _wp_image_fallback                 — when probing itself is unavailable
# Step 3 distinguishes "that tag does not exist" (keep trying the next candidate)
# from "I cannot ask" — Docker Hub's UNAUTHENTICATED pull limit counts every manifest
# probe, so a few builds in a row can turn every probe into `toomanyrequests`. Treating
# that as "tag missing" would walk the whole list and then pin the exact patch tag,
# which never exists — turning a rate limit into a failed build.
_resolve_wp_image() { # wp php
  local wp="$1" php="$2" tag err cands=() fallback
  while IFS= read -r tag; do
    [ -n "$tag" ] && cands+=("$tag")
  done < <(_wp_image_candidates "$wp" "$php")
  fallback="$(_wp_image_fallback "$wp" "$php")"
  [ "${#cands[@]}" -gt 0 ] || { printf '%s' "$fallback"; return 0; }

  for tag in "${cands[@]}"; do
    if docker image inspect "$tag" >/dev/null 2>&1; then printf '%s' "$tag"; return 0; fi
  done

  for tag in "${cands[@]}"; do
    if err="$(docker manifest inspect "$tag" 2>&1 >/dev/null)"; then
      printf '%s' "$tag"; return 0
    fi
    case "$err" in
      *"no such manifest"*|*"manifest unknown"*|*"not found"*|*"no such image"*|*"does not exist"*)
        ;;                                  # genuinely absent -> try the next candidate
      *)
        log_warn "Cannot probe the registry (${err%%$'\n'*})."
        log_warn "Using $fallback — the most specific tag that can exist without a lookup."
        printf '%s' "$fallback"; return 0 ;;
    esac
  done
  printf '%s' "$fallback"
}

# --- Host-matched WordPress image (native-Linux bind-mount ownership) -------------
#
# _render_compose bind-mounts ./wp-content into the container. On macOS, Docker
# Desktop's filesystem layer fakes ownership, so the stock image is right and this is a
# no-op. On NATIVE LINUX a bind mount preserves host UIDs: the extracted tree is owned
# by the invoking user while Apache runs as www-data (33), so the replica RENDERS but
# cannot WRITE — no uploads, no plugin/theme installs, no debug.log (which silently
# blinds _debug_fatal_count), and every `|| true`-guarded wp-cli step no-ops.
#
# Chowning the tree to 33 only moves the problem: the host then cannot `rm -rf` it on
# the next build. So instead we derive a one-off image whose www-data IS the host user
# — the same trick _shot_image_ensure / _adminer_image_ensure already use. UIDs then
# match on both sides and no chown is needed anywhere.
#
# Returns the tag to use, and the base tag unchanged whenever no remap is needed, so
# macOS keeps using the official image and builds nothing. Never fatal: a failed build
# falls back to the base image (the replica still runs; writes may fail) rather than
# aborting. Run via $() — set -e safe.
_wp_image_for_host() { # base_image
  local base="$1" uid gid tag
  uid="$(id -u)"; gid="$(id -g)"
  # Docker Desktop remaps ownership for us; and a host user that already IS 33 matches.
  if [ "$(uname -s)" = "Darwin" ] || { [ "$uid" = "33" ] && [ "$gid" = "33" ]; }; then
    printf '%s' "$base"; return 0
  fi
  tag="wpsite/wordpress:$(printf '%s' "${base#wordpress:}" | tr -c 'A-Za-z0-9_.' '-')-u${uid}-g${gid}"
  if docker image inspect "$tag" >/dev/null 2>&1; then
    printf '%s' "$tag"; return 0
  fi
  log_info "Building host-matched WordPress image (one-time): $tag"
  # The colliding-id shuffle matters: on Debian gid 20 is `dialout` and uid 1000 may
  # already exist, and usermod/groupmod refuse a duplicate id.
  if docker build -t "$tag" --build-arg "HOST_UID=$uid" --build-arg "HOST_GID=$gid" - <<EOF >/dev/null 2>&1
FROM $base
ARG HOST_UID
ARG HOST_GID
RUN set -eu; \
    if [ "\$HOST_GID" != "33" ]; then \
      old="\$(getent group "\$HOST_GID" | cut -d: -f1)"; \
      if [ -n "\$old" ]; then groupmod -g 9033 "\$old"; fi; \
      groupmod -g "\$HOST_GID" www-data; \
    fi; \
    if [ "\$HOST_UID" != "33" ]; then \
      old="\$(getent passwd "\$HOST_UID" | cut -d: -f1)"; \
      if [ -n "\$old" ]; then usermod -u 9033 "\$old"; fi; \
      usermod -u "\$HOST_UID" www-data; \
    fi; \
    chown -R www-data:www-data /var/www /usr/src/wordpress
EOF
  then
    printf '%s' "$tag"; return 0
  fi
  log_warn "Could not build the host-matched image; falling back to $base."
  log_warn "  wp-content will be read-only to the container (no uploads/plugin installs)."
  printf '%s' "$base"
  return 0
}

# Best-effort production table prefix from a DB dump, for backups that predate
# TABLE_PREFIX capture. Keys off the GLOBAL `<prefix>users` table (one per install
# even on multisite, unlike per-blog `<prefix>N_options`); the backtick anchor
# excludes `usermeta`. Empty when undetectable. Run via $() — set -e safe.
_detect_table_prefix() { # db_sql_file
  local f="$1"
  [ -f "$f" ] || return 0
  # Backticks here are literal SQL identifier quotes, not command substitution.
  # shellcheck disable=SC2016
  grep -m1 -oE 'CREATE TABLE `[^`]+users`' "$f" 2>/dev/null \
    | sed -E 's/^CREATE TABLE `(.*)users`$/\1/' || true
}

# First available system font for placeholder labels (empty = none → no text).
# ImageMagick on macOS has no default font configured, so we must pass one.
_placeholder_font() {
  local f
  for f in /System/Library/Fonts/Supplemental/Arial.ttf \
           /System/Library/Fonts/Helvetica.ttc \
           /System/Library/Fonts/Menlo.ttc \
           /Library/Fonts/Arial.ttf; do
    [ -f "$f" ] && { printf '%s' "$f"; return 0; }
  done
}

# Draw a labelled placeholder image at EXACT WxH: light-grey fill, a visible frame
# (so it doesn't vanish on a white/SVG background — the whole point), and centered
# filename + dimensions when there's room. Long names are middle-truncated.
_image_placeholder() { # im width height out font
  local im="$1" W="$2" H="$3" out="$4" font="${5:-}"
  local c_border='#9aa0a6' c_fill='#e9e9ec' c_text='#5f6368'
  local mind=$(( W < H ? W : H ))

  # Too small to frame meaningfully: solid grey swatch.
  if [ "$mind" -lt 8 ]; then
    "$im" -size "${W}x${H}" "xc:$c_border" "$out" >/dev/null 2>&1
    return
  fi

  # Border thickness scales with size. Tune via DIV (smaller = thicker), FLOOR, CAP.
  local div=45 floor=6 cap=24
  local b=$(( mind / div ))
  [ "$b" -lt "$floor" ] && b="$floor"
  [ "$b" -gt "$cap" ] && b="$cap"
  local maxb=$(( (mind - 2) / 3 )); [ "$b" -gt "$maxb" ] && b="$maxb"
  [ "$b" -lt 1 ] && b=1

  # Solid border canvas, then fill the interior — an EXACT b-px border, no fuzz.
  local args=( -size "${W}x${H}" "xc:$c_border"
               -fill "$c_fill" -draw "rectangle $b,$b $((W-1-b)),$((H-1-b))" )
  if [ -n "$font" ] && [ "$W" -ge 90 ] && [ "$H" -ge 44 ]; then
    local name="${out##*/}" ps=$(( mind / 9 ))
    [ "$ps" -lt 11 ] && ps=11
    [ "$ps" -gt 28 ] && ps=28
    local maxc=$(( W * 9 / (ps * 5) ))      # rough chars that fit at this size
    if [ "${#name}" -gt "$maxc" ] && [ "$maxc" -ge 9 ]; then
      local keep=$(( (maxc - 1) / 2 ))
      name="${name:0:keep}…${name:$(( ${#name} - keep ))}"
    fi
    args+=( -font "$font" -fill "$c_text" -pointsize "$ps" -gravity center
            -annotate "+0-$(( ps * 7 / 10 ))" "$name"
            -annotate "+0+$(( ps * 7 / 10 ))" "${W} x ${H}" )
  fi
  "$im" "${args[@]}" "$out" >/dev/null 2>&1
}

# Generate one placeholder file. Returns non-zero on failure (caller tolerates it).
# Paths in media_map are relative to the WP root (wp-content/uploads/...), so the
# caller must run from the docker dir — NOT from inside uploads, or paths nest.
_gen_placeholder() { # filepath width height im font
  local filepath="$1" width="$2" height="$3" im="$4" font="${5:-}" ext dir
  dir="$(dirname "$filepath")"
  # Parallel stripes often create the SAME uploads dir at once; `mkdir -p` has a
  # TOCTOU race that fails with EEXIST. Tolerate it: a dir that now exists is fine.
  mkdir -p "$dir" 2>/dev/null || [ -d "$dir" ] || return 1
  ext="$(printf '%s' "${filepath##*.}" | tr '[:upper:]' '[:lower:]')"

  # Missing/zero dimensions: PDFs become empty files; images fall back to 800x600.
  if ! [ "$width" -gt 0 ] 2>/dev/null || ! [ "$height" -gt 0 ] 2>/dev/null; then
    [ "$ext" = "pdf" ] && { : > "$filepath"; return 0; }
    width=800; height=600
  fi

  case "$ext" in
    pdf) : > "$filepath" ;;
    mp4|mov|webm)
      width=$(((width / 2) * 2)); height=$(((height / 2) * 2))   # encoders need even dims
      # WebM can't hold H.264 — it needs VP8/VP9 (libvpx). mp4/mov use libx264.
      local vcodec=libx264
      [ "$ext" = "webm" ] && vcodec=libvpx
      # -nostdin is essential: without it ffmpeg reads the loop's stdin (the map
      # lines feeding `while read`), stealing iterations and corrupting the run —
      # the cause of intermittent "N failed" under parallel generation.
      ffmpeg -nostdin -f lavfi -i "color=c=black:s=${width}x${height}:d=1" \
        -c:v "$vcodec" -pix_fmt yuv420p "$filepath" -y >/dev/null 2>&1 || return 1 ;;
    *)
      _image_placeholder "$im" "$width" "$height" "$filepath" "$font" || return 1 ;;
  esac
  return 0
}

# One worker stripe: process every Nth line of the map (offset k of n). Runs in a
# subshell, so it inherits _gen_placeholder/_image_placeholder and $im/$font with
# no exporting. Failures are appended to its own file (no cross-stripe contention).
_rebuild_stripe() { # map n k im font failfile
  local map="$1" n="$2" k="$3" im="$4" font="$5" failfile="$6"
  local filepath width height
  awk -v n="$n" -v k="$k" 'NR % n == k' "$map" \
  | while IFS='|' read -r filepath width height; do
      [ -z "$filepath" ] && continue
      _gen_placeholder "$filepath" "$width" "$height" "$im" "$font" \
        || printf '%s\n' "$filepath" >> "$failfile"
    done
}

# Regenerate uploads as blank, layout-accurate placeholders from media_map.txt,
# parallelised across CPU cores. A failed asset is recorded and skipped — it never
# aborts the run.
_rebuild_media() { # media_map_file im_convert
  local map="$1" im="$2"
  [ -f "$map" ] || return 0
  local total font jobs
  # grep -c prints "0" AND exits 1 on no match. Guard with `|| true` — NOT `|| echo 0`
  # (double-prints "0\n0", breaking the int test) and NOT a pipe to `head` (under
  # `set -o pipefail` the substitution inherits grep's exit 1 and `set -e` silently
  # aborts the whole build). grep -c already prints exactly one line, so this is enough.
  total="$(grep -c . "$map" 2>/dev/null || true)"
  [ -n "$total" ] || total=0
  [ "$total" -gt 0 ] || { log_info "No media to generate."; return 0; }
  font="$(_placeholder_font)"
  [ -n "$font" ] || log_warn "No system font found; placeholders won't be labelled."
  jobs="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  [ "$jobs" -ge 1 ] 2>/dev/null || jobs=4
  [ "$jobs" -gt "$total" ] && jobs="$total"
  log_info "Generating $total placeholder asset(s) ($jobs parallel)..."

  local tmpd k
  tmpd="$(mktemp -d)"
  for (( k=0; k<jobs; k++ )); do
    : > "$tmpd/fail.$k"   # pre-create so the glob below always matches (set -e safe)
    _rebuild_stripe "$map" "$jobs" "$k" "$im" "$font" "$tmpd/fail.$k" &
  done
  wait

  local failed
  failed="$(cat "$tmpd"/fail.* | wc -l | tr -d ' ')"
  if [ "$failed" -gt 0 ]; then
    cat "$tmpd"/fail.* 2>/dev/null | while read -r f; do log_warn "  skipped: $f"; done
    log_warn "Generated $((total - failed))/$total placeholder assets ($failed failed)."
  else
    log_ok "Generated $total placeholder asset(s)."
  fi
  rm -rf "$tmpd"
}

# The official wordpress:*-apache image ships no wp-cli, and each build is a fresh
# container — so wp-cli must be (re)installed every time. To keep builds working
# OFFLINE, we cache the phar on the host (<base_dir>/.cache/wp-cli.phar): download it
# once when online, then `docker cp` the cached copy into each container. Only when the
# cache is empty do we fall back to an in-container PHP download (online-only).
WPSITE_WP_CLI_URL="https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"
_wp_cli_cache() { printf '%s/.cache/wp-cli.phar' "$(config_base_dir)"; }

# Populate the host wp-cli cache (idempotent; online-only via curl). Also used by
# `wpsite prefetch`. Returns 0 iff the cache is present afterward.
_wp_cli_cache_warm() {
  local cache; cache="$(_wp_cli_cache)"
  [ -s "$cache" ] && return 0
  have curl || return 1
  mkdir -p "$(dirname "$cache")"
  if curl -fsSL "$WPSITE_WP_CLI_URL" -o "$cache.tmp.$$" 2>/dev/null && [ -s "$cache.tmp.$$" ]; then
    mv -f "$cache.tmp.$$" "$cache"
    return 0
  fi
  rm -f "$cache.tmp.$$"
  return 1
}

# Returns non-zero if wp-cli couldn't be made available in the container.
_ensure_wp_cli() { # app_container
  local app="$1"
  docker exec "$app" sh -c '[ -x /usr/local/bin/wp ]' >/dev/null 2>&1 && return 0

  local cache; cache="$(_wp_cli_cache)"
  _wp_cli_cache_warm || true   # best-effort; may be offline

  # Offline-friendly path: copy the cached phar straight into the container.
  if [ -s "$cache" ]; then
    log_info "Installing wp-cli into $app (from cache)..."
    if docker cp "$cache" "$app:/usr/local/bin/wp" >/dev/null 2>&1 \
       && docker exec "$app" chmod +x /usr/local/bin/wp >/dev/null 2>&1; then
      return 0
    fi
    log_warn "  Cached wp-cli copy failed — trying an in-container download."
  fi

  # Last resort (online only): fetch via PHP inside the container (curl/wget aren't
  # guaranteed there), then seed the host cache for next time. URL must match above.
  log_info "Installing wp-cli into $app (downloading)..."
  docker exec "$app" sh -c '
    php -r "copy(\"https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar\", \"/usr/local/bin/wp\");" &&
    chmod +x /usr/local/bin/wp
  ' >/dev/null 2>&1 || return 1
  mkdir -p "$(dirname "$cache")"
  docker cp "$app:/usr/local/bin/wp" "$cache" >/dev/null 2>&1 || true
  return 0
}

# Second mail-trap layer: the mu-plugin only routes wp_mail()/WP's PHPMailer. Any
# plugin calling PHP's native mail() (or its own PHPMailer in isMail() mode) would
# otherwise bypass Mailpit — and the stock image's sendmail_path points at a
# non-existent /usr/sbin/sendmail, so those mails silently vanish. This drops a
# tiny SMTP shim (referenced by sendmail_path in php-wpsite.ini) that forwards the
# raw message to the shared Mailpit. Pure PHP — no extra packages, mirrors how
# _ensure_wp_cli installs into the running container. Best-effort (never fatal).
_install_sendmail_shim() { # app_container
  local app="$1"
  if ! docker exec -i "$app" sh -c \
      'cat > /usr/local/bin/wpsite-sendmail && chmod +x /usr/local/bin/wpsite-sendmail' <<PHP
#!/usr/local/bin/php
<?php
// wpsite: minimal sendmail replacement — forwards native PHP mail() to Mailpit.
// Recipients come from the headers (called as \`-t\`). Never blocks the app: any
// error just drops the message (this is a dev trap, not a real MTA).
\$host = getenv('WPSITE_MAIL_HOST') ?: '${WPSITE_MAIL_HOST}';
\$port = (int) (getenv('WPSITE_MAIL_PORT') ?: 1025);
\$raw = stream_get_contents(STDIN);
if (!\$raw) { exit(0); }
\$raw = str_replace("\r\n", "\n", \$raw);
list(\$head, \$body) = array_pad(explode("\n\n", \$raw, 2), 2, '');
\$headers = [];
foreach (explode("\n", \$head) as \$line) {
    if (preg_match('/^([A-Za-z\-]+):\s*(.*)\$/', \$line, \$m)) { \$headers[strtolower(\$m[1])] = \$m[2]; }
}
\$recips = [];
foreach (['to', 'cc', 'bcc'] as \$h) {
    if (empty(\$headers[\$h])) { continue; }
    foreach (explode(',', \$headers[\$h]) as \$addr) {
        if (preg_match('/<([^>]+)>/', \$addr, \$mm)) { \$recips[] = trim(\$mm[1]); }
        elseif (trim(\$addr) !== '') { \$recips[] = trim(\$addr); }
    }
}
if (!\$recips) { \$recips = ['catch-all@wpsite.local']; }
\$from = 'wpsite@localhost';
if (!empty(\$headers['from'])) {
    \$from = preg_match('/<([^>]+)>/', \$headers['from'], \$mm) ? \$mm[1] : trim(\$headers['from']);
}
\$fp = @fsockopen(\$host, \$port, \$eno, \$estr, 10);
if (!\$fp) { exit(0); }
\$say = function (\$cmd) use (\$fp) { fwrite(\$fp, \$cmd . "\r\n"); return fgets(\$fp, 1024); };
fgets(\$fp, 1024);                      // greeting
\$say('HELO wpsite');
\$say('MAIL FROM:<' . \$from . '>');
foreach (\$recips as \$r) { \$say('RCPT TO:<' . \$r . '>'); }
\$say('DATA');
\$data = preg_replace('/^\./m', '..', str_replace("\n", "\r\n", \$raw)); // dot-stuff
fwrite(\$fp, \$data . "\r\n.\r\n");
fgets(\$fp, 1024);
\$say('QUIT');
fclose(\$fp);
exit(0);
PHP
  then
    log_warn "Could not install the sendmail→Mailpit shim; native mail() won't be trapped."
  fi
  return 0
}

# Keep Wordfence ACTIVE (scans/WAF are valuable on a replica) but stop it emailing:
# its wp_mail() alerts are already trapped by Mailpit, but a Wordfence-Central-linked
# site pushes alerts to noc1.wordfence.com over HTTPS — Mailpit cannot intercept that.
# So blank the recipient list, switch every alert + the summary off, and drop the
# Central link. wfConfig lives in <prefix>wfconfig (no wp-cli command exposes it, and
# the app image has no mysql client), so this is raw SQL via the db container —
# guarded to a clean no-op when Wordfence isn't installed.
_silence_wordfence() { # db_container table_prefix
  local db_c="$1" p="${2:-wp_}"
  docker exec "$db_c" mariadb -uroot -proot wordpress -N \
      -e "SHOW TABLES LIKE '${p}wfconfig'" 2>/dev/null | grep -q . || return 0
  log_info "Silencing Wordfence notifications (plugin stays active)..."
  docker exec -i "$db_c" mariadb -uroot -proot wordpress 2>/dev/null <<SQL || log_warn "Wordfence silencing had issues"
UPDATE ${p}wfconfig SET val='' WHERE name='alertEmails';
UPDATE ${p}wfconfig SET val='0' WHERE name LIKE 'alertOn\_%';
UPDATE ${p}wfconfig SET val='0' WHERE name IN ('email_summary_enabled','email_summary_dashboard_widget_enabled');
DELETE FROM ${p}wfconfig WHERE name LIKE 'wordfenceCentral%';
SQL
  return 0
}

# Write the compatibility mu-plugin into a replica's wp-content (creating mu-plugins/ if needed).
# This prevents plugins (like aule) that globally call admin-only functions from breaking WP-CLI.
_inject_wpsite_compat_muplugin() { # wp_content_dir
  local d="$1/mu-plugins"
  mkdir -p "$d"
  cat <<'EOF' > "$d/wpsite-compat.php"
<?php
/**
 * Plugin Name: wpsite Compatibility Layer
 * Description: Fixes bad coding in third-party plugins that fatal under WP-CLI.
 * Author: wpsite
 * Version: 1.0.0
 */
if (!defined('ABSPATH')) { exit; }

if (defined('WP_CLI') && WP_CLI) {
    if (!function_exists('add_settings_error')) {
        include_once ABSPATH . 'wp-admin/includes/template.php';
    }
}
EOF
}

# Add `127.0.0.1 <host>` to /etc/hosts if not already an ACTIVE entry.
# Two subtleties this guards against:
#  - Other tools (e.g. the "Local" app) may leave the file without a trailing
#    newline, so a naive `>> ` merges our line onto theirs — and if theirs is a
#    `#` comment, ours gets commented out and never resolves. We add a separating
#    newline first when the file doesn't end in one.
#  - The "already present?" check ignores commented lines, so a previously
#    broken/merged entry doesn't make us skip adding a real one.
_add_hosts_entry() { # host
  local host="$1" host_re
  host_re="${host//./\\.}"
  if grep -vE '^[[:space:]]*#' /etc/hosts 2>/dev/null \
       | grep -qE "[[:space:]]${host_re}([[:space:]]|\$)"; then
    log_debug "$host already in /etc/hosts"
    return 0
  fi
  log_info "Adding $host to /etc/hosts (sudo)..."
  if ! sudo sh -c '
    f=/etc/hosts
    if [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ]; then printf "\n" >> "$f"; fi
    printf "127.0.0.1\t%s\n" "$1" >> "$f"
  ' _ "$host"; then
    # Warn loudly but don't abort the build over a hosts write (set -e would
    # otherwise kill it silently). The site just won't resolve until added.
    log_warn "Could not add $host to /etc/hosts. Add manually:"
    log_warn "  echo '127.0.0.1 $host' | sudo tee -a /etc/hosts"
  fi
  return 0
}

# Remove caching/DB drop-ins and page caches from an extracted wp-content tree.
_strip_dropins() { # wp_content_dir
  local d="$1" f
  for f in advanced-cache.php object-cache.php db.php; do
    if [ -f "$d/$f" ]; then rm -f "${d:?}/$f"; log_debug "removed drop-in $f"; fi
  done
  for f in cache wp-rocket-config w3tc-config litespeed; do
    if [ -e "$d/$f" ]; then rm -rf "${d:?}/$f"; log_debug "removed $f"; fi
  done
  return 0   # never let a falsy [ -e ] test become the function's exit status (set -e)
}

# Rewrite every production-domain reference in the DB to the local replica URL.
# Covers the combinations that bite WordPress migrations:
#   - http and https schemes
#   - real slashes AND JSON-escaped slashes (https:\/\/host), e.g. WP Rocket's
#     wp_wpr_preload_fonts — a plain search misses these entirely
#   - protocol-relative //host
# Runs with --skip-plugins --skip-themes and with mu-plugins moved aside, because
# prod-only plugins/drop-ins routinely fatal wp-cli's WP bootstrap otherwise.
_rewrite_urls() { # app_container  wp_content_dir  local_host  local_url  src_url...
  local app="$1" wpc_dir="$2" lhost="$3" lurl="$4"; shift 4
  local hosts=() u h
  for u in "$@"; do
    [ -z "$u" ] && continue
    h="${u#*://}"; h="${h%%/*}"
    [ -z "$h" ] && continue
    case " ${hosts[*]:-} " in *" $h "*) ;; *) hosts+=("$h") ;; esac
  done
  [ "${#hosts[@]}" -gt 0 ] || return 0

  # mu-plugins load even with --skip-plugins; move them aside for the rewrite.
  local moved=0
  if [ -d "$wpc_dir/mu-plugins" ]; then
    mv "$wpc_dir/mu-plugins" "$wpc_dir/.wpsite-mu-off" && moved=1
  fi

  local wp=(docker exec "$app" wp --allow-root --path=/var/www/html --skip-plugins --skip-themes)
  local f=(--all-tables --skip-columns=guid)
  for h in "${hosts[@]}"; do
    "${wp[@]}" search-replace "https://$h"      "$lurl"             "${f[@]}" || true
    "${wp[@]}" search-replace "http://$h"       "$lurl"             "${f[@]}" || true
    "${wp[@]}" search-replace "https:\\/\\/$h"  "http:\\/\\/$lhost" "${f[@]}" || true
    "${wp[@]}" search-replace "http:\\/\\/$h"   "http:\\/\\/$lhost" "${f[@]}" || true
    "${wp[@]}" search-replace "//$h"            "//$lhost"          "${f[@]}" || true
    "${wp[@]}" search-replace "\\/\\/$h"        "\\/\\/$lhost"      "${f[@]}" || true
  done

  [ "$moved" = 1 ] && mv "$wpc_dir/.wpsite-mu-off" "$wpc_dir/mu-plugins"
  return 0
}

# Deactivate caching/optimization/backup/staging plugins that misbehave in a local
# clone (serve stale caches, phone home, hijack requests). Functional plugins —
# including custom ones like `aule` — are left ACTIVE. Runs with --skip-plugins so
# it edits the active_plugins option without loading (and fataling on) any plugin.
# Extend per client via clients.<c>.deactivate_plugins in the config.
# Deactivate any of $slugs that are active in a given scope. status/net_flag pair:
# "active"/"" for per-site, "active-network"/"--network" for network-wide. Kept set -e
# safe (empty match is fine; final `return 0`).
_deactivate_matching() { # app_container  slugs  status  net_flag
  local app="$1" slugs="$2" status="$3" net_flag="${4:-}"
  local wp=(docker exec "$app" wp --allow-root --path=/var/www/html --skip-plugins --skip-themes)
  local active hit=() c
  active="$("${wp[@]}" plugin list --status="$status" --field=name 2>/dev/null | tr '\n' ' ')" || return 0
  for c in $slugs; do
    case " $active " in *" $c "*) hit+=("$c") ;; esac
  done
  if [ "${#hit[@]}" -gt 0 ]; then
    log_info "Deactivating ${net_flag:+network-}caching/optimization/mail plugins: ${hit[*]}"
    # Branch (not an empty-array splat) to stay bash-3.2 + set -u safe and shellcheck-clean.
    if [ -n "$net_flag" ]; then
      "${wp[@]}" plugin deactivate "${hit[@]}" "$net_flag" --quiet 2>/dev/null || true
    else
      "${wp[@]}" plugin deactivate "${hit[@]}" --quiet 2>/dev/null || true
    fi
  fi
  return 0
}

_sanitize_plugins() { # app_container  extra_slugs
  local app="$1" extra="${2:-}"
  # Caching/optimization + mail/SMTP plugins. The SMTP ones are deactivated so they
  # can't route mail around Mailpit via an API/external relay (the mu-plugin then
  # catches wp_mail through the default PHPMailer path).
  local defaults="wp-rocket w3-total-cache wp-super-cache litespeed-cache wp-fastest-cache \
comet-cache cache-enabler breeze sg-cachepress autoptimize wp-optimize swift-performance \
redis-cache wp-staging wp-staging-pro nginx-helper \
wp-mail-smtp post-smtp easy-wp-smtp fluent-smtp wp-ses gmail-smtp \
sendgrid-email-delivery-simplified mailgun wp-sendgrid wp-mailgun-smtp"
  local wp=(docker exec "$app" wp --allow-root --path=/var/www/html --skip-plugins --skip-themes)

  # Per-site activations (single-site, or a subsite-level activation on multisite).
  _deactivate_matching "$app" "$defaults $extra" active ""

  # Multisite: network-activated plugins live in wp_sitemeta, NOT any site's
  # active_plugins, so the per-site pass misses them — they need --network to
  # switch off. Without this, a network-activated cache/backup plugin stays live.
  if [ "$("${wp[@]}" eval 'echo is_multisite() ? 1 : 0;' 2>/dev/null | tr -d '[:space:]')" = "1" ]; then
    _deactivate_matching "$app" "$defaults $extra" active-network --network
  fi
  return 0
}

# Ensure a known admin login on the replica (production password hashes are
# unknown). Creates/updates a dedicated user so existing accounts are untouched.
# Overridable via WPSITE_ADMIN_USER / WPSITE_ADMIN_PASS.
_set_known_admin() { # app_container local_url
  local app="$1" url="$2"
  local login="${WPSITE_ADMIN_USER:-wpsite}" pass="${WPSITE_ADMIN_PASS:-wpsite}"
  local wp=(docker exec "$app" wp --allow-root --path=/var/www/html --skip-plugins --skip-themes)
  if "${wp[@]}" user get "$login" >/dev/null 2>&1; then
    "${wp[@]}" user update "$login" --user_pass="$pass" --role=administrator --quiet >/dev/null 2>&1 || true
  else
    "${wp[@]}" user create "$login" "${login}@local.test" --role=administrator \
      --user_pass="$pass" --quiet >/dev/null 2>&1 || true
  fi
  log_ok "Admin login: $login / $pass   →   $url/wp-admin/"
}

# Use wildcard DNS when it's configured; otherwise fall back to /etc/hosts.
_ensure_local_dns() { # host
  if [ -f "$(wpsite_resolver_file)" ]; then
    log_debug "Wildcard *.test DNS active; not editing /etc/hosts."
    return 0
  fi
  _add_hosts_entry "$1"
}

# Dev PHP overrides, mounted into the container's conf.d (see _render_compose).
# The stock php:apache image caps upload_max_filesize at 2M / post_max_size at 8M,
# which fails plugin/theme uploads and imports on a dev replica. Written to the
# docker dir (wiped + regenerated each build) so it always matches the compose file.
_write_php_ini() { # dest_file
  # Resource/upload/timezone directives lifted from our house php.ini-production
  # profile (repo: masterphp.ini) so replicas match our real hosts. Error-handling
  # is left to the image + WORDPRESS_CONFIG_EXTRA dev-debug setup, NOT this file —
  # masterphp.ini is a production profile (display_errors/log_errors Off) that would
  # fight WP_DEBUG on a dev replica, so only the resource group is carried over.
  cat <<'EOF' > "$1"
; wpsite dev PHP overrides — house defaults from masterphp.ini (resource group).
upload_max_filesize = 32M
post_max_size = 32M
memory_limit = 256M
max_execution_time = 240
max_input_time = 240
max_input_vars = 1500
max_file_uploads = 20
date.timezone = "Europe/Berlin"
; Trap native PHP mail() too (plugins that bypass wp_mail): route it through our
; shim → Mailpit. The shim is installed into the container by _install_sendmail_shim.
sendmail_path = "/usr/local/bin/wpsite-sendmail -t -i"
EOF
}

# Render the per-replica compose file. No published host port: the WordPress
# container joins the shared proxy network so Traefik can reach it by name
# (wp_<client>_app). db stays on the project's default network only.
_render_compose() { # db_container app_container image client local_host ms_php
  local db_c="$1" app_c="$2" image="$3" ms_php="${6:-}" table_prefix="${7:-}"
  # Match the imported DB's prefix; omitted → image default (wp_).
  local prefix_line=""
  [ -n "$table_prefix" ] && prefix_line="      WORDPRESS_TABLE_PREFIX: \"$table_prefix\""
  # Standard dev defines + optional multisite constants, all indented 8 spaces for
  # the WORDPRESS_CONFIG_EXTRA YAML block scalar.
  local extra="        define('WP_DEBUG_LOG', true);
        define('WP_DEBUG_DISPLAY', false);
        @ini_set('display_errors', '0');
        define('SCRIPT_DEBUG', true);
        define('WP_ENVIRONMENT_TYPE', 'local');"
  [ -n "$ms_php" ] && extra="$extra
$(printf '%s\n' "$ms_php" | sed 's/^/        /')"
  cat <<EOF
services:
  db:
    image: $WPSITE_DB_IMAGE
    container_name: $db_c
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: root
      MYSQL_DATABASE: wordpress
      MYSQL_USER: wordpress
      MYSQL_PASSWORD: wordpress
    volumes:
      - db_data:/var/lib/mysql
  wordpress:
    image: $image
    container_name: $app_c
    restart: unless-stopped
    depends_on:
      - db
    environment:
      WORDPRESS_DB_HOST: db
      WORDPRESS_DB_USER: wordpress
      WORDPRESS_DB_PASSWORD: wordpress
      WORDPRESS_DB_NAME: wordpress
$prefix_line
      # Dev debugging: WP_DEBUG on, errors logged to wp-content/debug.log (not shown
      # on the page, so layouts aren't broken by prod's deprecation spam).
      WORDPRESS_DEBUG: "1"
      WORDPRESS_CONFIG_EXTRA: |
$extra
    volumes:
      - ./wp-content:/var/www/html/wp-content
      # Dev PHP limits (uploads/memory) — stock php:apache defaults cap uploads at
      # 2M, which blocks installing modestly sized plugins/themes. See _write_php_ini.
      - ./php-wpsite.ini:/usr/local/etc/php/conf.d/wpsite.ini:ro
    networks:
      - default
      - proxy
networks:
  proxy:
    external: true
    name: ${WPSITE_PROXY_NET}
volumes:
  db_data:
EOF
}

cmd_build() {
  local client="" backup_id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --backup)   backup_id="${2:-}"; shift 2 ;;
      --backup=*) backup_id="${1#*=}"; shift ;;
      -*) die "Unknown flag: $1" ;;
      *) client="$1"; shift ;;
    esac
  done

  config_require_registry
  require_client "$client"
  require docker

  local backup_dir local_host
  backup_dir="$(client_backup_dir "$client")"
  local_host="$(client_local_host "$client")"

  [ -d "$backup_dir" ] && [ -n "$(ls -A "$backup_dir" 2>/dev/null)" ] \
    || die "No backups found for $client (run: wpsite backup $client)"

  # Pick the backup: a specific one via --backup <id>, else the newest.
  local latest
  if [ -n "$backup_id" ]; then
    latest="$(resolve_backup_dir "$client" "${backup_id%/}")"
    [ -d "$latest" ] || die "Backup '$backup_id' not found for $client. See: wpsite list $client"
  else
    # ls -t sorts by mtime; backup dirs are timestamps so no odd-filename risk.
    # shellcheck disable=SC2012
    latest="$(ls -td "$backup_dir"/*/ 2>/dev/null | head -1)"
    latest="${latest%/}"
  fi
  [ -f "$latest/db.sql" ] && [ -f "$latest/wp-content.tar.gz" ] \
    || die "Backup at $latest is incomplete (missing db.sql or wp-content.tar.gz)."
  log_info "Using backup: $(basename "$latest")$([ -z "$backup_id" ] && echo ' (newest)')"

  _build_from_backup "$latest" "$client" "$local_host" "$(wclient_get "$client" deactivate_plugins)"
}

# Given a chosen backup dir, a target site name and its local host, produce a
# running replica. Shared by `build` (target = the client) and `clone` (target =
# a new dev site). `target` drives the compose project / container / dir / route
# names; deactivate_slugs is the source client's clients.<c>.deactivate_plugins.
# ms_ns (5th, optional) namespaces a MULTISITE clone's hosts under <ms_ns>.test so it
# can't collide with the client's own build — empty for `build` (legacy TLD swap).
_build_from_backup() { # latest target local_host deactivate_slugs [ms_ns]
  local latest="$1" target="$2" local_host="$3" extra_deactivate="${4:-}" ms_ns="${5:-}"
  local local_url="http://$local_host" docker_dir
  docker_dir="$(target_docker_dir "$target")"

  # A full backup ships real media and no media_map.txt; placeholder mode has the
  # map and needs ImageMagick + ffmpeg to regenerate assets.
  local im="" placeholder_mode=0
  if [ -f "$latest/media_map.txt" ]; then
    placeholder_mode=1
    require ffmpeg
    im="$(command -v magick || command -v convert || true)"
    [ -n "$im" ] || die "ImageMagick required for placeholder backups. Install: brew install imagemagick"
  fi

  local project="wpsite_${target}" db_c="wp_${target}_db" app_c="wp_${target}_app"

  # --- Tear down any existing replica, then reset the working dir ---
  # Use the project name so this actually stops the old containers + wipes the DB
  # volume (a fresh import must not inherit stale data). Runs even if the dir is
  # gone, so orphaned containers from a deleted dir still get cleaned.
  log_info "Tearing down any existing '$target' replica..."
  _compose_down "$project" "$docker_dir"
  rm -rf "$docker_dir"
  mkdir -p "$docker_dir"
  cd "$docker_dir" || die "Cannot enter $docker_dir"

  cp "$latest/db.sql" .
  tar -xzf "$latest/wp-content.tar.gz"
  mkdir -p wp-content/uploads

  # Drop caching/DB drop-ins + page caches that older backups may still contain.
  # They point at prod infra (Redis/WP Rocket), serve stale HTML with hardcoded
  # production URLs, and fatal wp-cli's bootstrap. New backups already omit them.
  _strip_dropins wp-content

  # Trap ALL outgoing mail: drop in the mu-plugin that routes wp_mail() to Mailpit.
  # (Mail/SMTP plugins that could bypass it are deactivated in _sanitize_plugins.)
  _inject_mailpit_muplugin wp-content

  # Inject custom compatibility helpers to avoid bootstrap fatals on active plugins (like aule).
  _inject_wpsite_compat_muplugin wp-content

  # Placeholder mode: regenerate blank media from the map (run from the docker dir
  # so the wp-content/uploads/... paths resolve correctly — no cd into uploads).
  # Full mode: real media already came down in the tarball, nothing to do.
  if [ "$placeholder_mode" = "1" ]; then
    _rebuild_media "$latest/media_map.txt" "$im"
  else
    log_info "Full backup — using real media files (no placeholders)."
  fi

  # --- Version + source URL from captured metadata (fall back to scraping db) ---
  local meta="$latest/meta.env" wp_version php_version source_home source_siteurl
  wp_version="$(_meta_get WP_VERSION "$meta")"
  php_version="$(_meta_get PHP_VERSION "$meta")"
  source_home="$(_meta_get SOURCE_HOME "$meta")"
  source_siteurl="$(_meta_get SOURCE_SITEURL "$meta")"
  if [ -z "$wp_version" ]; then
    wp_version="$(grep -m1 -oE "wp_version', '[0-9.]+" db.sql | cut -d"'" -f3 || true)"
  fi

  # Production table prefix → replica wp-config (via WORDPRESS_TABLE_PREFIX). Without
  # this, the image defaults to wp_ while the imported DB may use a custom prefix
  # (e.g. hfm3_), making WP/wp-cli see "not installed" and the URL rewrite no-op.
  local table_prefix
  table_prefix="$(_meta_get TABLE_PREFIX "$meta")"
  if [ -z "$table_prefix" ]; then
    table_prefix="$(_detect_table_prefix db.sql)"
    [ -n "$table_prefix" ] && log_warn "TABLE_PREFIX missing from metadata; detected '$table_prefix' from db.sql (re-backup to capture it reliably)."
  fi
  [ -n "$table_prefix" ] && [ "$table_prefix" != "wp_" ] && log_info "Production table prefix: $table_prefix"

  local preferred image
  preferred="$(_wp_image_tag "$wp_version" "$php_version")"
  image="$(_resolve_wp_image "$wp_version" "$php_version")"
  if [ "$image" != "$preferred" ]; then
    log_warn "Prod image $preferred isn't published — using closest available: $image"
  fi
  # Match container UIDs to the host on native Linux (no-op on macOS). Must run AFTER
  # resolution so the derived image is built FROM the tag we actually settled on.
  image="$(_wp_image_for_host "$image")"
  log_info "WordPress image: $image"

  # --- Multisite: drive the local host + wp-config from the captured network ---
  local is_ms ms_php="" sites_csv="$latest/sites.csv"
  is_ms="$(_meta_get MULTISITE "$meta")"
  if [ "$is_ms" = "1" ] && [ -f "$sites_csv" ]; then
    local main_prod; main_prod="$(_ms_main_domain "$sites_csv")"
    # main site's local host — namespaced under <ms_ns>.test for a clone, else TLD-swap.
    local_host="$(_ms_local_host "$main_prod" "$main_prod" "$ms_ns")"
    local_url="http://$local_host"
    ms_php="$(_ms_config_extra "$local_host" "$(_meta_get SUBDOMAIN_INSTALL "$meta")")"
    log_info "Multisite network — main site: $local_url ($(tail -n +2 "$sites_csv" | grep -c . ) subsites)"
  else
    is_ms=0
  fi

  # Local DNS: with wildcard *.test in place (wpsite proxy install-dns) nothing is
  # needed; otherwise fall back to a per-host /etc/hosts entry (sudo).
  if [ "$is_ms" = "1" ]; then _ms_ensure_dns "$sites_csv" "$ms_ns"; else _ensure_local_dns "$local_host"; fi

  # Must exist as a FILE before `up -d`, or Docker creates a dir at the mount point.
  _write_php_ini php-wpsite.ini
  _render_compose "$db_c" "$app_c" "$image" "$target" "$local_host" "$ms_php" "$table_prefix" > docker-compose.yml

  # Start the shared infra (proxy + Mailpit) — both create/use the proxy network
  # the compose file joins — BEFORE bringing the replica up.
  _proxy_ensure
  _mail_ensure

  # What the BACKUP brought — so the image's bundled extras can be removed afterwards.
  _content_snapshot wp-content > .wpsite-content-before

  log_info "Starting containers..."
  docker compose -p "$project" up -d

  # Complete the mail trap: route native PHP mail() (not just wp_mail) to Mailpit.
  _install_sendmail_shim "$app_c"

  # Register the replica's route with the proxy (Traefik picks it up via file-watch).
  # Multisite lists every subsite domain; single-site is the one host.
  if [ "$is_ms" = "1" ]; then _ms_write_route "$target" "$sites_csv" "$ms_ns"; else _proxy_write_route "$target" "$local_host"; fi

  # Connect over TCP (-h127.0.0.1), not the default socket: the image creates the
  # user as 'wordpress'@'%' (TCP), not @'localhost' (socket), so a socket login is
  # denied. TCP also only works once the real server is up — the entrypoint's init
  # phase runs socket-only with --skip-networking — so this doubles as the readiness
  # gate, avoiding a race where the DB looks ready mid-init.
  log_info "Waiting for database..."
  until docker exec "$db_c" \
    mariadb -h127.0.0.1 -uwordpress -pwordpress wordpress -e 'SELECT 1' >/dev/null 2>&1; do
    sleep 1
  done

  log_info "Importing database..."
  docker exec -i "$db_c" mariadb -h127.0.0.1 -uwordpress -pwordpress wordpress < db.sql

  # Multisite: fix <prefix>site/<prefix>blogs domains with raw SQL FIRST, so wp-cli
  # can then bootstrap the network (domains must match DOMAIN_CURRENT_SITE in wp-config).
  if [ "$is_ms" = "1" ]; then
    log_info "Rewriting network domains (${table_prefix:-wp_}site/${table_prefix:-wp_}blogs)..."
    _ms_fix_domains "$db_c" "$local_host" "$sites_csv" "$ms_ns" "$table_prefix" >/dev/null 2>&1 || log_warn "network domain SQL fix had issues"
  fi

  # Rehearsal fidelity: exactly production's plugins/themes and core version.
  _strip_image_extras wp-content .wpsite-content-before
  rm -f .wpsite-content-before

  local wpcli_ok=1
  _ensure_wp_cli "$app_c" || wpcli_ok=0
  if [ "$wpcli_ok" = 1 ]; then _pin_core_version "$app_c" "$wp_version"; fi

  # --- Rewrite production domain → local replica URL (uses captured URLs) ---
  if [ "$wpcli_ok" != 1 ]; then
    log_warn "Could not install wp-cli in $app_c; skipped domain rewrite + sanitization."
    log_warn "Site may still reference production URLs."
  elif [ "$is_ms" = "1" ]; then
    log_info "Rewriting content URLs across the network..."
    _ms_rewrite_content "$app_c" "$sites_csv" "$ms_ns"
    _sanitize_plugins "$app_c" "$extra_deactivate"
    # Create the known admin first, THEN grant network super-admin (promotion needs
    # the user to exist) — gives a working network-admin login on the replica.
    _set_known_admin "$app_c" "$local_url"
    docker exec "$app_c" wp --allow-root --path=/var/www/html --skip-plugins --skip-themes \
      super-admin add "${WPSITE_ADMIN_USER:-wpsite}" >/dev/null 2>&1 || true
    # Membership on every blog so the admin-bar "My Sites" lists all subsites.
    _ms_join_all_sites "$app_c" "${WPSITE_ADMIN_USER:-wpsite}" "$sites_csv"
  else
    if [ -n "$source_home$source_siteurl" ]; then
      log_info "Rewriting production domain to $local_url..."
      _rewrite_urls "$app_c" wp-content "$local_host" "$local_url" "$source_home" "$source_siteurl"
    else
      log_warn "No source URL in metadata; skipping domain rewrite (older backup?)."
    fi
    _sanitize_plugins "$app_c" "$extra_deactivate"
    _set_known_admin "$app_c" "$local_url"
  fi

  # Stop Wordfence emailing out (Central/HTTPS alerts bypass Mailpit entirely).
  # Pure SQL, independent of the wp-cli branch above; no-op if Wordfence is absent.
  _silence_wordfence "$db_c" "$table_prefix"

# Real liveness check — WordPress must see itself as installed. Catches a table
  # prefix mismatch (the symptom: wp-cli prints "site not installed / Found
  # installation with table prefix: …"), which would otherwise sail past all the
  # `|| true`-guarded steps above and report a false success.
  if docker exec "$app_c" wp --allow-root --path=/var/www/html --skip-plugins --skip-themes \
       core is-installed >/dev/null 2>&1; then
    _warn_if_core_older "$app_c" "$wp_version"
    log_ok "SUCCESS: $local_url is live."
  else
    log_warn "Build finished, but WordPress does not report as installed — the replica is likely broken."
    log_warn "Most common cause: table-prefix mismatch between wp-config and the imported DB."
    log_warn "If this site predates prefix capture, run a fresh 'wpsite backup $target' and rebuild."
    return 1
  fi
}
