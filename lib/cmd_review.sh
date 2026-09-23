# shellcheck shell=bash
# Screenshot review for upgrades: capture key pages before/after an upgrade and
# build a self-contained comparison page (drag-to-wipe slider + side-by-side toggle)
# that opens in the default browser. Driven by `wpsite upgrade <client> --review`;
# `wpsite review <client>` re-opens the latest. Capture uses a one-shot Playwright
# container reaching the replica through the proxy — no host browser needed.

# Native-arm64 Playwright base (has browsers, lacks the npm pkg) → we build a tiny
# derived image once that adds the `playwright` CLI. Avoids amd64 emulation.
WPSITE_SHOT_BASE="${WPSITE_SHOT_BASE:-mcr.microsoft.com/playwright:v1.49.1-noble}"
WPSITE_SHOT_IMAGE="${WPSITE_SHOT_IMAGE:-wpsite/shot}"

# Cookie/consent banners hidden (display:none) before each screenshot so they don't
# cover content. These are the managers our clients use; extend per client via
# clients.<c>.review_dismiss (a list of CSS selectors).
WPSITE_REVIEW_DISMISS_DEFAULTS="${WPSITE_REVIEW_DISMISS_DEFAULTS:-#usercentrics-root .ccm-root}"

# Combined dismiss selectors for a client: built-in defaults + configured extras.
# Space-separated on one line (the shot script splits on whitespace).
_review_dismiss() { # client
  local extra; extra="$(wclient_get "$1" review_dismiss 2>/dev/null | tr '\n' ' ')"
  printf '%s %s\n' "$WPSITE_REVIEW_DISMISS_DEFAULTS" "$extra" | tr -s ' ' | sed 's/ *$//'
}

# Build the screenshot image if absent (one-time; cached thereafter).
_shot_image_ensure() {
  docker image inspect "$WPSITE_SHOT_IMAGE" >/dev/null 2>&1 && return 0
  log_info "Building screenshot image (one-time)..."
  docker build -t "$WPSITE_SHOT_IMAGE" - <<EOF >/dev/null 2>&1 || { log_warn "Could not build screenshot image."; return 1; }
FROM $WPSITE_SHOT_BASE
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
RUN npm i -g playwright@1.49.1
EOF
}

# A filesystem-safe name for a URL's path. host-only or "/" -> home.
_url_slug() { # url
  local p="${1#*://}"          # host[/path]
  case "$p" in */*) p="${p#*/}" ;; *) p="" ;; esac   # keep path, or empty if host-only
  p="${p%/}"
  [ -z "$p" ] && { printf 'home'; return; }
  printf '%s' "$p" | tr '/' '_' | tr -cd '[:alnum:]_-'
}

