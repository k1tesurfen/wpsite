# GEMINI.md

Instructional context and architecture guide for the `wpsite` project.

---

## 1. Project Overview

`wpsite` is a Bash-based CLI tool designed to backup WordPress sites over SSH and rebuild near-perfect local replicas under Docker (optimized for macOS + Homebrew). 

### Main Concepts & Architecture
* **Depends on `mandos`**: A separate internal Go CLI (`~/git/mandos`) owns **client identity** (the shared `clients:` registry on Google Drive), **SSH-key onboarding**, and **Google Drive paths**. `wpsite` shells out to it (`MANDOS_BIN`, default `mandos`) and no longer stores clients or `cloud_base` itself. Configure a machine once with `mandos config init`.
* **Low-Overhead Replica Storage**: Media uploads default to the real files. Pass `--light` to instead fetch only image/video dimensions from production and procedurally generate layout-accurate blank placeholders locally (ImageMagick + `ffmpeg`). (`--full` is accepted as a no-op for back-compat.)
* **Centralized Reverse Proxy**: Replicas run simultaneously on dedicated local domains (e.g., `http://<client>.test`) mapped through a shared Traefik reverse proxy. No per-replica port collisions.
* **Wildcard DNS**: Avoids per-build `sudo` hosts file modifications by optionally routing `*.test` to `127.0.0.1` locally via `dnsmasq`.
* **Production Sandbox**:
  * **Email Trapped**: Injects a custom WordPress MU-plugin to route all outgoing emails to a shared **Mailpit** container (`http://localhost:8025`). All live SMTP/mailing plugins are dynamically disabled on replicas.
  * **Login Credentials**: To avoid needing production password hashes, replica builds automatically provision/refresh a developer admin account: `wpsite` / `wpsite` at `/wp-admin/`.
  * **WP_DEBUG**: Automatically enabled, logging errors to `wp-content/debug.log`.
* **Quarterly Retainer Upgrade Loop**: Supports safe testing and production application of WordPress core, theme, and plugin updates:
  1. `wpsite backup <client>` — Take a remote backup snapshot.
  2. `wpsite build <client>` — Build the local Docker replica from the backup.
  3. `wpsite upgrade <client> --review` — Run upgrades on the replica, take screenshots before and after, and open a local visual regression diffing report in the browser.
  4. `wpsite apply <client>` — After visual confirmation, run the verified upgrade sequence over SSH in production (wrapped in maintenance mode with a fresh production backup for rollback).

---

## 2. Directory Structure

```
/
├── bin/
│   └── wpsite                  # Tool entrypoint; dispatches subcommands
├── lib/
│   ├── common.sh               # Sourced helpers: logging, SSH mux, yq, Docker
│   ├── cmd_backup.sh           # remote SSH snapshotting
│   ├── cmd_build.sh            # Docker replica build + placeholder generation
│   ├── cmd_upgrade.sh          # local replica package upgrades + screenshots
│   ├── cmd_apply.sh            # production update application
│   ├── cmd_doctor.sh           # dependency checks
│   └── cmd_*.sh                # other command handlers (mail, proxy, prune, etc.)
├── test/
│   ├── fixtures/
│   │   └── wpsite.yml          # Test suite mock config
│   ├── *.bats                  # bats integration and unit tests
│   └── placeholder.bats        # media generator validation
├── install.sh                  # symlinks bin/wpsite into path
└── wpsite.yml.example          # configuration template
```

---

## 3. Building, Running, and Testing

### Setup & Local Installation
To symlink `bin/wpsite` into `/usr/local/bin`:
```bash
./install.sh
```
To install to a custom directory (such as `~/.local/bin`):
```bash
WPSITE_BIN_DIR=~/.local/bin ./install.sh
```
To uninstall:
```bash
./install.sh --uninstall
```

