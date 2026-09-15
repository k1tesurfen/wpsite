# The dev box environment: toolchain containers and the plugin workflow

**Status:** agreed concepts, not yet implemented. Companion doc: `DEVBOX-PLAN.md`
(roles, data flow, wpsite work items).

This document is written in two passes. **Part A** explains the ideas with no assumed
background. **Part B** gives the mechanics, the gotchas, and the reasoning behind each
decision. Read A first; B will make sense afterwards.

---

# Part A — the concepts in plain terms

## A1. The problem we are solving

Modern WordPress plugin development needs build tools. Gutenberg blocks are written in
JSX, which a browser cannot read — a compiler (`@wordpress/scripts`, which is webpack)
turns them into plain JavaScript. SCSS becomes CSS. Composer generates PHP autoloaders.

Those tools are Node.js and Composer, and installing them globally is exactly the
"cluttering and poisoning my machine" problem we are getting away from: one global Node
install, shared by every project, pulling thousands of transitive dependencies that run
arbitrary install scripts.

So we don't install them. We put them in containers.

## A2. The core idea: one folder, three viewers

The thing that makes this click is that **nothing is ever copied anywhere**. There is
one real directory on the dev box — your plugin's git repository — and three different
things look at it:

```
              ~/git/pluginx/          ← the ONE real directory (git repo, on the host)
                    │
      ┌─────────────┼──────────────────────────┐
      │             │                          │
  the host      WordPress container       toolchain container
  (Debian)      (long-running)            (lives ~40 seconds)
      │             │                          │
  has neither   has PHP + Apache           has node + npm
  node nor PHP  NO node, NO composer       NO webserver
      │             │                          │
  just holds    mounts the repo at         mounts the same repo
  the files     wp-content/plugins/        at /app, runs ONE
  and runs      pluginx and SERVES it      command, writes its
  docker                                   output, then vanishes
```

The WordPress container's job is to **run** the plugin. The toolchain container's job is
to **build** it. They never talk to each other — they just both happen to see the same
folder on disk, so whatever the builder writes, the runtime immediately serves.

That works because a build is a one-shot *transformation of a directory*, not a service:
webpack reads `src/`, writes `build/`, exits. PHP at runtime only ever reads `build/` and
never needs to know Node existed.

## A3. Why not just install Node inside the WordPress container?

Three reasons:

1. It is a **long-lived** container. A compromised build tool would sit there for weeks
   instead of forty seconds.
2. wpsite **rebuilds** that container on every `build`/`clone`, wiping anything
   installed by hand. This is the same reason `_ensure_wp_cli` has to reinstall the
   wp-cli phar after every `up -d`.
3. You would need a **different WordPress image per Node version**, when the whole point
   is that client A can be on Node 20 while client B is on 22.

## A4. Why not install Node on the Debian host?

Because then the dev box has the same problem the Mac had: one global toolchain, shared
by every project, that every `npm install` can write to. Containers give us per-project
versions *and* a blast radius of one directory.

## A5. What a working day looks like

```bash
# once per feature — get the client's real site running locally
wpsite clone schatz schatz-dev          # newest local packet; --backup <id> to pick one

# once per feature — install deps and do a first build
cd ~/git/pluginx
t npm ci                     # a container appears, writes ./node_modules, exits
t npx wp-scripts build       # another container, compiles src/ → build/, exits

# once per feature — bind-mount the repo into the running site
wpsite inject schatz-dev --from ~/git/pluginx --slug pluginx --activate

# then, all day, in a tmux pane
t npx wp-scripts start       # watch mode: recompiles on every save
```

And the loop becomes: edit `src/index.js` on the dev box → webpack rewrites `build/`
within a second → refresh `http://schatz-dev.test` in the browser on your Mac → see the
change. No re-inject, no rebuild, no container restart, no file copying. The bind mount
means the WordPress container is reading the file webpack just wrote.

Watch mode is the one case where the toolchain container is not ephemeral — it lives as
long as you are coding. That is fine; it is still confined to `/app`.

Note what is *absent* from that loop: `wpsite upgrade`. It exists for the quarterly
client-maintenance workflow on the gateway, not for plugin development. If a dev site
needs WordPress or a plugin updated, do it by hand in `/wp-admin`.

## A6. Viewing the sites from the Mac

The replicas are served by a shared Traefik proxy on the dev box, which routes purely on
the HTTP `Host` header and does not care where a request came from. So the Mac only
needs `<devname>.test` to resolve to the dev box.

There is a wrinkle: the Mac **also** serves `.test`, for the client replicas it builds
during the quarterly retainer work (`DEVBOX-PLAN.md` §2, Workflow A). So we split the
namespace by machine:

