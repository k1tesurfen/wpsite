#!/usr/bin/env bats
# The remote backup payload: media map + tar excludes in light vs full mode.
# We run _backup_remote_script locally against a fixture "site" with stubbed
# wp/identify, exactly as the server would.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO/lib/cmd_backup.sh"

  ROOT="$BATS_TEST_TMPDIR/site"
  OUT="$BATS_TEST_TMPDIR/out"
  STUB="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$ROOT"/wp-content/uploads/2026/02 \
           "$ROOT"/wp-content/uploads/fonts \
           "$ROOT"/wp-content/uploads/wp-staging/backups \
           "$ROOT"/wp-content/uploads/sites/2/wp-staging/backups \
           "$ROOT"/wp-content/cache \
           "$ROOT"/wp-content/plugins/elementor/css \
           "$STUB"
  printf '\xff\xd8\xff' > "$ROOT/wp-content/uploads/2026/02/photo.jpg"
  echo woff       > "$ROOT/wp-content/uploads/fonts/Brand-Regular.woff2"
  echo body       > "$ROOT/wp-content/plugins/elementor/css/post-9.css"
  echo archive    > "$ROOT/wp-content/uploads/wp-staging/backups/site.wpstg"
  echo ms-archive > "$ROOT/wp-content/uploads/sites/2/wp-staging/backups/ms.wpstg"
  echo stale      > "$ROOT/wp-content/cache/page.html"
  : > "$ROOT/wp-content/advanced-cache.php"

  cat > "$STUB/wp" <<'EOF'
#!/bin/bash
if [[ "$*" == *"db export"* ]]; then
  for a in "$@"; do case "$a" in /*) echo "-- dump" > "$a";; esac; done; exit 0
fi
case "$*" in
  *siteurl*) echo "https://x.de";; *home*) echo "https://x.de";;
  *"core version"*) echo "6.4";; *eval*) echo "8.3";;
esac
EOF
  cat > "$STUB/identify" <<'EOF'
#!/bin/bash
echo "640|480"
EOF
  chmod +x "$STUB/wp" "$STUB/identify"
}

# run the remote payload with FULL_BACKUP=$1 ("" or "1"); mode mirrors cmd_backup
run_backup() {
  local mode="placeholder"; [ "$1" = "1" ] && mode="full"
  { printf 'WP_ROOT=%q\nREMOTE_TMP=%q\nFULL_BACKUP=%q\nBACKUP_MODE=%q\nexport WP_ROOT REMOTE_TMP FULL_BACKUP BACKUP_MODE\n' \
      "$ROOT" "$OUT" "$1" "$mode"
    _backup_remote_script
  } | PATH="$STUB:$PATH" bash -s
}
in_tar() { tar -tzf "$OUT/wp-content.tar.gz" | grep -c "$1"; }

@test "light: produces all four artifacts incl. media_map" {
  run_backup ""
  [ -f "$OUT/db.sql" ]
  [ -f "$OUT/wp-content.tar.gz" ]
  [ -f "$OUT/media_map.txt" ]
  grep -q "BACKUP_MODE=placeholder" "$OUT/meta.env"
}

@test "light: media excluded from tar, mapped instead" {
  run_backup ""
  [ "$(in_tar 'uploads/2026/02/photo.jpg')" = "0" ]
  grep -q "uploads/2026/02/photo.jpg" "$OUT/media_map.txt"
}

@test "light: non-media (fonts, plugin css) kept" {
  run_backup ""
  [ "$(in_tar 'uploads/fonts/Brand-Regular.woff2')" -ge "1" ]
  [ "$(in_tar 'plugins/elementor/css/post-9.css')" -ge "1" ]
}

@test "full: no media_map, BACKUP_MODE=full, real media kept" {
  run_backup "1"
  [ ! -f "$OUT/media_map.txt" ]
  grep -q "BACKUP_MODE=full" "$OUT/meta.env"
  [ "$(in_tar 'uploads/2026/02/photo.jpg')" -ge "1" ]
}

@test "wp-staging .wpstg pruned in BOTH modes (incl. multisite)" {
  run_backup ""
  [ "$(in_tar '\.wpstg$')" = "0" ]
  [ "$(in_tar 'sites/2/wp-staging')" = "0" ]
  rm -rf "$OUT"
  run_backup "1"
  [ "$(in_tar '\.wpstg$')" = "0" ]
}

@test "top-level cache + advanced-cache.php drop-in pruned" {
  run_backup ""
  [ "$(in_tar 'wp-content/cache/')" = "0" ]
  [ "$(in_tar 'advanced-cache.php')" = "0" ]
}
