#!/usr/bin/env bats
# Multisite NETWORKS in upgrade + apply (test/multisite.bats covers build's domain mapping) (schatz: 6 sites, 3 on their own domains; hartmann;
# greyda). Every check covers EVERY site: boot checks, per-subsite plugin reconcile, the
# sample pages (never a legal page), a per-site maintenance hold — a broken subsite stays
# behind the 503 on its own, the rest of the network goes live — a test mail per site,
# and a customer report that names every domain.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_upgrade.sh"
  source "$REPO/lib/cmd_review.sh"
  source "$REPO/lib/cmd_apply.sh"
  CALLS="$BATS_TEST_TMPDIR/calls"; : > "$CALLS"
}

# --- sample pages -----------------------------------------------------------------------

@test "_is_legal_url: impressum / agb / datenschutz (+ variants) are legal pages" {
  for u in https://a.de/impressum/ https://a.de/agb https://a.de/datenschutz/ https://a.de/datenschutzerklaerung/ \
           https://a.de/privacy-policy/ https://a.de/cookie-richtlinie/ https://a.de/widerrufsbelehrung/; do
    _is_legal_url "$u" || { echo "not legal: $u"; return 1; }
  done
  ! _is_legal_url https://a.de/leistungen/
  ! _is_legal_url https://a.de/impressionen/          # only whole slugs
}

@test "_sample_pages: pages first, never the home or a legal page, at most n" {
  runner() { case "$*" in *post_type=page*) printf 'https://a.de/\nhttps://a.de/impressum/\nhttps://a.de/agb/\nhttps://a.de/leistungen/\nhttps://a.de/kontakt/\n' ;;
                          *post_type=post*) printf 'https://a.de/2026/news/\n' ;; esac; }
  run _sample_pages 1 https://a.de/ runner
  [ "$output" = "https://a.de/leistungen/" ]
  run _sample_pages 5 https://a.de/ runner
  [ "$output" = $'https://a.de/leistungen/\nhttps://a.de/kontakt/\nhttps://a.de/2026/news/' ]
}

@test "_sample_pages: reaching n under set -euo pipefail doesn't abort (the apply regression)" {
  run env REPO="$REPO" bash -c 'set -euo pipefail; source "$REPO/lib/common.sh"; source "$REPO/lib/cmd_upgrade.sh"
    runner() { printf "https://a.de/x/\nhttps://a.de/y/\nhttps://a.de/z/\n"; }
    _sample_pages 1 https://a.de/ runner >/dev/null; _sample_pages 9 https://a.de/ runner >/dev/null; echo __REACHED__'
  [[ "$output" == *__REACHED__* ]]
}

# --- screenshots --------------------------------------------------------------------------

_net() { # a 3-site network: main + subdomain + own domain
  _upgrade_wp() { shift; case "$*" in
    *"site list"*) printf 'http://main.test/\nhttp://shop.main.test/\nhttp://www.eigene-domain.test/\n' ;;
    *"post list"*--url=http://main.test/*post_type=page*) printf 'http://main.test/impressum/\nhttp://main.test/ueber-uns/\n' ;;
    *"post list"*--url=http://shop.main.test/*post_type=page*) printf 'http://shop.main.test/agb/\nhttp://shop.main.test/produkte/\n' ;;
    *"post list"*--url=http://www.eigene-domain.test/*post_type=page*) printf 'http://www.eigene-domain.test/datenschutz/\n' ;;
    *"post list"*--url=http://www.eigene-domain.test/*post_type=post*) printf 'http://www.eigene-domain.test/aktuelles/\n' ;;
  esac; }
}

@test "_ms_review_specs: every site — its home and one NON-legal page" {
  _net; wclient_get() { return 0; }
  run _ms_review_specs app acme
  [ "$(printf '%s\n' "$output" | grep -c '__home|')" -eq 3 ]
  [[ "$output" == *"http://main.test/ueber-uns/"* ]]
  [[ "$output" == *"http://shop.main.test/produkte/"* ]]
  [[ "$output" == *"http://www.eigene-domain.test/aktuelles/"* ]]
  [[ "$output" != *impressum* ]]; [[ "$output" != *agb* ]]; [[ "$output" != *datenschutz* ]]
}

