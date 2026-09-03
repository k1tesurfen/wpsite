# wpsite Tauri GUI Installation Guide

This guide provides extensive instructions for setting up the development environment, running, and building the Mac-only Tauri GUI for `wpsite`.

## Prerequisites

Before beginning, ensure you have the following installed on your macOS system:

1.  **Xcode Command Line Tools**
    Tauri requires Apple's native build tools to compile the Rust backend and package the application.
    ```bash
    xcode-select --install
    ```

2.  **Homebrew (macOS Package Manager)**
    If you don't have Homebrew installed, run:
    ```bash
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    ```

3.  **Node.js (for the React Frontend)**
    We recommend using the latest LTS version of Node.js.
    ```bash
    brew install node
    ```

4.  **Rust (for the Tauri Backend)**
    Tauri's backend is built with Rust. Install it using `rustup`, the official installer:
    ```bash
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
    ```
    *Note: Restart your terminal or run `source $HOME/.cargo/env` after installation.*

5.  **wpsite CLI**
    The GUI requires the underlying `wpsite` CLI tool to be installed and accessible in your system's `PATH`. Ensure you have completed the `wpsite` base installation (e.g., `wpsite doctor` passes).

6.  **mandos CLI**
    Client onboarding and machine setup are handled by the internal `mandos` CLI, which `wpsite` shells out to for the shared client registry, SSH-key onboarding, and Google Drive paths. Install it (`make install` in the `mandos` repo) and configure this machine once with `mandos config init`. The GUI does **not** create or edit clients: add a new client with `mandos client add`, then use the sidebar refresh button (⟳) to reload the list.

## Running in Development Mode

Development mode provides hot-reloading for the React frontend and fast recompilation for the Rust backend.

1.  Navigate to the GUI directory within the repository (assuming it will be created in a `gui/` or `wpsite-gui/` folder):
    ```bash
    cd wpsite-gui
    ```

2.  Install the frontend dependencies:
    ```bash
    npm install
    ```

3.  Start the Tauri development window:
    ```bash
    npm run tauri dev
    ```
    *This will compile the Rust backend (which takes a minute on the first run) and open a native macOS window containing the React application.*

## Building for Production (macOS App Bundle)

To create a standalone `.app` bundle that you can distribute to your colleagues or move to your `/Applications` folder:

1.  Ensure you are in the GUI directory:
    ```bash
    cd wpsite-gui
    ```

2.  Run the Tauri build command:
    ```bash
    npm run tauri build
    ```

3.  **Locate the App Bundle:**
    Once the build completes, your packaged macOS application will be located at:
    `src-tauri/target/release/bundle/macos/wpsite.app`

4.  **Installation:**
    You can simply drag and drop the `wpsite.app` file into your `~/Applications` or `/Applications` folder.

    *Note:* `npm run tauri build` runs `beforeBuildCommand` → `npm run build:app`, which first
    stages the `wpsite` CLI (`bin/` + `lib/`) into the app via `scripts/stage-cli.sh` so the
    bundle carries its own CLI. The `mandos` CLI is **not** bundled into wpsite.app — it ships
    inside `mandos.app` (separate repo) or is installed with `make install`.

## Distributing to colleagues (installer)

For a hand-off that installs everything (runtime deps + app(s) + CLIs) in one double-click,
use `dist/install.command`. It assumes Homebrew is present, runs `brew bundle` (`dist/Brewfile`),
copies the app(s) into `/Applications`, and symlinks the bundled CLIs onto `PATH`. See
[`dist/README.md`](dist/README.md) for assembling the delivery folder and building a `.dmg`.

## Troubleshooting

*   **Tauri Build Errors:** Ensure your Rust toolchain is up to date by running `rustup update`.
*   **wpsite Commands Failing in GUI:** If the GUI cannot find the `wpsite` CLI, ensure that `/usr/local/bin` (or wherever `wpsite` was installed) is included in the `PATH` environment variable that Tauri inherits.