# The pages to shoot: home + clients.<c>.review_pages, or home + a few auto-picked
# published pages/posts. Prints unique full URLs (deduped, capped). One per line.
_review_pages() { # client app_container local_url
  local client="$1" app="$2" url="$3" configured
  {
    printf '%s\n' "$url"
    configured="$(wclient_get "$client" review_pages)"
    if [ -n "$configured" ]; then
      printf '%s\n' "$configured" | while IFS= read -r p; do
        [ -z "$p" ] && continue
        case "$p" in
          http*) printf '%s\n' "$p" ;;
          /*)    printf '%s%s\n' "$url" "$p" ;;
          *)     printf '%s/%s\n' "$url" "$p" ;;
        esac
      done
    else
      # Published pages (by menu order) then posts, never a legal page — impressum/agb/
      # datenschutz rarely carry the risky stuff (sliders, forms, shops).
      _sample_pages 7 "$url" _upgrade_wp "$app"
    fi
  } | grep -E '^https?://[^[:space:]]+$' \
    | awk -v host="$(_review_host "$url")" '
        # Only pages OF THE REPLICA. A domain-mapping plugin (weinwege) returns pages under
        # other live domains the build did not rewrite — screenshotting those would hit
        # PRODUCTION and compare nothing. Dropped, and counted on stderr.
        seen[$0]++ { next }
        { h = $0; sub(/^https?:\/\//, "", h); sub(/[\/?#:].*$/, "", h) }
        h != host { skipped++; next }
        { print }
        END { if (skipped) printf "  (skipped %d page(s) on other domains — domain mapping?)\n", skipped > "/dev/stderr" }' \
    | head -8 || true
}

# The host part of a URL (no scheme, path, port).
_review_host() { local h="${1#*://}"; h="${h%%/*}"; printf '%s' "${h%%:*}"; }

# Multisite review specs: for EVERY site of the network its home page plus one sample
# page (published, never a legal page — _sample_pages). A client's review_pages paths
# (wpsite registry) are shot on every site too. Slugs are namespaced by host
# (`greyda_artismedia_test__home`) so they never collide across sites, and the review
# page groups them per site. Prints "slug|url".
_ms_review_specs() { # app_container [client]
  local app="$1" client="${2:-}" site_url host label page configured="" p
  [ -n "$client" ] && configured="$(wclient_get "$client" review_pages)"
  _ms_site_urls _upgrade_wp "$app" | while IFS= read -r site_url; do
      host="${site_url#*://}"; host="${host%%/*}"
      label="$(printf '%s' "$host" | tr -c '[:alnum:]' '_')"
      printf '%s|%s\n' "${label}__home" "$site_url"
      if [ -n "$configured" ]; then
        printf '%s\n' "$configured" | while IFS= read -r p; do
          [ -n "$p" ] || continue
          p="/${p#/}"; page="${site_url%/}$p"
          printf '%s|%s\n' "${label}__$(_url_slug "$page")" "$page"
        done
      else
        page="$(_sample_pages 1 "$site_url" _upgrade_wp "$app")"
        [ -n "$page" ] && printf '%s|%s\n' "${label}__$(_url_slug "$page")" "$page"
      fi
    done
  return 0
}

# Unique replica hosts referenced by a set of "slug|url" specs (for --add-host).
_specs_hosts() { # specs...
  local spec url host
  for spec in "$@"; do
    url="${spec#*|}"; host="${url#*://}"; host="${host%%/*}"
    [ -n "$host" ] && printf '%s\n' "$host"
  done | sort -u
}

# Playwright API script (run via `node -e`): read "slug|url" specs from stdin, and for
# each — navigate, inject CSS hiding the DISMISS selectors (consent banners; the rule
# persists so late-injected banners are hidden too), settle, full-page screenshot to
# /out/<slug>.png. One reused browser. Single-quoted: no shell interpolation.
_SHOT_JS='
const { chromium } = require("playwright");
const fs = require("fs");
const dismiss = (process.env.DISMISS || "").split(/\s+/).filter(Boolean);
const specs = fs.readFileSync(0, "utf8").split("\n").map(l => l.trim()).filter(Boolean);
(async () => {
  const browser = await chromium.launch({ args: ["--no-sandbox"] });
  const page = await (await browser.newContext({ viewport: { width: 1440, height: 900 } })).newPage();
  for (const line of specs) {
    const i = line.indexOf("|"); if (i < 0) continue;
    const slug = line.slice(0, i), url = line.slice(i + 1);
    try {
      await page.goto(url, { waitUntil: "networkidle", timeout: 30000 }).catch(() => {});
      if (dismiss.length) {
        const css = dismiss.map(s => s + "{display:none !important;visibility:hidden !important}").join("");
        await page.addStyleTag({ content: css }).catch(() => {});
      }
      await page.waitForTimeout(1500);
      await page.screenshot({ path: "/out/" + slug + ".png", fullPage: true });
      console.log("  shot: " + slug);
    } catch (e) { console.log("  shot FAILED: " + slug); }
  }
  await browser.close();
})();'

# Capture full-page screenshots of each URL into <outdir>. specs are "slug|url".
# hosts is space-separated: one entry for single-site, every subsite domain for
# multisite — each gets an --add-host so the browser resolves them all to Traefik.
# dismiss is space-separated CSS selectors hidden before each shot (consent banners).
_capture_shots() { # outdir hosts dismiss specs...
  local outdir="$1" hosts="$2" dismiss="$3"; shift 3
  mkdir -p "$outdir"
  _shot_image_ensure || return 1
  local tip
  tip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$WPSITE_PROXY_NET\").IPAddress}}" "$WPSITE_PROXY_CONTAINER" 2>/dev/null)"
  [ -n "$tip" ] || { log_warn "Proxy not running; cannot screenshot."; return 1; }

  # One --add-host per replica domain (so in-page assets on any .test host resolve too).
  local add_hosts=() h
  # shellcheck disable=SC2086
  for h in $hosts; do add_hosts+=(--add-host "$h:$tip"); done

  # One container, looping the specs from stdin via the Playwright API (NODE_PATH points
  # at the global install). DISMISS + the script travel as env so quoting stays sane.
  printf '%s\n' "$@" | docker run -i --rm \
    --network "$WPSITE_PROXY_NET" "${add_hosts[@]}" \
    -e DISMISS="$dismiss" -e SHOT_JS="$_SHOT_JS" \
    -v "$outdir":/out "$WPSITE_SHOT_IMAGE" \
    sh -c 'NODE_PATH=$(npm root -g) node -e "$SHOT_JS"'
}

# Count "PHP Fatal" lines in the replica's debug.log (0 if none/absent). Guards the
# grep -c trap (prints "0" + exits 1 on no match → would double up with `|| echo`).
_debug_fatal_count() { # docker_dir
  local f="$1/wp-content/debug.log" n
  [ -f "$f" ] || { printf 0; return; }
  n="$(grep -c 'PHP Fatal' "$f" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

# Post-upgrade smoke check: every page 200, no new fatals. Informational (warn only).
# Host is derived per-spec from its URL, so it spans every subsite on a multisite.
_smoke_check() { # docker_dir fatal_baseline specs...
  local docker_dir="$1" baseline="$2"; shift 2
  local bad=0 spec slug url hostpath host path code
  for spec in "$@"; do
    slug="${spec%%|*}"; url="${spec#*|}"
    hostpath="${url#*://}"                       # host[/path]
    host="${hostpath%%/*}"
    case "$hostpath" in */*) path="/${hostpath#*/}" ;; *) path="/" ;; esac
    code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $host" \
      "http://127.0.0.1$path" 2>/dev/null || echo 000)"
    [ "$code" = "200" ] || { log_warn "  smoke: $slug returned HTTP $code"; bad=$((bad + 1)); }
  done
  local now; now="$(_debug_fatal_count "$docker_dir")"
  if [ "$now" -gt "$baseline" ]; then
    log_warn "  smoke: $((now - baseline)) new PHP fatal(s) in debug.log after upgrade"
    bad=$((bad + 1))
  fi
  if [ "$bad" -eq 0 ]; then log_ok "Smoke check passed (all pages 200, no new fatals)."; fi
  return 0
}

