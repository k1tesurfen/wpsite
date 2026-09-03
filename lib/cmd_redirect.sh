# shellcheck shell=bash
# wpsite redirect <sub> <client> … — manage Apache/.htaccess redirects on a client's
# PRODUCTION server over SSH, as a replacement for the "Redirection" WP plugin.
#
# This is a production-writing command (same class as `apply`): every mutating
# subcommand backs up the remote .htaccess (remote copy + a local snapshot under
# <client_base>/redirects/), writes atomically, then verifies the home still responds
# and rolls back on a 5xx. Confirmation is [y/N] (default No) with --yes to bypass —
# lighter than `apply`'s typed-name because a redirect edit is fast and reversible.
#
# We only ever touch OUR OWN delimited block; WordPress's block and any hand-written
# rules are never modified. Rules are stored as mod_rewrite RewriteRules (not mod_alias
# Redirect) so regex + capture groups port straight over from the plugin (both use PCRE).
# Each rule carries a machine-readable "# wpsite-rule<TAB>…" marker so list/merge/remove
# round-trip losslessly.
#
#   wpsite redirect list    <client>
#   wpsite redirect add     <client> <source> <target> [--code 301|302|307|308] [--yes]
#   wpsite redirect import  <client> <file.csv> [--replace] [--deactivate-plugin] [--yes]
#   wpsite redirect migrate <client> [--replace] [--deactivate-plugin] [--yes]
#   wpsite redirect remove  <client> <source> [--yes]

REDIRECT_BEGIN="# BEGIN wpsite-redirects"
REDIRECT_END="# END wpsite-redirects"

_redirect_usage() {
  cat >&2 <<'EOF'
wpsite redirect — manage .htaccess redirects on a client's production server

  list    <client> [--porcelain]            Show the wpsite-managed redirects
                                            (--porcelain: tab lines to stdout, for tools)
  add     <client> <source> <target>        Add/update a single redirect
          [--code 301|302|307|308] [--yes]
  import  <client> <file.csv>               Import redirects from a CSV
          [--replace] [--deactivate-plugin] [--yes]
  migrate <client>                          Import existing redirects from the
          [--replace] [--deactivate-plugin]   Redirection plugin (all groups)
          [--yes]
  remove  <client> <source> [--yes]         Remove a redirect by its source

CSV columns: source,target,code,regex   (a header row is auto-detected; # comments and
blank lines are ignored; code defaults to 301; regex 1/0 defaults to 0). Targets starting
http:// or https:// are treated as external; otherwise the source/target are site paths.
Rows with a query-string source, or migrated redirects with conditional/complex match
types, are skipped and written to <client_base>/redirects/<stamp>.skipped.txt.
EOF
}

# --- pure string helpers ---------------------------------------------------

_redirect_trim() { # string
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Escape regex metacharacters so a literal path becomes a safe anchored pattern.
_redirect_regex_escape() { # string
  local s="$1" out="" c i
  for (( i=0; i<${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      '.'|'^'|'$'|'*'|'+'|'?'|'('|')'|'['|']'|'{'|'}'|'|'|\\) out+="\\$c" ;;
      *) out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

# Normalize a source for dedupe keying: drop leading + trailing slash.
_redirect_norm_source() { # source
  local s="$1"; s="${s#/}"; s="${s%/}"; printf '%s' "$s"
}

_redirect_key() { # source regex
  printf '%s|%s' "$(_redirect_norm_source "$1")" "${2:-0}"
}

# Build the RewriteRule pattern from a canonical source + regex flag.
_redirect_pattern() { # source regex
  local s="$1" rx="${2:-0}"
  if [ "$rx" = "1" ]; then
    # Author-supplied regex: strip a leading slash (RewriteRule in .htaccess matches
    # the path with the leading slash already removed), respect their own anchors.
    case "$s" in
      "^/"*) printf '^%s' "${s#^/}" ;;
      "/"*)  printf '%s'  "${s#/}"  ;;
      *)     printf '%s'  "$s"      ;;
    esac
  else
    # Literal path: strip surrounding slashes, escape, anchor, tolerate a trailing slash.
    s="${s#/}"; s="${s%/}"
    printf '^%s/?$' "$(_redirect_regex_escape "$s")"
  fi
}

