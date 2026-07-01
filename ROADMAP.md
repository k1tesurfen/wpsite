# wpsite — Roadmap & Implementation History

The single source of truth for what `wpsite` is, how it got here, and what's left.
A macOS + Homebrew Bash CLI that snapshots production WordPress sites over SSH and
rebuilds near-perfect local replicas under Docker — then rehearses quarterly
core/plugin/theme upgrades on the replica and applies the validated result to
production in place.

```
wpsite client add|edit|remove <name>       # manage clients (add wizard: ssh-copy-id + test)
wpsite backup  <client> [--full] [--all]   # remote → local artifacts
wpsite build   <client>                    # artifacts → running Docker replica
wpsite start | stop | destroy <client>     # lifecycle of a built replica
wpsite list | status | doctor              # introspection + preflight
wpsite prune   <client>|--all [<id>] [--keep N] [--older-than Nd] [--dry-run] [--yes]
wpsite backup sync [<client>|--all] [--dry-run]   # mirror local ↔ cloud (Drive)
wpsite upgrade <client> [--review]         # rehearse the upgrade on the replica
wpsite apply   <client>                    # re-run the validated upgrade ON PRODUCTION
wpsite proxy   up|down|status|install-dns  # shared Traefik proxy + wildcard DNS
wpsite mail    up                          # shared Mailpit inbox
```

---

## Guiding principles

1. **macOS + Homebrew only.** We lean into the platform (dnsmasq, Mailpit, brew
   deps, `/System` fonts, Docker Desktop) instead of writing portable shell. CI runs
   on `macos-latest` for the same reason — Linux gave false failures.
2. **Bash orchestrates; it never computes or holds rich data.** It shells out to the
   right tool (Docker, ssh, WP-CLI, ImageMagick, ffmpeg, Playwright, yq) and renders
   the result. Stability comes from the bats suite + shellcheck + CI, not from
   rewriting in another language. (If this ever ships to a team or goes
   cross-platform, revisit with Go — not warranted for single-user macOS today.)
3. **The replica is a rehearsal, not the source of truth.** We never copy replica
   data back to production (see Upgrade workflow). We re-run the _validated upgrade_
   on production in place.

---

## Implementation history

Everything below is **built and in real use against client sites** unless marked
otherwise. Deep mechanics live in `CLAUDE.md`; this is the what/why.

### Foundation & hygiene — ✅ done

- Unified `bin/wpsite` dispatcher + `lib/common.sh`; one `lib/cmd_<name>.sh` per
  subcommand. Arg dispatch only in `bin/wpsite`.
- `set -euo pipefail` everywhere; `trap` cleanup of remote `/tmp` dirs, the SSH mux,
  and half-built `docker/` dirs.
- `wpsite doctor` — one preflight for brew deps + Docker daemon.
- YAML config (`~/.config/wpsite/wpsite.yml`) parsed with `yq` (a hard dep) — **no
  `eval`/`source` of config input**. Accessed only through `common.sh` helpers.
- shellcheck + bats gate every push (`.github/workflows/lint.yml`, on macOS).

### Correctness backbone — ✅ done

- Per-run, per-client remote paths (`/tmp/wpsite_<client>_<timestamp>`) so same-day
  and concurrent runs don't collide.
- SSH ControlMaster multiplexing (`wpsite_ssh`); rsync-free downloads via tar over
  SSH stdin (shared hosts lack rsync; tar is universal).
- **Capture the real source URL at backup time** (`wp option get siteurl`/`home` →
  `meta.env`), not a guessed `<client>.com`. The replica rewrites the _actual_ prod
  URL → local. Single biggest fidelity win.
- Pin **both** WP and PHP versions from `meta.env` → `wordpress:<wp>-php<php>-apache`.
- Local TLD is `.test` (RFC 6761), not `.local` (macOS mDNS reserves it).

### Replica fidelity & infrastructure — ✅ done

- **Wildcard DNS via dnsmasq** (`wpsite proxy install-dns` → `/etc/resolver/test`).
  Falls back to a per-host `/etc/hosts` entry (sudo) when the resolver isn't set up.
- **Shared Traefik reverse proxy** so every client replica runs at once. Replicas
  publish **no host port**; they join the external `wpsite_proxy` network and Traefik
  routes by name via a per-client route file it watches. **File provider, not the
  Docker socket** — Docker Desktop blocks the socket for containers. Auto-started by
  `build`; route removed by `destroy`.
