# shellcheck shell=bash
# wpsite new [<name>] — spin up a FRESH, blank WordPress dev site (no production
# source). Local-only sandbox under base_dir/dev/<name>, wired into the same shared
# proxy + Mailpit + .test DNS + known admin as a built replica. With no name it runs
# an interactive wizard. To clone an existing client instead, see `wpsite clone`.

# Prompt for a value with a default; echoes the answer. EOF/empty → default.
# Kept set -e safe: `read` returns non-zero at EOF, so `|| true`.
_prompt() { # message default
  local msg="$1" def="${2:-}" ans=""
  if [ -n "$def" ]; then printf '%s [%s]: ' "$msg" "$def" >&2; else printf '%s: ' "$msg" >&2; fi
  read -r ans || true
  printf '%s' "${ans:-$def}"
}

cmd_new() {
  local name="" wp="" php="" host=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --wp)     wp="${2:-}"; shift 2 ;;
      --wp=*)   wp="${1#*=}"; shift ;;
      --php)    php="${2:-}"; shift 2 ;;
      --php=*)  php="${1#*=}"; shift ;;
      --host)   host="${2:-}"; shift 2 ;;
      --host=*) host="${1#*=}"; shift ;;
      -*) die "Unknown flag: $1" ;;
      *) name="$1"; shift ;;
    esac
  done

  config_require
  require docker

  # No name → interactive wizard (requires a TTY to read answers).
  if [ -z "$name" ]; then
    [ -t 0 ] || die "No <name> given. Provide one, or run interactively for the wizard."
    log_info "New dev site wizard — press Enter to accept the [default]."
    while :; do
      name="$(_prompt "Site name (letters, digits, hyphens)")"
      if ! _valid_site_name "$name"; then log_warn "Invalid name. Use lowercase letters, digits and hyphens."; continue; fi
      if [ -n "$(target_kind "$name")" ]; then log_warn "'$name' already exists. Pick another."; continue; fi
      break
    done
    wp="$(_prompt "WordPress version (blank = latest)" "$wp")"
    php="$(_prompt "PHP version" "${php:-8.2}")"
    host="$(_prompt "Local host" "${host:-$name.test}")"
  fi

  _valid_site_name "$name" || die "Invalid site name '$name' (use lowercase letters, digits, hyphens)."
  [ -z "$(target_kind "$name")" ] || die "'$name' already exists as a $(target_kind "$name"). Choose another name."

  : "${php:=8.2}"
  : "${host:=$name.test}"
  local image local_url
  image="$(_resolve_wp_image "$wp" "$php")"
  local_url="http://$host"

  log_info "Creating dev site '$name'"
  log_info "  Host:  $local_url"
  log_info "  Image: $image"

  # Register the site so the lifecycle commands (start/stop/destroy/status) and the
  # resolver can find it. Written before the build so a failed build is still
  # cleanable with `wpsite destroy $name`.
  _ensure_base_layout
  dev_set "$name" host "$host"
  dev_set "$name" wp_version "$wp"
  dev_set "$name" php "$php"

  local docker_dir project db_c app_c
  docker_dir="$(dev_docker_dir "$name")"
  project="wpsite_${name}"; db_c="wp_${name}_db"; app_c="wp_${name}_app"

  # Fresh working dir (tear down any leftover containers/volume of the same name).
  log_info "Preparing $docker_dir..."
  _compose_down "$project" "$docker_dir"
  rm -rf "$docker_dir"
  mkdir -p "$docker_dir"
  cd "$docker_dir" || die "Cannot enter $docker_dir"

  # Empty wp-content: the WordPress image's entrypoint populates default themes /
  # plugins into the (empty) bind mount on first boot. We only pre-seed mu-plugins.
  mkdir -p wp-content
  _inject_mailpit_muplugin wp-content
  _inject_wpsite_compat_muplugin wp-content

  _ensure_local_dns "$host"

  _render_compose "$db_c" "$app_c" "$image" "$name" "$host" "" > docker-compose.yml

  # Shared infra must exist before the replica joins the proxy network.
  _proxy_ensure
  _mail_ensure

  log_info "Starting containers..."
  docker compose -p "$project" up -d
  _proxy_write_route "$name" "$host"

  # TCP readiness gate (see cmd_build for why -h127.0.0.1, not the socket).
  log_info "Waiting for database..."
  until docker exec "$db_c" \
    mariadb -h127.0.0.1 -uwordpress -pwordpress wordpress -e 'SELECT 1' >/dev/null 2>&1; do
    sleep 1
  done

  _ensure_wp_cli "$app_c" || die "Could not install wp-cli in $app_c; cannot install WordPress."

  # Fresh install with the known dev admin (override via WPSITE_ADMIN_USER/_PASS).
  local login="${WPSITE_ADMIN_USER:-wpsite}" pass="${WPSITE_ADMIN_PASS:-wpsite}"
  local wpc=(docker exec "$app_c" wp --allow-root --path=/var/www/html)
  log_info "Installing WordPress..."
  "${wpc[@]}" core install --url="$local_url" --title="$name" \
    --admin_user="$login" --admin_password="$pass" --admin_email="${login}@local.test" \
    --skip-email >/dev/null 2>&1 || die "WordPress install failed."

  # Blank slate: drop the default Hello-world post + sample/privacy pages.
  "${wpc[@]}" site empty --yes >/dev/null 2>&1 || log_warn "Could not clear default content."

  log_ok "Admin login: $login / $pass   →   $local_url/wp-admin/"
  log_ok "SUCCESS: $local_url is live (blank dev site)."
}
