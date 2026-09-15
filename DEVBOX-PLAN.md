# Gateway + dev box: plan and required wpsite changes

**Status:** agreed design, not yet implemented. Companion doc: `DEVBOX-TOOLCHAIN.md`
(the dev environment itself). Platform contract lives in `CLAUDE.md` → "What this is".

---

## 1. In plain terms

Today one MacBook does everything: company email and planning, production access,
Google Drive, *and* WordPress development with its thousands of lines of third-party
npm/composer/plugin code.

We are splitting that in two:

- The **Mac** stays the *gateway*. It keeps the production SSH keys and Google Drive,
  pulls copies of live sites, ships them to the dev box — and keeps doing the **quarterly
  client-maintenance work** end to end, because that work touches production.
- A **headless Debian 13 box** becomes the *plugin factory*. It hosts the WordPress
  replicas that plugin development runs against, runs the build tools in throwaway
  containers, and runs Claude Code. It has **no** production access and **no** Google
  Drive.

Note what this is *not*: the dev box is not "where replicas live". Both machines run
replicas, for different reasons (§2).

We reach it over SSH on a Tailscale tailnet and view the sites in a browser on the Mac.

**Why:** the two riskiest things in this workflow are an agent with shell access and a
mountain of untrusted transitive dependencies. Putting both on a machine that cannot
reach production, Drive, or company communication means a supply-chain compromise costs
us one expendable machine instead of the company's data.

**The one rule that makes it work:** the dev box never holds a production credential.
Everything reaching production hops via the Mac. We accept that a compromised dev box
can poison plugin source in our GitHub repos (it holds per-repo deploy keys), which
could eventually reach production — that risk exists on any dev machine. What we refuse
is *direct* access to every client's database.

---

## 2. Two workflows, two machines

The split follows the **workflow**, not the tool. wpsite serves two jobs that happen to
share a codebase, and only one of them moves.

### Workflow A — client maintenance (retainers). Stays entirely on the gateway.

Quarterly core/plugin/theme updates across ~50 client sites. The value of wpsite here is
rehearsing the upgrade locally before touching production, then applying the validated
one in place, and producing the client report:

```
backup <c>  →  build <c>  →  upgrade <c>  →  apply <c>        (all on the gateway)
                (replica)     (rehearse +      (production)
                              screenshot
                              review + PDF)
```

Every step needs either production SSH or the client registry, so **the gateway keeps
Docker, keeps building client replicas, and keeps `upgrade`/`review`.** This is the
workflow the German `wartungsbericht.txt`/`.pdf` exists for.

### Workflow B — plugin and tool development. Moves to the dev box.

Build a plugin against a realistic copy of a client's site. Needs no production access
at all once the packet has arrived:

```
(gateway) backup --light <c>  →  push packet
(dev box) clone <c> <devsite>  →  inject <devsite> --from ~/git/pluginx
                               →  edit / build / refresh, all day
```

Updating WordPress or plugins on a dev site, if ever needed, is done by hand in
`/wp-admin`. `wpsite upgrade` is not part of this workflow.

### Role table

| | **Gateway (macOS)** | **Dev box (Debian 13, headless)** |
|---|---|---|
| Production SSH keys | yes — the only copy | **never** |
| Google Drive / `cloud_base` | yes | no (unset → all cloud ops no-op) |
| mandos + client registry | yes | **not installed** |
| Docker replicas | yes — client replicas for retainer rehearsals | yes — dev sites for plugin work |
| wpsite commands | `backup`, `build`, `clone`, `upgrade`, `review`, `apply`, `redirect`, `prune`, `client`, `test`, `list`, `db` | `clone`, `new`, `inject`, `start`/`stop`/`destroy`, `db`, `status`, `list` |
| Client report PDF (`cupsfilter`) | yes | **never needed** |
| Node / PHP / Composer on the host | none | **none** (containers only) |
| Disposable | no | yes, by design |

`apply` and `redirect` — the only two commands that write to a live server — stay on the
gateway unconditionally. So do `upgrade` and `review`, because they belong to Workflow A.

---

## 3. Data flow: the "packet"

`_build_from_backup` consumes nothing but a backup directory, and `meta.env` carries the
WP version, PHP version, table prefix and production URLs. So the backup directory is a
complete, self-contained transport unit that refers to nothing on the Mac.

```
  production  ──SSH──▶  Mac  ──rsync over tailnet──▶  dev box  ──▶  Docker replica
              (backup)        (the packet)                (import)

  packet = <base_dir>/clients/<client>/backups/<YYYYMMDD_HHMMSS>/
             db.sql · wp-content.tar.gz · meta.env · [media_map.txt] · [sites.csv]
```

