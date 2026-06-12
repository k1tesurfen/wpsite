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

## Roadmap

See [ROADMAP.md](ROADMAP.md) for planned work (dnsmasq wildcard DNS, a shared
reverse proxy for running multiple sites at once, mailpit, post-import
sanitization, media tiers).
