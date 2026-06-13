#!/usr/bin/env bats
# Screenshot-review: URL→slug, page selection, comparison-page HTML, re-open guard.
# The Playwright capture itself is integration-only and not unit-tested here.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_proxy.sh"
  source "$REPO/lib/cmd_upgrade.sh"
  source "$REPO/lib/cmd_review.sh"
}

@test "_url_slug: home + nested paths" {
  [ "$(_url_slug 'http://x.test/')" = "home" ]
  [ "$(_url_slug 'http://x.test/kontakt/')" = "kontakt" ]
  [ "$(_url_slug 'http://x.test/shop/cart/')" = "shop_cart" ]
}

@test "_review_pages: configured review_pages, home always first" {
  client_get() { [ "$2" = "review_pages" ] && printf '/kontakt\n/referenzen\n'; return 0; }
  run _review_pages acme app http://acme.test
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "http://acme.test" ]
  [[ "$output" == *"http://acme.test/kontakt"* ]]
  [[ "$output" == *"http://acme.test/referenzen"* ]]
}

@test "_review_pages: auto-picks via wp-cli when unconfigured, dedups home" {
  client_get() { return 0; }   # nothing configured
  _upgrade_wp() { printf 'http://acme.test/\nhttp://acme.test/a/\nhttp://acme.test/b/\n'; }  # --field=url, no header
  run _review_pages acme app http://acme.test
  [[ "$output" == *"http://acme.test/a/"* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^http://acme.test$')" -eq 1 ]
}

@test "_render_review_html: slider page referencing both shots + toggle" {
  _render_review_html "$BATS_TEST_TMPDIR" acme 20260101_000000 \
    'home|http://acme.test/' 'kontakt|http://acme.test/kontakt/'
  f="$BATS_TEST_TMPDIR/review.html"
  [ -f "$f" ]
  grep -q 'class="page sbs"' "$f"     # side-by-side is the DEFAULT view
  grep -q 'clip-path' "$f"            # the wipe slider is available via toggle
  grep -q 'before/home.png' "$f"
  grep -q 'after/kontakt.png' "$f"
  grep -q 'side by side ⇄ slider' "$f"
}

@test "_ms_review_specs: home + 1 page per subsite, host-namespaced slugs" {
  # Stub wp-cli: subsite list, then one extra page per subsite (echoes its --url back).
  _upgrade_wp() {
    shift   # drop app container
    case "$1" in
      site) printf 'http://greyd.artismedia.test/\nhttp://greyda.artismedia.test/\n' ;;
      post) local a url=""; for a in "$@"; do case "$a" in --url=*) url="${a#--url=}" ;; esac; done
            printf '%sabout/\n' "$url" ;;
    esac
  }
  run _ms_review_specs app
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 4 ]                 # 2 subsites × 2 pages
  [[ "$output" == *"greyd_artismedia_test__home|http://greyd.artismedia.test/"* ]]
  [[ "$output" == *"greyda_artismedia_test__home|http://greyda.artismedia.test/"* ]]   # distinct from greyd
  [[ "$output" == *"greyda_artismedia_test__about|http://greyda.artismedia.test/about/"* ]]
}

@test "_review_dismiss: built-in consent selectors present by default" {
  client_get() { return 0; }   # no per-client review_dismiss
  run _review_dismiss acme
  [[ "$output" == *"#usercentrics-root"* ]]   # Usercentrics
  [[ "$output" == *".ccm-root"* ]]            # CCM19
}

@test "_review_dismiss: per-client selectors are appended to the defaults" {
  client_get() { [ "$2" = "review_dismiss" ] && printf '#my-banner\n.foo-consent\n'; return 0; }
  run _review_dismiss acme
  [[ "$output" == *"#usercentrics-root"* ]]
  [[ "$output" == *"#my-banner"* ]]
  [[ "$output" == *".foo-consent"* ]]
}

@test "_specs_hosts: unique replica hosts across specs" {
  run _specs_hosts 'a__home|http://greyd.x.test/' 'a__about|http://greyd.x.test/about/' 'b__home|http://greyda.x.test/'
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 2 ]
  [[ "$output" == *"greyd.x.test"* ]]
  [[ "$output" == *"greyda.x.test"* ]]
}

@test "cmd_review: errors clearly when there's no review yet" {
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  export WPSITE_CONFIG="$REPO/test/fixtures/wpsite.yml"
  run cmd_review acme
  [ "$status" -ne 0 ]
  [[ "$output" == *"No review found"* ]]
}
