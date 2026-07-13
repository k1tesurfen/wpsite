# shellcheck shell=bash
# wpsite db <site> — open a shared Adminer DB browser, logged straight into a
# built site's database. One container serves every replica: it lives on the
# proxy network and, per invocation, is attached to the target's compose network
# so it can reach that site's db container (wp_<site>_db) by name.
#
# Auto-login: Adminer treats a tokenless auth POST as a fresh login (no CSRF), so
# our custom index.php synthesizes one from ?wpsite_server=<db-container> and
# scrubs the param before Adminer builds its post-login redirect (else it loops).
# Credentials are the fixed replica creds (root/root) — safe: local-only replicas.
#
#   wpsite db <site>        open <site>'s DB in the default browser, logged in
#   wpsite db up|down|status   manage the shared Adminer container

WPSITE_ADMINER_CONTAINER="wpsite_adminer"
WPSITE_ADMINER_IMAGE="${WPSITE_ADMINER_IMAGE:-wpsite/adminer}"
WPSITE_ADMINER_BASE="${WPSITE_ADMINER_BASE:-adminer:4.8.1-standalone}"
WPSITE_ADMINER_PORT="${WPSITE_ADMINER_PORT:-8080}"

_adminer_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$WPSITE_ADMINER_CONTAINER" 2>/dev/null)" = "true" ]
}

# Build the derived Adminer image once (like wpsite/shot): the stock standalone
# image, with our auto-login index.php wrapping the original (renamed) one.
_adminer_image_ensure() {
  docker image inspect "$WPSITE_ADMINER_IMAGE" >/dev/null 2>&1 && return 0
  log_info "Building Adminer image (one-time)..."
  local ctx
  ctx="$(mktemp -d)"
  cat > "$ctx/index.php" <<'PHP'
<?php
// wpsite: land straight in a site's DB when ?wpsite_server=<db-container> is set.
if (isset($_GET['wpsite_server'])) {
    $_POST['auth'] = [
        'driver'   => 'server',
        'server'   => (string) $_GET['wpsite_server'],
        'username' => 'root',
        'password' => 'root',
        'db'       => 'wordpress',
    ];
    // Adminer copies the incoming query string into its post-login redirect, so
    // scrub our param everywhere it reads or the redirect loops forever.
    $_GET = [];
    $_SERVER['QUERY_STRING'] = '';
    $_SERVER['REQUEST_URI'] = strtok($_SERVER['REQUEST_URI'], '?');
}
require __DIR__ . '/_adminer_index.php';
PHP
  cat > "$ctx/Dockerfile" <<EOF
FROM $WPSITE_ADMINER_BASE
USER root
RUN mv /var/www/html/index.php /var/www/html/_adminer_index.php
COPY index.php /var/www/html/index.php
USER adminer
EOF
  if ! docker build -t "$WPSITE_ADMINER_IMAGE" "$ctx" >/dev/null 2>&1; then
    rm -rf "$ctx"
    return 1
  fi
  rm -rf "$ctx"
}

# Start the shared Adminer on the proxy network, UI published on the host so it's
# reachable without DNS. Idempotent (mirrors _mail_ensure).
_adminer_ensure() {
  require docker
  docker network inspect "$WPSITE_PROXY_NET" >/dev/null 2>&1 \
    || docker network create "$WPSITE_PROXY_NET" >/dev/null
  _adminer_running && return 0
  docker rm -f "$WPSITE_ADMINER_CONTAINER" >/dev/null 2>&1 || true
  log_info "Starting Adminer (shared DB browser) — http://localhost:$WPSITE_ADMINER_PORT"
  docker run -d --name "$WPSITE_ADMINER_CONTAINER" --restart unless-stopped \
    --network "$WPSITE_PROXY_NET" \
    -p "$WPSITE_ADMINER_PORT:8080" \
    "$WPSITE_ADMINER_IMAGE" >/dev/null \
    || die "Could not start Adminer — is port $WPSITE_ADMINER_PORT in use? (lsof -nP -i :$WPSITE_ADMINER_PORT)"
}

# Attach Adminer to the db container's network(s) so it can resolve wp_<site>_db.
# The db sits only on its project's default net (never the proxy net), so this is
# the one bridge that lets a single shared Adminer reach every client. Idempotent.
_adminer_attach() { # db_container
  local db_c="$1" nets n
  nets="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$db_c" 2>/dev/null || true)"
  for n in $nets; do
    [ "$n" = "$WPSITE_PROXY_NET" ] && continue
    docker network connect "$n" "$WPSITE_ADMINER_CONTAINER" >/dev/null 2>&1 || true
  done
  return 0
}

# Remember / recall the last site opened, so `wpsite db` (no arg) can repeat it.
# Stored next to the config so a WPSITE_CONFIG override (tests) relocates it too.
_db_state_file() { printf '%s/last-db' "$(dirname "$WPSITE_CONFIG")"; }
_db_remember() { # site
  local f; f="$(_db_state_file)"
  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$1" > "$f"
}
_db_last() {
  local f; f="$(_db_state_file)"
  [ -f "$f" ] || return 0
  head -n1 "$f" | tr -d '[:space:]'
}

# Open a built site's DB in the browser, already logged in.
_db_open() { # site
  local site="$1"
  config_require
  require_target "$site"
  require docker

  local db_c="wp_${site}_db"
  _adminer_running_db_check "$db_c" "$site"

  _adminer_image_ensure || die "Could not build the Adminer image."
  _adminer_ensure
  _adminer_attach "$db_c"

  _db_remember "$site"
  local url="http://localhost:${WPSITE_ADMINER_PORT}/?wpsite_server=${db_c}"
  if have open; then
    open "$url" >/dev/null 2>&1 || true
  fi
  log_ok "Adminer open for '$site' (login: root/root) — $url"
}

# `wpsite db` with no site: reopen the last one. Never auto-builds/starts a site —
# _db_open's running-guard just reports which site it was if it's offline.
_db_open_last() {
  config_require
  local last; last="$(_db_last)"
  [ -n "$last" ] || die "No previous site to reopen — run: wpsite db <site>"
  [ -n "$(target_kind "$last")" ] \
    || die "Last-used site '$last' no longer exists in the config — run: wpsite db <site>"
  log_info "Reopening last-used site: $last"
  _db_open "$last"
}

# Fail early with an actionable hint if the site's db container isn't running.
_adminer_running_db_check() { # db_container site
  [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ] && return 0
  die "No running database for '$2' (container $1). Build/start it first: wpsite build $2  (or: wpsite start $2)"
}

cmd_db() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    "")   _db_open_last ;;
    up)   require docker
          _adminer_image_ensure || die "Could not build the Adminer image."
          _adminer_ensure
          log_ok "Adminer up — http://localhost:$WPSITE_ADMINER_PORT (open a site with: wpsite db <site>)" ;;
    down) require docker
          if docker rm -f "$WPSITE_ADMINER_CONTAINER" >/dev/null 2>&1; then
            log_ok "Adminer stopped."
          else
            log_info "Adminer was not running."
          fi ;;
    status) require docker
          if _adminer_running; then
            log_ok "Adminer running — http://localhost:$WPSITE_ADMINER_PORT"
          else
            log_info "Adminer not running (starts automatically on 'wpsite db <site>')."
          fi ;;
    -*)   die "Unknown flag: $sub" ;;
    *)    _db_open "$sub" ;;
  esac
}
