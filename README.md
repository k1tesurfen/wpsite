# wpsite

CLI tool to back up WordPress sites over SSH and rebuild near-perfect local
replicas under Docker. macOS + Homebrew.

To keep backups tiny, **uploads are never transferred** — instead their
dimensions are recorded and regenerated locally as blank, layout-accurate
placeholder images/videos.

## Install

```bash
brew install yq imagemagick ffmpeg
brew install --cask docker        # or Docker Desktop / OrbStack

git clone <this repo> && cd wpsite
./install.sh                      # symlinks bin/wpsite into /usr/local/bin
                                  #   (WPSITE_BIN_DIR=~/.local/bin ./install.sh to change;
                                  #    ./install.sh --uninstall to remove)

mkdir -p ~/.config/wpsite
cp wpsite.yml.example ~/.config/wpsite/wpsite.yml   # then edit

wpsite doctor                     # verify everything is ready
```

## Usage

```bash
wpsite backup  <client>   # snapshot a remote site → local backup artifacts (media → placeholders)
wpsite backup --full <c>  # …download REAL media instead (larger, exact replica)
wpsite build   <client>   # (re)build & run a backup at http://<client>.test (newest by default)
wpsite build <c> --backup <id>   # …use a specific backup (id from `wpsite list <c>`)
wpsite start   <client>   # start a stopped replica (keeps data)
wpsite stop    <client>   # stop a running replica (keeps data, restartable)
wpsite destroy <client>   # remove a replica (containers + DB volume + files)
wpsite prune   <client>   # delete old backups (default: keep newest 5)
wpsite prune --all --keep 3            # apply to every client
wpsite prune <c> --older-than 30d --dry-run   # preview by age; --yes to skip the prompt
wpsite proxy   status     # shared reverse proxy + wildcard DNS status
wpsite proxy   install-dns             # one-time: *.test → 127.0.0.1 (drops per-build sudo)
wpsite mail    status     # shared Mailpit (traps all replica email); inbox at :8025
wpsite list    [client]   # all clients + backups, or one client's backups in detail
wpsite status             # running replicas and their URLs
wpsite doctor             # verify dependencies and environment
```

Typical loop: `backup` once, then `build` to (re)create the replica from it;
`stop`/`start` to pause and resume without rebuilding; `destroy` to remove it.

## Configuration

`~/.config/wpsite/wpsite.yml` (see [`wpsite.yml.example`](wpsite.yml.example)):

```yaml
base_dir: ~/websites
clients:
  acme:
    ssh: ubuntu@acme-industrial.com
    wp_root: /var/www/acme.com
    # local_host: acme.test   # optional override (default <client>.test)
```

Backups and the Docker working tree live under `<base_dir>/<client>/`.

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

## Dev conveniences on every replica

- **WP_DEBUG on** — errors logged to `wp-content/debug.log` (not shown on the page),
  with `WP_ENVIRONMENT_TYPE=local` and `SCRIPT_DEBUG`.
- **A known admin login** — production password hashes are unknown, so `build`
  creates/refreshes a dedicated admin and prints it: `wpsite` / `wpsite`. Log in at
  `http://<client>.test/wp-admin/`. Override with `WPSITE_ADMIN_USER` /
  `WPSITE_ADMIN_PASS`. (Existing accounts are left untouched.)

## Development

```bash
brew install bats-core shellcheck
shellcheck -x bin/wpsite lib/*.sh install.sh
bats test/
```

CI runs both on every push (`.github/workflows/lint.yml`).

## Roadmap

See [ROADMAP.md](ROADMAP.md) for planned work (dnsmasq wildcard DNS, a shared
reverse proxy for running multiple sites at once, mailpit, post-import
sanitization, media tiers).