# _open_file lives in common.sh (platform shim: xdg-open / open / print).


# Latest upgrades/<timestamp> dir for a client (most recent), or empty.
_latest_upgrade_dir() { # client
  local d
  # shellcheck disable=SC2012
  d="$(ls -td "$(client_base "$1")/upgrades/"*/ 2>/dev/null | head -1)"
  printf '%s' "${d%/}"
}

# Write a self-contained review.html into <dir> referencing before/<slug>.png and
# after/<slug>.png. Default view: drag-to-wipe slider; per-page toggle to side-by-side.
_render_review_html() { # dir client stamp specs...
  local dir="$1" client="$2" stamp="$3"; shift 3
  local spec slug url
  {
    cat <<HEAD
<!doctype html><html><head><meta charset="utf-8"><title>wpsite review — $client</title>
<style>
body{font-family:-apple-system,system-ui,sans-serif;margin:0;background:#1d1f23;color:#e8e8ea}
header{padding:16px 24px;background:#16181c;border-bottom:1px solid #2a2d33;position:sticky;top:0;z-index:5}
h1{font-size:16px;margin:0}.meta{color:#9aa0a6;font-size:13px;margin-top:4px}
.page{max-width:1480px;margin:28px auto;padding:0 20px}
.page h2{font-size:14px;color:#cfd2d6;margin:0 0 2px}.page .url{color:#7aa2f7;font-size:12px;word-break:break-all;margin-bottom:8px}
.toggle{float:right;font-size:12px;color:#9aa0a6;cursor:pointer;user-select:none;border:1px solid #3a3d44;border-radius:6px;padding:3px 8px}
.cmp{position:relative;border:1px solid #2a2d33;border-radius:8px;overflow:hidden;background:#0d0e10}
.cmp img{display:block;width:100%}
.cmp .before{position:absolute;top:0;left:0;clip-path:inset(0 50% 0 0)}
.cmp input[type=range]{position:absolute;top:0;left:0;width:100%;height:100%;margin:0;opacity:0;cursor:ew-resize}
.cmp .handle{position:absolute;top:0;bottom:0;left:50%;width:2px;background:#f5466b;pointer-events:none}
.cmp .lbl{position:absolute;top:8px;font-size:11px;background:rgba(0,0,0,.6);padding:2px 6px;border-radius:4px;pointer-events:none}
.cmp .lbl.l{left:8px}.cmp .lbl.r{right:8px}
.side{display:none;gap:12px}.side>div{flex:1;min-width:0}.side .cap{font-size:11px;color:#9aa0a6;margin-bottom:4px}
.side img{width:100%;display:block;border:1px solid #2a2d33;border-radius:8px}
.page.sbs .cmp{display:none}.page.sbs .side{display:flex}
nav.sites{max-width:1480px;margin:16px auto 0;padding:0 20px;font-size:13px;color:#9aa0a6}
nav.sites a{color:#7aa2f7;margin-left:10px;text-decoration:none}
h2.site{max-width:1480px;margin:44px auto 0;padding:12px 20px 0;font-size:18px;color:#fff;border-top:1px solid #2a2d33;scroll-margin-top:70px}
</style></head><body>
<header><h1>wpsite review — $client</h1>
<div class="meta">$stamp · before / after side by side · toggle any page to the wipe slider</div></header>
HEAD
    # Several hosts (a multisite): a jump list, and a heading whenever the site changes.
    local hosts=() host last="" h
    for spec in "$@"; do h="${spec#*|}"; h="${h#*://}"; h="${h%%/*}"
      case " ${hosts[*]-} " in *" $h "*) ;; *) hosts+=("$h") ;; esac; done
    if [ "${#hosts[@]}" -gt 1 ]; then
      printf '<nav class="sites">%s sites:' "${#hosts[@]}"
      for h in "${hosts[@]}"; do printf ' <a href="#site-%s">%s</a>' "$(printf '%s' "$h" | tr -c '[:alnum:]' '-')" "$h"; done
      printf '</nav>\n'
    fi
    for spec in "$@"; do
      slug="${spec%%|*}"; url="${spec#*|}"
      host="${url#*://}"; host="${host%%/*}"
      if [ "${#hosts[@]}" -gt 1 ] && [ "$host" != "$last" ]; then
        printf '<h2 class="site" id="site-%s">%s</h2>\n' "$(printf '%s' "$host" | tr -c '[:alnum:]' '-')" "$host"
        last="$host"
      fi
      cat <<SECTION
<div class="page sbs">
  <span class="toggle" onclick="toggle(this)">side by side ⇄ slider</span>
  <h2>$slug</h2><div class="url">$url</div>
  <div class="cmp">
    <img class="after" src="after/$slug.png" alt="after">
    <img class="before" src="before/$slug.png" alt="before">
    <span class="lbl l">before</span><span class="lbl r">after</span>
    <div class="handle"></div>
    <input type="range" min="0" max="100" value="50" oninput="slide(this)">
  </div>
  <div class="side">
    <div><div class="cap">before</div><img src="before/$slug.png"></div>
    <div><div class="cap">after</div><img src="after/$slug.png"></div>
  </div>
</div>
SECTION
    done
    cat <<'FOOT'
<script>
function slide(r){var c=r.parentElement;c.querySelector('.before').style.clipPath='inset(0 '+(100-r.value)+'% 0 0)';c.querySelector('.handle').style.left=r.value+'%';}
function toggle(b){b.closest('.page').classList.toggle('sbs');}
</script></body></html>
FOOT
  } > "$dir/review.html"
}

cmd_review() {
  local client="${1:-}"
  config_require_registry
  require_client "$client"
  local dir; dir="$(_latest_upgrade_dir "$client")"
  [ -n "$dir" ] && [ -f "$dir/review.html" ] \
    || die "No review found for $client. Run: wpsite upgrade $client --review"
  log_info "Opening $dir/review.html"
  _open_file "$dir/review.html"
}
