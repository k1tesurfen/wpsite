# shellcheck shell=bash
# wpsite php <site> [<X.Y>] — show or switch the PHP version of a BUILT site (client
# replica or dev site) without rebuilding. For testing a site against a PHP release —
# e.g. a security patch — before production moves, or before a backup exists.
#
# The PHP version IS the image: official images publish one tag per PHP series
# (wordpress:php8.4-apache), rebuilt for every patch release. So a switch = pull the
# newest image for the series (_wp_image_fresh), point the generated compose file at it,
# and `up -d` to recreate the app container. Data survives: the DB lives in its volume
# and wp-content is a bind mount. What does NOT survive a recreate is everything put
# into the container LAYER — wp-cli and the sendmail shim — so those are restored after
# it (same rule as start/inject).
#
# The site keeps its WordPress core version. Core lives in the image's anonymous
# /var/www/html volume, which Compose re-attaches on a recreate, so it normally stays
# put on its own; the image tag is still chosen for the CURRENT core, and if the
# container comes back with another one anyway (volume gone), _php_keep_core downloads
# the previous version — a PHP test must not silently become a core upgrade too.
#
# A dev site's choice is recorded in the config (dev.<name>.php). A client replica's is
# not: the next `wpsite build` re-renders compose from the backup, i.e. production's PHP.

# The `image:` of the wordpress service in a generated docker-compose.yml.
_compose_wp_image() { # compose_file
  awk '/^  wordpress:[[:space:]]*$/ { w = 1; next }
       /^  [^ ]/                    { w = 0 }
       w && /^    image:/           { sub(/^    image:[[:space:]]*/, ""); print; exit }' "$1"
}

# Rewrite ONLY the wordpress service's image line; every other byte of the generated
# file (comments, the WORDPRESS_CONFIG_EXTRA block with its $$ escapes) stays as is.
# Returns 1 (file untouched) when the line isn't there.
_compose_set_wp_image() { # compose_file image
  local f="$1" img="$2" tmp="$1.tmp.$$"
  if awk -v img="$img" '
       /^  wordpress:[[:space:]]*$/      { w = 1; print; next }
       /^  [^ ]/                         { w = 0 }
       w && !done && /^    image:/      { print "    image: " img; done = 1; next }
       { print }
       END { exit done ? 0 : 1 }' "$f" > "$tmp"; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"; return 1
  fi
}

# WordPress core version from the container's version.php — needs only PHP, not wp-cli.
_container_wp_version() { # app_container
  # shellcheck disable=SC2016  # $wp_version is PHP, not shell
  docker exec "$1" php -r 'include "/var/www/html/wp-includes/version.php"; echo $wp_version;' \
    2>/dev/null | tr -d '\r' || true
}

# Put the core version the site had before the switch back, when the new image ships
# another one. Offline it warns: the site then runs the image's core.
_php_keep_core() { # app_container wp_version
  local app="$1" want="$2" have
  [ -n "$want" ] || return 0
  have="$(_container_wp_version "$app")"
  [ -n "$have" ] && [ "$have" != "$want" ] || return 0
  log_info "Image ships WordPress $have — restoring the site's core $want..."
  if docker exec "$app" wp --allow-root --path=/var/www/html --skip-plugins --skip-themes \
       core download --version="$want" --force --skip-content >/dev/null 2>&1; then
    log_ok "WordPress core stays at $want."
  else
    log_warn "Could not download WordPress $want (offline?) — the site now runs core $have."
  fi
  return 0
}

_php_show() { # site app_container compose_file
  local site="$1" app="$2" compose="$3" running
  log_info "Image: $(_compose_wp_image "$compose")"
  running="$(_container_php_version "$app")"
  if [ -n "$running" ]; then
    log_ok "'$site' runs PHP $running"
  else
    log_info "'$site' is not running — start it to see the exact PHP version: wpsite start $site"
  fi
  return 0
}