Real-world size, full media: ~1.1 GB (191 MB `db.sql` + 944 MB tarball).
With `backup --light`: **~20 MB** — placeholder media at exact original dimensions, full
database, all plugin and theme files. **`--light` is the default choice for feature
work**; take a full backup only for genuine visual QA on real imagery.

Transport notes: rsync with `--compress --skip-compress=gz,tgz,zip,mp4,jpg,png` (so
`db.sql` compresses ~10× on the wire and the already-gzipped tarball doesn't burn CPU),
plus `--partial --append-verify` so a dropped connection resumes. On a home LAN,
Tailscale negotiates a **direct** connection — check `tailscale status` for `direct` vs
`relay`; direct means LAN speed, not upload speed.

---

## 4. Decisions taken, and what we rejected

| Decision | Why | Rejected alternative |
|---|---|---|
| One codebase for both platforms | ~30 lines are genuinely macOS-specific out of 5,500; a fork reintroduces at repo level exactly the drift `_build_from_backup` exists to prevent at function level | A stripped "dev box edition" branch |
| Capability detection, not `uname` branches | Already the codebase idiom (`cloud_available`, `_ensure_local_dns`, `have`/`require`) | Scattered `if [ "$(uname)" = Darwin ]` |
| Nothing to strip for Drive | It is not a macOS feature — it is an optional path behind `cloud_available()`. Leaving `cloud_base` unset *is* the Drive-free build | Removing `lib/cloud.sh` on the dev box |
| Prod SSH on the gateway only | Direct SSH from the dev box = every client's DB one hop from untrusted npm code; immediate, estate-wide, no artifact to diff afterwards. Poisoned plugin code is scoped, delayed and reviewable in git history. For a German agency handling client customer data this is also the incident/reportable-breach line | Permanent prod keys on the dev box |
| No ephemeral/JIT keys either | `mandos client setup-key` only *appends* to remote `authorized_keys` (`remote/remote.go:134`) — there is no revocation path in either repo, so "delete the key" leaves the authorization live and accumulates orphaned keys. And resident malware simply waits for the window. Six steps, one easy to skip, to save one rsync that happens once per feature | Per-client temporary keys |
| Dev box needs no mandos at all | After the three changes in §5, every remaining `client_get`/`cloud base` call is `\|\| true`-wrapped and degrades to empty. Also means **no Linux build of mandos is needed** | Syncing the team YAML to the dev box (would put a map of the production estate on the expendable machine) |
| `clone` never pulls from production; always a local backup | Makes `clone` symmetric with `build` (which is already local-backup-only), removes the surprise that a command named "clone" silently hits prod, and makes its behaviour identical on both machines. The gateway pays one extra command: `backup` then `clone` | Keeping the fresh-backup path as the default |
| `clone` made registry-optional, rather than adding `wpsite import` | Once `clone` is local-only both would need exactly one precondition — a complete local backup — so a second command is pure surface area. `require_client` → "backup dir exists and is complete" | A separate `import <backup-dir> <devname>`; stub registry entries with dummy `ssh`/`wp_root` |
| `inject` (not `build`) for plugin work | `cmd_inject.sh:45` hard-refuses anything that is not a dev site | — |
| `upgrade`/`review` stay client-only and gateway-only | They exist for the quarterly retainer workflow (§2 A), which needs prod SSH and the registry anyway. Plugin development never uses them — WordPress/plugin updates on a dev site are done by hand in `/wp-admin` | Teaching `upgrade` to accept dev sites (see §6) |
| Dev sites live under `.dev.test`, clients under `.test` | Splits the namespace by machine so the Mac's dnsmasq can route each to the right host by longest match, with no per-site `/etc/hosts`. Stays inside `.test`, which RFC 6761 reserves permanently | **`.dev`** — Google owns it as a real gTLD and the **whole TLD is HSTS-preloaded** into every browser binary, so `http://` is force-upgraded to `https://` before DNS and our HTTP-only replicas are unreachable. Also `.localhost` (resolvers force it to loopback, so it cannot point at a remote box) |
| No PDF/report tooling on the dev box | The `wartungsbericht` is a Workflow A client deliverable, produced on the gateway where `cupsfilter` exists | A `_txt_to_pdf` shim with a Linux fallback |

---

## 5. Work items

Ordered. P0 items block everything after them.

### P0 — nothing works on Debian without these

**1. `wp-content` bind-mount ownership** — *the blocker.* ✅ **DONE** (`_wp_image_for_host`, `cmd_build.sh`) — written but only verifiable on Debian.
`_render_compose` (`cmd_build.sh:600`) mounts `./wp-content:/var/www/html/wp-content`
with no `user:`, and nothing in the tree ever `chown`s it (only `chmod +x` on the wp-cli
phar). On macOS Docker Desktop's virtiofs layer fakes ownership; on native Linux it does
not. The extract leaves the tree as uid 1000, Apache runs as www-data (33), so the site
renders but **cannot write**: no uploads, no plugin/theme install, no `debug.log` (which
silently blinds `_debug_fatal_count`), and `wpsite upgrade` fails at its core job.

A naive `chown -R 33:33` then breaks the host side — `build`'s `rm -rf` needs write on
those directories.

*Chosen fix:* a derived image built once, like `_shot_image_ensure` /
`_adminer_image_ensure` already do — `wpsite/wordpress:<wp>-php<php>` from the pinned
upstream tag with `usermod -u $(id -u) www-data && groupmod -g $(id -g) www-data`.
Ownership then matches on both sides with no chown at all. Must stay a no-op on macOS
(where the stock image is used directly) and must respect the existing
`_wp_image_tag` pinning.

**2. `clone` becomes local-only and registry-optional.** ✅ **DONE**
Two separate couplings to production, both removed:

*Local-only.* `clone` currently takes a **fresh backup over SSH** unless given
`--backup <id>` (`cmd_clone.sh:47-57`). It stops doing that: always the newest COMPLETE
local backup, or `--backup <id>`. Delete `_backup_one_client`, `ssh_setup_mux` and the
`trap ssh_close_mux EXIT` — no SSH code path remains. `--light`/`--full` are removed
(they only ever described how to take the fresh backup); error with a pointer to
`wpsite backup --light` rather than accepting them as silent no-ops.

*Registry-optional.* `require_client` (`cmd_clone.sh:31`) is replaced by "the backup
directory exists and holds a complete backup" (`_is_complete_backup`) — a check that
subsumes what `require_client` protected against, with a better message.
`client_backup_dir` is pure path derivation and needs no change: on the gateway `<name>`
is a real client, on the dev box it is simply the directory the push packet landed in.
`client_get <name> deactivate_plugins` already degrades to empty without mandos; add
`--deactivate <slugs>` so the gateway can pass the list through (§5.8). Add `--host`.

Selection must filter through `_is_complete_backup`, not a bare `ls -td`, so a
half-transferred packet is never picked. **Log the chosen backup's age up front**
(`Cloning from backup 20260730_164752 (37 days old)`) — with fresh backups no longer
automatic, cloning from a stale snapshot becomes possible. The id IS a timestamp, so
compute the age from the NAME; no `stat` call, which also sidesteps item 9's BSD-ism.

Net effect: `clone` becomes exactly "`build`, but into a dev site" — same inputs, same
selection logic, same `_build_from_backup` call. Identical behaviour on both machines,
and no command that builds a replica can reach production any more.

Two follow-ons:
- **`wpsite list --backups <name>`** gates on `config_has_client` (`cmd_list.sh:25`) and
  so returns nothing on the dev box. Same relaxation — check the directory — so packets
  can be listed there.
- **The GUI clone dialog** offers "fresh from server" with a `--light` checkbox; that
  option disappears, leaving the backup picker. `wpsite-gui/` only, Mac-only, does not
  block the dev box.

*Superseded:* an earlier draft added a separate `wpsite import <backup-dir> <devname>`.
Folding it into `clone` is better **because** clone is now local-only: the two would have
had identical preconditions (one complete local backup), so a second command would have
been pure surface area.

**3. Split `config_require`** (`common.sh:53-57`). ✅ **DONE** (`config_require_registry`)
It currently hard-requires mandos for every command. Split into:
- `config_require` — `yq` + config file present (all commands)
- `config_require_registry` — adds `require "$MANDOS_BIN"` (only commands touching the
  client registry: `backup`, `build`, `clone`, `apply`, `redirect`, `prune`, `client`,
  `test`, `list` when given a client)

Add a `seterr.bats` case for both.

### P1 — Debian usability (works, but reports nonsense or dead-ends without these)

**4. `_open_file` shim in `common.sh`.** ✅ **DONE** (plus `_pkg_hint`, `_resolves_loopback`, `wpsite_resolver_file`, `_mandos`) `open` is called at `cmd_db.sh:124` and
`cmd_review.sh:185`. `review` is gateway-only, but **`wpsite db` is a dev-box command**,
and on a headless box there is no browser to open at all. Prefer `xdg-open`, else
`open`, else log the URL so you can paste it into the Mac's browser. One `have` check
inside the shim.

**5. `doctor` becomes platform- and role-aware.** ✅ **DONE** Skip the `/etc/resolver` +
`dscacheutil` branch off macOS (`cmd_doctor.sh:77-84`), report the detected role, don't
report missing mandos as a failure on a dev box, and use `_pkg_hint` (item 9).

**6. `proxy install-dns`** ✅ **DONE** (refuses on non-Homebrew with the manual recipe; the Linux path is deliberately not automated) — currently `die`s with "Homebrew required"
(`cmd_proxy.sh:106`). Either implement the Linux path (dnsmasq on `127.0.0.1:5353` plus
a systemd-resolved drop-in with `Domains=~test`) or fail with a clear message that the
`/etc/hosts` fallback is in use and is fine. Do not leave a Homebrew error on Debian.

**7. `WPSITE_DEV_SUFFIX`** ✅ **DONE** (landed early — `clone` needed the host default) — the dev-site host suffix, default `test` (preserving
today's behaviour), set to `dev.test` on the dev box. Dev sites then default to
`<name>.dev.test` while CLIENT replicas keep bare `<client>.test`, so the Mac's dnsmasq
can route each namespace to the right machine by longest match:

```
address=/test/127.0.0.1        # gateway's own retainer replicas
address=/dev.test/<devbox-ip>  # dev box sites
```

Read in exactly five places, all dev-site paths:

| site | current |
|---|---|
| `common.sh:350` | `target_local_host` dev default → `<name>.test` |
| `cmd_new.sh:46,53` | new-site host default (prompt + fallback) |
| `cmd_clone.sh:60` | `host="$devname.test"` |
| `cmd_build_multisite.sh:23,25,27` | `_ms_local_host`'s three `ns` (clone/import) branches |

**`_swap_tld` (`cmd_build_multisite.sh:10`) must NOT change** — it is the `ns`-empty
client `build` path and belongs to the gateway's `.test` namespace.

Because `dev_set <name> host` persists the resolved host, the suffix only affects the
**default at creation time**; existing dev sites keep their stored host, so there is no
migration. Add a `pure.bats` case per branch.

### P2 — ergonomics and guardrails

**8. `wpsite push <client> [devname]`** ✅ **DONE** — implemented as a SUBCOMMAND (`lib/cmd_push.sh`), not the standalone `bin/wpsite-push` first sketched: `install.sh` only symlinks `bin/wpsite`, so a second script would not be on PATH, and as a subcommand it inherits config, logging, `config_require_registry`, `client_get` and the role guard for free. Default ships the newest *complete* local backup (no production hit) — symmetric with `clone` and with the two-step Workflow B example in §2 (`backup --light <c>` then `push`); pass `--fresh` to explicitly take a new one from production first, `--backup <id>` to ship a specific one. Then: `rsync` → `ssh devbox wpsite clone`. Reads
`deactivate_plugins` from the registry and passes it through. One command, so the
boundary is never worth shortcutting.

Also handles the rsync-flag mismatch between platforms: macOS's stock rsync is
`openrsync` (Apple's BSD reimplementation), which has no `--info=progress2`,
`--skip-compress` or `--append-verify` — passing them is a hard failure, not a silent
ignore. `_rsync_is_openrsync` (`common.sh`) detects this by capability (`rsync
--version`'s first line), not by `uname`, and `cmd_push.sh` falls back to `--progress`
and drops the other two on that path. `brew install rsync` gets the full GNU rsync and
the fast path.

**9. Remaining portability shims** ✅ **DONE** (`_pkg_hint` with item 5, `_mtime` now — note `_mtime` tries GNU `-c` FIRST and validates the result is numeric, because GNU's `-f` means `--file-system` and would treat `%m` as a filename, printing filesystem info on stdout while exiting non-zero). Correctness cleanups, not dev-box blockers, since
both affected commands are gateway-only. Still worth doing because CI (item 12) runs a
Linux leg and because a latent BSD-ism will bite the next person:

| shim | replaces | breakage |
|---|---|---|
| `_mtime` | `stat -f %m` at `cmd_prune.sh:61,177` | `\|\| echo $now`-guarded → ages print `0d` and **`prune --older-than` silently never deletes** on Linux |
| `_pkg_hint` | `brew install …` at `common.sh:39`, `cmd_doctor.sh:12,27`, `install.sh:52` | misleading on Debian |

No `_txt_to_pdf` shim: `cupsfilter` (`cmd_apply.sh:190`, `cmd_upgrade.sh:235`) is only
reached by `apply`/`upgrade`, which are gateway-only. It never runs on Debian.

**10. `WPSITE_ROLE=dev`** ✅ **DONE** — guards `test` and `prune` too (both reach production or Drive), beyond the four first listed. A config/env key making the dispatcher refuse `apply`,
`redirect`, `backup`, and `client` with "this machine is role=dev; run that on the
gateway". Honest framing: this is a guardrail against *our own* 11pm mistakes, not a
security control — the credential is the boundary. ~10 lines in `bin/wpsite`.

**11. `WPSITE_BIND_ADDR`** ✅ **DONE** — renamed from `WPSITE_PROXY_BIND` because it covers all three published services (proxy, Mailpit, Adminer) via `_port_spec`, not just the proxy. `_proxy_ensure` hardcoded `-p 80:80`
(`cmd_proxy.sh:31`), publishing on every interface. Make the bind address
configurable (default `0.0.0.0` to preserve today's behaviour) so the dev box can bind
its tailnet address. Same for Mailpit (`cmd_mail.sh:29`) and Adminer (`cmd_db.sh:75`).
A host firewall allowing `80/8025/8080` only on `tailscale0` is the simpler alternative.

**12. CI matrix** ✅ **DONE** (tool versions pinned; arch derived from `uname -m` since `macos-latest` is arm64) — `.github/workflows/lint.yml` over `macos-latest` +
`ubuntu-latest`, both legs running shellcheck and bats. This is the highest-leverage
item on the list: it prevents drift mechanically rather than by discipline. The suite
already `skip`s font/codec-dependent cases off macOS.

---

## 6. Explicitly not changing

- **`lib/cloud.sh` and every cloud helper.** Already correctly gated by
  `cloud_available()`. Unset `cloud_base` on the dev box; that is the entire change.
- **mandos.** No Linux build, no changes. Its `osascript` askpass is already correctly
  gated (`askpassSetup` deliberately never sets `SSH_ASKPASS_REQUIRE=force`, so on a TTY
  ssh prompts on the terminal) and will never be reached on a headless box anyway.
- **`wpsite-gui/`.** A separate Tauri app that shells out to the CLI and is never
  sourced by it. Stays macOS-only; the platform boundary already exists here.
- **`backup` / `apply` / `redirect` / `prune` / `client` / `upgrade` / `review` staying
  client-only.** That is the design, not a limitation — see §2 Workflow A.

  Recorded in case it is ever wanted: teaching `upgrade`/`review` to accept a dev site is
  a small, well-supported change, because the resolvers already exist. It would be
  `require_client` → `require_target` (`cmd_upgrade.sh:141`, `cmd_review.sh:256`),
  `client_docker_dir` → `target_docker_dir` (`:158`), `client_local_host` →
  `target_local_host` (`:166`), `client_base` → a new `target_base()` (`:151`,
  `cmd_review.sh:191`). `_review_dismiss`/`_review_pages` would need no change (their
  `client_get` calls are `|| true`-wrapped and fall back to defaults). **We are
  deliberately not doing this** — plugin work updates WordPress by hand in `/wp-admin`.
- **Rootless Docker.** A genuine improvement for the threat model, but it fights both
  the `-p 80:80` bind and the ownership fix. Deferred; revisit once P0/P1 are in.

---

## 7. Dev box prerequisites

Deliberately short:

- Docker CE + `docker-compose-plugin` **from Docker's own apt repo** — not Debian's
  `docker.io`
- **mikefarah `yq`, from GitHub releases** — `apt install yq` installs the *Python*
  jq-wrapper, a different tool; wpsite uses mikefarah syntax (`yq -i`, `-e`, `del(…)`,
  comment-preserving writes)
- `imagemagick` + `ffmpeg` — needed because the dev box is what regenerates placeholder
  media for `--light` packets (`cmd_build.sh:672-674`; skipped only when
  `media_map.txt` is absent, i.e. full backups)
- `git`, `rsync`, `curl`, `openssh-client`, `bats`, `shellcheck`
- Claude Code via the **native installer, not npm** — otherwise the first act on a
  machine built to avoid a global Node install is a global Node install
- **`herdr`**, run from the Mac to reach this box — its persistent session survives a
  dropped connection, which is the property this box needs from any terminal tool

Not installed, ever: Node, PHP, Composer, mandos.

A persistent session is not optional — a 1.1 GB clone over a dropped SSH connection is a
wasted half hour. `herdr` already provides this (attach/reattach to the same running
session), so there is nothing extra to install or run for it, and `tmux` is not needed.

---

## 8. Open questions

1. **`_wp_image_tag` + derived image interaction** (item 1) — one derived image per
   `<wp>-php<php>` combination could mean several; acceptable, but confirm the build
   cost and cache behaviour before committing.