- **`<client>.test`** → the Mac's own retainer replicas, at `127.0.0.1`
- **`<devsite>.dev.test`** → dev-box sites, at the dev box's tailnet IP

dnsmasq resolves by longest matching domain, so both rules coexist with no per-site
setup, forever:

```
# dnsmasq on the Mac
address=/test/127.0.0.1          # retainer replicas (already set up by
                                 # `wpsite proxy install-dns`)
address=/dev.test/100.x.y.z      # dev box — more specific, so it wins
```

The dev-site suffix comes from `WPSITE_DEV_SUFFIX` (`DEVBOX-PLAN.md` §5.7), set to
`dev.test` on the dev box. Client replicas keep bare `.test`.

**Do not use `.dev` for this.** Google owns `.dev` as a real gTLD and the *entire TLD* is
on the HSTS preload list compiled into every browser, so `http://foo.dev` is force-upgraded
to `https://foo.dev` before DNS is even consulted — and our replicas are HTTP-only
(Traefik's `web` entrypoint on :80, `http://` URLs written into the database by
`_rewrite_urls`). There is no per-domain opt-out. `.test` is reserved by RFC 6761 and is
safe; this is why the PHP tooling world moved off `.dev` years ago. `.localhost` is also
unusable here — resolvers force it to loopback, so it cannot point at a remote machine.

Mailpit (`:8025`, trapped outgoing email) and Adminer (`:8080`, the database browser) run
on the dev box on plain ports and are equally useful from the Mac.

---

# Part B — mechanics and reasoning

## B1. The `t` script

A per-project `.toolchain` file pins which image runs which command, so version choices
live with the project and not in your shell profile:

```
# ~/git/pluginx/.toolchain
npm=node:22-alpine
npx=node:22-alpine
node=node:22-alpine
composer=composer:2
```

And `~/.local/bin/t`:

```bash
#!/usr/bin/env bash
# t — run a project toolchain command in a throwaway container.
#   t npm ci · t npx wp-scripts build · t composer install
set -euo pipefail
cmd="${1:?usage: t <npm|npx|composer|node> [args...]}"
img="$(sed -n "s/^${cmd}=//p" .toolchain 2>/dev/null | head -1)"
[ -n "$img" ] || { echo "t: '$cmd' not defined in ./.toolchain" >&2; exit 1; }
exec docker run --rm -it \
  -u "$(id -u):$(id -g)" \
  -v "$PWD":/app -w /app \
  -v tc-cache:/cache \
  -e HOME=/tmp \
  -e npm_config_cache=/cache/npm \
  -e COMPOSER_CACHE_DIR=/cache/composer \
  "$img" "$cmd" "${@:2}"
```

Run it from inside the project directory — it uses `$PWD` and `./.toolchain`.

Three lines are doing real work:

**`-u "$(id -u):$(id -g)"`** — runs the container as *you*, so `node_modules/` and
`build/` come out owned by your user. Leave it off and everything is root-owned and you
are typing `sudo rm -rf node_modules`. This is the same class of problem as the
`wp-content` ownership blocker in `DEVBOX-PLAN.md` §5.1: native Linux bind mounts
preserve host UIDs, and macOS Docker Desktop's filesystem layer had been hiding that.

**`-e HOME=/tmp`** — the gotcha that catches everyone. Once you pass `-u`, the container
user has no home directory, and both npm and Composer try to write config into a home
that does not exist, failing with confusing permission errors. Pointing `HOME` at a
writable path fixes it.

**`-v tc-cache:/cache`** — a named Docker volume for package caches, shared across
projects, so `npm ci` does not re-download the internet for every client. This is a
deliberate crack in the isolation between projects; see B5.

Drop `-t` when calling this from a script rather than a terminal.

## B2. How `inject` actually works

`wpsite inject <devsite> --from <abs-path> --slug <name>` does four things
(`lib/cmd_inject.sh`):

1. Renames the dev site's existing `wp-content/plugins/<slug>` to `<slug>-alt`, so if
   the client already ships that plugin their production copy is preserved but inactive
   and out of the way.
2. Writes a **`docker-compose.override.yml`** — it does not edit the generated
   `docker-compose.yml`. Compose auto-merges the override on the existing
   `docker compose -p <project>` calls and *concatenates* the `volumes` lists, so
   `./wp-content` survives alongside the new bind mount.
3. `up -d` to recreate the container with the mount.
4. Unconditionally re-runs `_ensure_wp_cli`.

