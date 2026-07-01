# shellcheck shell=bash
# wpsite build <client> — (re)build & run the latest backup as a local replica.
# Heavy/destructive: tears down any existing replica (incl. its DB volume) and
# rebuilds from scratch. For pause/resume use `wpsite stop` / `wpsite start`.

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

# Candidate image tags in priority order. The exact prod match is ideal, but the
# official wordpress image doesn't publish every WP×PHP combo (e.g. WP 7.0 ships
# only php8.2/8.3, not php8.1). For a local replica the WP *core* version matters
# far more than the PHP minor, so we keep WP and let PHP float before the reverse.
_wp_image_candidates() { # wp php
  local wp="$1" php="$2"
  if [ -n "$wp" ] && [ -n "$php" ]; then echo "wordpress:${wp}-php${php}-apache"; fi
  if [ -n "$wp" ];                  then echo "wordpress:${wp}-apache"; fi
  if [ -n "$php" ];                 then echo "wordpress:php${php}-apache"; fi
  echo "wordpress:latest"
}

# Resolve to the first candidate that actually exists on the registry (probed with
# `docker manifest inspect`, which doesn't pull). Falls back to the preferred tag
# when probing can't run (offline / no docker) so behaviour degrades to the old
# pin-and-let-compose-complain path rather than silently picking `latest`.
_resolve_wp_image() { # wp php
  local wp="$1" php="$2" tag first=""
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    [ -n "$first" ] || first="$tag"
    if docker manifest inspect "$tag" >/dev/null 2>&1; then
      printf '%s' "$tag"; return 0
    fi
  done < <(_wp_image_candidates "$wp" "$php")
  printf '%s' "$first"
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

# The official wordpress:*-apache image ships no wp-cli. Install the phar into the
# running app container (it has PHP, a generated wp-config, DB access and WP core
# — everything wp-cli needs). Fetched via PHP since curl/wget aren't guaranteed.
# Returns non-zero if it couldn't be made available.
_ensure_wp_cli() { # app_container
  local app="$1"
  docker exec "$app" sh -c '[ -x /usr/local/bin/wp ]' >/dev/null 2>&1 && return 0
  log_info "Installing wp-cli into $app..."
  docker exec "$app" sh -c '
    php -r "copy(\"https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar\", \"/usr/local/bin/wp\");" &&
    chmod +x /usr/local/bin/wp
  ' >/dev/null 2>&1
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
  if [ -f "${WPSITE_RESOLVER:-/etc/resolver/test}" ]; then
    log_debug "Wildcard *.test DNS active; not editing /etc/hosts."
    return 0
  fi
  _add_hosts_entry "$1"
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
    image: mariadb:10.11
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

  config_require
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

  _build_from_backup "$latest" "$client" "$local_host" "$(client_get "$client" deactivate_plugins)"
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

  _render_compose "$db_c" "$app_c" "$image" "$target" "$local_host" "$ms_php" "$table_prefix" > docker-compose.yml

  # Start the shared infra (proxy + Mailpit) — both create/use the proxy network
  # the compose file joins — BEFORE bringing the replica up.
  _proxy_ensure
  _mail_ensure

  log_info "Starting containers..."
  docker compose -p "$project" up -d

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

  # --- Rewrite production domain → local replica URL (uses captured URLs) ---
  if ! _ensure_wp_cli "$app_c"; then
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

  # Real liveness check — WordPress must see itself as installed. Catches a table
  # prefix mismatch (the symptom: wp-cli prints "site not installed / Found
  # installation with table prefix: …"), which would otherwise sail past all the
  # `|| true`-guarded steps above and report a false success.
  if docker exec "$app_c" wp --allow-root --path=/var/www/html --skip-plugins --skip-themes \
       core is-installed >/dev/null 2>&1; then
    log_ok "SUCCESS: $local_url is live."
  else
    log_warn "Build finished, but WordPress does not report as installed — the replica is likely broken."
    log_warn "Most common cause: table-prefix mismatch between wp-config and the imported DB."
    log_warn "If this site predates prefix capture, run a fresh 'wpsite backup $target' and rebuild."
    return 1
  fi
}
