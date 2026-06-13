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

## Phase B — before/after screenshot review (NO automated diff) — ✅ BUILT

Implemented in `lib/cmd_review.sh` + `upgrade --review`. Captures key pages before/after
(Playwright in a one-time-built native `wpsite/shot` image, reaching the replica via
Traefik with `--add-host`), runs a smoke check (200s + no new fatals), builds a
self-contained `review.html` (drag-to-wipe slider + side-by-side toggle), and `open`s it.
`wpsite review <client>` re-opens the latest. Verified live (8 pages, real captures).
Known v1 gap: cookie/consent banners can cover content. Original design below.

By decision: the tool **captures and presents**; the human **judges**. No diff
algorithm, no thresholds. Designed for a one-command, lazy workflow.

### UX
- `wpsite upgrade <client> --review` — screenshot pages → upgrade → screenshot again →
  build `review.html` → **`open` it in the default browser**. One command.
- `wpsite review <client>` — re-open the latest comparison page (no re-run).
- Plain `wpsite upgrade` stays fast/screenshot-free.

### Decisions (locked)
- **Engine: one-shot Playwright/Chromium container** (`docker run --rm`), not a host
  browser. Reliable full-page captures + `networkidle` waits + consistent rendering, no
  host deps beyond Docker. Joins the `wpsite_proxy` network and reaches the replica with
  `--add-host <client>.test:<traefik-ip>` — same path a real browser takes. ~GB one-time
  image pull.
- **Pages: home + a small auto-picked set** (recent pages/posts via `wp post list`),
  overridable per client via `clients.<c>.review_pages: [/, /kontakt, ...]`. Zero-config
  default, tunable.
- **Comparison page: default view = drag-to-wipe SLIDER**, with a per-page
  **side-by-side** toggle. ~30 lines of vanilla JS/CSS, no library, works offline.
  Header carries client + timestamp + the Phase A old→new summary.
- **Capture is before-vs-after on the SAME replica** (what the upgrade changed) — the
  meaningful comparison; same engine/viewport both times, so it's like-for-like.

### Storage (reuses the Phase A folder)
`<base_dir>/<client>/upgrades/<timestamp>/` gains `shots/before/*.png`,
`shots/after/*.png`, `review.html` — alongside `report.txt` + the CSVs. One dated,
sendable record per quarterly upgrade.

### Smoke check (cheap pre-step, folded into --review)
Every captured page returns **HTTP 200** and `wp-content/debug.log` shows **no new
fatals** after the upgrade. Catches the white-screen class instantly, no browser needed;
reused later by Phase C.

### Caveats (kept honest)
- Placeholder media is deterministic → no visual noise; only real rendering changes show.
- Dynamic content (sliders/dates) differs between shots → eyeballed, not failed.
- Headless rendering may differ from Safari/Chrome, but before/after share the engine so
  the *comparison* stays valid.
- Aggressive cookie/consent banners may cover pages → a future `review_dismiss` selector
  in config; not solved in v1.

### Build order
1. **Smoke check** — 200s + no-new-fatals on the page list (pure-ish; also feeds Phase C).
2. **Capture** — Playwright container screenshots a URL list to a dir.
3. **`review.html` generator** — slider default + side-by-side toggle; `open` it.
4. **Wire `--review`** into `upgrade` + the `review` re-open command.

---

## Phase C — `wpsite apply <client>` — ✅ BUILT (⚠ unverified against a live server)

Implemented in `lib/cmd_apply.sh`. Guards: typed-name confirmation (`_confirm_prod`),
mandatory fresh backup as rollback point (aborts if it fails), one client at a time.
Sequence: fresh backup → maintenance ON → `core update`/`update-db`, `plugin/theme
update --all`, `cache flush` over SSH → maintenance OFF (always) → verify the live home
URL returns 200 → prod report (reuses the upgrade report renderer). **Never copies
replica data to prod** — re-runs the validated upgrade in place.

**Deliberately NOT done: automated rollback.** An untested auto-restore running on
production is its own footgun, so on failure `apply` deactivates maintenance mode and
points at the fresh backup + manual steps. The whole command ships **unverified against
a real server** (no prod SSH during development) — only the orchestration/guards are
unit-tested (`test/apply.bats`, fully stubbed). Treat the first real run as careful.
Original design below.

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

## Multisite support (subdomain + domain-mapped)

Clients: 2–3 networks of 3–8 sites, mixing subdomain (`site1.domain.com`) and
domain-mapped (`mycooldomain.com`, `myotherdomain.com`) subsites in the same network.

**Mapping rule (locked): read EVERY domain from the live network (`wp site list` /
`wp_blogs`/`wp_site`) and swap only the TLD to `.test`, keeping the original host:**

