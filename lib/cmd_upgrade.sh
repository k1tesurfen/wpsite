# shellcheck shell=bash
# wpsite upgrade <client> — run WP-CLI core/plugin/theme updates on the RUNNING
# replica and write a before→after report. Local only; never touches production.
# Fully reversible: a bad upgrade is just `wpsite build <client>` away from a reset.

# wp-cli in a client's app container. Runs without --skip-plugins/--skip-themes
# to ensure third-party update-checkers boot fully and capture premium updates.
_upgrade_wp() { # app_container args...
  local app="$1"; shift
  docker exec "$app" php -d memory_limit=512M -d max_execution_time=300 /usr/local/bin/wp --allow-root --path=/var/www/html "$@"
}

# --- Active-plugin reconciliation -------------------------------------------
# An update can leave a plugin DEACTIVATED: a failed upgrade routine, WP's own
# fatal-error protection, or a plugin deactivating itself. Nothing used to notice.
# The before/after CSVs recorded name,version,update but never `status`, and every
# update call sent stdout AND stderr to /dev/null — so a silently dropped plugin
# left no trace at all. Seen in the wild: wp-mail-smtp went inactive during a
# production apply and was caught only because the verification mail never arrived.
#
# `status` is appended as the LAST CSV field on purpose — _report_section and
# _report_section_de index $2/$3 and join -o '1.1,1.2,2.2', so adding a leading
# field would silently shift every existing version diff.
WPSITE_PLUGIN_FIELDS="name,version,update,status"

# Active plugins in a name,version,update,status CSV → "name<TAB>status" per line.
# Tolerates the older 3-field CSVs (no $4 → no output), so an upgrade dir written
# by an earlier wpsite still renders. Quoted names ("foo (old)") are unquoted.
_active_plugins_from_csv() { # csv
  [ -f "$1" ] || return 0
  tail -n +2 "$1" 2>/dev/null | awk -F, '
    $4=="active" || $4=="active-network" {
      name=$1; gsub(/^"|"$/,"",name); printf "%s\t%s\n", name, $4
    }' || true
  return 0
}

# Restore plugins that were active BEFORE the run and are not active after.
# Each candidate is activated, then WP is booted once (`wp eval` loads every active
# plugin) to prove the site still comes up. A plugin that fatals is deactivated
# again and reported for manual investigation rather than left breaking the site —
# that is the accident-vs-error split: only what boots cleanly is auto-healed.
# Writes "<result><TAB><name><TAB><detail>" per candidate to <outfile>.
# The runner ("$@") is the wp driver plus its fixed args: `_upgrade_wp <container>`
# locally, `_prod_wp <ssh_target> <wp_root>` on production — so both paths share
# this logic and can't drift.
# Returns non-zero when at least one plugin could NOT be restored.
_reconcile_active_plugins() { # before_csv after_csv logfile outfile runner...
  local before="$1" after="$2" logf="$3" outf="$4"; shift 4
  : > "$outf"
  [ -f "$before" ] || return 0

  local tmp; tmp="$(mktemp -d)"
  _active_plugins_from_csv "$before" > "$tmp/b"
  _active_plugins_from_csv "$after"  > "$tmp/a"
  # Active before, absent from the after-set. Keyed on the NAME only: a plugin that
  # merely dropped from active-network to active is still running, not lost.
  # awk, not a bash associative array — the codebase stays bash-3.2 compatible.
  # NOT the usual NR==FNR two-file idiom: when the after-set is EMPTY (every active
  # plugin dropped out) NR==FNR is still true for the first line of the second file,
  # so the loss would be silently swallowed. Reading the after-set in BEGIN via
  # getline is empty-file-safe.
  local lost_raw
  lost_raw="$(awk -F'\t' -v afile="$tmp/a" '
    BEGIN { while ((getline line < afile) > 0) { split(line, f, "\t"); seen[f[1]]=1 } }
    !($1 in seen)
  ' "$tmp/b" || true)"
  rm -rf "$tmp"

  # Collect into an array FIRST. The runner may be ssh (apply), and ssh reads stdin —
  # driven from inside a `while read` loop it would swallow the remaining candidates,
  # the same trap that forces ffmpeg's -nostdin in _gen_placeholder. Every runner
  # call below also gets </dev/null for the same reason.
  local lost=() line
  while IFS= read -r line; do [ -n "$line" ] && lost+=("$line"); done <<EOF
$lost_raw
EOF
  # bash 3.2: "${lost[@]}" on an empty array trips set -u, so bail out before it.
  [ "${#lost[@]}" -eq 0 ] && return 0

  local failed=0 name st entry activated
  log_warn "${#lost[@]} plugin(s) went INACTIVE during the update — reconciling..."

  # Baseline: does the site boot AT ALL before we touch anything? Without this, a
  # PRE-EXISTING fatal (a prod-only plugin, a broken drop-in, a half-applied update)
  # is blamed on whichever plugin we happen to reactivate first, and a perfectly
  # healthy plugin gets left switched off for a fault that was never its own.
  local bootable=1
  "$@" eval 'echo "WPSITE_BOOT_OK";' >> "$logf" 2>&1 < /dev/null || bootable=0
  [ "$bootable" = 1 ] \
    || log_warn "  site does NOT boot cleanly before reconciliation — boot checks disabled"
  for entry in "${lost[@]}"; do
    name="$(printf '%s' "$entry" | cut -f1)"   # cut's default delimiter is TAB
    st="$(printf '%s' "$entry" | cut -f2)"
    [ -n "$name" ] || continue
    printf '\n--- reconcile: activating %s (was %s) ---\n' "$name" "$st" >> "$logf"
    activated=0
    if [ "$st" = "active-network" ]; then
      "$@" plugin activate "$name" --network >> "$logf" 2>&1 < /dev/null && activated=1
    else
      "$@" plugin activate "$name" >> "$logf" 2>&1 < /dev/null && activated=1
    fi
    if [ "$activated" != 1 ]; then
      printf 'FAILED\t%s\tactivation refused — see update.log\n' "$name" >> "$outf"
      log_error "  $name: could not be reactivated — investigate by hand"
      failed=1
      continue
    fi
    if [ "$bootable" != 1 ]; then
      printf 'UNVERIFIED\t%s\treactivated, but the site already failed to boot beforehand\n' "$name" >> "$outf"
      log_warn "  $name: reactivated, but the boot check is unusable — verify by hand"
      failed=1
      continue
    fi
    # Boot check: `wp eval` loads every active plugin, so a fatal surfaces here.
    if "$@" eval 'echo "WPSITE_BOOT_OK";' >> "$logf" 2>&1 < /dev/null; then
      printf 'REACTIVATED\t%s\tno error on boot\n' "$name" >> "$outf"
      log_ok "  $name: reactivated (site still boots)"
    else
      "$@" plugin deactivate "$name" --skip-plugins >> "$logf" 2>&1 < /dev/null || true
      printf 'FAILED\t%s\tfatal error on boot — left DEACTIVATED\n' "$name" >> "$outf"
      log_error "  $name: fatals on load — left deactivated, investigate by hand"
      failed=1
    fi
  done
  [ "$failed" = 0 ]
}

