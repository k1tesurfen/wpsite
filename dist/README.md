# Distributing the wpsite suite

This folder holds the installer that colleagues run to get everything: the runtime
dependencies (via their existing Homebrew), the app(s) in `/Applications`, and the CLIs
on their `PATH`. Homebrew is assumed already installed on every machine.

```
dist/
  install.command   ← double-clickable installer (opens Terminal, does the work)
  Brewfile          ← runtime deps: yq, imagemagick, ffmpeg, docker (cask)
  README.md         ← this file
```

## What the installer does

1. Confirms Homebrew is present (bails with a link if not).
2. `brew bundle` the `Brewfile` (yq, imagemagick, ffmpeg, Docker Desktop).
3. Copies `wpsite.app` (and `mandos.app` if present) into `/Applications`, clearing the
   Gatekeeper quarantine flag so the unsigned app opens without a right-click dance.
4. Symlinks the **bundled** CLIs into `/usr/local/bin` (one `sudo` prompt) — `wpsite`
   from inside `wpsite.app`, `mandos` from inside `mandos.app`. The CLI ships *inside* the
   app bundle (see below), so `/Applications` is its permanent home.

The GUI then walks the user through machine configuration on first launch (the setup
screen), which is per-machine only and never touches the shared client registry on Drive.

## How the CLI gets inside wpsite.app

`wpsite build` bundles the CLI automatically. `beforeBuildCommand` runs
`scripts/stage-cli.sh`, which copies `bin/` + `lib/` into
`wpsite-gui/src-tauri/resources/cli/`; `tauri.conf.json`'s `bundle.resources` maps that to
`Contents/Resources/cli/`. `install.command` finds `bin/wpsite` inside the bundle by name
(robust to the exact subpath) and symlinks it — `bin/wpsite` resolves its real path to
locate `lib/`, which sits alongside it in the bundle.

## Assembling a delivery for colleagues

1. **Build wpsite.app** (bundles the CLI):
   ```sh
   cd wpsite-gui && npm install && npm run tauri build
   # → wpsite-gui/src-tauri/target/release/bundle/macos/wpsite.app
   ```
2. **Build mandos.app** (separate repo `~/git/mandos/mandos-gui`):
   ```sh
   cd ~/git/mandos/mandos-gui && npm install && npm run tauri build
   # → src-tauri/target/release/bundle/macos/mandos.app  (CLI bundled inside; needs Go on this machine)
   ```
3. **Assemble the delivery folder:**
   ```sh
   mkdir -p ~/wpsite-suite
   cp dist/install.command dist/Brewfile ~/wpsite-suite/
   cp -R wpsite-gui/src-tauri/target/release/bundle/macos/wpsite.app ~/wpsite-suite/
   cp -R /path/to/mandos.app ~/wpsite-suite/   # once available
   ```
4. **Ship it** as a `.dmg` (or zip). For a DMG:
   ```sh
   hdiutil create -volname "wpsite" -srcfolder ~/wpsite-suite -ov -format UDZO ~/wpsite-suite.dmg
   ```
   Colleagues open the DMG and **double-click `install.command`**.

## Caveats

- **Unsigned.** The installer strips the quarantine flag from the copied apps so they
  launch, but the `.dmg`/`.command` themselves are unsigned — macOS may still warn on the
  `install.command` (right-click → Open the first time). For a frictionless drag-install,
  sign + notarize the apps and the DMG with an Apple Developer ID (future work).
- **Docker Desktop** still needs its one-time first-launch permission grant by the user.
- **Google Drive** must be mounted by the user before the client list works — external to
  this installer.
