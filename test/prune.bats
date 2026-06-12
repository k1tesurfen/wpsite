#!/usr/bin/env bats
# Backup retention: --keep, --older-than, --all, default policy, safety/preview.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  command -v yq >/dev/null 2>&1 || skip "yq not installed"

  # A throwaway base_dir + config for this test.
  BASE="$BATS_TEST_TMPDIR/root"
  CFG="$BATS_TEST_TMPDIR/wpsite.yml"
  cat > "$CFG" <<EOF
base_dir: $BASE
clients:
  acme:
    ssh: u@acme
    wp_root: /var/www/acme
  baker:
    ssh: u@baker
    wp_root: /var/www/html
EOF
  export WPSITE_CONFIG="$CFG"
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_prune.sh"
}

# Create N backups for a client with increasing mtimes (oldest first); the dir
# name encodes order. $1=client, then a list of "name age_days" pairs.
mkbackup() { # client name age_days
  local d="$BASE/$1/backups/$2"
  mkdir -p "$d"; echo x > "$d/db.sql"
  # set mtime to now - age_days
  touch -t "$(date -v -"$3"d +%Y%m%d0000)" "$d" 2>/dev/null \
    || touch -d "-$3 days" "$d" 2>/dev/null || true
}

@test "_prune_days parses d / w / bare" {
  [ "$(_prune_days 30d)" = "30" ]
  [ "$(_prune_days 2w)" = "14" ]
  [ "$(_prune_days 7)" = "7" ]
  run _prune_days "junk"; [ "$status" -ne 0 ]
}

@test "--keep keeps the newest N, deletes the rest (dry-run preview)" {
  for i in 1 2 3 4 5; do mkbackup acme "2026010$i" "$(( 10 - i ))"; done
  run env WPSITE_CONFIG="$CFG" "$REPO/bin/wpsite" prune acme --keep 2 --dry-run
  [ "$status" -eq 0 ]
  # newest two (20260105, 20260104) must NOT appear; older ones must
  [[ "$output" != *20260105* ]]
  [[ "$output" != *20260104* ]]
  [[ "$output" == *20260101* ]]
  [[ "$output" == *"dry run"* ]]
}

@test "--keep N actually deletes when --yes, leaving exactly N" {
  for i in 1 2 3 4 5; do mkbackup acme "2026010$i" "$(( 10 - i ))"; done
  run env WPSITE_CONFIG="$CFG" "$REPO/bin/wpsite" prune acme --keep 2 --yes
  [ "$status" -eq 0 ]
  [ "$(find "$BASE/acme/backups" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" = "2" ]
  [ -d "$BASE/acme/backups/20260105" ]   # newest kept
  [ ! -d "$BASE/acme/backups/20260101" ] # oldest gone
}

@test "--older-than deletes only old backups" {
  mkbackup acme fresh 1
  mkbackup acme stale 100
  run env WPSITE_CONFIG="$CFG" "$REPO/bin/wpsite" prune acme --older-than 30d --yes
  [ "$status" -eq 0 ]
  [ -d "$BASE/acme/backups/fresh" ]
  [ ! -d "$BASE/acme/backups/stale" ]
}

@test "--keep protects newest even if old; --older-than only trims the rest" {
  mkbackup acme oldest 100
  mkbackup acme middle 80
  mkbackup acme newest 60
  run env WPSITE_CONFIG="$CFG" "$REPO/bin/wpsite" prune acme --keep 1 --older-than 30d --yes
  [ "$status" -eq 0 ]
  [ -d "$BASE/acme/backups/newest" ]      # protected by --keep 1
  [ ! -d "$BASE/acme/backups/oldest" ]
  [ ! -d "$BASE/acme/backups/middle" ]
}

@test "--all prunes every configured client" {
  for i in 1 2 3; do mkbackup acme "ac$i" "$(( 9 - i ))"; mkbackup baker "bk$i" "$(( 9 - i ))"; done
  run env WPSITE_CONFIG="$CFG" "$REPO/bin/wpsite" prune --all --keep 1 --yes
  [ "$status" -eq 0 ]
  [ "$(find "$BASE/acme/backups"  -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" = "1" ]
  [ "$(find "$BASE/baker/backups" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" = "1" ]
}

@test "nothing to prune is a clean no-op" {
  mkbackup acme only 1
  run env WPSITE_CONFIG="$CFG" "$REPO/bin/wpsite" prune acme --keep 5 --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to prune"* ]]
  [ -d "$BASE/acme/backups/only" ]
}

@test "requires a client or --all" {
  run env WPSITE_CONFIG="$CFG" "$REPO/bin/wpsite" prune --keep 2
  [ "$status" -ne 0 ]
  [[ "$output" == *"Specify a <client>"* ]]
}