# Report block for the reconciliation file. Silent when nothing went inactive.
_report_reconcile() { # reconcile.txt
  [ -s "$1" ] || return 0
  echo
  echo "Plugin activation state:"
  awk -F'\t' '
    $1=="REACTIVATED" {printf "  ↻ %s — went inactive during the update, reactivated OK\n",$2}
    $1=="FAILED"      {printf "  ✗ %s — went inactive and could NOT be restored: %s\n",$2,$3}
    $1=="UNVERIFIED"  {printf "  ? %s — %s; verify by hand\n",$2,$3}
  ' "$1"
  return 0
}

# Render the changed + still-pending items for one section (plugins or themes) by
# diffing two `name,version,update` CSVs (wp-cli --format=csv, header on line 1).
_report_section() { # before.csv after.csv
  local before="$1" after="$2" tmp changed pending
  tmp="$(mktemp -d)"
  tail -n +2 "$before" 2>/dev/null | sort -t, -k1,1 > "$tmp/b"
  tail -n +2 "$after"  2>/dev/null | sort -t, -k1,1 > "$tmp/a"
  # name, before-version, after-version  → list where the version changed
  changed="$(join -t, -j1 -o '1.1,1.2,2.2' "$tmp/b" "$tmp/a" 2>/dev/null \
    | awk -F, '$2!=$3 {printf "  • %s: %s → %s\n",$1,$2,$3}')"
  # after rows still showing an available update → not applied (premium / failed)
  pending="$(awk -F, '$3=="available" {printf "  ! %s (%s) — update still available, not applied (premium? handle manually)\n",$1,$2}' "$tmp/a")"
  rm -rf "$tmp"
  if [ -n "$changed" ]; then printf '%s\n' "$changed"; else echo "  (none updated)"; fi
  [ -n "$pending" ] && printf '%s\n' "$pending"
  return 0
}

# Human-readable report to stdout (also tee'd to report.txt by the caller).
_upgrade_report() { # client stamp core_before core_after dir
  local client="$1" stamp="$2" cb="$3" ca="$4" dir="$5"
  echo "wpsite upgrade report — $client — $stamp"
  echo "=================================================================="
  echo
  if [ "$cb" = "$ca" ]; then
    echo "WordPress core:  $cb  (no change)"
  else
    echo "WordPress core:  $cb → $ca"
  fi
  echo
  local oc="$dir/updates.outcome.tsv" client_id="${client%% *}"
  echo "Plugins:"
  if [ -f "$oc" ]; then _report_outcome "$oc" plugin "$client_id"
  else _report_section "$dir/plugins.before.csv" "$dir/plugins.after.csv"; fi
  echo
  echo "Themes:"
  if [ -f "$oc" ]; then _report_outcome "$oc" theme "$client_id"
  else _report_section "$dir/themes.before.csv" "$dir/themes.after.csv"; fi
  [ -f "$oc" ] && _report_manual "$oc"
  _report_reconcile "$dir/plugins.reconcile.txt"
}

_report_section_de() { # before.csv after.csv
  # The CUSTOMER report lists only what was actually updated. Held / no-package / manual /
  # failed items are left out on purpose (internal matters, see report.txt), and it never
  # claims "bereits aktuell" — WP-CLI can't see every update (e.g. Greyd's theme).
  local before="$1" after="$2" tmp changed
  tmp="$(mktemp -d)"
  tail -n +2 "$before" 2>/dev/null | sort -t, -k1,1 > "$tmp/b"
  tail -n +2 "$after"  2>/dev/null | sort -t, -k1,1 > "$tmp/a"
  changed="$(join -t, -j1 -o '1.1,1.2,2.2' "$tmp/b" "$tmp/a" 2>/dev/null \
    | awk -F, '$2!=$3 {printf "    ✓ %s: %s —> %s\n",$1,$2,$3}')"
  rm -rf "$tmp"
  if [ -n "$changed" ]; then printf '%s\n' "$changed"; else echo "    Keine Änderungen"; fi
  return 0
}

