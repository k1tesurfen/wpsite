---
name: wpsite
description: >-
  Drive the `wpsite` CLI to snapshot production WordPress sites over SSH and run
  near-perfect local replicas under Docker. Use when the user wants to back up a
  client site, (re)build or start/stop a local replica, clone a client into a dev
  sandbox, spin up a fresh blank dev site, rehearse or apply core/plugin/theme
  upgrades, browse a replica's database, manage the shared proxy/mail/Adminer
  services, or onboard/edit/remove a client. Works in English and German — reply
  in whichever language the user writes. Triggers on "wpsite", "backup this
  client", "build a replica", "clone <client> locally", "upgrade the site", "apply
  to production", or any mention of the local `.test` WordPress replicas — and on
  the German equivalents "Backup/Sicherung erstellen", "Replik/lokale Kopie bauen",
  "Kunden(-website) klonen", "Dev-Seite anlegen", "Website/Plugins aktualisieren",
  "auf Produktion anwenden/übertragen", "Kunde anlegen/bearbeiten/entfernen".
---

# wpsite

A macOS + Homebrew Bash CLI (`bin/wpsite`) that snapshots production WordPress
sites over SSH and rebuilds local replicas under Docker. Single entrypoint with
subcommands: `bin/wpsite <command> [args]`. No build step — it's shell run directly.

Run it as `bin/wpsite …` from the repo root (or `wpsite …` if installed on PATH).
Local replicas are served at `http://<site>.test` through a shared Traefik proxy.

## How this skill is used

The user invokes it **deliberately** with `/wpsite`, then describes the task in free
prose — usually **German**. Your job is to turn that description into the correct
`wpsite` command(s). Two things you must do every time:

1. **Respond in the user's language** (German in, German out). Command names, flags,
   config keys, and site/client names are always literal — never translate them
   (`wpsite backup <client>`, `--light`, `clients:`, `.test` stay verbatim). Only the
   surrounding prose (explanations, confirmations, summaries) follows the user's language.
   German verb → command mapping: *Sicherung/Backup (erstellen)* → `backup`,
   *(Replik/lokale Kopie) bauen/erstellen* → `build`, *klonen* → `clone`,
   *starten/stoppen/anhalten* → `start`/`stop`, *aktualisieren* → `upgrade`,
   *auf Produktion anwenden/übertragen/live schalten* → `apply`,
   *löschen/entfernen* → `destroy` / `client remove`,
   *einrichten/einrichten neuer Rechner/Zugang einrichten* → `setup`.

2. **Resolve the named site to a real configured target — see below.**

## Resolving the target (slug OR domain → configured client)

The user will refer to a site by its **slug** (e.g. `acme`) OR by its **domain**
(e.g. `acme-industrial.com`, `www.acme.de`) — or a fuzzy fragment of either. The CLI
only accepts the exact **slug** (the `clients:`/`dev:` config key), so you must map it.

**Resolution steps:**

1. List the authoritative targets: `wpsite list` (CLIENT slugs + DEV SITE names).
2. If the user's word already matches a slug exactly → use it.
3. Otherwise read the config to match against a client's other identifiers. Config is at
   `$WPSITE_CONFIG` (default `~/.config/wpsite/wpsite.yml`) — always honor the env var if
   set. Per client, compare the user's string against `ssh` (the `user@host`), `wp_root`,
   `local_host`, and `cloud_dir`.
4. The **ground-truth production domain** lives in a backup's metadata:
   `<base_dir>/clients/<slug>/backups/<newest-id>/meta.env` → `SOURCE_HOME` /
   `SOURCE_SITEURL`. Read it when a domain doesn't obviously match a config field.
   When comparing, strip protocol, `www.`, port, and path first.

**Rules — do not guess:**

- **Exactly one confident match** → proceed, but state the resolved slug in your reply
  (e.g. "Ich sichere den Kunden `acme` (acme-industrial.com) …").
- **No match, or more than one plausible match** → STOP and ask, showing the candidates
  from `wpsite list`. Never run a command against a target you inferred loosely.
- **For any destructive or production command** (`apply`, `destroy`, `build`,
  `client remove --purge`, `prune`) require an unambiguous match AND an explicit
  confirmation before running — echo back the resolved slug and exactly what will happen.

## Two kinds of managed site

- **Clients** — SSH-backed production sites (`clients:` in config). Have backups.
- **Dev sites** — local-only sandboxes with no SSH source, made by `new`/`clone`.

A name is EITHER a client or a dev site, never both. Names must be DNS-label-safe
(lowercase alphanumeric + hyphens) — they drive container names, the compose
project, and the `.test` host.

## Team config (shared client definitions)

Config is split in two: a **local** file (`~/.config/wpsite/wpsite.yml`) holds this
machine's `base_dir`, `cloud_base`, a `team_config:` pointer, and this user's dev sites;
a **team** file in Google Drive holds the shared `clients:` map. Clients live in Drive so
the whole team shares one source of truth; dev sites and machine paths stay local and are
never propagated.

- **A new colleague / new machine runs `wpsite setup`** — it writes the local config and
  installs their SSH key on every client in the team config (sharing the config does NOT
  share access; SSH keys are per-person). After adding a new client, `wpsite setup
  --keys-only` gets the rest of the team access.
- If someone reports *"no clients / team config unreachable"*, their **Google Drive isn't
  mounted** — the client definitions live there. Client edits also refuse to write when
  Drive is unmounted (so nothing is silently written to the wrong place).