Step 4 is not optional plumbing. The wp-cli phar is `docker cp`'d into the container's
own filesystem *layer*, not a volume, so a recreate wipes it — and every later
`docker exec … wp` then fails with `executable file not found`, silently no-opping every
`|| true`-guarded wp-cli step.

Two consequences for daily use:

- **`inject` is per-clone, not permanent.** `wpsite build`/`clone` wipe the docker dir
  and take the override file with them. Re-inject after a rebuild.
- **`inject` only accepts dev sites.** `cmd_inject.sh:45` hard-refuses a client name.
  This is why the dev box workflow uses `clone` (which creates a dev site) rather than
  `build` (which creates a client replica).

The mount is multisite-agnostic — `wp-content/plugins/` is network-shared, so the bind
lands correctly for a whole network with no special-casing.

## B3. Ownership inside the injected plugin

The repo is owned by your user (uid 1000); Apache in the container runs as www-data
(33). So the container can **read** the plugin but not **write** into it.

Reads are all a normal plugin needs. But a plugin that writes logs or a cache next to
itself will fail. Fix by pointing it at `wp-content/uploads/`, or group-writing that one
subdirectory. Same root cause as `DEVBOX-PLAN.md` §5.1 — and once that item lands (a
derived image with www-data remapped to the host UID) this problem disappears too.

## B4. Performance note

`node_modules` on a bind mount is genuinely **fast** on native Linux. If you have
suffered through webpack on Docker Desktop on the Mac, that pain is a macOS
filesystem-virtualisation artifact and simply does not exist here. This part of the move
will feel better, not worse.

## B5. What this isolation does and does not buy

Be clear-eyed about it.

**It protects:** `~/.ssh`, your other project directories, anything outside `$PWD`, and
— because of the boundary in `DEVBOX-PLAN.md` — production, Google Drive, and everything
on the Mac.

**It does not protect:** the project directory itself, or the shared package cache
volume. A malicious `postinstall` owns both. That is acceptable because on this machine
the project directory is already treated as expendable and is git-backed.

**It collapses entirely if you mount the Docker socket into a toolchain container.**
Socket access is host root. Never do it.

If a specific dependency ever looks off, switching `-v tc-cache:/cache` to a per-project
volume is a one-word change. Adding `--network none` also works for build-only steps
(`wp-scripts build`) though not for `npm ci`, which needs the network.

## B6. Decisions and rejected alternatives

| Decision | Why | Rejected |
|---|---|---|
| Ephemeral one-shot containers behind a `t` wrapper | Zero host installs, per-project versions, blast radius of one directory, no daemon to maintain | Global Node/Composer on the host |
| Toolchain separate from the WordPress container | Long-lived vs 40-second lifetime; survives wpsite's container recreates; decouples Node version from WP image | Installing Node in the WP image |
| Per-project `.toolchain` file | Version choice travels with the repo and is visible in git, not hidden in a shell profile | A global default image |
| `wpsite inject` bind mount for the live loop | Symlinks into Docker do not work; a bind mount does. Already implemented, already handles the wp-cli recreate trap | Copying build output into the container |
| Shared package cache volume | Avoids re-downloading per project; the cross-project leak is acceptable on an expendable box | Per-project volumes (available if needed) |
| Plain `t` script, not devcontainers | The devcontainer CLI needs a Node install — the exact thing we are avoiding — and its editor integration is worthless on a headless TTY box | VS Code devcontainers |
| Per-repo GitHub **deploy keys**, not an account key | Same daily workflow; a compromise reaches only the repos that box works on rather than everything we can push to | One account-wide SSH key |

## B7. Onboarding checklist

1. Debian 13 prerequisites — see `DEVBOX-PLAN.md` §7. Note especially: mikefarah `yq`
   from GitHub (not `apt install yq`), Docker from Docker's apt repo (not `docker.io`),
   and Claude Code via the native installer (not npm).
2. Confirm no Node, PHP, or Composer on the host. That is the invariant.
3. Install `t` to `~/.local/bin/t` and `chmod +x`.
4. Per-repo GitHub deploy keys.
5. Wildcard `.test` DNS on the Mac pointing at the dev box's tailnet IP (A6).
6. Firewall: allow `80`/`8025`/`8080` only on `tailscale0`, or set the bind address once
   `WPSITE_PROXY_BIND` exists (`DEVBOX-PLAN.md` §5.10).
7. `tmux` on every long-running operation. Imports are measured in minutes.
8. Verify every plugin repo pushes to a real remote. **The dev box must be disposable:**
   if reinstalling it costs an afternoon rather than a week, "nuke it on suspicion"
   becomes an option you will actually take — which is worth more than most hardening
   you could do to it.
