#!/usr/bin/env bats
# wpsite redirect — .htaccess redirect management on a client's production server.
# Covers the pure transforms (block round-trip, merge dedup, CSV/plugin parsing,
# pattern escaping) and the mutate-and-write flow (add/import/migrate/remove) over a
# stubbed remote: wpsite_ssh is backed by a local file standing in for the remote
# .htaccess, and _prod_wp / curl are stubbed. Nothing real runs over SSH.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"

  BASE="$BATS_TEST_TMPDIR/root"
  CFG="$BATS_TEST_TMPDIR/wpsite.yml"
  cat > "$CFG" <<EOF
base_dir: $BASE
clients:
  acme:
    ssh: u@acme
    wp_root: /var/www/acme
EOF
  export WPSITE_CONFIG="$CFG"
  export MANDOS_BIN="$BATS_TEST_DIRNAME/fixtures/mandos-stub"
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_apply.sh"      # _prod_wp lives here (we override it below)
  source "$REPO/lib/cmd_redirect.sh"

  require() { :; }                     # skip yq/mandos PATH checks

  # Stand-in for the remote .htaccess: a local file.
  REMOTE="$BATS_TEST_TMPDIR/htaccess"

  # wpsite_ssh stub: interpret only the shapes cmd_redirect issues, backing them with
  # $REMOTE. Order matters — the atomic-write shape must be matched before the plain cat.
  wpsite_ssh() {
    local cmd="$2"
    case "$cmd" in
      *"&& mv "*)                 cat > "$REMOTE" ;;                 # atomic write (stdin)
      *"[ -f "*)                  [ -f "$REMOTE" ] ;;               # exists check
      *"cp -f "*".bak"*)          cp -f "$REMOTE" "$REMOTE.bak" 2>/dev/null || true ;;
      *"mv -f "*".bak"*)          mv -f "$REMOTE.bak" "$REMOTE" ;;  # rollback restore
      *"rm -f "*htaccess*)        rm -f "$REMOTE" ;;
      *"cat "*htaccess*)          cat "$REMOTE" 2>/dev/null || true ;;  # get
      *) return 0 ;;
    esac
  }

  # _prod_wp stub: home for verify; plugin/config/db for migrate. Records calls.
  PWLOG="$BATS_TEST_TMPDIR/pwlog"; : > "$PWLOG"
  HOME_URL="http://acme.example"
  MIGRATE_ROWS=""
  _prod_wp() {
    shift 2                            # drop ssh_target + wp_root
    echo "$*" >> "$PWLOG"
    case "$*" in
      "option get home")             printf '%s\n' "$HOME_URL" ;;
      "config get table_prefix")     printf 'wp_\n' ;;
      *"SHOW TABLES"*)               printf 'wp_redirection_items\n' ;;
      *"SELECT"*)                    printf '%s' "$MIGRATE_ROWS" ;;
      "plugin deactivate redirection") return "${DEACT_RC:-0}" ;;
      *) return 0 ;;
    esac
  }

  # curl stub: emit the desired HTTP code (default 200).
  CURL_CODE="200"
  curl() { printf '%s' "$CURL_CODE"; }
}

# Auto-confirm all prompts unless a test wants the abort path.

# --- pure transforms -------------------------------------------------------

@test "redirect: build block round-trips through extract" {
  nf="$BATS_TEST_TMPDIR/rules"
  printf '/alt/pfad\t/neu\t301\t0\n^produkte/(.*)$\t/shop/$1\t302\t1\n' > "$nf"
  run bash -c "source '$REPO/lib/cmd_redirect.sh'; _redirect_build_block '$nf' | _redirect_extract_rules"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "/alt/pfad	/neu	301	0" ]]
  [[ "${lines[1]}" == "^produkte/(.*)$	/shop/\$1	302	1" ]]
}

@test "redirect: literal pattern is regex-escaped + anchored; regex passes through" {
  run bash -c "source '$REPO/lib/cmd_redirect.sh'; _redirect_pattern '/foo.html' 0"
  [ "$output" = '^foo\.html/?$' ]
  run bash -c "source '$REPO/lib/cmd_redirect.sh'; _redirect_pattern '^/produkte/(.*)$' 1"
  [ "$output" = '^produkte/(.*)$' ]
}

@test "redirect: external target kept verbatim, internal gets a leading slash" {
  run bash -c "source '$REPO/lib/cmd_redirect.sh'; _redirect_target 'https://x.io/a'"
  [ "$output" = 'https://x.io/a' ]
  run bash -c "source '$REPO/lib/cmd_redirect.sh'; _redirect_target 'neu'"
  [ "$output" = '/neu' ]
}

