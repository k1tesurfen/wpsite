# wpsite

CLI tool to back up WordPress sites over SSH and rebuild near-perfect local
replicas under Docker. macOS + Homebrew.

To keep backups tiny, **uploads are never transferred** — instead their
dimensions are recorded and regenerated locally as blank, layout-accurate
placeholder images/videos.

## Install

> **New team member / non-technical?** Follow the plain-language, click-by-click guide
> instead — **[INSTALL.md](INSTALL.md)** (English) / **[INSTALL.de.md](INSTALL.de.md)**
> (Deutsch). It covers Homebrew, Docker, copying wpsite from the shared Google Drive, and
> the one-time `mandos` config. The steps below are the short technical version.

```bash
brew install yq imagemagick ffmpeg
brew install --cask docker        # or Docker Desktop / OrbStack

git clone <this repo> && cd wpsite
./install.sh                      # symlinks bin/wpsite into /usr/local/bin
                                  #   (WPSITE_BIN_DIR=~/.local/bin ./install.sh to change;
                                  #    ./install.sh --uninstall to remove)

# mandos owns client identity, SSH key onboarding, and Google Drive paths — install it too:
cd ../mandos && make install      # builds & installs /usr/local/bin/mandos

wpsite setup                      # one command: writes base_dir, points mandos at the
                                  #   shared registry + Drive root (mandos config init),
                                  #   and installs your SSH key on every client
wpsite doctor                     # verify everything is ready
```

Client identity/SSH access and the Drive `cloud_base` root now live in **mandos**
(`~/.config/mandos/mandos.yml`); wpsite's own config holds only `base_dir` + your local
`dev:` sites. See [Configuration](#configuration).

## Usage

```bash
# Access (SSH target, WordPress path, keys) — mandos is the keyholder:
mandos client add <name> --ssh <u@h> --wp-root <p>   # onboard access + install your SSH key
mandos client list        # who we have access to   (get/set/unset/remove/setup-key/has too)
mandos client setup-key <c>   # (re)install your personal SSH key on a client's server
# wpsite keeps its OWN registry (WordPress settings per client). A client joins wpsite
# with its first backup:
wpsite backup  <c>        # first run for an ID mandos knows → registers it in wpsite
wpsite show    <c>        # everything wpsite knows about a client (+ its mandos access)
wpsite hold    <c> <plugin> [--reason "…"]   # never auto-update this plugin (upgrade + apply)
wpsite manual  <c> <item>                    # reminder: update this by hand in wp-admin
wpsite forget  <c>        # drop the client from wpsite (--purge: local backups too)

# Backup & build replicas
wpsite backup  <client>   # snapshot a remote site → local backup artifacts (media → placeholders)
wpsite backup --all       # …back up every configured client, one after another
wpsite backup --full <c>  # …download REAL media instead (larger, exact replica)
wpsite build   <client>   # (re)build & run a backup at http://<client>.test (newest by default)
wpsite build <c> --backup <id>   # …use a specific backup (id from `wpsite list <c>`)
wpsite start   <client>   # start a stopped replica (keeps data)
wpsite stop    <client>   # stop a running replica (keeps data, restartable)
wpsite test    <client>   # preflight: SSH reachability + remote deps + wp-cli/DB readiness
wpsite destroy <client>   # remove a replica (containers + DB volume + files)

# Local dev sites (no production source)
wpsite new     [name]     # create a blank local dev site (no name → wizard)
wpsite clone   <c> <dev>  # create a dev site from a client (real media; --light = placeholders)
wpsite inject  <dev>      # live-mount a local plugin into a dev site (default ~/git/aule)
wpsite inject <dev> --activate [--network]   # …and activate it (--network = multisite-wide)

# Upgrade workflow
wpsite upgrade <client>   # update core/plugins/themes on the replica + before→after report
wpsite upgrade <c> --review   # …also screenshot pages before/after & open a comparison
wpsite review  <client>   # re-open the latest upgrade comparison page
wpsite apply   <client>   # run the rehearsed upgrade ON PRODUCTION (fresh backup + typed confirm)

# Backups retention & shared infra
wpsite prune   <client>   # delete old backups (default: keep newest 4)
wpsite prune --all --keep 3            # apply to every client
wpsite prune <c> --older-than 30d --dry-run   # preview by age; --yes to skip the prompt
wpsite proxy   status     # shared reverse proxy + wildcard DNS status
wpsite proxy   install-dns             # one-time: *.test → 127.0.0.1 (drops per-build sudo)
wpsite mail    status     # shared Mailpit (traps all replica email); inbox at :8025
wpsite db      <site>     # open the DB in a browser (Adminer), logged in — client or dev site
wpsite db                 # …reopen the last site's DB (no arg)
wpsite list    [client]   # all clients + backups, or one client's backups in detail
wpsite status             # running replicas and their URLs
wpsite doctor             # verify dependencies and environment
```

Typical loop: `mandos client add` for access, `backup` once (registers the client in
wpsite), then `build` to (re)create the replica from it; `stop`/`start` to pause and
resume without rebuilding; `destroy` to remove the replica (or `forget` to drop the
client from wpsite entirely — mandos access is untouched).

## Configuration

Config is split across two tools:

**wpsite** — `~/.config/wpsite/wpsite.yml` (see [`wpsite.yml.example`](wpsite.yml.example))
holds only your machine-local settings: `base_dir` and your `dev:` sites.

```yaml
base_dir: ~/websites
# dev: sites are managed by `wpsite new`/`clone`
```

**Two shared registries on Google Drive, deliberately not linked:**

- **mandos** (`~/.config/mandos/mandos.yml` → its team file) is the **keyholder**: per
  client only `ssh`, `wp_root` and the Drive project folder, plus SSH-key onboarding and
  the Drive `cloud_base` root. Set it up once with
  `mandos config init --team-config <mandos.team.yml> --cloud-base <Drive-root>`.
- **wpsite** keeps its **own** registry for everything WordPress: hold lists, manual-update
  reminders, deactivate lists, review pages, login path, backup temp dir, … By default it
  sits next to mandos's file (`…/01_Global/mandos/mandos.team.yml` →
  `…/01_Global/wpsite/wpsite.team.yml`); override with `team_config:` in the local config
  or `WPSITE_TEAM_CONFIG`.

