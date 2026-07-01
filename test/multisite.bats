#!/usr/bin/env bats
# Multisite domain mapping — the legacy TLD-swap (build) and the namespaced mapping
# used by `clone` (so a network clone can't collide with the client's own build).

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_build_multisite.sh"

  CSV="$BATS_TEST_TMPDIR/sites.csv"
  cat > "$CSV" <<EOF
blog_id,domain,path
1,acme.de,/
2,shop.acme.de,/
3,blog.acme.de,/
4,partner.example.org,/
EOF
}

# --- legacy mapping (build: no namespace) ----------------------------------

@test "_swap_tld swaps only the TLD" {
  run _swap_tld shop.acme.de
  [ "$output" = "shop.acme.test" ]
}

@test "_ms_local_host without ns == TLD swap" {
  run _ms_local_host shop.acme.de acme.de ""
  [ "$output" = "shop.acme.test" ]
  run _ms_local_host acme.de acme.de ""
  [ "$output" = "acme.test" ]
}

@test "_ms_pairs without ns: legacy per-domain TLD swap" {
  run _ms_pairs "$CSV"
  [[ "$output" == *"acme.de acme.test"* ]]
  [[ "$output" == *"shop.acme.de shop.acme.test"* ]]
  [[ "$output" == *"partner.example.org partner.example.test"* ]]
}

# --- namespaced mapping (clone: ns = devname) ------------------------------

@test "_ms_local_host: main domain → <ns>.test" {
  run _ms_local_host acme.de acme.de mydev
  [ "$output" = "mydev.test" ]
}

@test "_ms_local_host: subdomain subsite → <label>.<ns>.test" {
  run _ms_local_host shop.acme.de acme.de mydev
  [ "$output" = "shop.mydev.test" ]
  run _ms_local_host blog.acme.de acme.de mydev
  [ "$output" = "blog.mydev.test" ]
}

@test "_ms_local_host: unrelated mapped domain → sanitized.<ns>.test" {
  run _ms_local_host partner.example.org acme.de mydev
  [ "$output" = "partner-example-org.mydev.test" ]
}

@test "_ms_pairs with ns: every host namespaced under <ns>.test, none bare" {
  run _ms_pairs "$CSV" mydev
  [[ "$output" == *"acme.de mydev.test"* ]]
  [[ "$output" == *"shop.acme.de shop.mydev.test"* ]]
  [[ "$output" == *"blog.acme.de blog.mydev.test"* ]]
  [[ "$output" == *"partner.example.org partner-example-org.mydev.test"* ]]
  # The collision-prone bare client host must NOT appear.
  [[ "$output" != *" acme.test"* ]]
}

@test "subdirectory network: all rows share the main domain → one namespaced host" {
  local csv="$BATS_TEST_TMPDIR/subdir.csv"
  cat > "$csv" <<EOF
blog_id,domain,path
1,acme.de,/
2,acme.de,/shop/
3,acme.de,/blog/
EOF
  run _ms_pairs "$csv" mydev
  # Every line maps the single domain to mydev.test (paths distinguish subsites).
  [[ "$output" == *"acme.de mydev.test"* ]]
  [[ "$output" != *".mydev.test"* ]]   # no spurious subdomain labels
}

# --- raw-SQL network domain fix honours the imported DB's table prefix ----------

@test "_ms_fix_domains uses the given table prefix (not hardcoded wp_)" {
  CAP="$BATS_TEST_TMPDIR/sql"; : > "$CAP"
  # Stub docker: capture the SQL passed after `-e`.
  docker() {
    local prev=""
    for a in "$@"; do [ "$prev" = "-e" ] && { printf '%s' "$a" > "$CAP"; break; }; prev="$a"; done
  }
  run _ms_fix_domains dbc acme.test "$CSV" "" hfm3_
  [ "$status" -eq 0 ]
  grep -q "UPDATE hfm3_site SET domain='acme.test';" "$CAP"
  grep -q "UPDATE hfm3_blogs SET domain=" "$CAP"
  ! grep -q "wp_site" "$CAP"
}

@test "_ms_fix_domains defaults to wp_ when no prefix passed" {
  CAP="$BATS_TEST_TMPDIR/sql"; : > "$CAP"
  docker() {
    local prev=""
    for a in "$@"; do [ "$prev" = "-e" ] && { printf '%s' "$a" > "$CAP"; break; }; prev="$a"; done
  }
  run _ms_fix_domains dbc acme.test "$CSV" ""
  [ "$status" -eq 0 ]
  grep -q "UPDATE wp_site SET domain='acme.test';" "$CAP"
}