# Plugins we NEVER auto-update — in the local `upgrade` rehearsal and on `apply`
# alike. One list for both paths so they can't drift; empty output = update it.
# Note these are EXACT slugs: the free `wp-staging` is a different plugin and IS
# updated. Deactivation is a separate concern (_sanitize_plugins in cmd_build.sh);
# these stay active, we just don't let the updater touch them.
_plugin_update_skip_reason() { # slug
  case "$1" in
    # Premium: its updater needs a logged-in user and the credentials rotate.
    wp-staging-pro) printf 'premium, no auto-update' ;;
    # Our own plugin: we ship it ourselves (wpsite inject / by hand), so an updater
    # run would at best be a no-op and at worst overwrite it with an unrelated
    # wp.org plugin that happens to share the slug.
    aule)           printf 'our own plugin, updated by hand' ;;
  esac
  return 0
}

# The client a run belongs to (upgrade/apply set it) — for its hold list.
_WPSITE_RUN_CLIENT=""

# Why <name> must not be auto-updated in this run, or empty. The global list above
# (plugins only) + the client's hold list in wpsite's registry (`wpsite hold`), which
# covers plugin AND theme slugs.
_update_skip_reason() { # kind name
  local r=""
  [ "$1" = plugin ] && r="$(_plugin_update_skip_reason "$2")"
  if [ -z "$r" ] && [ -n "$_WPSITE_RUN_CLIENT" ] && wclient_map_has "$_WPSITE_RUN_CLIENT" hold_plugins "$2"; then
    r="held: $(wclient_map_get "$_WPSITE_RUN_CLIENT" hold_plugins "$2")"
  fi
  printf '%s' "$r"
  return 0
}

# --- Update run + its log ----------------------------------------------------
# update.log must let a run be reconstructed AFTER the fact, from local files alone
# (production may since have been fixed by hand). It used to hold only raw wp-cli
# output: no command, no time, no exit code, and neither the list the loop iterated
# nor any skip decision. On bauklimaneutral (apply 20260923_105427) six plugins the
# before-snapshot flagged as updatable were never even attempted, and the log could
# not say why. So every call is a labelled section and every decision a note.

# One wp-cli call as a labelled, timestamped section of <logfile>; returns its exit code.
_ulog() { # logfile label runner...
  local logf="$1" label="$2"; shift 2
  local rc=0
  printf '\n=== %s  %s\n' "$(date '+%F %T')" "$label" >> "$logf"
  "$@" >> "$logf" 2>&1 || rc=$?
  printf '=== exit %s\n' "$rc" >> "$logf"
  return "$rc"
}

# A decision (plan entry, skip, miss) as a single line of <logfile>.
_ulog_note() { # logfile message
  printf -- '--- %s  %s\n' "$(date '+%F %T')" "$2" >> "$1"
  return 0
}

# Drop WordPress's cached update data and re-query plugin + theme updates, logging
# what came back. `core update` invalidates this cache, and a list taken straight
# afterwards can come back WITHOUT the wp.org entries — third-party updaters that
# inject their data live (greyd) still show up, which hides the gap. Never fatal.
_refresh_update_cache() { # logfile runner...
  local logf="$1"; shift
  # shellcheck disable=SC2016  # PHP source: the $vars are PHP's, not the shell's
  _ulog "$logf" "refresh update cache" "$@" eval '
    wp_clean_update_cache(); wp_update_plugins(); wp_update_themes();
    $p = get_site_transient("update_plugins"); $t = get_site_transient("update_themes");
    echo "plugins with updates: ", implode(" ", array_keys((array) ($p->response ?? array()))), "\n";
    echo "themes with updates:  ", implode(" ", array_keys((array) ($t->response ?? array()))), "\n";' \
    || log_warn "Could not refresh the update cache — see update.log"
  return 0
}

# Names flagged update=available in a name,version,update[,status] CSV.
_update_available_from_csv() { # csv
  [ -f "$1" ] || return 0
  tail -n +2 "$1" 2>/dev/null | awk -F, '$3=="available" { n=$1; gsub(/^"|"$/,"",n); print n }' || true
  return 0
}

# The update candidates for <kind> (plugin|theme): everything the BEFORE snapshot
# flagged update=available, plus whatever a fresh --update=available query reports.
# Taking the union means a flaky post-core-update query can no longer silently shrink
# the run. Every candidate is noted in the log with where it came from.
_update_plan() { # kind before_csv logfile runner...
  local kind="$1" csv="$2" logf="$3"; shift 3
  local before fresh raw n src
  before="$(_update_available_from_csv "$csv")"
  raw="$("$@" "$kind" list --update=available --field=name 2>>"$logf" | tr -d '\r' || true)"
  # Keep slug-shaped lines only: a PHP notice printed to stdout must not become a slug.
  fresh="$(printf '%s\n' "$raw" | grep -E '^[A-Za-z0-9._-]+$' || true)"
  _ulog_note "$logf" "$kind plan: before-snapshot=[$(printf '%s' "$before" | tr '\n' ' ')] fresh-query=[$(printf '%s' "$fresh" | tr '\n' ' ')]"
  { printf '%s\n' "$before"; printf '%s\n' "$fresh"; } | awk 'NF && !seen[$0]++' | while IFS= read -r n; do
    case $'\n'"$fresh"$'\n' in
      *$'\n'"$n"$'\n'*) src="reported by fresh query" ;;
      *)                src="ONLY in before-snapshot — fresh query missed it" ;;
    esac
    _ulog_note "$logf" "$kind plan: $n ($src)"
    printf '%s\n' "$n"
  done
  return 0
}