@test "redirect: merge dedupes by source (new wins), preserves order" {
  ex="$BATS_TEST_TMPDIR/ex"; new="$BATS_TEST_TMPDIR/new"
  printf '/a\t/1\t301\t0\n/keep\t/k\t301\t0\n' > "$ex"
  printf '/a\t/2\t302\t0\n/b\t/y\t301\t0\n' > "$new"
  run bash -c "source '$REPO/lib/cmd_redirect.sh'; _redirect_merge '$ex' '$new'"
  [ "${lines[0]}" = "/a	/2	302	0" ]    # updated in place
  [ "${lines[1]}" = "/keep	/k	301	0" ]
  [ "${lines[2]}" = "/b	/y	301	0" ]    # appended
}

@test "redirect: CSV parse — header/comment skip, query + empty-target skipped" {
  csv="$BATS_TEST_TMPDIR/in.csv"; skip="$BATS_TEST_TMPDIR/skip"
  printf 'source,target,code\n/a,/b,301\n# c\n/q?x=1,/z,301\n/notarget,,\n/e,https://x.io/e,302\n' > "$csv"
  run bash -c "source '$REPO/lib/cmd_redirect.sh'; _redirect_parse_csv '$csv' '$skip'"
  [ "${lines[0]}" = "/a	/b	301	0" ]
  [ "${lines[1]}" = "/e	https://x.io/e	302	0" ]
  [ "${#lines[@]}" -eq 2 ]
  grep -q 'query string' "$skip"
  grep -q 'empty target' "$skip"
}

# --- add -------------------------------------------------------------------

@test "redirect add: writes a managed block with the rule, verifies 200" {
  run cmd_redirect add acme /alt /neu --yes
  [ "$status" -eq 0 ]
  grep -q '# BEGIN wpsite-redirects' "$REMOTE"
  grep -q 'RewriteRule \^alt/?\$ /neu \[R=301,L\]' "$REMOTE"
  grep -q '# END wpsite-redirects' "$REMOTE"
}

@test "redirect add: block is inserted ABOVE the WordPress block" {
  cat > "$REMOTE" <<'EOF'
# BEGIN WordPress
RewriteRule . /index.php [L]
# END WordPress
EOF
  run cmd_redirect add acme /alt /neu --yes
  [ "$status" -eq 0 ]
  # our block must appear before WordPress's
  begin_ours="$(grep -n 'BEGIN wpsite-redirects' "$REMOTE" | cut -d: -f1)"
  begin_wp="$(grep -n 'BEGIN WordPress' "$REMOTE" | cut -d: -f1)"
  [ "$begin_ours" -lt "$begin_wp" ]
}

@test "redirect add: invalid --code rejected" {
  run cmd_redirect add acme /alt /neu --code 418 --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid --code"* ]]
}

@test "redirect add: 5xx after write triggers rollback (empty file restored)" {
  CURL_CODE="500"
  run cmd_redirect add acme /alt /neu --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"rolling back"* ]] || [[ "$output" == *"rolled back"* ]]
  # started with no htaccess -> rollback removes it
  [ ! -f "$REMOTE" ]
}

@test "redirect add: re-adding the same rule is a no-op" {
  cmd_redirect add acme /alt /neu >/dev/null --yes
  run cmd_redirect add acme /alt /neu --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"No changes"* ]]
}

# --- import ----------------------------------------------------------------

@test "redirect import: merges CSV rows into the block; skipped file reported" {
  csv="$BATS_TEST_TMPDIR/r.csv"
  printf 'source,target,code,regex\n/a,/b,301,0\n/q?x=1,/z,301,0\n' > "$csv"
  run cmd_redirect import acme "$csv" --yes
  [ "$status" -eq 0 ]
  grep -q 'RewriteRule \^a/?\$ /b' "$REMOTE"
  [[ "$output" == *"Skipped"* ]]
}

@test "redirect import --replace: wipes prior managed rules" {
  cmd_redirect add acme /old /gone >/dev/null --yes
  csv="$BATS_TEST_TMPDIR/r.csv"
  printf '/new,/here,301,0\n' > "$csv"
  run cmd_redirect import acme "$csv" --replace --yes
  [ "$status" -eq 0 ]
  grep -q 'RewriteRule \^new/?\$ /here' "$REMOTE"
  ! grep -q '/old' "$REMOTE"
}

