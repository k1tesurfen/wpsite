# shellcheck shell=bash
# wpsite mail <up|down|status> — a shared Mailpit container that TRAPS all email
# every replica tries to send (production data → real customer addresses, so this
# is a safety net). `build` starts it automatically and drops a mu-plugin into the
# replica that routes wp_mail() to it. Inbox: http://localhost:<ui-port>.

WPSITE_MAIL_CONTAINER="wpsite_mail"
# Network alias WITHOUT an underscore: PHPMailer rejects hostnames containing '_'
# (RFC-invalid), so the replica must reach Mailpit via this hyphenated name.
WPSITE_MAIL_HOST="wpsite-mail"
WPSITE_MAIL_IMAGE="axllent/mailpit:latest"
WPSITE_MAIL_UI_PORT="${WPSITE_MAIL_UI_PORT:-8025}"

_mail_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$WPSITE_MAIL_CONTAINER" 2>/dev/null)" = "true" ]
}

# Start Mailpit on the shared proxy network (so replicas reach it as wpsite_mail:1025).
# The web UI is published on the host so it's reachable without DNS. Idempotent.
_mail_ensure() {
  require docker
  docker network inspect "$WPSITE_PROXY_NET" >/dev/null 2>&1 \
    || docker network create "$WPSITE_PROXY_NET" >/dev/null
  _mail_running && return 0
  docker rm -f "$WPSITE_MAIL_CONTAINER" >/dev/null 2>&1 || true
  log_info "Starting Mailpit (traps all replica email) — inbox: http://localhost:$WPSITE_MAIL_UI_PORT"
  docker run -d --name "$WPSITE_MAIL_CONTAINER" --restart unless-stopped \
    --network "$WPSITE_PROXY_NET" --network-alias "$WPSITE_MAIL_HOST" \
    -p "$WPSITE_MAIL_UI_PORT:8025" \
    "$WPSITE_MAIL_IMAGE" >/dev/null \
    || die "Could not start Mailpit — is port $WPSITE_MAIL_UI_PORT in use? (lsof -nP -i :$WPSITE_MAIL_UI_PORT)"
}

# mu-plugin that forces every wp_mail() through Mailpit's SMTP (wpsite_mail:1025).
# Priority 99 so it overrides SMTP plugins; nothing is ever delivered for real.
_mail_muplugin() {
  cat <<'PHP'
<?php
/**
 * Plugin Name: wpsite — Mailpit catch-all
 * Description: Routes ALL outgoing mail to the local Mailpit container (dev only).
 * Managed by wpsite; do not edit.
 */
if (!defined('ABSPATH')) { exit; }
add_action('phpmailer_init', function ($phpmailer) {
    $phpmailer->isSMTP();
    $phpmailer->Host        = 'wpsite-mail';
    $phpmailer->Port        = 1025;
    $phpmailer->SMTPAuth    = false;
    $phpmailer->SMTPAutoTLS = false;
    $phpmailer->SMTPSecure  = '';
}, 99);
PHP
}

# Write the mu-plugin into a replica's wp-content (creating mu-plugins/ if needed).
_inject_mailpit_muplugin() { # wp_content_dir
  local d="$1/mu-plugins"
  mkdir -p "$d"
  _mail_muplugin > "$d/wpsite-mailpit.php"
}

cmd_mail() {
  local sub="${1:-status}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    up)     _mail_ensure; log_ok "Mailpit up — inbox: http://localhost:$WPSITE_MAIL_UI_PORT" ;;
    down)   require docker
            if docker rm -f "$WPSITE_MAIL_CONTAINER" >/dev/null 2>&1; then
              log_ok "Mailpit stopped."
            else
              log_info "Mailpit was not running."
            fi ;;
    status) require docker
            if _mail_running; then
              log_ok "Mailpit running — inbox: http://localhost:$WPSITE_MAIL_UI_PORT"
            else
              log_info "Mailpit not running (starts automatically on 'wpsite build')."
            fi ;;
    *) die "Unknown: wpsite mail $sub (expected up|down|status)" ;;
  esac
}
