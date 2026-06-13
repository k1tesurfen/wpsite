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
  grep -q 'class="cmp"' "$f"
  grep -q 'clip-path' "$f"            # the wipe slider
  grep -q 'before/home.png' "$f"
  grep -q 'after/kontakt.png' "$f"
  grep -q 'side by side' "$f"         # the toggle
}

@test "cmd_review: errors clearly when there's no review yet" {
  command -v yq >/dev/null 2>&1 || skip "yq not installed"
  export WPSITE_CONFIG="$REPO/test/fixtures/wpsite.yml"
  run cmd_review acme
  [ "$status" -ne 0 ]
  [[ "$output" == *"No review found"* ]]
}