@test "_ms_review_specs: a client's review_pages are shot on EVERY site" {
  _net; wclient_get() { [ "$2" = review_pages ] && printf '/kontakt\n'; return 0; }
  run _ms_review_specs app acme
  [ "$(printf '%s\n' "$output" | grep -c '/kontakt$')" -eq 3 ]
}

@test "review.html: grouped per site with a jump list (one long scroll page)" {
  local d="$BATS_TEST_TMPDIR/rev"; mkdir -p "$d"
  _render_review_html "$d" acme 20260923_120000 "main_test__home|http://main.test/" \
    "main_test__ueber-uns|http://main.test/ueber-uns/" "shop__home|http://shop.main.test/"
  grep -q '<nav class="sites">2 sites:' "$d/review.html"
  [ "$(grep -c '<h2 class="site"' "$d/review.html")" -eq 2 ]
  grep -q 'class="page sbs"' "$d/review.html"           # side by side by default
}

# --- boot checks + reconcile per site -----------------------------------------------------

@test "_site_boots: on a network every site is booted; the failing one is named" {
  runner() { case "$*" in *--url=http://shop.main.test/*) return 0 ;; *WPSITE_BOOT_OK*) echo WPSITE_BOOT_OK ;; esac; }
  _WPSITE_SITE_URLS=$'http://main.test/\nhttp://shop.main.test/'
  ! _site_boots runner
  [ "$_WPSITE_BOOT_FAILED" = "http://shop.main.test/" ]
  _WPSITE_SITE_URLS=""; _site_boots runner
}

@test "subsite reconcile: a plugin knocked out on ONE subsite is reactivated there; a fatal one isn't" {
  local d="$BATS_TEST_TMPDIR/r"; mkdir -p "$d"
  _WPSITE_SITE_URLS=$'http://main.test/\nhttp://shop.main.test/'
  PHASE=before
  runner() {
    printf '%s\n' "$*" >> "$CALLS"
    case "$*" in
      *"plugin list"*--url=http://shop.main.test/*) [ "$PHASE" = before ] && printf 'woocommerce\nshop-helper\n' ;;
      *"plugin activate"*) return 0 ;;
      *WPSITE_BOOT_OK*--url=http://shop.main.test/*) grep -q 'activate shop-helper' "$CALLS" && ! grep -q 'deactivate' "$CALLS" && return 0; echo WPSITE_BOOT_OK ;;
    esac
  }
  _ms_active_snapshot "$d" before runner
  PHASE=after; _ms_active_snapshot "$d" after runner
  ! grep -q 'main.test/ --status' "$CALLS"             # the main site is the CSV's job
  run _ms_reconcile_subsites "$d" "$d/log" "$d/rec" runner
  [ "$status" -ne 0 ]
  grep -q $'REACTIVATED\twoocommerce (shop.main.test)' "$d/rec"
  grep -q $'FAILED\tshop-helper (shop.main.test)\tfatal' "$d/rec"
  grep -q 'plugin activate woocommerce --url=http://shop.main.test/' "$CALLS"
  grep -q 'plugin deactivate shop-helper --url=http://shop.main.test/' "$CALLS"
}

# --- apply: per-site hold -----------------------------------------------------------------

@test "_apply_sites_to_hold: main broken → all; a broken subsite → just its blog ID" {
  local d="$BATS_TEST_TMPDIR/h"; mkdir -p "$d"
  printf '1\thttps://main.de/\n2\thttps://shop.main.de/\n5\thttps://www.eigene.de/\n' > "$d/sites"
  printf 'ok\t200\thttps://main.de/\nok\t200\thttps://shop.main.de/\nfatal\t500\thttps://www.eigene.de/\n' > "$d/gate"
  runner() { echo WPSITE_BOOT_OK; }
  [ "$(_apply_sites_to_hold "$d/sites" "$d/gate" runner)" = 5 ]
  runner() { case "$*" in *shop.main.de*) return 0 ;; *) echo WPSITE_BOOT_OK ;; esac; }   # shop doesn't boot
  [ "$(_apply_sites_to_hold "$d/sites" "$d/gate" runner)" = "2,5" ]
  printf 'down\t000\thttps://main.de/\n' > "$d/gate"
  runner() { echo WPSITE_BOOT_OK; }
  [ "$(_apply_sites_to_hold "$d/sites" "$d/gate" runner)" = all ]
}