```yaml
# wpsite.team.yml
settings:
  test_mail_to: admin@example.com
clients:
  acme:
    registered: 2026-09-23
    hold_plugins:
      advanced-custom-fields-pro: "Pro, licence with the customer (2026-09-23)"
    manual_updates:
      greyd_suite: "updates only visible in wp-admin (2026-09-23)"
    # local_host: acme.test   # optional override (default derived from the live domain)
```

Deleting a client in mandos never touches wpsite (it simply loses production access);
`wpsite forget` never touches mandos. First machine of the team after upgrading from the
old layout: `wpsite migrate-registry` (dry run) → `wpsite migrate-registry --apply`.

Client backups and the Docker working tree live under `<base_dir>/clients/<client>/`;
local-only dev sites live under `<base_dir>/dev/<name>/`.

## Multi-site

Every replica runs at once, each at `http://<client>.test`, via a shared Traefik
reverse proxy that `wpsite build` starts automatically (no per-replica ports). One
optional one-time step removes the per-build `sudo`:

```bash
wpsite proxy install-dns   # dnsmasq: *.test → 127.0.0.1 + /etc/resolver/test (sudo once)
```

Without it, builds fall back to adding a `/etc/hosts` entry per client (sudo each
time). The proxy routes by Host header, so e.g. `acme.test` and `baker.test` are
served simultaneously. `wpsite proxy status` shows what's running.

## Email is trapped (never sent)

Replicas run a production database with **real customer addresses**, so `build`
auto-starts a shared **Mailpit** container and injects a mu-plugin that routes every
`wp_mail()` to it — nothing is ever delivered for real. Read what the site sends at
**http://localhost:8025**. Mail/SMTP plugins are deactivated so they can't relay
around it. `wpsite mail status` / `down` manage the container.

Three layers make the trap hard to escape: the mu-plugin (`wp_mail()`), a
`sendmail_path` shim so any plugin using PHP's native `mail()` is caught too, and —
for **Wordfence** — silencing its own notifications on the replica (it stays active
for scans/WAF). That last one matters because a site linked to **Wordfence Central**
emails alerts from Wordfence's cloud over HTTPS, which no local mail catcher can
intercept; `build` blanks its alert recipients and disconnects Central instead. (Rebuild
existing replicas to pick up the sendmail_path + Wordfence layers.)

## Browse the database

`wpsite db <site>` opens the database of any built replica (client **or** dev site)
in your default browser, already logged in — no credentials to type. It runs a
single shared **Adminer** container (started on first use, built once as
`wpsite/adminer`) that reaches each site's private DB by joining that site's Docker
network on demand, so one install serves every client. Inspect tables, run queries,
edit rows. Run it with no argument (`wpsite db`) to reopen the last site you looked
at — if that site isn't currently built/online it just tells you which one it was and
stops (it never auto-starts a site). `wpsite db status` / `down` manage the container;
the UI lives at **http://localhost:8080** (override with `WPSITE_ADMINER_PORT`).

## Dev conveniences on every replica

- **WP_DEBUG on** — errors logged to `wp-content/debug.log` (not shown on the page),
  with `WP_ENVIRONMENT_TYPE=local` and `SCRIPT_DEBUG`.
- **A known admin login** — production password hashes are unknown, so `build`
  creates/refreshes a dedicated admin and prints it: `wpsite` / `wpsite`. Log in at
  `http://<client>.test/wp-admin/`. Override with `WPSITE_ADMIN_USER` /
  `WPSITE_ADMIN_PASS`. (Existing accounts are left untouched.)

## The quarterly retainer loop

`backup --all` → `build <client>` → `upgrade <client> --review` (eyeball before/after) →
`apply <client>` (run the same upgrade on production). `apply` rehearses nothing itself:
it takes a fresh production backup as a rollback point, requires you to type the client
name, runs the WP-CLI updates over SSH in maintenance mode, and verifies the site
responds. It **never copies replica data to production** — it re-runs the validated
upgrade in place. Rollback is manual (it points you at the fresh backup).

## Development

```bash
brew install bats-core shellcheck
shellcheck -x bin/wpsite lib/*.sh install.sh
bats test/
```

CI runs both on every push (`.github/workflows/lint.yml`).

## Roadmap

See [ROADMAP.md](ROADMAP.md) for the full implementation history and remaining
work. The core platform (backup/build, dnsmasq wildcard DNS, shared Traefik proxy,
Mailpit, sanitization, media tiers, multisite) and the quarterly upgrade workflow
(`upgrade`/`--review`/`apply`) are built and in use.