- **Retention is fixed at 5 backups** per client and is not configurable; `--persist`
  exempts a backup from the rotation.

## Lifecycle model (important vocabulary)

- `build` = heavy (re)create a client replica from its latest backup. **Destructive**:
  wipes containers + DB volume, then reimports.
- `start` / `stop` = pause/resume an already-built replica or dev site without
  rebuilding (data preserved).
- `destroy` = full teardown (containers + DB volume + files).

The shared services (`proxy`, `mail`, `db`) also use **`start` / `stop`** (the old
`up` / `down` still work as silent aliases). `up`/`down` as top-level commands are
retired — the dispatcher points you to `build`/`start` or `stop`/`destroy`.

## Command reference

**Onboarding:**
```bash
wpsite setup                    # write local config + install SSH keys for all team clients
wpsite setup --keys-only        # skip config; just (re)install keys for team clients
```

**Backups** (real media by default; `--light` = blank placeholders, smaller):
```bash
wpsite backup <client>              # full backup (real media) — the default
wpsite backup <client> --light      # placeholder media (small; layout preserved)
wpsite backup <client> --persist    # mark permanent (exempt from rolling prune)
wpsite backup --all                 # back up every client, sequentially
wpsite backup sync [<client>|--all] [--dry-run]   # reconcile local <-> cloud
wpsite backup persist <client> <id> [--off]       # promote/demote a backup
```

**Replicas & dev sites:**
```bash
wpsite build   <client> [--backup <id>]    # (re)build replica from a backup (newest default)
wpsite clone   <client> <devname> [--light|--backup <id>]   # dev site from a client
wpsite new     [name] [--wp <ver>] [--php <ver>] [--host <h>]  # blank dev site (no name = wizard)
wpsite start   <site>          # resume a stopped replica/dev site
wpsite stop    <site> [--all]  # pause (data kept); --all stops everything
wpsite destroy <site>          # full teardown
wpsite inject  <devsite> [--from <path>] [--slug <name>] [--activate [--network]]
```

**Upgrades:**
```bash
wpsite upgrade <client> [--noreview]   # rehearse core/plugin/theme updates locally + report
wpsite review  <client>                # re-open the latest before/after screenshot page
wpsite apply   <client>                # run the rehearsed upgrade ON PRODUCTION (irreversible!)
```

**Clients:**
```bash
wpsite client add [name]            # onboard (wizard on TTY, else flags: --ssh/--wp-root/…)
wpsite client edit <name>           # change fields (interactive or --ssh/--wp-root/… ; --unset <key>)
wpsite client remove <name> [--purge]   # remove client + replica (--purge also deletes local backups)
```

**Shared services & inspection:**
```bash
wpsite proxy  start|stop|status|install-dns   # Traefik reverse proxy + wildcard .test DNS
wpsite mail   start|stop|status               # Mailpit — traps all replica email (localhost:8025)
wpsite db     [<site>]                         # open Adminer for a site (no arg = last used)
wpsite db     start|stop|status                # manage the shared Adminer container
wpsite list   [site]                           # clients + backups + dev sites (or one site's detail)
wpsite status                                  # running replicas/dev sites + URLs
wpsite doctor                                  # verify dependencies + environment
wpsite test   <client>                         # pre-flight remote readiness check (read-only)
wpsite prune  <client> [<id>] [--keep N|--older-than Nd|--all] [--dry-run] [--yes]
```

## Common workflows

- **Onboard a client, then get a local copy:**
  `wpsite client add acme` → `wpsite test acme` → `wpsite backup acme` → `wpsite build acme`
  → open `http://acme.test`.
- **Quick dev sandbox from a client (fast, small):**
  `wpsite clone acme acme-dev --light` — namespaced under `acme-dev.test`.
- **Rehearse an upgrade before touching prod:**
  `wpsite build acme` → `wpsite upgrade acme` (review the screenshot page) → only if
  clean, `wpsite apply acme` (types confirmation, takes a fresh backup first).
- **Peek at a replica's data:** `wpsite db acme` (opens Adminer already logged in).

## Guardrails — respect these

- **`apply` writes to a LIVE production server.** It is the only command that does.
  It rehearses via `upgrade` first, requires typing the client name, takes a mandatory
  fresh backup, and is irreversible with manual rollback. Never add a `--yes` bypass.
  Confirm with the user before running it.
- **`build` is destructive** — it wipes the replica's containers and DB volume. Fine
  for replicas (rebuilt from backup), but never run it expecting to preserve local edits.
- **`destroy` and `client remove --purge`** are irreversible. `--purge` deletes local
  backups; cloud backups are the source of truth and are only removed via `prune`.
- Cloud backups are NEVER touched except by explicit `prune`.

## Conventions

- Replicas get a known local admin: **`wpsite` / `wpsite`** (prod hashes are unknown).
- Local host is `<site>.test` (derived from the production domain, or `<name>.test`).
- Email is trapped locally (Mailpit at `localhost:8025`); Adminer at `localhost:8080`.
- Media in placeholder mode (`--light`) is regenerated blank at exact dimensions — layout
  is preserved but images/videos are empty. Use full mode (default) when real media matters.

## Validating changes to the CLI itself

If you edit the shell code, both gates must pass (also run in CI):
```bash
shellcheck -x bin/wpsite lib/*.sh install.sh   # must be clean
bats test/                                       # bats-core suite (brew install bats-core)
```
See `CLAUDE.md` for the full architecture, gotchas, and the many hard-won conventions
before changing library code.
