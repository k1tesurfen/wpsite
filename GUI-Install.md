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

## Troubleshooting

*   **Tauri Build Errors:** Ensure your Rust toolchain is up to date by running `rustup update`.
*   **wpsite Commands Failing in GUI:** If the GUI cannot find the `wpsite` CLI, ensure that `/usr/local/bin` (or wherever `wpsite` was installed) is included in the `PATH` environment variable that Tauri inherits.