cmd_php() {
  local site="" ver=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -*) die "Unknown flag: $1" ;;
      *)
        if   [ -z "$site" ]; then site="$1"
        elif [ -z "$ver" ];  then ver="$1"
        else die "Usage: wpsite php <site> [<X.Y>]"
        fi
        shift ;;
    esac
  done
  [ -n "$site" ] || die "Usage: wpsite php <site> [<X.Y>]"

  config_require
  require_target "$site"
  require docker

  local docker_dir project app_c compose
  docker_dir="$(target_docker_dir "$site")"
  project="wpsite_${site}"; app_c="wp_${site}_app"
  compose="$docker_dir/docker-compose.yml"
  [ -f "$compose" ] \
    || die "Nothing built for '$site'. Build it first ('wpsite build $site' / 'wpsite new')."

  if [ -z "$ver" ]; then _php_show "$site" "$app_c" "$compose"; return 0; fi

  # Images exist per series only, so a patch can't be CHOSEN — the newest is always taken.
  case "$ver" in
    [0-9]*.[0-9]*.[0-9]*)
      die "Give the PHP series (e.g. ${ver%.*}), not a patch release — wpsite always pulls the series' newest patch." ;;
  esac
  [[ "$ver" =~ ^[0-9]+\.[0-9]+$ ]] || die "Invalid PHP version '$ver' (expected X.Y, e.g. 8.4)."

  # Running container = the source of the current core + PHP version. A stopped site is
  # started (the switch recreates it anyway).
  if [ -z "$(_container_php_version "$app_c")" ]; then
    log_info "Starting '$site' to read its current versions..."
    ( cd "$docker_dir" && docker compose -p "$project" up -d ) || die "Could not start '$site'."
  fi
  local old_php wp_core old_image image
  old_php="$(_container_php_version "$app_c")"
  wp_core="$(_container_wp_version "$app_c")"
  old_image="$(_compose_wp_image "$compose")"
  log_info "'$site' now: PHP ${old_php:-?}, WordPress ${wp_core:-?} ($old_image)"

  image="$(_wp_image_fresh "$wp_core" "$ver")" \
    || die "No WordPress image for PHP $ver could be pulled or found locally."
  # Same host-UID remap as build (no-op on macOS).
  image="$(_wp_image_for_host "$image")"

  _compose_set_wp_image "$compose" "$image" \
    || die "Could not find the wordpress image line in $compose."
  log_info "Recreating $app_c on $image..."
  if ! ( cd "$docker_dir" && docker compose -p "$project" up -d ); then
    log_warn "Recreate failed — restoring $old_image."
    _compose_set_wp_image "$compose" "$old_image" || true
    ( cd "$docker_dir" && docker compose -p "$project" up -d ) || true
    die "Could not switch '$site' to PHP $ver."
  fi

  # The recreate wiped the container layer (wp-cli, the sendmail shim); core is a safety net.
  _ensure_wp_cli "$app_c" \
    || log_warn "wp-cli could not be (re)installed in $app_c — 'docker exec ... wp' will fail."
  _install_sendmail_shim "$app_c"
  _php_keep_core "$app_c" "$wp_core"

  local new_php
  new_php="$(_container_php_version "$app_c")"
  case "$new_php" in
    "$ver".*) log_ok "'$site' runs PHP $new_php (was ${old_php:-?})." ;;
    *) log_warn "'$site' runs PHP ${new_php:-?}, not the requested $ver series." ;;
  esac

  # A boot loads every active plugin + the theme: a fatal under the new PHP shows here.
  if docker exec "$app_c" wp --allow-root --path=/var/www/html \
       eval 'echo "wpsite-boot-ok";' 2>/dev/null | grep -q wpsite-boot-ok; then
    log_ok "WordPress boots on PHP $ver."
  else
    log_warn "WordPress does NOT boot on PHP $ver — check wp-content/debug.log."
    log_warn "  Switch back with: wpsite php $site ${old_php%.*}"
  fi

  if [ "$(target_kind "$site")" = "dev" ]; then
    dev_set "$site" php "$ver"
  else
    log_warn "'$site' is a client replica: until its next 'wpsite build' it runs PHP $ver,"
    log_warn "  NOT production's — 'wpsite upgrade' rehearsals on it test PHP $ver too."
  fi
  log_ok "Done: http://$(target_local_host "$site")"
}