# Optional hook run after EVERY update step (core, update-db, each plugin/theme). `apply`
# sets it to re-arm the maintenance locks (WordPress's updater deletes .maintenance after
# each update); the local rehearsal leaves it empty.
_WPSITE_STEP_HOOK=""
_update_step_done() { [ -z "$_WPSITE_STEP_HOOK" ] || "$_WPSITE_STEP_HOOK" || true; return 0; }

# Does the site still boot? `wp eval` loads every active plugin, so a fatal surfaces here.
_site_boots() { # runner...
  "$@" eval 'echo "WPSITE_BOOT_OK";' 2>/dev/null < /dev/null | grep -q WPSITE_BOOT_OK
}

# Set by _run_updates when it stopped because the site no longer boots.
_WPSITE_UPDATES_BROKEN=0

# Core, plugin and theme updates — ONE implementation for the local rehearsal
# (`_upgrade_wp <container>`) and production (`_prod_wp <target> <root>`), so the two
# can't drift. Needs <dir>/plugins.before.csv + themes.before.csv already written.
# Updates run one-by-one (a failing plugin must not abort the cascade) — BUT after any
# failed update the site is boot-checked: still boots → carry on; doesn't → STOP (no
# further updates on a broken site), _WPSITE_UPDATES_BROKEN=1, return 2.
# Returns 0 all fine, 1 some update failed, 2 stopped because the site no longer boots.
_run_updates() { # dir is_multisite runner...
  local dir="$1" is_ms="$2"; shift 2
  local logf="$dir/update.log" rc=0 x skip list
  _WPSITE_UPDATES_BROKEN=0
  log_info "Updating WordPress core..."
  _ulog "$logf" "core update" "$@" core update || { rc=1; log_warn "core update failed"; }
  _update_step_done
  # Multisite migrates ALL subsites' tables → needs --network (which errors on single sites).
  if [ "$is_ms" = 1 ]; then
    _ulog "$logf" "core update-db --network" "$@" core update-db --network \
      || { rc=1; log_warn "core update-db --network failed"; }
  else
    _ulog "$logf" "core update-db" "$@" core update-db || { rc=1; log_warn "core update-db failed"; }
  fi
  _update_step_done
  if [ "$rc" != 0 ] && ! _site_boots "$@"; then
    _ulog_note "$logf" "STOP: site does not boot after the core update — no plugin/theme updates run"
    log_error "The site does not boot after the core update — stopping all further updates."
    _WPSITE_UPDATES_BROKEN=1; return 2
  fi
  _refresh_update_cache "$logf" "$@"

  local kind out ec
  for kind in plugin theme; do
    log_info "Updating ${kind}s..."
    # What WordPress knows BEFORE updating (an empty update_package = no download link —
    # licence/pro/custom): kept for the classification, see _classify_updates.
    "$@" "$kind" list --fields=name,update,update_version,update_package --format=csv \
      2>/dev/null < /dev/null | tr -d '\r' > "$dir/${kind}s.packages.csv" || true
    : > "$dir/${kind}s.attempts.tsv"
    list="$(_update_plan "$kind" "$dir/${kind}s.before.csv" "$logf" "$@")"
    [ -n "$list" ] || log_info "  All ${kind}s already up to date."
    for x in $list; do
      skip="$(_update_skip_reason "$kind" "$x")"
      if [ -n "$skip" ]; then
        log_info "  Skipping $x ($skip)"
        _ulog_note "$logf" "$kind skip: $x ($skip)"
        continue
      fi
      log_info "  Updating $kind: $x..."
      out="$(mktemp)"; ec=0
      _ulog "$logf" "$kind update $x" _run_to "$out" "$@" "$kind" update "$x" || ec=$?
      # name, exit code, fatal?, first error line — the raw material for the classes.
      printf '%s\t%s\t%s\t%s\n' "$x" "$ec" \
        "$(grep -qiE 'PHP Fatal error|Fatal error:' "$out" && echo 1 || echo 0)" \
        "$(grep -m1 -iE '^(Error|Warning|Fehler|PHP Fatal error)' "$out" | tr '\t' ' ' | cut -c1-200 || true)" \
        >> "$dir/${kind}s.attempts.tsv"
      rm -f "$out"
      if [ "$ec" != 0 ]; then
        rc=1; log_warn "  $kind update failed: $x"
        _update_step_done
        if ! _site_boots "$@"; then
          _ulog_note "$logf" "STOP: site does not boot after '$kind update $x' — no further updates run"
          log_error "The site does not boot after updating $x — stopping all further updates."
          _WPSITE_UPDATES_BROKEN=1; return 2
        fi
        _ulog_note "$logf" "boot check after failed '$kind update $x': site still boots — continuing"
        continue
      fi
      _update_step_done
    done
  done
  return "$rc"
}

# Run a command, copying its combined output to <file> as well as stdout; keeps its status.
# The status travels through a file, not PIPESTATUS: any DEBUG trap (bats has one) runs
# between the pipeline and the `return` and clobbers PIPESTATUS — every update then
# looked like exit 0.
_run_to() { # file cmd...
  local f="$1" rc; shift
  { local r=0; "$@" || r=$?; echo "$r" > "$f.rc"; } 2>&1 | tee "$f"
  rc="$(cat "$f.rc" 2>/dev/null || echo 1)"; rm -f "$f.rc"
  return "$rc"
}