```
example.com         → example.test
shop.example.com    → shop.example.test
mycooldomain.com    → mycooldomain.test      (a mapped subsite)
```

Handles subdomain AND mapped subsites uniformly, mirrors prod (easy to recognise), all
resolve via dnsmasq `*.test`, and replacing full hosts *with scheme* avoids touching
email addresses. Detected early; **correctness over speed**.

### Phase M1 — backup detection — ✅ BUILT
Remote backup records `MULTISITE` + `SUBDOMAIN_INSTALL` in `meta.env` and the full
network in `sites.csv` (`blog_id,domain,path,url`). Single-site unaffected (`MULTISITE=0`,
no `sites.csv`). ⚠ unverified against a real multisite (none available in dev).

### Phase M2 — `core update-db --network` — ✅ BUILT
`upgrade` + `apply` detect `is_multisite()` at runtime and run `core update-db --network`
on networks (`--network` errors on single sites, so it must be conditional). Makes the
production `apply` correct for multisite **now**, before local replicas exist.

### Phase M3 — multisite replica build — ✅ BUILT & VERIFIED (greyda, 6 subsites)
Gated behind `MULTISITE=1`; single-site path untouched & test-guarded. Logic lives in
`lib/cmd_build_multisite.sh`; `cmd_build` branches on `is_ms`.
- Inject constants via `WORDPRESS_CONFIG_EXTRA` (`MULTISITE`, `SUBDOMAIN_INSTALL`,
  `DOMAIN_CURRENT_SITE` = the main site's `.test` host). ✅
- **Fix `wp_site`/`wp_blogs` domains with RAW SQL first** — breaks the wp-cli bootstrap
  chicken-and-egg (can't run `wp` on a network whose domains don't match the config). ✅
- Then per-domain content `search-replace` (reuse the http/https/escaped matrix) for
  every domain in `sites.csv`. ✅
- Traefik route lists every local domain: ``Host(`d1.test`) || Host(`d2.test`) || …``. ✅
- **REQUIRES dnsmasq** wildcard DNS (`proxy install-dns`); `/etc/hosts` can't wildcard.
- Known login (`wpsite`) created first, THEN promoted to super-admin. ✅
- **Verified:** all 6 greyda subsites (`greyd…greydu.artismedia.test`) return HTTP 200
  through Traefik with distinct titles; `wp site list` shows correct `.test` domains.
- Note: bare `wp` fatals on the Greyd `aule` plugin (`add_settings_error()` at
  `plugins_loaded` in CLI context) — every helper runs `--skip-plugins --skip-themes`.
- TODO: `--network` deactivation of network-activated plugins still uses per-site
  `_sanitize_plugins`; revisit if a client network-activates a plugin we must disable.

### Phase M4 — multisite review — ✅ BUILT & VERIFIED (greyda, 12 specs)
`upgrade --review` branches on `is_multisite()`. Multisite path (`_ms_review_specs`):
home + 1 published page **per subsite**, subsite list read from the running replica's
DB (already `.test` after M3). Slugs namespaced by host (`greyda_artismedia_test__home`)
so `home`/`home` across sites don't overwrite each other's PNG. `_capture_shots` now takes
a space-separated host list → one `--add-host` per subsite domain; `_smoke_check` derives
the Host header per-spec so it spans the whole network. Single-site path unchanged.
- **Verified:** against the live greyda replica `_ms_review_specs` yields 12 specs
  (6 subsites × 2), `_specs_hosts` lists all 6 `.test` domains. New bats cases:
  `_ms_review_specs` (namespacing + 2/site) and `_specs_hosts` (unique hosts).

### Caveats
- Replica is a faithful *rehearsal*, not a perfect clone (cross-subdomain cookies/SSO,
  network-admin nuances differ).
- Per-host URL replacement leaves email addresses intact; anything that slips through is
  harmless on a throwaway local replica (Mailpit traps mail anyway).
- Theoretical `.test` collisions across clients (two clients → same swapped host); per-
  client route files match exact hosts, and real domains haven't collided.
- **M1–M3 verified against the greyda network** (6 subdomain subsites) via a local build —
  no SSH. Domain-mapped networks remain unverified (no such client backup on hand yet);
  the TLD-swap path treats them uniformly, but confirm on the first mapped client.

## Open questions

- Which pages get screenshotted? (homepage + manual list in config, vs sitemap crawl.)
- Screenshot engine: host `shot-scraper` vs Playwright container.
- `upgrade` as a standalone command on a built replica (preferred) vs a `build --upgrade`
  flag.
- Should the report be per-upgrade only, or accumulate a per-client history?