# Normalize a target: full URL verbatim; otherwise ensure a leading slash (internal path).
_redirect_target() { # target
  local t="$1"
  case "$t" in
    http://*|https://*) printf '%s' "$t" ;;
    /*)                 printf '%s' "$t" ;;
    *)                  printf '/%s' "$t" ;;
  esac
}

# --- block <-> canonical-rules transforms ----------------------------------

# Emit the canonical tab rules (source<TAB>target<TAB>code<TAB>regex) recorded in our
# block's "# wpsite-rule" markers. Reads htaccess on stdin.
_redirect_extract_rules() {
  awk -v b="$REDIRECT_BEGIN" -v e="$REDIRECT_END" '
    $0==b {inb=1; next}
    $0==e {inb=0; next}
    inb && /^# wpsite-rule\t/ { sub(/^# wpsite-rule\t/, ""); print }
  '
}

# Print htaccess (stdin) with our managed block removed.
_redirect_strip_block() {
  awk -v b="$REDIRECT_BEGIN" -v e="$REDIRECT_END" '
    $0==b {skip=1; next}
    $0==e {skip=0; next}
    !skip {print}
  '
}

# Build the full managed block from a canonical rules file.
_redirect_build_block() { # rules_file
  local f="$1" src tgt code rx
  printf '%s\n' "$REDIRECT_BEGIN"
  printf '%s\n' "# Managed by wpsite (wpsite redirect …). Do not edit by hand — changes are overwritten."
  printf '%s\n' "<IfModule mod_rewrite.c>"
  printf '%s\n' "RewriteEngine On"
  while IFS=$'\t' read -r src tgt code rx; do
    [ -n "$src" ] || continue
    printf '# wpsite-rule\t%s\t%s\t%s\t%s\n' "$src" "$tgt" "$code" "${rx:-0}"
    printf 'RewriteRule %s %s [R=%s,L]\n' \
      "$(_redirect_pattern "$src" "${rx:-0}")" "$(_redirect_target "$tgt")" "$code"
  done < "$f"
  printf '%s\n' "</IfModule>"
  printf '%s\n' "$REDIRECT_END"
}

# Compose a new htaccess: insert the block (block_file) before "# BEGIN WordPress" in the
# body (body_file); if WordPress's block isn't present, prepend the block at the top.
_redirect_compose() { # body_file block_file
  local body="$1" block="$2"
  if grep -q '^# BEGIN WordPress' "$body"; then
    awk -v bf="$block" '
      BEGIN { while ((getline l < bf) > 0) blk = blk l "\n" }
      /^# BEGIN WordPress/ && !ins { printf "%s", blk; ins=1 }
      { print }
    ' "$body"
  else
    cat "$block"
    printf '\n'
    cat "$body"
  fi
}

# Prefix each canonical rule (stdin) with its dedupe key: KEY<TAB>source<TAB>…
_redirect_keyed() {
  local src tgt code rx
  while IFS=$'\t' read -r src tgt code rx; do
    [ -n "$src" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$(_redirect_key "$src" "${rx:-0}")" "$src" "$tgt" "$code" "${rx:-0}"
  done
  return 0
}

# Merge existing + new canonical rules, deduped by (normalized source, regex); new wins,
# insertion order preserved (existing first, then new). Dedup runs in awk so we stay
# bash-3.2 compatible (no associative arrays). Reads two files.
_redirect_merge() { # existing_file new_file
  { _redirect_keyed < "$1"; _redirect_keyed < "$2"; } | awk -F'\t' '
    { key=$1; line=substr($0, index($0, "\t")+1)
      if (!(key in val)) order[++n]=key
      val[key]=line }
    END { for (i=1; i<=n; i++) print val[order[i]] }
  '
  return 0
}

# Print existing rules (file) minus any whose normalized source matches the given source.
_redirect_filter_out() { # existing_file source
  local want; want="$(_redirect_norm_source "$2")"
  local src tgt code rx
  while IFS=$'\t' read -r src tgt code rx; do
    [ -n "$src" ] || continue
    [ "$(_redirect_norm_source "$src")" = "$want" ] && continue
    printf '%s\t%s\t%s\t%s\n' "$src" "$tgt" "$code" "${rx:-0}"
  done < "$1"
  return 0
}

# Pretty-print canonical rules (file) for a human summary.
_redirect_print_rules() { # rules_file
  local src tgt code rx tag i=0
  while IFS=$'\t' read -r src tgt code rx; do
    [ -n "$src" ] || continue
    i=$((i+1))
    tag="$code"; [ "${rx:-0}" = "1" ] && tag="$code, regex"
    printf '    %s  →  %s  (%s)\n' "$src" "$tgt" "$tag"
  done < "$1"
  [ "$i" = "0" ] && printf '    (none)\n'
  return 0
}

# --- CSV + plugin parsing --------------------------------------------------

# Parse a CSV (source,target,code,regex) into canonical tab rules on stdout. Rows that
# cannot become a plain RewriteRule are appended to skip_file as "source<TAB>reason".
_redirect_parse_csv() { # csv_file skip_file
  local file="$1" skip="$2"
  local first=1 line src tgt code rx rest lc
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    IFS=',' read -r src tgt code rx rest <<< "$line"
    src="$(_redirect_trim "${src:-}")"
    tgt="$(_redirect_trim "${tgt:-}")"
    code="$(_redirect_trim "${code:-}")"
    rx="$(_redirect_trim "${rx:-}")"
    if [ "$first" = "1" ]; then
      first=0
      lc="$(printf '%s' "$src" | tr '[:upper:]' '[:lower:]')"
      [ "$lc" = "source" ] && continue
    fi
    [ -n "$src" ] || continue
    if [ -z "$tgt" ]; then
      printf '%s\tempty target\n' "$src" >> "$skip"; continue
    fi
    case "$(printf '%s' "$rx" | tr '[:upper:]' '[:lower:]')" in
      1|true|yes|y|regex) rx=1 ;;
      *)                  rx=0 ;;
    esac
    case "$code" in 301|302|307|308) : ;; *) code=301 ;; esac
    if [ "$rx" = "0" ] && [[ "$src" == *"?"* ]]; then
      printf '%s\tquery string (needs RewriteCond)\n' "$src" >> "$skip"; continue
    fi
    printf '%s\t%s\t%s\t%s\n' "$src" "$tgt" "$code" "$rx"
  done < "$file"
  return 0
}

# Read migratable redirects out of the Redirection plugin's DB tables (all groups) into
# canonical tab rules on stdout. Non-simple entries go to skip_file with a reason.
_redirect_migrate_fetch() { # client skip_file
  local client="$1" skip="$2" t root prefix tbl check rows
  t="$(client_get "$client" ssh)"; root="$(client_get "$client" wp_root)"
  prefix="$(_prod_wp "$t" "$root" config get table_prefix 2>/dev/null | tr -d '\r' || true)"
  [ -n "$prefix" ] || prefix="wp_"
  tbl="${prefix}redirection_items"
  check="$(_prod_wp "$t" "$root" db query "SHOW TABLES LIKE '$tbl'" --skip-column-names 2>/dev/null | tr -d '\r' || true)"
  [ -n "$check" ] || die "Redirection plugin tables not found ($tbl). Is the plugin installed on '$client'?"
  rows="$(_prod_wp "$t" "$root" db query \
    "SELECT url, action_data, action_code, regex, match_type, action_type, status FROM $tbl" \
    --skip-column-names 2>/dev/null | tr -d '\r' || true)"
  local url data code rx mt at st
  while IFS=$'\t' read -r url data code rx mt at st; do
    [ -n "$url" ] || continue
    [ "$st" = "enabled" ]   || { printf '%s\tstatus=%s\n' "$url" "$st" >> "$skip"; continue; }
    [ "$at" = "url" ]       || { printf '%s\taction_type=%s\n' "$url" "$at" >> "$skip"; continue; }
    [ "$mt" = "url" ]       || { printf '%s\tmatch_type=%s\n' "$url" "$mt" >> "$skip"; continue; }
    if [ -z "$data" ] || [ "$data" = "NULL" ]; then
      printf '%s\tempty target\n' "$url" >> "$skip"; continue
    fi
    case "$code" in ''|0|NULL) code=301 ;; esac
    case "$rx" in 1) rx=1 ;; *) rx=0 ;; esac
    printf '%s\t%s\t%s\t%s\n' "$url" "$data" "$code" "$rx"
  done <<< "$rows"
  return 0
}

# --- remote read / write (with backup + verify + rollback) -----------------

_redirect_htaccess_get() {    # ssh_target wp_root  -> stdout (empty if none)
  wpsite_ssh "$1" "cat '$2/.htaccess' 2>/dev/null || true"
}
_redirect_htaccess_exists() { # ssh_target wp_root
  wpsite_ssh "$1" "[ -f '$2/.htaccess' ]"
}

# [y/N] confirmation (default No, so a piped/non-TTY stdin aborts safely). --yes bypasses.
_redirect_confirm() { # prompt
  [ "${_RD_YES:-0}" = "1" ] && return 0
  printf '%s [y/N] ' "$1" >&2
  local ans=""
  read -r ans 2>/dev/null < /dev/tty || read -r ans 2>/dev/null || ans=""
  [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

# Write new_file to the remote .htaccess: snapshot (remote .bak + local), atomic write,
# then verify the home responds; roll back on a 5xx.
_redirect_push() { # client ssh_target wp_root new_file
  local client="$1" t="$2" root="$3" new_file="$4"
  local stamp rdir had=0 tmpname home code
  stamp="$(date +%Y%m%d_%H%M%S)"
  rdir="$(client_base "$client")/redirects"; mkdir -p "$rdir"
  if _redirect_htaccess_exists "$t" "$root"; then
    had=1
    _redirect_htaccess_get "$t" "$root" > "$rdir/$stamp.htaccess"
    wpsite_ssh "$t" "cp -f '$root/.htaccess' '$root/.htaccess.wpsite.bak-$stamp'" \
      || log_warn "Could not create a remote backup — continuing (local snapshot kept)."
  fi
  tmpname=".htaccess.wpsite.tmp.$$"
  if ! wpsite_ssh "$t" "cat > '$root/$tmpname' && mv '$root/$tmpname' '$root/.htaccess'" < "$new_file"; then
    die "Failed to write the remote .htaccess."
  fi
  home="$(_prod_wp "$t" "$root" option get home 2>/dev/null | tr -d '\r' || true)"
  code="000"
  [ -n "$home" ] && code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$home" 2>/dev/null || echo 000)"
  if [ "${code:0:1}" = "5" ]; then
    log_error "Home returned HTTP $code after the change — rolling back."
    if [ "$had" = "1" ]; then
      wpsite_ssh "$t" "mv -f '$root/.htaccess.wpsite.bak-$stamp' '$root/.htaccess'" \
        || log_error "  ROLLBACK FAILED — restore manually from $rdir/$stamp.htaccess"
    else
      wpsite_ssh "$t" "rm -f '$root/.htaccess'"
    fi
    return 1
  fi
  log_ok "Wrote .htaccess (home HTTP $code). Local backup: $rdir/$stamp.htaccess"
  [ "$had" = "1" ] && log_info "Remote backup: $root/.htaccess.wpsite.bak-$stamp"
  return 0
}

# Core mutate-and-write orchestrator. Reads the remote htaccess once, computes the final
# rule set per mode, shows a summary, confirms, then writes with backup/verify/rollback.
_redirect_commit() { # client mode arg   (mode: merge|replace|remove; arg: rules_file|source)
  local client="$1" mode="$2" arg="$3" t root
  t="$(client_get "$client" ssh)"; root="$(client_get "$client" wp_root)"
  [ -n "$t" ] && [ -n "$root" ] || die "clients.$client.ssh / wp_root not set."

  ssh_setup_mux
  trap 'ssh_close_mux' EXIT

  local cur existing final body block newh
  cur="$(mktemp)"; existing="$(mktemp)"; final="$(mktemp)"
  body="$(mktemp)"; block="$(mktemp)"; newh="$(mktemp)"

  _redirect_htaccess_get "$t" "$root" > "$cur"
  _redirect_extract_rules < "$cur" > "$existing"

  case "$mode" in
    replace) cp "$arg" "$final" ;;
    merge)   _redirect_merge "$existing" "$arg" > "$final" ;;
    remove)  _redirect_filter_out "$existing" "$arg" > "$final" ;;
    *)       die "internal: bad commit mode '$mode'" ;;
  esac

  # No-op guard: nothing to write (identical content).
  if cmp -s "$existing" "$final"; then
    if [ "$mode" = "remove" ]; then
      log_warn "No redirect matching '$arg' — nothing to remove."
    else
      log_info "No changes — the redirects are already in place."
    fi
    rm -f "$cur" "$existing" "$final" "$body" "$block" "$newh"
    ssh_close_mux; trap - EXIT
    return 0
  fi

  local n_before n_after
  n_before="$(grep -c . "$existing" || true)"
  n_after="$(grep -c . "$final" || true)"
  log_info "Redirects for '$client': $n_before → $n_after rule(s). Result:"
  _redirect_print_rules "$final" >&2

  if ! _redirect_confirm "Apply to PRODUCTION ($t:$root/.htaccess)?"; then
    log_warn "Aborted — nothing written."
    rm -f "$cur" "$existing" "$final" "$body" "$block" "$newh"
    ssh_close_mux; trap - EXIT
    return 1
  fi

  _redirect_strip_block < "$cur" > "$body"
  if [ "$n_after" -gt 0 ]; then
    _redirect_build_block "$final" > "$block"
    _redirect_compose "$body" "$block" > "$newh"
  else
    cp "$body" "$newh"
  fi

  local rc=0
  if _redirect_push "$client" "$t" "$root" "$newh"; then
    log_ok "Redirects updated for '$client'."
    if [ "${_RD_DEACT:-0}" = "1" ]; then
      log_info "Deactivating the Redirection plugin on PRODUCTION..."
      if _prod_wp "$t" "$root" plugin deactivate redirection >/dev/null 2>&1; then
        log_ok "  Redirection plugin deactivated."
      else
        log_warn "  Could not deactivate the Redirection plugin — deactivate it manually."
      fi
    fi
  else
    rc=1
  fi

  rm -f "$cur" "$existing" "$final" "$body" "$block" "$newh"
  ssh_close_mux; trap - EXIT
  [ "$rc" = "0" ] || die "Redirect update failed and was rolled back."
  return 0
}

# --- subcommands -----------------------------------------------------------

_redirect_cmd_list() {
  local client="" porcelain=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --porcelain) porcelain=1; shift ;;   # canonical tab lines to stdout (for the GUI)
      -*)          die "Unknown flag: $1" ;;
      *)  if [ -z "$client" ]; then client="$1"; else die "Too many arguments."; fi; shift ;;
    esac
  done
  config_require; require_client "$client"
  local t root
  t="$(client_get "$client" ssh)"; root="$(client_get "$client" wp_root)"
  [ -n "$t" ] && [ -n "$root" ] || die "clients.$client.ssh / wp_root not set."

  ssh_setup_mux
  trap 'ssh_close_mux' EXIT

  local cur rules n foreign
  cur="$(mktemp)"; rules="$(mktemp)"
  _redirect_htaccess_get "$t" "$root" > "$cur"
  _redirect_extract_rules < "$cur" > "$rules"

  # Porcelain: just the canonical source<TAB>target<TAB>code<TAB>regex lines, no logging.
  if [ "$porcelain" = "1" ]; then
    cat "$rules"
    rm -f "$cur" "$rules"
    ssh_close_mux; trap - EXIT
    return 0
  fi

  n="$(grep -c . "$rules" || true)"
  log_info "wpsite-managed redirects for '$client' ($n):"
  _redirect_print_rules "$rules"

  # Warn about redirect/rewrite directives that live OUTSIDE our block and WP's block.
  foreign="$(_redirect_strip_block < "$cur" \
    | awk '/^# BEGIN WordPress/{s=1} /^# END WordPress/{s=0;next} !s' \
    | grep -E '^[[:space:]]*(Redirect(Match|Permanent|Temp)?|RewriteRule)[[:space:]]' || true)"
  if [ -n "$foreign" ]; then
    log_warn "Unmanaged redirect/rewrite directives also exist in .htaccess:"
    printf '%s\n' "$foreign" | sed 's/^/    /' >&2
  fi

  rm -f "$cur" "$rules"
  ssh_close_mux; trap - EXIT
}

_redirect_cmd_add() {
  local client="" source="" target="" code=301
  _RD_YES=0; _RD_DEACT=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --code)   code="${2:-}"; shift 2 ;;
      --yes|-y) _RD_YES=1; shift ;;
      -*)       die "Unknown flag: $1" ;;
      *)
        if   [ -z "$client" ]; then client="$1"
        elif [ -z "$source" ]; then source="$1"
        elif [ -z "$target" ]; then target="$1"
        else die "Too many arguments (see: wpsite redirect)."; fi
        shift ;;
    esac
  done
  [ -n "$client" ] && [ -n "$source" ] && [ -n "$target" ] \
    || die "Usage: wpsite redirect add <client> <source> <target> [--code 301|302|307|308] [--yes]"
  case "$code" in 301|302|307|308) : ;; *) die "Invalid --code: $code (use 301|302|307|308)." ;; esac
  config_require; require_client "$client"

  local nf; nf="$(mktemp)"
  printf '%s\t%s\t%s\t0\n' "$source" "$target" "$code" > "$nf"
  _redirect_commit "$client" merge "$nf"
  rm -f "$nf"
}

_redirect_cmd_import() {
  local client="" file="" replace=0
  _RD_YES=0; _RD_DEACT=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --replace)            replace=1; shift ;;
      --deactivate-plugin)  _RD_DEACT=1; shift ;;
      --yes|-y)             _RD_YES=1; shift ;;
      -*)                   die "Unknown flag: $1" ;;
      *)
        if   [ -z "$client" ]; then client="$1"
        elif [ -z "$file" ];   then file="$1"
        else die "Too many arguments."; fi
        shift ;;
    esac
  done
  [ -n "$client" ] && [ -n "$file" ] \
    || die "Usage: wpsite redirect import <client> <file.csv> [--replace] [--deactivate-plugin] [--yes]"
  [ -f "$file" ] || die "File not found: $file"
  config_require; require_client "$client"

  local nf skip nnew
  nf="$(mktemp)"
  skip="$(client_base "$client")/redirects/$(date +%Y%m%d_%H%M%S).skipped.txt"
  mkdir -p "$(dirname "$skip")"; : > "$skip"
  _redirect_parse_csv "$file" "$skip" > "$nf"
  nnew="$(grep -c . "$nf" || true)"
  if [ "$nnew" -le 0 ]; then
    [ -s "$skip" ] && log_warn "All rows skipped — see $skip"
    rm -f "$nf"
    die "No valid redirect rows found in $file."
  fi
  _redirect_commit "$client" "$([ "$replace" = "1" ] && echo replace || echo merge)" "$nf"
  if [ -s "$skip" ]; then
    log_warn "Skipped $(grep -c . "$skip" || true) row(s) needing manual handling → $skip"
  else
    rm -f "$skip"
  fi
  rm -f "$nf"
}

_redirect_cmd_migrate() {
  local client="" replace=0
  _RD_YES=0; _RD_DEACT=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --replace)            replace=1; shift ;;
      --deactivate-plugin)  _RD_DEACT=1; shift ;;
      --yes|-y)             _RD_YES=1; shift ;;
      -*)                   die "Unknown flag: $1" ;;
      *)  if [ -z "$client" ]; then client="$1"; else die "Too many arguments."; fi; shift ;;
    esac
  done
  [ -n "$client" ] || die "Usage: wpsite redirect migrate <client> [--replace] [--deactivate-plugin] [--yes]"
  config_require; require_client "$client"

  local nf skip nnew
  nf="$(mktemp)"
  skip="$(client_base "$client")/redirects/$(date +%Y%m%d_%H%M%S).skipped.txt"
  mkdir -p "$(dirname "$skip")"; : > "$skip"

  ssh_setup_mux
  trap 'ssh_close_mux' EXIT
  log_info "Reading redirects from the Redirection plugin on '$client' (all groups)..."
  _redirect_migrate_fetch "$client" "$skip" > "$nf"
  ssh_close_mux; trap - EXIT

  nnew="$(grep -c . "$nf" || true)"
  log_info "Found $nnew simple redirect(s) suitable for .htaccess."
  if [ "$nnew" -le 0 ]; then
    [ -s "$skip" ] && log_warn "Nothing migratable — see skipped: $skip"
    rm -f "$nf"
    die "No migratable redirects found for '$client'."
  fi
  _redirect_commit "$client" "$([ "$replace" = "1" ] && echo replace || echo merge)" "$nf"
  if [ -s "$skip" ]; then
    log_warn "Skipped $(grep -c . "$skip" || true) redirect(s) (regex-conditional/query/complex) → $skip"
  else
    rm -f "$skip"
  fi
  rm -f "$nf"
}

_redirect_cmd_remove() {
  local client="" source=""
  _RD_YES=0; _RD_DEACT=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes|-y) _RD_YES=1; shift ;;
      -*)       die "Unknown flag: $1" ;;
      *)
        if   [ -z "$client" ]; then client="$1"
        elif [ -z "$source" ]; then source="$1"
        else die "Too many arguments."; fi
        shift ;;
    esac
  done
  [ -n "$client" ] && [ -n "$source" ] || die "Usage: wpsite redirect remove <client> <source> [--yes]"
  config_require; require_client "$client"
  _redirect_commit "$client" remove "$source"
}

cmd_redirect() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    ""|-h|--help)      _redirect_usage ;;
    list)              _redirect_cmd_list "$@" ;;
    add)               _redirect_cmd_add "$@" ;;
    import)            _redirect_cmd_import "$@" ;;
    migrate)           _redirect_cmd_migrate "$@" ;;
    remove|rm|delete)  _redirect_cmd_remove "$@" ;;
    -*)                die "Unknown flag: $sub" ;;
    *)                 die "Unknown redirect subcommand: $sub (list|add|import|migrate|remove)" ;;
  esac
}