# --- Why didn't it update? (HARDENING-PLAN.md Phase 4) ---------------------------------
# Every plugin/theme that had an update (or was attempted, or is held/manual) gets ONE
# class, locale-independent — derived from versions, exit codes, the PHP fatal marker and
# the update_package WordPress knew BEFORE the run, never from German/English wording:
#   updated      version changed
#   held         client hold list / global skip — not attempted, on purpose
#   no-package   not updated and WordPress had NO download package (licence/pro/custom)
#   refused      update call exit 0, version unchanged (the plugin's updater declined)
#   fatal        PHP fatal in the update output — a real bug
#   error        any other failure (download, filesystem, disk) — first error line kept
#   not-attempted  had an update but was never tried (the run stopped early)
#   manual       on the client's manual list (updates WP-CLI can't see) — reminder only
# Written to <dir>/updates.outcome.tsv: kind, name, class, from, to, detail.

# One column of the row whose (unquoted) first field is <name>, from a CSV with header.
_csv_col() { # file name col
  [ -f "$1" ] || return 0
  awk -F, -v n="$2" -v c="$3" 'NR>1 { x=$1; gsub(/^"|"$/,"",x); if (x==n) { v=$c; gsub(/^"|"$/,"",v); print v; exit } }' "$1" 2>/dev/null || true
}

_classify_updates() { # dir client
  local dir="$1" client="$2" out="$1/updates.outcome.tsv" kind name
  : > "$out"
  for kind in plugin theme; do
    local b="$dir/${kind}s.before.csv" a="$dir/${kind}s.after.csv" pk="$dir/${kind}s.packages.csv" at="$dir/${kind}s.attempts.tsv"
    local names
    names="$( { _update_available_from_csv "$b"
                awk -F, 'NR>1 && $2=="available" { x=$1; gsub(/^"|"$/,"",x); print x }' "$pk" 2>/dev/null
                cut -f1 "$at" 2>/dev/null; } | awk 'NF && !seen[$0]++' || true)"
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      local vb va to pkg skip row ec fatal err class detail=""
      vb="$(_csv_col "$b" "$name" 2)"; va="$(_csv_col "$a" "$name" 2)"
      to="$(_csv_col "$pk" "$name" 3)"; pkg="$(_csv_col "$pk" "$name" 4)"
      row="$(awk -F'\t' -v n="$name" '$1==n' "$at" 2>/dev/null | tail -1 || true)"
      skip="$(_WPSITE_RUN_CLIENT="$client" _update_skip_reason "$kind" "$name")"
      if [ -n "$va" ] && [ "$va" != "$vb" ]; then class=updated; to="$va"
      elif [ -n "$skip" ]; then class=held; detail="$skip"
      elif [ -n "$row" ]; then
        ec="$(printf '%s' "$row" | cut -f2)"; fatal="$(printf '%s' "$row" | cut -f3)"; err="$(printf '%s' "$row" | cut -f4)"
        if [ "$fatal" = 1 ]; then class=fatal; detail="$err"
        elif [ -z "$pkg" ]; then class=no-package; detail="${err:-WordPress had no download package}"
        elif [ "$ec" = 0 ]; then class=refused; detail="the update call succeeded but the version did not change"
        else class=error; detail="${err:-exit $ec}"
        fi
      else class=not-attempted; detail="had an update but was never tried (run stopped?)"
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$name" "$class" "$vb" "$to" "$detail" >> "$out"
    done <<< "$names"
  done
  # Manual reminders (either kind; version from whichever before-snapshot has it).
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    local v; v="$(_csv_col "$dir/plugins.before.csv" "$name" 2)"; [ -n "$v" ] || v="$(_csv_col "$dir/themes.before.csv" "$name" 2)"
    printf 'manual\t%s\tmanual\t%s\t\t%s\n' "$name" "$v" "$(wclient_map_get "$client" manual_updates "$name")" >> "$out"
  done < <(wclient_map_keys "$client" manual_updates)
  return 0
}

# Report lines for one kind from the outcome file (updated first, then everything else
# grouped with what to do about it).
_report_outcome() { # outcome.tsv kind client
  local f="$1" kind="$2" client="$3"
  awk -F'\t' -v k="$kind" '$1==k && $3=="updated" { printf "  • %s: %s → %s\n", $2, $4, $5; found=1 } END { exit !found }' "$f" || echo "  (none updated)"
  awk -F'\t' -v k="$kind" -v c="$client" '
    $1!=k || $3=="updated" { next }
    $3=="held"          { printf "  ⊘ %s (%s) — %s%s\n", $2, $4, $6, ($5 != "" ? "; " $5 " available" : "") }
    $3=="no-package"    { printf "  ! %s (%s → %s) — NO download package (licence/pro/custom?) — check it, then: wpsite hold %s %s\n", $2, $4, $5, c, $2 }
    $3=="refused"       { printf "  ? %s (%s) — refused: %s\n", $2, $4, $6 }
    $3=="error"         { printf "  ✗ %s (%s) — FAILED: %s\n", $2, $4, $6 }
    $3=="fatal"         { printf "  ✗ %s (%s) — PHP FATAL during the update: %s\n", $2, $4, $6 }
    $3=="not-attempted" { printf "  ⋯ %s (%s) — %s\n", $2, $4, $6 }' "$f"
  return 0
}

# Manual reminders, rendered once (they're not tied to plugins vs themes).
_report_manual() { # outcome.tsv
  awk -F'\t' '$3=="manual" { if (!h) { print ""; print "Update by hand in wp-admin (WP-CLI cannot see these updates):"; h=1 }
                             printf "  ✎ %s (currently %s)%s\n", $2, ($4 != "" ? $4 : "?"), ($6 != "" ? " — " $6 : "") }' "$1"
  return 0
}

