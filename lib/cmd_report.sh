#!/usr/bin/env bash
# cmd_report — regenerate a maintenance-report PDF from its (hand-edited) .txt.
#
# The Wartungsbericht we send a customer is written by `apply` (see cmd_upgrade.sh's
# _write_client_report_de). Its .txt is plain text the user may want to touch up —
# reword a line, drop a detail — before it goes out. This command re-runs ONLY the
# PDF step (_report_pdf, the same helper apply uses), so an edited report keeps the
# exact styling of a generated one. It never re-renders the text: whatever is in the
# .txt is what lands in the PDF.
#
# Local-only, read-then-write inside the report folder — no registry, no SSH, so it
# also works for a client whose entry is gone.

_report_usage() {
  cat >&2 <<'USAGE'
Usage: wpsite report <client> [<id>] [--apply <id> | --upgrade <id>] [--list] [--no-open]

Regenerates the PDF from the report's .txt (edit the .txt first, then run this).
Default source: the newest apply of <client>.

  <id> | --apply <id>   a run under clients/<client>/applies/
  --upgrade <id>        a run under clients/<client>/upgrades/ instead
  --list                list the runs that have a report, newest first
  --no-open             don't open the regenerated PDF
USAGE
}

# All run dirs of <client> under <kind> that carry a report .txt, newest first.
_report_runs() { # client kind
  local dir; dir="$(client_base "$1")/$2"
  [ -d "$dir" ] || return 0
  local d
  # shellcheck disable=SC2012  # timestamp dirs: name sort == chronological
  for d in $(ls -1r "$dir" 2>/dev/null || true); do
    [ -n "$(_report_txt "$dir/$d")" ] && printf '%s\n' "$d"
  done
  return 0
}

# The report .txt inside a run dir: the domain-named one apply writes, else the
# plain `wartungsbericht.txt` (upgrade, and apply runs from before the rename).
_report_txt() { # run_dir
  local f
  for f in "$1"/*-wartungsbericht.txt "$1/wartungsbericht.txt"; do
    [ -f "$f" ] && { printf '%s' "$f"; return 0; }
  done
  return 0
}

cmd_report() {
  config_require

  local client="" kind=applies id="" list=0 open=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply)   kind=applies;  id="${2:-}"; shift 2 ;;
      --upgrade) kind=upgrades; id="${2:-}"; shift 2 ;;
      --list)    list=1; shift ;;
      --no-open) open=0; shift ;;
      -h|--help) _report_usage; return 0 ;;
      -*) die "Unknown flag: $1" ;;
      *) if [ -z "$client" ]; then client="$1"; elif [ -z "$id" ]; then id="$1"; else die "Unexpected argument: $1"; fi; shift ;;
    esac
  done
  [ -n "$client" ] || { _report_usage; return 1; }

  local runs; runs="$(_report_runs "$client" "$kind")"
  if [ "$list" = 1 ]; then
    [ -n "$runs" ] || die "No $kind with a report found for '$client'."
    printf '%s\n' "$runs"
    return 0
  fi
  [ -n "$runs" ] || die "No $kind with a report found for '$client' (looked in $(client_base "$client")/$kind)."

  [ -n "$id" ] || id="$(printf '%s\n' "$runs" | head -1)"
  local run_dir; run_dir="$(client_base "$client")/$kind/$id"
  [ -d "$run_dir" ] || die "No such $kind run: $id
  Available: $(printf '%s' "$runs" | tr '\n' ' ')"

  local txt; txt="$(_report_txt "$run_dir")"
  [ -n "$txt" ] || die "No wartungsbericht .txt in $run_dir."

  log_info "Regenerating PDF from $txt"
  _report_pdf "$txt"
  local pdf="${txt%.txt}.pdf"
  [ -f "$pdf" ] || die "PDF was not written (is cupsfilter available?)."
  log_ok "Wartungsbericht: $pdf"
  [ "$open" = 1 ] && _open_file "$pdf"
  return 0
}
