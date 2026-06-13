# wpsite — Upgrade Workflow Plan

Design for the quarterly-retainer workflow: upgrade WordPress core, plugins and
themes for client sites, validate the result, and apply it to production safely.

Status: **planning** (nothing here is built yet). Phase A is the agreed first build.

---

## The core principle: rehearse locally, apply on production

The replica is a **rehearsal, not the source of truth.** Two facts make "copy the
upgraded data back to production" a data-loss bug, not a feature:

- The replica's database is a **snapshot frozen at backup time.** Production keeps
  living between backup and apply (orders, comments, form entries, posts, users).
  Copying the replica's DB over production **destroys everything that happened in
  between.**
- The replica runs **placeholder media** (fake uploads).

So we never push the replica's data back. Instead:

> The replica proves the upgrade is safe and produces a changelog. Then we **re-run
> the same upgrade commands on production, in place** — production upgrades its own
> live data. `wp plugin update` on prod fetches the exact same new versions and runs
> the same migrations against the real DB.

This sidesteps data loss entirely, and is actually *better*: premium plugins update
more reliably on production, where their license is active.

---

## Architecture decision: stay Bash, "orchestrate — don't compute"

We are NOT rewriting the tool. The project's hard bugs were environmental, not
linguistic; stability comes from the test suite + shellcheck + CI. Bash is glue, and
all heavy work is already delegated to purpose-built tools.

Standing rule going forward: **Bash orchestrates and assembles; it never does heavy
lifting or holds rich data — it shells out to the right tool and renders the result.**

| Need | Delegate to |
|---|---|
| Container / lifecycle / SSH | Docker, ssh (Bash glue) |
| WordPress operations | WP-CLI (`wp ... --format=json`) |
| Structured upgrade report | WP-CLI JSON + `jq` (don't hand-parse in Bash) |
| Screenshots | headless browser (host `shot-scraper`/Chrome, or a Playwright container) |
| Before/after comparison UI | a **static HTML page** Bash writes and `open`s in the browser |

(If this ever needs to ship to a team or go cross-platform, revisit with Go — single
binary, good Docker/SSH libs. Not warranted for single-user macOS today.)

---

## Phase A — `wpsite upgrade <client>` — ✅ BUILT

Implemented in `lib/cmd_upgrade.sh`: runs WP-CLI `core update`/`update-db`,
`plugin update --all`, `theme update --all` on the running replica (with
`--skip-plugins --skip-themes` to dodge the aule fatal), captures before/after
`name,version,update` CSVs, and writes a human report (`report.txt`) plus the CSVs to
`<base_dir>/<client>/upgrades/<timestamp>/`. The report lists each changed item
(old → new) and flags updates still "available" (premium/manual). Verified live.
Tests in `test/upgrade.bats`. Original design below.

Run WP-CLI against the **running replica**; safe and fully reversible (a broken
upgrade = just `wpsite build <client>` again to reset from the backup).

Steps:
1. Capture **before** versions: `wp core version`, `wp plugin list --format=json`,
   `wp theme list --format=json`.
2. `wp core update` → `wp core update-db` (the schema migration; see sidebar).
3. `wp plugin update --all`.
4. `wp theme update --all`.
5. Capture **after** versions; diff into a **report** (each item, old → new) — saved
   under `<base_dir>/<client>/upgrades/<timestamp>/report.{txt,json}` and printed.
   This report is itself a retainer deliverable.

Notes / caveats:
- Runs wp-cli `--skip-plugins --skip-themes` to dodge the prod-plugin bootstrap fatal
  (`aule`). Consequence: **premium plugins (own updaters) won't update locally** — the
  report flags them as "not updated; handle manually" until `aule` is wp-cli-safe.
  wp.org core/plugins/themes update fine.
- Idempotent; re-running is safe.
- `upgrade --all` (every running replica, sequentially) is a natural follow-up.

### Sidebar: why `wp core update-db`?
It is **not** upgrading MariaDB and **not** touching content. It runs WordPress's own
schema/data migrations that a new *core version* may need (add a column, migrate an
option format, bump `db_version`). wp-admin runs this for you automatically (the
"Updating database…" screen); WP-CLI updates files only, so it must be run as an
explicit step or the site shows "database update required." Usually a no-op; always
safe; doing it on the replica first means a misbehaving migration is caught locally.
Footnote: some big plugins have their own equivalent (e.g. WooCommerce `wp wc update`).

---

## Phase B — before/after screenshots for human review (NO automated diff)

By decision: the tool **captures and presents**; the human **judges**. No diff
algorithm, no thresholds.

1. Before the upgrade, screenshot a configurable set of pages (homepage + key pages,
   or pulled from the sitemap) at one or more viewport widths.
2. Run the Phase A upgrade.
3. Screenshot the same pages again.
4. Generate a **static `review.html`** showing, per page, **before | after** side by
   side plus an **overlay slider** (drag to wipe between the two). Bash writes the
   HTML referencing the PNGs and `open`s it.

Why this is robust: placeholder media is deterministic (identical before/after), so it
adds no visual noise — only real theme/plugin rendering changes show up. Dynamic
content (sliders, dates) is simply judged by eye, not failed by a threshold.

Tooling TBD: host `shot-scraper` (brew, simplest) vs a Playwright container (no host
deps, consistent with our Docker-first approach). The page reaching `<client>.test`
works the same way the browser does (resolve → Traefik). Defer until Phase A is in use.

A cheaper pre-step worth having regardless: a **smoke check** — every key page returns
HTTP 200 and `wp-content/debug.log` shows no new fatals after the upgrade. Catches the
white-screen class instantly, no browser needed.

---

## Phase C — `wpsite apply <client>` (production; heavily guarded, never auto-chained)

Only after local validation and an explicit human decision. Re-runs the validated
upgrade **on production in place** — never copies replica data.

1. **Fresh production backup** (the rollback point) — reuse `wpsite backup`.
2. `wp maintenance-mode activate` on prod (over SSH).
3. Re-run the same upgrade commands on prod: `core update` → `core update-db`,
   `plugin update --all`, `theme update --all` (premium updaters run here with live
   licenses).
4. Flush caches; `wp maintenance-mode deactivate`.
5. **Verify**: key pages return 200, no new fatals.
6. **On any failure → roll back** by restoring the fresh backup taken in step 1.

Guards (non-negotiable): explicit command, interactive confirmation, one client at a
time, fresh backup mandatory, documented rollback. This step is irreversible and
outward-facing — maximum caution.

---

## Human-in-the-loop gates

- Phases A and B are fully automatable and safe (local only).
- The **decision to apply** (B → C) is **never** automated for client work.
- Phase C runs **only** on explicit, confirmed command with a fresh backup.
- The screenshot review *focuses* the human; it does not replace them.

---

## Suggested build order

1. **Phase A** — `upgrade` + version report. Small, high-leverage, safe. Use it for a
   quarter before deciding on B/C.
2. **Smoke check** — 200s + no fatals (cheap, high value).
3. **Phase B** — screenshot capture + `review.html`.
4. **Phase C** — `apply` to production, with fresh backup + rollback. Design separately
   and carefully when the rest has earned its keep.

## Open questions

- Which pages get screenshotted? (homepage + manual list in config, vs sitemap crawl.)
- Screenshot engine: host `shot-scraper` vs Playwright container.
- `upgrade` as a standalone command on a built replica (preferred) vs a `build --upgrade`
  flag.
- Should the report be per-upgrade only, or accumulate a per-client history?