# The post-upgrade briefing: everything that didn't update, and what to do. With
# interactive=1 on a TTY, offers to put no-package/refused items on the hold list (never
# fatal/error — those are bugs to look at). Always prints the ready-made commands too.
_update_briefing() { # dir client interactive
  local dir="$1" client="$2" interactive="${3:-0}" f="$1/updates.outcome.tsv"
  [ -s "$f" ] || return 0
  local n; n="$(awk -F'\t' '$3!="updated" && $3!="manual"' "$f" | grep -c . || true)"
  local m; m="$(awk -F'\t' '$3=="manual"' "$f" | grep -c . || true)"
  [ "$n" -gt 0 ] || [ "$m" -gt 0 ] || { log_ok "Everything with an update was updated."; return 0; }
  echo >&2
  log_info "Briefing — not updated ($n):"
  awk -F'\t' '$3!="updated" && $3!="manual" { printf "  %-12s %-34s %s%s\n", $3, $2 " (" $1 ")", $4, ($6 != "" ? "  — " $6 : "") }' "$f" >&2
  [ "$m" -gt 0 ] && _report_manual "$f" >&2
  local cands; cands="$(awk -F'\t' '$3=="no-package" || $3=="refused" { print $2 }' "$f")"
  [ -n "$cands" ] || return 0
  echo >&2
  log_info "Pro/licensed/custom and shouldn't be auto-updated? Put it on the hold list:"
  local c; for c in $cands; do log_info "  wpsite hold $client $c --reason \"…\""; done
  if [ "$interactive" = 1 ] && [ -t 0 ] && [ -t 2 ]; then
    local ans reason
    for c in $cands; do
      printf 'Hold %s for %s (never auto-update it)? [y/N] ' "$c" "$client" >&2
      read -r ans < /dev/tty || ans=""
      case "$ans" in y|Y|yes|j|J|ja) ;; *) continue ;; esac
      printf '  Reason (Enter = "%s"): ' "$(awk -F'\t' -v n="$c" '$2==n {print $3; exit}' "$f")" >&2
      read -r reason < /dev/tty || reason=""
      [ -n "$reason" ] || reason="$(awk -F'\t' -v n="$c" '$2==n {print $3; exit}' "$f")"
      cmd_hold "$client" "$c" --reason "$reason" || log_warn "  could not hold $c"
    done
  fi
  return 0
}

# apply vs. the latest rehearsal — informational only, never a gate. Anything that behaved
# differently on production than in the rehearsal, and production versions that moved
# since the backup the rehearsal was built from.
_compare_with_rehearsal() { # apply_dir client
  local dir="$1" client="$2" rdir
  rdir="$(_latest_upgrade_dir "$client" 2>/dev/null || true)"
  [ -n "$rdir" ] && [ -d "$rdir" ] || return 0
  local lines=""
  if [ -s "$rdir/updates.outcome.tsv" ] && [ -s "$dir/updates.outcome.tsv" ]; then
    lines="$(awk -F'\t' 'NR==FNR { r[$1 FS $2]=$3; next } ($1 FS $2) in r && r[$1 FS $2] != $3 {
               printf "  %s %s: rehearsal %s, production %s\n", $1, $2, r[$1 FS $2], $3 }' \
             "$rdir/updates.outcome.tsv" "$dir/updates.outcome.tsv" 2>/dev/null || true)"
  fi
  local k moved=""
  for k in plugins themes; do
    [ -f "$rdir/$k.before.csv" ] && [ -f "$dir/$k.before.csv" ] || continue
    moved+="$(awk -F, 'NR==FNR { if (FNR>1) { x=$1; gsub(/^"|"$/,"",x); r[x]=$2 }; next }
                FNR>1 { x=$1; gsub(/^"|"$/,"",x); if ((x in r) && r[x] != $2) printf "  %s: %s in the rehearsal, %s on production now\n", x, r[x], $2 }' \
              "$rdir/$k.before.csv" "$dir/$k.before.csv" 2>/dev/null || true)"
  done
  [ -n "$lines$moved" ] || return 0
  {
    echo
    echo "Compared with the rehearsal ($(basename "$rdir")):"
    [ -n "$lines" ] && printf '%s\n' "$lines"
    [ -n "$moved" ] && { echo "  Production changed since the rehearsal's backup:"; printf '%s\n' "$moved"; }
  }
  return 0
}

# After the run: what was updatable BEFORE but still sits at the same version (and
# isn't on the skip list)? Warned on the terminal and noted in update.log, so a
# silently short run is loud instead of only a line in the report.
_report_missed_updates() { # dir
  local dir="$1" kind csv_b csv_a n vb va missed=""
  for kind in plugin theme; do
    csv_b="$dir/${kind}s.before.csv"; csv_a="$dir/${kind}s.after.csv"
    for n in $(_update_available_from_csv "$csv_b"); do
      [ -n "$(_update_skip_reason "$kind" "$n")" ] && continue
      vb="$(awk -F, -v n="$n" 'NR>1 { x=$1; gsub(/^"|"$/,"",x); if (x==n) { print $2; exit } }' "$csv_b" 2>/dev/null || true)"
      va="$(awk -F, -v n="$n" 'NR>1 { x=$1; gsub(/^"|"$/,"",x); if (x==n) { print $2; exit } }' "$csv_a" 2>/dev/null || true)"
      if [ -n "$va" ] && [ "$vb" = "$va" ]; then
        missed="$missed $kind:$n"
        _ulog_note "$dir/update.log" "NOT UPDATED: $kind $n still $va (was update=available before)"
      fi
    done
  done
  if [ -n "$missed" ]; then
    log_warn "Updatable before the run but NOT updated:$missed"
    log_warn "  Details: $dir/update.log (search 'NOT UPDATED' / 'plan:')"
  fi
  return 0
}