### Client Identity & Google Drive (`mandos`)
Client definitions, SSH-key onboarding, and the Google Drive backup root are owned by the internal `mandos` CLI. Install it from `~/git/mandos` (`make install` → `/usr/local/bin/mandos`), then onboard this machine with the single wpsite command:
```bash
wpsite setup   # writes base_dir, runs `mandos config init` (points mandos at the shared
               # registry + Drive root), and installs your SSH key on every client
```
It prompts for the `base_dir`, the shared registry path, and the Drive root (drag-and-drop in Terminal). Under the hood only `base_dir` goes in the wpsite config; the registry path + `cloud_base` go to mandos. You can also drive mandos directly: `mandos config init --team-config <file> --cloud-base <dir>` and `mandos client setup-key <name>`.

### Dependency Verification
`wpsite` requires several system packages. Check status using:
```bash
wpsite doctor
```
Install missing requirements with Homebrew:
```bash
brew install yq imagemagick ffmpeg bats-core shellcheck
brew install --cask docker
```

### Static Analysis & Testing
The project uses strict Shellcheck linting and the `bats` framework for automated testing.
* **Linting scripts**:
  ```bash
  shellcheck -x bin/wpsite lib/*.sh install.sh
  ```
* **Running the test suite**:
  ```bash
  bats test/
  ```

---

## 4. Development & Coding Conventions

### Bash Scripting Quality
* **Strict Flags**: Every script runs with `set -euo pipefail`.
* **Path Resolution**: The entry point `bin/wpsite` resolves its real absolute path, allowing symlinks across `/usr/local/bin` to find the relative `lib/` directory seamlessly.
* **Formatting and Linting**: Run Shellcheck (`shellcheck -x`) before checking in code. Address all warnings.
* **Command Modularization**: 
  * Avoid placing complex logic inside `bin/wpsite`.
  * Every command must reside in `lib/cmd_<verb>.sh` as a function named `cmd_<verb>`.
  * Sourced utility logic goes into `lib/common.sh`.
* **SSH Connection Multiplexing**: Sockets are initialized inside `WPSITE_SSH_CONTROL_DIR="/tmp/wpsite-ssh.$$"` via `ssh_setup_mux` to keep authentication rapid across multiple calls, and closed on finish via `ssh_close_mux`.
* **Docker Compose Projects**: Ensure all compose actions (e.g. `down -v --remove-orphans`) pass the exact project namespace name `-p <project>` to avoid conflicts and clean up orphaned resources cleanly.

### Testing Practices
* **Test Isolation**: `bats` tests use temporary directories via `$BATS_TEST_TMPDIR`. Ensure test cases clean up after themselves or work inside isolated paths.
* **Configuration Fixtures**: Mock the active configuration location before sourcing `common.sh` or executing helpers:
  ```bash
  export WPSITE_CONFIG="$REPO/test/fixtures/wpsite.yml"
  ```
* **Mandos Stub**: the client-registry / cloud / SSH-key helpers shell out to `mandos`; tests point `MANDOS_BIN` at `test/fixtures/mandos-stub` (which serves the fixture's `clients:`/`cloud_base:` via yq) so they never hit the real `mandos` or the real Drive registry.
* **Feature Completeness**: Any new CLI option, utility helper, or config parse path must be accompanied by a dedicated test case in `test/`.

---

## 5. Configuration Schema

Config is split across two tools.

**wpsite** — `~/.config/wpsite/wpsite.yml` holds only machine-local settings: `base_dir`
and your `dev:` sites. Clients and `cloud_base` are **not** here anymore.

```yaml
base_dir: ~/websites            # Root working directory where local backups & docker folders reside
# dev: sites are managed by `wpsite new` / `wpsite clone`
```

**mandos** — `~/.config/mandos/mandos.yml` (set via `mandos config init`) points at the
shared **client registry** (the `clients:` map, a YAML on mounted Google Drive) and the
Drive `cloud_base` root. A client entry looks like:

```yaml
clients:
  acme:
    ssh: ubuntu@acme-industrial.com
    wp_root: /var/www/acme.com
    # local_host: acme.test   # optional (defaults to <client>.test)
```

* wpsite reads client values through `common.sh` helpers, which shell out to `mandos`:
  ```bash
  client_get "acme" "ssh"     # -> mandos client get acme ssh
  ```
* Manage clients with `mandos client add/set/unset/remove/setup-key` (or the `wpsite
  client add/edit/remove` wrappers, which write through mandos).
