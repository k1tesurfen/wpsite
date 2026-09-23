# wpsite hardening plan — registry split, apply & upgrade

Status: **IMPLEMENTED (2026-09-23)** — all seven phases, in the order below. Deviations
from the approved draft are marked **[changed]** with the reason. Tests: `registry.bats`,
`maintenance.bats`, `faultinject.bats`, `preflight.bats`, `outcome.bats` (+ updates to
`apply.bats`, `setup.bats`, `pure.bats`, `platform.bats`). The registry migration was run
on the real Drive files (7 clients registered, 1 key moved, 33 stale access copies
dropped; backup `wpsite.team.yml.pre-split-20260923_154756`).

Workflow this plan is built around (always, for every production apply):

```
wpsite backup <c>  →  wpsite build <c>  →  wpsite upgrade <c>  →  wpsite apply <c>
```

Guiding rules:
- Anything that can go wrong after production is touched is checked **before** it is touched.
  Whatever still goes wrong is **never silent**, never leaves the site locked by accident,
  and always ends with a verification (site live? mail works?).
- No "perfect rehearsal" requirement. Pro/licensed/custom plugins that can't or mustn't
  update are normal — they're classified and held, not treated as errors.
- **mandos is the keyholder, wpsite is the WordPress handler.** Two registries, not linked.

---

## 0. What went wrong (September 2026 round)

| # | Where | What happened | Class |
|---|---|---|---|
| 1 | bauklimaneutral apply | 6 wp.org plugins never attempted; the log couldn't say why | invisible plan shrink (fixed: union plan + labelled log) |
| 2 | gerfin test | `wpsite test` aborted silently after the `[4/4]` header | silent `set -e` abort (fixed) |
| 3 | gerfin backup | Plesk WP-Toolkit `wp` wrapper fatals in the chrooted shell | host environment (fixed: bundled wp-cli fallback) |
| 4 | apply (stub repro) | one failing `wp plugin list` after the updates → exit 255, no message, **maintenance left ON** | silent abort in the critical section |
| 5 | arbeitsplatz-erde apply | WordPress's updater deletes our `.maintenance` after every plugin → site unprotected for most of the run | maintenance protection illusory |
| 6 | arbeitsplatz-erde apply | ACF Pro "package not available" (empty `update_package`) reported as "premium? handle manually" | no failure classification |
| 7 | both | greyd_suite 1.34.0 invisible to WP-CLI; customer report claimed "bereits aktuell" | report claims what we can't know |
| 8 | all applies since June | `wp-content/maintenance.php` left behind | incomplete cleanup |
| 9 | upgrade | replica ≠ production: core 7.0 vs 7.0.6, image-injected akismet/hello/twentytwenty* | rehearsal fidelity |

#2 and #4 slipped through because bats' `run` disables `set -e`.

---

## Phase 1 — Registry split: mandos = access, wpsite = its own file

### 1.1 What moves where

| Field | Today | After | Note |
|---|---|---|---|
| `ssh` | mandos (22) | **mandos** | access |
| `wp_root` | mandos (22) | **mandos** | where the site lives on the server |
| `cloud_folder` | mandos (3) | **mandos** | Drive project folder (mandos owns Drive) |
| `remote_tmp` | mandos (1) | **wpsite** | backup staging |
| `deactivate_plugins`, `review_pages`, `review_dismiss`, `local_host`, `cloud_dir`, `login_path` | read from mandos (0 set) | **wpsite** | WordPress logic |
| `hold_plugins`, `manual_updates` | — | **wpsite** (new) | Phase 3 |

### 1.2 wpsite's shared file
- Location: derived from mandos's team file — `…/01_Global/mandos/mandos.team.yml` →
  **`…/01_Global/wpsite/wpsite.team.yml`**. Override: `team_config:` in
  `~/.config/wpsite/wpsite.yml` (or `WPSITE_TEAM_CONFIG`).
- Shape (keyed by client ID; global settings on top):
  ```yaml
  settings:
    test_mail_to: admin@artismedia.de
  clients:
    arbeitsplatz-erde:
      registered: 2026-09-23
      hold_plugins:
        advanced-custom-fields-pro: "Pro, Lizenz beim Kunden – 2026-09-23"
      manual_updates:
        greyd_suite: "Updates nur in wp-admin sichtbar"
  ```
- Read/written with `yq` (`yq -i` for writes → comments survive), only through `common.sh`
  helpers (`wclient_get/set/unset`, `wsetting_get`) — never parsed inline.
- **Unreadable file = hard stop** for `upgrade`/`apply` (Drive unmounted must never look
  like "no held plugins"). Writes refuse when the Drive isn't mounted.
- Dev box: doesn't need the file (upgrade/apply are gateway-only).

### 1.3 Lifecycle — not linked
- A mandos client is **not** automatically a wpsite client.
- **[changed later]** a PASSING `wpsite test <c>` registers too (the usual workflow is
  `mandos client add` → `wpsite test`); a failing test registers nothing.