# Renders the customer-facing report. $1 is the SITE LABEL shown to the customer
# (the domain — see _write_client_report_de), never the internal client id.
_client_report_de() { # site stamp core_before core_after dir
  local site="$1" stamp="$2" cb="$3" ca="$4" dir="$5"
  local formatted_date
  # Parse stamp (YYYYMMDD_HHMMSS) to a nice readable German format, e.g. DD.MM.YYYY um HH:MM Uhr
  if [[ "$stamp" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})$ ]]; then
    formatted_date="${BASH_REMATCH[3]}.${BASH_REMATCH[2]}.${BASH_REMATCH[1]} um ${BASH_REMATCH[4]}:${BASH_REMATCH[5]} Uhr"
  else
    formatted_date="$(date '+%d.%m.%Y um %H:%M Uhr')"
  fi

  cat <<EOF
================================================================================
                           WARTUNGSBERICHT
================================================================================

--------------------------------------------------------------------------------
PROJEKT-DETAILS
--------------------------------------------------------------------------------
  • Website:            $site
  • Zeitpunkt:          $formatted_date
  • Status nach Update: Aktiv und stabil (HTTP 200)

--------------------------------------------------------------------------------
DURCHGEFÜHRTE AKTUALISIERUNGEN
--------------------------------------------------------------------------------

EOF

  if [ "$cb" = "$ca" ]; then
    echo "  • WordPress Core:      $cb (bereits auf dem neuesten Stand)"
  else
    echo "  • WordPress Core:      $cb  ──>  $ca (erfolgreich aktualisiert)"
  fi
  echo

  echo "Erweiterungen (Plugins):"
  _report_section_de "$dir/plugins.before.csv" "$dir/plugins.after.csv"
  echo

  echo "Design-Vorlagen (Themes):"
  _report_section_de "$dir/themes.before.csv" "$dir/themes.after.csv"
  echo

  if [ -s "$dir/plugins.reconcile.txt" ]; then
    echo "Plugin-Aktivierung:"
    awk -F'\t' '
      $1=="REACTIVATED" {printf "    ↻ %s — war nach dem Update kurzzeitig deaktiviert und wurde reaktiviert\n",$2}
      $1=="FAILED"      {printf "    ✗ %s — ist nach dem Update deaktiviert und konnte NICHT reaktiviert werden (manuelle Prüfung erforderlich)\n",$2}
      $1=="UNVERIFIED"  {printf "    ? %s — wurde reaktiviert, konnte aber nicht automatisch geprüft werden (manuelle Prüfung erforderlich)\n",$2}
    ' "$dir/plugins.reconcile.txt"
    echo
  fi

  cat <<EOF
--------------------------------------------------------------------------------
UNSERE QUALITÄTSSICHERUNG
--------------------------------------------------------------------------------
Im Rahmen des Wartungsprozesses wurden folgende Schritte durchgeführt:
  1. Erstellung eines vollständigen Backups als Wiederherstellungspunkt.
  2. Einspielen aller Sicherheits- und Systemupdates.
  3. Automatische visuelle Vorher-Nachher-Überprüfung aller Kernseiten.
  4. Leerung und Optimierung aller System-Caches.
  5. Abschließender Erreichbarkeits- und Funktionscheck.

================================================================================
EOF
}

# Render <txt> to a PDF next to it via macOS `cupsfilter` — the one place the
# report's print styling is produced, so a regenerated PDF (`wpsite report`) is
# byte-for-byte the same shape as the one apply wrote. Non-fatal: the .txt is the
# real deliverable and cupsfilter doesn't exist on a headless Linux box.
_report_pdf() { # txt_file
  local txt="$1" pdf="${1%.txt}.pdf"
  have cupsfilter || { log_warn "cupsfilter not available — no PDF written (txt: $txt)"; return 0; }
  cupsfilter -i text/plain -o document-format=application/pdf "$txt" > "$pdf" 2>/dev/null || {
    log_warn "PDF generation failed — the report text is still at $txt"
    rm -f "$pdf"
    return 0
  }
  return 0
}

# Write the German maintenance report (txt + PDF) for <client> into <dir>.
# Mode `domain` is the CUSTOMER-facing form used by `apply`: the file is named after,
# and the report headed with, the site's DOMAIN (bluebase5_com-wartungsbericht.pdf,
# "bluebase5.com") — the client id is our in-house reference and must not travel to
# the customer. Any other mode (the default, used by the local `upgrade` rehearsal,
# whose report nobody sends out) keeps the plain `wartungsbericht.txt` + the id.
_write_client_report_de() { # client stamp core_before core_after dir [mode]
  local client="$1" stamp="$2" cb="$3" ca="$4" dir="$5" mode="${6:-}"
  local site base
  if [ "$mode" = domain ]; then
    site="$(client_domain "$client")"
    base="$(printf '%s' "$site" | tr '.' '_')-wartungsbericht"
  else
    site="$client"
    base="wartungsbericht"
  fi
  _client_report_de "$site" "$stamp" "$cb" "$ca" "$dir" > "$dir/$base.txt"
  _report_pdf "$dir/$base.txt"
  log_ok "Wartungsbericht (DE): $dir/$base.txt (.pdf)"
  return 0
}