@test "hold with blog IDs: only those sites are listed, WordPress's network-wide lock is removed" {
  ROOT="$BATS_TEST_TMPDIR/site"; mkdir -p "$ROOT/wp-content"
  wpsite_ssh() { shift; bash -c "$1"; }
  _prod_maintenance_on u@h "$ROOT" tok
  _prod_maintenance_hold u@h "$ROOT" "3,5"
  [ "$(cat "$ROOT/wp-content/.wpsite-maintenance")" = "0 tok 3,5" ]
  [ ! -e "$ROOT/.maintenance" ]
}

@test "gate: a per-site hold blocks exactly the listed blogs" {
  command -v php >/dev/null 2>&1 || skip "php not installed"
  ROOT="$BATS_TEST_TMPDIR/site"; mkdir -p "$ROOT/wp-content"
  wpsite_ssh() { shift; bash -c "$1"; }
  _prod_maintenance_on u@h "$ROOT" tok; _prod_maintenance_hold u@h "$ROOT" "3,5"
  for blog in 1 3 5 7; do
    out="$(BLOG=$blog WPC="$ROOT/wp-content" php -r '
      define("WP_CONTENT_DIR", getenv("WPC")); function get_current_blog_id() { return (int) getenv("BLOG"); }
      include getenv("WPC") . "/mu-plugins/wpsite-maintenance.php"; echo "PASSED";' 2>&1)"
    case "$blog" in 3|5) [[ "$out" == *Wartungsarbeiten* ]] || { echo "blog $blog not held"; return 1; } ;;
                    *)   [ "$out" = PASSED ] || { echo "blog $blog held"; return 1; } ;; esac
  done
}

# --- customer report ----------------------------------------------------------------------

@test "customer report: every network domain is listed; the file is named after the live domain" {
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  local base="$BATS_TEST_TMPDIR/root"
  CFG="$BATS_TEST_TMPDIR/w.yml"
  printf 'base_dir: %s\nclients:\n  schatz:\n    ssh: u@h\n    wp_root: /v\n    domain: schatz-gruppe.de\n' "$base" > "$CFG"
  export WPSITE_CONFIG="$CFG" WPSITE_TEAM_CONFIG="$CFG" MANDOS_STUB_CONFIG="$CFG" MANDOS_BIN="$REPO/test/fixtures/mandos-stub"
  local b="$base/clients/schatz/backups/20260730_164752"; mkdir -p "$b"
  echo "-- dump" > "$b/db.sql"; echo tar > "$b/wp-content.tar.gz"
  printf 'SOURCE_HOME=https://schatzgruppe-site.wird.cool\nMULTISITE=1\n' > "$b/meta.env"
  printf 'blog_id,domain,path,url\n1,schatzgruppe-site.wird.cool,/,x\n2,www.schorndorfer-immobilien.de,/,x\n3,www.schatz-architektur.de,/,x\n' > "$b/sites.csv"
  local d="$BATS_TEST_TMPDIR/apply"; mkdir -p "$d"
  printf 'name,version,update\n' > "$d/plugins.before.csv"; cp "$d/plugins.before.csv" "$d/plugins.after.csv"
  cp "$d/plugins.before.csv" "$d/themes.before.csv"; cp "$d/plugins.before.csv" "$d/themes.after.csv"
  _report_pdf() { :; }
  _write_client_report_de schatz 20260923_120000 7.1.1 7.1.2 "$d" domain 2>/dev/null
  [ -f "$d/schatz-gruppe_de-wartungsbericht.txt" ]
  grep -q 'Websites (3):' "$d/schatz-gruppe_de-wartungsbericht.txt"
  grep -q 'www.schorndorfer-immobilien.de' "$d/schatz-gruppe_de-wartungsbericht.txt"
  grep -q 'www.schatz-architektur.de' "$d/schatz-gruppe_de-wartungsbericht.txt"
}