- **Mailpit** traps all outbound mail. `build` auto-starts a shared Mailpit container;
  a mu-plugin forces `wp_mail()` through SMTP to it (host alias `wpsite-mail` — the
  `_` in the container name is RFC-invalid for PHPMailer). Inbox on `localhost:8025`.
- **Post-import sanitization:**
  - **Plugin deactivation** (`_sanitize_plugins`): deactivates caching/optimization/
    backup/staging + mail/SMTP plugins (stale caches, phone-home, request hijacking,
    relays around Mailpit) while leaving functional plugins active. Runs
    `--skip-plugins` so it edits `active_plugins` without loading/fataling any plugin.
    Extend per client via `clients.<c>.deactivate_plugins`. **On multisite it also
    runs a `--network` pass** (`active-network` plugins live in `wp_sitemeta`, not any
    site's `active_plugins`, so the per-site pass alone misses them).
  - Drop-in/cache stripping (`advanced-cache.php`, `object-cache.php`, `db.php`,
    `wp-content/cache`) — they serve stale HTML with hardcoded prod URLs and break
    wp-cli.
  - Dev extras: `WP_DEBUG`/`WP_DEBUG_LOG`, `WP_ENVIRONMENT_TYPE=local`, `SCRIPT_DEBUG`
    via `WORDPRESS_CONFIG_EXTRA`.
  - Known admin login (`wpsite`/`wpsite`, overridable via `WPSITE_ADMIN_USER`/`_PASS`)
    since prod password hashes are unknown.
- **Domain rewrite** (`_rewrite_urls`) covers http/https × plain/JSON-escaped ×
  protocol-relative for every host in `meta.env`, via `wp search-replace` (handles
  serialized data), running `--skip-plugins --skip-themes` and moving `mu-plugins/`
  aside so prod-only plugins don't fatal the bootstrap.

### Media strategy — ✅ done (the clever bit)

- **Placeholder tier (default):** media files are never transferred. `backup` records
  each upload's dimensions (ImageMagick `identify`, `[0]` for first video frame);
  `build` regenerates blank, layout-accurate placeholders at exact dimensions
  (ImageMagick for images, ffmpeg black clips with even dims for video, empty files
  for PDFs). Preserves layout without copying media.
- **`--full` tier:** ships the real media, writes no `media_map.txt`; `build` keys off
  its absence to skip regeneration (and the ImageMagick/ffmpeg requirement).
- **Parallelized generation:** the map is split into CPU-count stripes
  (`awk 'NR % n == k'`), each a background subshell. Per-stripe failures go to
  pre-created `fail.$k` files (pre-creating dodges the unmatched-glob `set -e` trap);
  one bad asset never aborts the run.
- **Framed + labelled placeholders:** grey fill + visible frame (a plain white
  placeholder is invisible on a white/SVG background) + centered filename/dimensions,
  middle-truncated, text dropped when too small. Needs an explicit `-font` (macOS
  ImageMagick has no default).
- Fonts/non-media under `uploads/` (woff2/ttf, plugin-generated CSS/JSON) are kept
  real — only true media extensions + regenerable caches are excluded.

### Lifecycle, UX & distribution — ✅ done

- `build` (heavy re-create), `start`/`stop` (pause/resume, keep data), `destroy`
  (full teardown), `list` (+ detail), `status`, `doctor`. Teardown passes
  `-p <project>` so the named DB volume is actually wiped.
- `--backup <id>` selection (default newest).
- `wpsite prune` — rolling retention (default keep newest `keep_backups`/4, skipping
  `-permanent`), `--keep N` / `--older-than Nd`, single-backup form `prune <client> <id>`,
  preview + confirm by default. Prunes local + cloud together. Tested.
- **Cloud backup sync — ✅ done.** Mirror local backups to a mounted Google Drive folder
  (cloud = single source of truth). `backup sync`, auto-push + rolling auto-prune after
  each `backup`, manifest-based new-vs-deleted detection, `-permanent` backups (`--persist`
  / `backup persist`) exempt from prune with tolerant `--backup` id resolution. macOS-only
  (the Drive mount is a filesystem path). See CLAUDE.md "Cloud backup sync".
- Consistent `log_info/ok/warn/error/debug` + `die`; `--verbose`.
- `install.sh` symlink installer. (Homebrew formula skipped by choice.)
- **`wpsite client add|edit|remove` — ✅ done.** Client lifecycle in the config.
  **add:** onboarding wizard — prompts name/ssh/wp_root (+ cloud_dir when cloud sync is
  on, since its default can't be derived before the first backup, + gated advanced
  overrides), writes the entry via `client_set` (`yq -i`, comment-preserving, appended at
  the end of `clients:`), installs the SSH key (`ssh-copy-id`, with a manual
  `authorized_keys` fallback since macOS ships none), then runs `wpsite test` — a failed
  test only warns and keeps the entry. **edit:** interactive (Enter keeps each current
  value) or flag-driven field changes, `--unset` for optionals, re-tests only when
  ssh/wp_root changed; rename intentionally unsupported. **remove:** tears down the
  replica + drops the config entry, keeps local backups unless `--purge`, never touches
  cloud; typed-name confirm for `--purge`, `[y/N]` otherwise. Scriptable via flags for the
  GUI. `test/client.bats`.

### Upgrade workflow — the quarterly retainer

**Core principle — rehearse locally, apply on production.** The replica's DB is a
snapshot frozen at backup time and its media are placeholders, so copying replica data
back to prod would destroy everything that happened since the backup. Instead the
replica _proves_ the upgrade is safe and produces a changelog; then we re-run the same
upgrade commands on production in place, against its own live data. (Better, too:
premium plugins update more reliably where their license is active.)

- **Phase A — `wpsite upgrade <client>` — ✅ built, verified live.**
  WP-CLI `core update`/`update-db`, `plugin update --all`, `theme update --all` on the
  running replica; captures before/after `name,version,update` CSVs and writes a
  human report (`report.txt`) + CSVs to `<base>/<client>/upgrades/<timestamp>/`.
  Flags premium/manual updates still "available". Fully reversible (`wpsite build` to
  reset). Runs `--skip-plugins --skip-themes` to dodge the `aule` bootstrap fatal —
  consequence: premium plugins with their own updaters won't update _locally_ and are
  flagged "handle manually"; they update on production in Phase C where licenses are
  active. _Why `core update-db`:_ it runs WordPress's own schema/data migrations a new
  core version may need (not a MariaDB upgrade, not content) — wp-admin does this
  automatically; WP-CLI updates files only, so it's an explicit step.
- **Phase B — `upgrade --review` — ✅ built, verified live.**
  Captures key pages before/after with a one-time-built native `wpsite/shot`
  Playwright image (reaches the replica through Traefik via `--add-host`), runs a
  smoke check (every page 200 + no new `PHP Fatal` in `debug.log`), and writes a
  self-contained `review.html` (drag-to-wipe slider, per-page side-by-side toggle)
  that it `open`s. `wpsite review <client>` re-opens the latest. Pages = home + a
  small auto-picked set (`wp post list`), overridable via `clients.<c>.review_pages`.
  The tool **captures and presents; the human judges** — no diff algorithm. Capture
  runs the Playwright API (not the `screenshot` CLI) so it can **hide cookie/consent
  banners** before each shot — Usercentrics (`#usercentrics-root`) + CCM19
  (`.ccm-root`) by default, extendable per client via `clients.<c>.review_dismiss`.
- **Phase C — `wpsite apply <client>` — ✅ built, ⚠ unverified against a live server.**
  The only command that writes to a client server. Sequence: mandatory fresh backup
  (the rollback point; aborts if it fails) → maintenance ON → re-run the validated
  upgrade over SSH → maintenance OFF (always, even on failure) → verify the live home
  returns 200 → prod report. Guards (non-negotiable): typed-name confirmation
  (`_confirm_prod`), one client at a time, fresh backup mandatory, **no `--yes`
  bypass**. **Never copies replica data to prod.** Rollback is **manual on purpose**
  (an untested auto-restore on prod is its own footgun). Shipped unverified — only the
  orchestration/guards are unit-tested (`test/apply.bats`, all SSH/network stubbed).
  Treat the first real run as careful.

### Multisite support (subdomain + domain-mapped) — ✅ built

Clients run 2–3 networks of 3–8 sites, mixing subdomain (`site1.domain.com`) and
domain-mapped (`mycooldomain.com`) subsites in one network.

**Mapping rule (locked):** read EVERY domain from the live network (`wp site list`) and
swap only the TLD to `.test`, keeping the original host — `shop.example.com →
shop.example.test`, `mycooldomain.com → mycooldomain.test`. Handles subdomain and
mapped subsites uniformly, mirrors prod, all resolve via dnsmasq `*.test`, and
replacing full hosts _with scheme_ avoids touching email addresses.

- **M1 — backup detection — ✅.** Records `MULTISITE` + `SUBDOMAIN_INSTALL` in
  `meta.env` and the full network in `sites.csv` (`blog_id,domain,path,url`).
- **M2 — `core update-db --network` — ✅.** `upgrade` + `apply` detect `is_multisite()`
  and add `--network` (which errors on single sites, so it's conditional). Makes the
  production `apply` correct for multisite even before local replicas existed.
- **M3 — multisite replica build — ✅, verified (greyda, 6 subsites).** Logic in
  `lib/cmd_build_multisite.sh`; `cmd_build` branches on `is_ms`. Injects MS constants
  via `WORDPRESS_CONFIG_EXTRA`; **fixes `wp_site`/`wp_blogs` domains with RAW SQL
  first** (breaks the wp-cli bootstrap chicken-and-egg — can't `wp` a network whose
  domains don't match the config); per-domain `search-replace`; one Traefik route
  listing every local host; known admin created then promoted to super-admin **and
  added to every subsite** so the admin-bar "My Sites" lists them all. Requires
  dnsmasq wildcard DNS. All 6 greyda subsites serve HTTP 200 through Traefik.
- **M4 — multisite review — ✅, verified (greyda, 12 specs).** `upgrade --review`
  branches on `is_multisite()`: home + 1 page **per subsite**, subsite list read from
  the running replica's DB, slugs namespaced by host so they don't collide,
  `--add-host` per subsite domain, smoke-check Host header derived per-spec.

---

## Open / not yet built

Small, optional, and unforced — picked up when the need is actually felt.

- **`none` media tier** — skip media entirely (no placeholders) for builds where only
  DB/plugin behavior matters, not layout. Low value given placeholder is fast.
- **Domain-mapped multisite verification** — the TLD-swap path treats mapped and
  subdomain subsites identically, but no mapped-domain client backup has been on hand
  to confirm. Verify on the first one.
- **`apply` live-server verification** — Phase C ships unverified against a real
  server (no prod SSH during development). First real run gets careful, hands-on
  treatment. _(Held until the user can test end-to-end — not a coding task.)_

## Deliberately not done

- **Copy replica data → production.** Data-loss bug, never a feature (see Upgrade
  workflow). The whole architecture exists to avoid it.
- **Automated rollback in `apply`.** An untested auto-restore on production is a
  footgun; on failure we deactivate maintenance mode and point at the fresh backup +
  manual steps.
- **Homebrew formula.** Skipped by choice; `install.sh` symlink is enough for a
  single user.
- **API/secret scrubbing.** Considered and **declined** — not worth the maintenance
  surface for this workflow.

---

## Key design rationale (worth keeping)

- **tar over SSH, not rsync.** Shared client hosts often lack rsync; tar is universal.
  Every backup is a fresh full dump into a new timestamped dir, so rsync's delta
  advantage is moot. Trade-off: a dropped SSH connection aborts an in-progress
  backup — just re-run.
- **Traefik file provider, not the Docker socket.** On Docker Desktop the socket is a
  symlink to the user socket; containers get permission-denied/empty-API errors. Don't
  switch back.
- **RAW SQL before wp-cli on multisite.** wp-cli can't bootstrap a network whose
  `wp_site`/`wp_blogs` domains don't match `DOMAIN_CURRENT_SITE`; fix the domains with
  plain SQL (no WP bootstrap needed) first, then everything else is wp-cli.
- **`--skip-plugins --skip-themes` for every wp-cli call.** Prod-only plugins (e.g.
  Greyd's `aule`, which calls `add_settings_error()` at `plugins_loaded` in CLI
  context) fatal the bootstrap otherwise. File-only operations don't need plugins
  loaded.