@test "redirect import --deactivate-plugin: deactivates AFTER a good write" {
  csv="$BATS_TEST_TMPDIR/r.csv"
  printf '/a,/b,301,0\n' > "$csv"
  run cmd_redirect import acme "$csv" --deactivate-plugin --yes
  [ "$status" -eq 0 ]
  grep -q 'plugin deactivate redirection' "$PWLOG"
}

# --- migrate ---------------------------------------------------------------

@test "redirect migrate: imports plugin rows, skips non-url/disabled/empty" {
  # url,action_data,action_code,regex,match_type,action_type,status
  MIGRATE_ROWS="$(printf '/old\t/new\t301\t0\turl\turl\tenabled\n/re/(.*)\t/x/$1\t302\t1\turl\turl\tenabled\n/hdr\t/y\t301\t0\theader\turl\tenabled\n/dis\t/z\t301\t0\turl\turl\tdisabled\n')"
  run cmd_redirect migrate acme --yes
  [ "$status" -eq 0 ]
  grep -q 'RewriteRule \^old/?\$ /new \[R=301,L\]' "$REMOTE"
  grep -q 'RewriteRule re/(.*) /x/\$1 \[R=302,L\]' "$REMOTE"
  ! grep -q '/hdr' "$REMOTE"
  ! grep -q '/dis' "$REMOTE"
  [[ "$output" == *"Skipped"* ]]
}

@test "redirect migrate: no plugin tables -> dies" {
  _prod_wp() { shift 2; case "$*" in *"SHOW TABLES"*) printf '' ;; "config get table_prefix") printf 'wp_\n' ;; *) return 0 ;; esac; }
  run cmd_redirect migrate acme --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

# --- remove ----------------------------------------------------------------

@test "redirect remove: drops a rule by source (trailing slash tolerant)" {
  cmd_redirect add acme /gone /x >/dev/null --yes
  cmd_redirect add acme /stay /y >/dev/null --yes
  run cmd_redirect remove acme /gone/ --yes
  [ "$status" -eq 0 ]
  ! grep -q '\^gone' "$REMOTE"
  grep -q '\^stay/?\$' "$REMOTE"
}

@test "redirect remove: removing the only rule strips the block entirely" {
  cmd_redirect add acme /only /x >/dev/null --yes
  run cmd_redirect remove acme /only --yes
  [ "$status" -eq 0 ]
  ! grep -q 'BEGIN wpsite-redirects' "$REMOTE"
}

@test "redirect remove: no match -> warns, no write" {
  run cmd_redirect remove acme /nope --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to remove"* ]]
}

# --- list ------------------------------------------------------------------

@test "redirect list: prints managed rules and warns on unmanaged directives" {
  cat > "$REMOTE" <<'EOF'
# BEGIN wpsite-redirects
<IfModule mod_rewrite.c>
RewriteEngine On
# wpsite-rule	/a	/b	301	0
RewriteRule ^a/?$ /b [R=301,L]
</IfModule>
# END wpsite-redirects
# BEGIN WordPress
RewriteRule . /index.php [L]
# END WordPress
Redirect 301 /legacy /somewhere
EOF
  run cmd_redirect list acme
  [ "$status" -eq 0 ]
  [[ "$output" == *"/a"* ]]
  [[ "$output" == *"Unmanaged"* ]]
  [[ "$output" == *"/legacy"* ]]
  # WordPress's own RewriteRule must NOT be flagged as unmanaged
  [[ "$output" != *"index.php"* ]]
}

@test "redirect list --porcelain: emits only canonical tab lines" {
  cat > "$REMOTE" <<'EOF'
# BEGIN wpsite-redirects
<IfModule mod_rewrite.c>
RewriteEngine On
# wpsite-rule	/a	/b	301	0
RewriteRule ^a/?$ /b [R=301,L]
# wpsite-rule	^re/(.*)	/x/$1	302	1
RewriteRule re/(.*) /x/$1 [R=302,L]
</IfModule>
# END wpsite-redirects
EOF
  run cmd_redirect list acme --porcelain
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "/a	/b	301	0" ]
  [ "${lines[1]}" = "^re/(.*)	/x/\$1	302	1" ]
  [ "${#lines[@]}" -eq 2 ]
}

# --- dispatcher ------------------------------------------------------------

@test "redirect: unknown subcommand errors" {
  run cmd_redirect frobnicate acme
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown redirect subcommand"* ]]
}

@test "redirect: no subcommand prints usage" {
  run cmd_redirect
  [ "$status" -eq 0 ]
  [[ "$output" == *"manage .htaccess redirects"* ]]
}