- **Only `wpsite backup <c>` registers** an ID that mandos knows and wpsite doesn't
  ("gerfin is new in wpsite — registered"). Every other command on an unknown ID refuses with
  "not in wpsite yet — run `wpsite backup <c>` first".
- Deleting in mandos never touches wpsite. A wpsite client without mandos access keeps its
  local data; SSH commands say "no access in mandos"; local commands still work. `wpsite list`
  marks such clients.
- The client ID is the only join key → never rename in one registry only.

**[changed]** The derived path turned out to be where the PRE-mandos wpsite team file
still lived (15 clients with stale ssh/wp_root copies). `migrate-registry` therefore also
drops those access copies (only for clients mandos holds) after backing the file up.
**[added]** `wpsite list --unregistered` — the GUI lists mandos clients that aren't in
wpsite yet, so their first (registering) backup can start from the GUI.

### 1.4 Commands that change
- `wpsite client add/edit` (wrote ssh/wp_root into mandos) → **removed**; access is
  `mandos client add/set/setup-key`.
- `wpsite client remove` → replaced by **`wpsite forget <c> [--purge]`** (drops the wpsite
  entry + replica; `--purge` also local backups; cloud never touched — same guarantees as today).
- `wpsite setup` → no longer installs SSH keys (mandos's job); it sets `base_dir` and
  checks that both registries are reachable.
- GUI: `login_path` read via wpsite instead of mandos.

### 1.5 Migration (one-off, needs your go-ahead — writes both shared files)
Copy every WordPress field currently in the mandos registry (today: 1× `remote_tmp`) into
`wpsite.team.yml`, register the existing 22 clients (they're all in active use), then unset
the moved fields in mandos. Dry-run first, showing exactly what moves.

### 1.6 mandos repo (`~/git/mandos`), same round
**[changed]** Besides docs + GUI, `mandos client add` lost its `--remote-tmp`,
`--local-host` and `--cloud-dir` flags — otherwise it would keep writing WordPress fields
into the access registry. (Install the rebuilt binary: `sudo make -C ~/git/mandos install`.)
- GUI: remove the "WP-Login-Pfad" field; docs (`schema.md`, `CLI-CONTRACT.md`, README):
  mandos = access only, no WordPress examples.
- mandos keeps generic key passthrough in code (harmless, and other tools may need an
  access-level extra) — only docs + GUI change. *(Say if you'd rather it rejected unknown keys.)*

---

## Phase 2 — Apply that can't strand the site

### 2.1 Maintenance mode that survives WordPress's own updater (incident #5)
- Our own flag `wp-content/.wpsite-maintenance` (holds an expiry time) + a tiny mu-plugin
  that serves the 503 page when the flag exists (never under WP-CLI). WordPress never
  touches our flag.
- Additionally re-write `.maintenance` after every update step (covers core mid-update,
  before mu-plugins load).
- **Dead-man switch:** both locks carry a short expiry, refreshed per step → if wpsite dies
  or SSH drops, the site comes back by itself.
- 503 page in **German** ("Wartungsarbeiten – wir sind in Kürze wieder da"), neutral.
- Maintenance off removes flag, mu-plugin, `.maintenance` **and** `maintenance.php` (#8).
- **[added]** Before lifting, the finish looks at the REAL site through the gate with a
  per-run bypass token (`X-Wpsite-Bypass`); only if every page renders is maintenance
  lifted — otherwise it's held. Verified against a real local replica.

### 2.2 Fail-safe exit (incident #4)
- From maintenance-on onwards an `EXIT`/`INT`/`TERM` trap is armed; on ANY exit (Ctrl-C,
  error, silent abort) it runs: final state decision (2.4) → verification (2.5) → writes
  whatever logs/CSVs/report exist → rollback backup path + "APPLY INCOMPLETE" banner.
- The critical section doesn't rely on `set -e`: every step is an explicit, logged, checked
  call; a failure is recorded and the run proceeds to the cleanup.
- SSH lost → the trap prints the exact manual commands; the dead-man switch covers the rest.

### 2.3 Stop rule after a fatal
After an update that exits with a PHP fatal: boot-check the site. Still boots → continue with
the next plugin. Doesn't boot → stop updating, reconcile, go to 2.4.

### 2.4 End state
- Site boots and home is live → maintenance off.
- **Site doesn't boot → maintenance stays ON** (clean 503 for visitors and Google), the lock
  is switched to non-expiring so the dead-man switch can't expose the broken site, loud alarm
  with the rollback backup and the exact commands to lift maintenance manually.

### 2.5 Final verification — on EVERY exit
- Live check: home + login + a handful of pages from the rehearsal's page list → status code,
  no fatal/"critical error" text, not our 503 page (unless 2.4 kept it on deliberately).
- **Test mail via the site's real mailer (`wp_mail()`) to `settings.test_mail_to`
  (admin@artismedia.de)** — never the customer's admin_email.
- Summary is the last thing printed and goes into the report.

---

## Phase 3 — Preflight gate (before backup, before anything)

Runs first in `apply`. Any hard failure aborts with production untouched. Then the plan
summary, then the typed-name confirmation.

Hard (abort):
- wpsite file readable; client registered in wpsite; mandos access present.
- SSH + mux; wp-cli works (host or bundled fallback) and **boots the site with all plugins**.
- **Site is healthy right now**: home 200, no fatal text, boots cleanly — otherwise abort
  (fix first, or we can't tell later whether the updates broke it).
- Writable (probe file create + delete): WP root, `wp-content/`, `plugins/`, `themes/`,
  `upgrade/`, `languages/`, `mu-plugins/` (needed by 2.1).
- Server can download updates: outbound HTTPS from PHP to `downloads.wordpress.org`.
- Backup staging dir writable; free space check where `df` works.

Shown, never blocking: update plan with pre-classification (Phase 4), held/manual items,
differences vs. the rehearsal, mailer + test-mail recipient.

---

## Phase 4 — Why didn't it update? Classification, hold list, briefing

### 4.1 Classes (same code for upgrade and apply; locale-independent)
| Class | Detected by | Attempted? |
|---|---|---|
| `updated` | version changed | yes |
| `held` | client `hold_plugins` or global skip (wp-staging-pro, aule) | no |
| `no-package` | not updated and **`update_package` was empty** before the run (verified: ACF Pro shows exactly this) | **yes [changed]** — some premium updaters supply the package lazily via a hook; one failed call is cheap, skipping would miss real updates |
| `refused` | exit 0, version unchanged | yes |
| `fatal` | PHP fatal marker / exit 255 / site stops booting | yes → stop rule |
| `error` | any other failure (download, filesystem, disk); first error line quoted | yes |
| `manual` | client `manual_updates` (updates WP-CLI can't see, e.g. greyd_suite) | reminder only |

### 4.2 Commands
```
wpsite hold <c>                              # list held + manual items (with pending versions)
wpsite hold <c> <plugin> [--reason "…"]      # hold
wpsite hold <c> <plugin> --remove            # release
wpsite manual <c> <item> [--reason "…"] [--remove]
```
Other wpsite per-client keys (`deactivate_plugins`, `review_*`) are edited in the file
directly — rare, and `yq -i`/hand edits keep comments.

### 4.3 Post-upgrade briefing (end of `wpsite upgrade`)
Table of everything not `updated`, with class + reason. On a TTY, per `no-package`/`refused`
item: "hold <plugin> for <c>? [y/N]" + optional reason. Always also prints the ready
`wpsite hold …` commands (GUI console / later / scripts). `fatal`/`error` are never offered
for hold — they're bugs to look at.

### 4.4 Held items stay visible
Every upgrade/apply lists held and manual items that have something pending
("held — 6.8.10 available"; "manual — check greyd_suite in wp-admin") so nothing is forgotten.

### 4.5 Apply vs. rehearsal (light, no gate)
Apply reports anything that behaves differently from the latest rehearsal (updated there,
failed here; production versions changed since the backup). Informational only.

---

## Phase 5 — Honest reports
- Internal report uses the classes from 4.1.
- **German customer report: held / no-package / manual items are left out**; it lists what was
  updated. **[changed]** failed items (error/fatal/refused) are left out too — they're
  internal work, and the report only describes what was done. It never claims "bereits aktuell" for things WP-CLI can't see, and never claims a
  step that didn't run in this apply.

## Phase 6 — Tests for the whole bug class
- Production-touching commands are also tested under the real `set -euo pipefail`.
- **Fault injection:** run a clean stubbed `apply`, count its N remote calls, then re-run N
  times with call *i* failing. Invariants for every *i*: never silent; maintenance off again
  unless 2.4 deliberately kept it; verification ran whenever maintenance had been on; nothing
  changed on production before preflight + confirmation. Lighter version (never silent) for
  `backup`, `test`, `redirect`, `hold`. The harness counts calls, so new ones are covered
  automatically.
- Plus unit tests for the registry split, lifecycle rules, classification, hold/manual.

## Phase 7 — Rehearsal fidelity (last)
- Replica core pinned to production's exact version (7.0.6, not the image's 7.0).
- No image-injected akismet/hello/twentytwenty* in the replica.

## Later (not this round)
- GUI: hold dialog after upgrade.
- Canary sites per host type (Mittwald / checkdomain / Strato) for a real apply before each round.

---

## Order
1. Phase 1 registry split (+ mandos cleanup, migration dry-run → your go-ahead → migrate)
2. Phase 2 maintenance + fail-safe exit + always-verify
3. Phase 6 fault-injection harness (proves Phase 2 immediately, then grows with each phase)
4. Phase 3 preflight gate
5. Phase 4 + 5 classification, hold/manual, briefing, honest reports
6. Phase 7 rehearsal fidelity

Each phase ends green (`shellcheck` + `bats`), docs (`CLAUDE.md`) updated, nothing committed.