cmd_upgrade() {
  local client="" review=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --noreview) review=0; shift ;;
      -*) die "Unknown flag: $1" ;;
      *) client="$1"; shift ;;
    esac
  done
  config_require_registry
  require_client "$client"
  require docker

  local app_c="wp_${client}_app"
  [ "$(docker inspect -f '{{.State.Running}}' "$app_c" 2>/dev/null)" = "true" ] \
    || die "Replica '$client' isn't running. Build it first: wpsite build $client"
  _ensure_wp_cli "$app_c" || die "wp-cli unavailable in $app_c."

  local stamp dir
  stamp="$(date +%Y%m%d_%H%M%S)"
  dir="$(client_base "$client")/upgrades/$stamp"
  mkdir -p "$dir"
  log_info "Upgrading '$client' (local replica). Report → $dir"

  # --- Review setup: page list, fatal baseline, BEFORE screenshots ---
  local docker_dir fatal_baseline=0 specs=() shot_hosts="" dismiss=""
  if [ "$review" = 1 ]; then
    docker_dir="$(client_docker_dir "$client")"
    dismiss="$(_review_dismiss "$client")"   # consent banners to hide before each shot
    local u s
    if [ "$(_upgrade_wp "$app_c" eval 'echo is_multisite() ? 1 : 0;' 2>/dev/null | tr -d '[:space:]')" = "1" ]; then
      # Multisite: home + 1 page per subsite, slugs namespaced; shoot every subsite host.
      while IFS= read -r s; do [ -n "$s" ] && specs+=("$s"); done < <(_ms_review_specs "$app_c")
    else
      local local_host local_url
      local_host="$(client_local_host "$client")"
      local_url="http://$local_host"
      while IFS= read -r u; do [ -n "$u" ] && specs+=("$(_url_slug "$u")|$u"); done \
        < <(_review_pages "$client" "$app_c" "$local_url")
    fi
    shot_hosts="$(_specs_hosts "${specs[@]}" | tr '\n' ' ')"
    fatal_baseline="$(_debug_fatal_count "$docker_dir")"
    log_info "Capturing ${#specs[@]} page(s) BEFORE upgrade..."
    _capture_shots "$dir/before" "$shot_hosts" "$dismiss" "${specs[@]}" || log_warn "before-capture had issues"
  fi

  # --- BEFORE versions (fresh update data first, so the snapshot isn't stale) ---
  _refresh_update_cache "$dir/update.log" _upgrade_wp "$app_c"
  local core_before; core_before="$(_upgrade_wp "$app_c" core version 2>/dev/null | tr -d '\r')"
  _upgrade_wp "$app_c" plugin list --fields="$WPSITE_PLUGIN_FIELDS" --format=csv 2>/dev/null | tr -d '\r' > "$dir/plugins.before.csv"
  _upgrade_wp "$app_c" theme  list --fields=name,version,update --format=csv 2>/dev/null | tr -d '\r' > "$dir/themes.before.csv"

  # --- Upgrades (the version diff is the source of truth, so warn-don't-die) ---
  local is_ms=0
  [ "$(_upgrade_wp "$app_c" eval 'echo is_multisite() ? 1 : 0;' 2>/dev/null | tr -d '[:space:]')" = "1" ] && is_ms=1
  _WPSITE_RUN_CLIENT="$client"          # its hold list applies
  _run_updates "$dir" "$is_ms" _upgrade_wp "$app_c" || true

  # --- AFTER ---
  local core_after; core_after="$(_upgrade_wp "$app_c" core version 2>/dev/null | tr -d '\r')"
  _upgrade_wp "$app_c" plugin list --fields="$WPSITE_PLUGIN_FIELDS" --format=csv 2>/dev/null | tr -d '\r' > "$dir/plugins.after.csv"
  _upgrade_wp "$app_c" theme  list --fields=name,version,update --format=csv 2>/dev/null | tr -d '\r' > "$dir/themes.after.csv"
  _report_missed_updates "$dir"
  _classify_updates "$dir" "$client"

  # --- Reconcile plugins that fell inactive during the update ---
  # This is the rehearsal, so this is where you WANT to find out: a plugin that
  # cannot be restored here would have hit production in the next `wpsite apply`.
  local reconcile_ok=1
  _reconcile_active_plugins "$dir/plugins.before.csv" "$dir/plugins.after.csv" \
    "$dir/update.log" "$dir/plugins.reconcile.txt" _upgrade_wp "$app_c" || reconcile_ok=0

  # --- Report ---
  echo >&2
  _upgrade_report "$client" "$stamp" "$core_before" "$core_after" "$dir" | tee "$dir/report.txt" >&2
  log_ok "Report saved: $dir/report.txt   (reset anytime with: wpsite build $client)"

  [ -s "$dir/update.log" ] && log_info "WP-CLI output: $dir/update.log"

  # German client report and PDF compilation
  _write_client_report_de "$client" "$stamp" "$core_before" "$core_after" "$dir"

  # What didn't update, and what to do about it (offers the hold list on a terminal).
  _update_briefing "$dir" "$client" 1

  # --- Review: AFTER screenshots, smoke check, build + open comparison page ---
  if [ "$review" = 1 ]; then
    echo >&2
    log_info "Capturing ${#specs[@]} page(s) AFTER upgrade..."
    _capture_shots "$dir/after" "$shot_hosts" "$dismiss" "${specs[@]}" || log_warn "after-capture had issues"
    _smoke_check "$docker_dir" "$fatal_baseline" "${specs[@]}"
    _render_review_html "$dir" "$client" "$stamp" "${specs[@]}"
    log_ok "Comparison page: $dir/review.html"
    _open_file "$dir/review.html"
  fi

  # A plugin we could not bring back is the one outcome that must not be silent:
  # the same update is about to be replayed on production by `wpsite apply`.
  if [ "$reconcile_ok" != 1 ]; then
    echo >&2
    log_error "One or more plugins stayed INACTIVE — see $dir/plugins.reconcile.txt"
    log_error "Diagnose with $dir/update.log, then fix BEFORE running: wpsite apply $client"
    return 1
  fi
  return 0
}
