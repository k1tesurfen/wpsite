use tauri::Emitter;
use std::process::{Command, Stdio};
use std::io::{BufRead, BufReader};

// Set the macOS Dock icon at runtime. Needed because `tauri dev` launches a bare
// debug binary (no .app bundle), so the configured bundle icon isn't applied and
// the Dock shows a generic executable icon. The PNG is compiled into the binary.
#[cfg(target_os = "macos")]
fn set_dock_icon() {
    use objc2::{AnyThread, MainThreadMarker};
    use objc2_app_kit::{NSApplication, NSImage};
    use objc2_foundation::NSData;

    // Must run on the main thread (where the Tauri setup hook executes).
    let Some(mtm) = MainThreadMarker::new() else { return };

    const LOGO: &[u8] = include_bytes!("../icons/128x128@2x.png");
    let data = NSData::with_bytes(LOGO);
    let Some(image) = NSImage::initWithData(NSImage::alloc(), &data) else { return };

    let app = NSApplication::sharedApplication(mtm);
    // SAFETY: standard AppKit call on the main thread with a valid NSImage.
    unsafe { app.setApplicationIconImage(Some(&image)) };
}

// Learn more about Tauri commands at https://tauri.app/develop/calling-rust/
#[tauri::command]
fn greet(name: &str) -> String {
    format!("Hello, {}! You've been greeted from Rust!", name)
}

// Augmented PATH so the GUI finds Homebrew + /usr/local tools regardless of how it
// was launched (Finder gives a bare PATH). Mirrors the value used on every Command.
const AUG_PATH: &str = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin";

// First-run machine onboarding state. The three fields map 1:1 to what `wpsite setup`
// writes: `base_dir` (local data dir, wpsite config) + `team_config` + `cloud_base`
// (both owned by mandos). `complete` is true only when ALL THREE are set — the GUI
// treats a missing value as "not onboarded yet" and shows the setup screen.
#[derive(serde::Serialize)]
struct SetupStatus {
    base_dir: String,
    team_config: String,
    cloud_base: String,
    complete: bool,
}

// Read the wpsite config's `base_dir` (the only key wpsite owns). Uses the default
// config path — the GUI never overrides WPSITE_CONFIG. Empty string if unset/absent.
fn read_base_dir() -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    let cfg = format!("{home}/.config/wpsite/wpsite.yml");
    let out = Command::new("yq")
        .args(["-r", ".base_dir // \"\""])
        .arg(&cfg)
        .env("PATH", AUG_PATH)
        .output();
    match out {
        Ok(o) if o.status.success() => {
            let v = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if v == "null" { String::new() } else { v }
        }
        _ => String::new(),
    }
}

// Ask mandos for one resolved config value (team-config / cloud base). Empty on any
// failure (mandos missing, Drive unmounted, value unset) — the caller treats empty as
// "not configured", which is exactly the state the setup screen exists to fix.
fn mandos_value(args: &[&str]) -> String {
    let out = Command::new("/usr/local/bin/mandos")
        .args(args)
        .env("PATH", AUG_PATH)
        .output();
    match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        _ => String::new(),
    }
}

#[tauri::command]
fn get_setup_status() -> SetupStatus {
    let base_dir = read_base_dir();
    let team_config = mandos_value(&["config", "get", "team-config"]);
    let cloud_base = mandos_value(&["cloud", "base"]);
    let complete = !base_dir.is_empty() && !team_config.is_empty() && !cloud_base.is_empty();
    SetupStatus { base_dir, team_config, cloud_base, complete }
}

// One external tool the GUI depends on, and whether it's installed (on PATH).
#[derive(serde::Serialize)]
struct Prerequisite {
    name: String,
    installed: bool,
    hint: String,
}

// Is `bin` resolvable on the augmented PATH? Uses `command -v` in a shell so it works
// for anything on PATH without needing a `--version` flag that varies per tool.
fn on_path(bin: &str) -> bool {
    Command::new("/bin/sh")
        .arg("-c")
        .arg(format!("command -v {bin}"))
        .env("PATH", AUG_PATH)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

// Prerequisites the first-run screen blocks on: the CLI itself, mandos (client
// registry / cloud), yq (config parsing) and docker (replicas). Presence on PATH only
// — daemon health is `wpsite doctor`'s job.
#[tauri::command]
fn check_prerequisites() -> Vec<Prerequisite> {
    let checks = [
        ("wpsite", "brew install (dieses Repo) – die wpsite-CLI muss unter /usr/local/bin liegen."),
        ("mandos", "Interne mandos-CLI installieren (verwaltet Kunden-Registry, SSH & Google Drive)."),
        ("yq", "brew install yq"),
        ("docker", "Docker Desktop installieren und starten."),
    ];
    checks
        .iter()
        .map(|(name, hint)| Prerequisite {
            name: name.to_string(),
            installed: on_path(name),
            hint: hint.to_string(),
        })
        .collect()
}

#[tauri::command]
fn get_clients() -> Result<Vec<String>, String> {
    // Ask the CLI for the client names — it is the source of truth and knows about
    // the shared TEAM config in Google Drive (the client list no longer lives in the
    // local config file). `wpsite list --names` prints one name per line to stdout and
    // degrades to empty (with a stderr warning) when Drive is unmounted.
    let output = Command::new("/usr/local/bin/wpsite")
        .arg("list")
        .arg("--names")
        .env("PATH", "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin")
        .output();

    parse_name_lines(output)
}

#[tauri::command]
fn get_dev_sites() -> Result<Vec<String>, String> {
    // Dev sites live in the LOCAL config (not the shared team file), so this never
    // depends on Drive being mounted. `wpsite list --dev-names` prints one per line.
    let output = Command::new("/usr/local/bin/wpsite")
        .arg("list")
        .arg("--dev-names")
        .env("PATH", "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin")
        .output();

    parse_name_lines(output)
}

#[tauri::command]
fn get_backups(client: String) -> Result<Vec<String>, String> {
    // Complete on-disk backup ids for a client, newest first — used by the clone dialog
    // to offer cloning from an existing backup (offline-capable, no fresh backup).
    let output = Command::new("/usr/local/bin/wpsite")
        .arg("list")
        .arg("--backups")
        .arg(&client)
        .env("PATH", "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin")
        .output();

    parse_name_lines(output)
}

// One wpsite-managed .htaccess redirect, as read back from the client's production
// server via `wpsite redirect list --porcelain` (canonical source/target/code/regex).
#[derive(serde::Serialize)]
struct Redirect {
    source: String,
    target: String,
    code: String,
    regex: bool,
}

#[tauri::command]
fn get_redirects(client: String) -> Result<Vec<Redirect>, String> {
    // Reads the client's LIVE .htaccess over SSH (a few seconds). Porcelain output is one
    // TAB-separated `source<TAB>target<TAB>code<TAB>regex` line per managed rule on stdout;
    // warnings/errors go to stderr. A non-zero exit (offline, unreachable) is surfaced.
    let output = Command::new("/usr/local/bin/wpsite")
        .args(["redirect", "list", &client, "--porcelain"])
        .env("PATH", AUG_PATH)
        .output();

    match output {
        Ok(out) if out.status.success() => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            let rules = stdout
                .lines()
                .filter_map(|line| {
                    if line.trim().is_empty() {
                        return None;
                    }
                    let mut f = line.split('\t');
                    let source = f.next()?.to_string();
                    let target = f.next().unwrap_or("").to_string();
                    let code = f.next().unwrap_or("301").to_string();
                    let regex = f.next().unwrap_or("0") == "1";
                    Some(Redirect { source, target, code, regex })
                })
                .collect();
            Ok(rules)
        }
        Ok(out) => Err(String::from_utf8_lossy(&out.stderr).trim().to_string()),
        Err(e) => Err(format!("Failed to run wpsite: {}", e)),
    }
}

// A built site (has a Docker container). `state` is the container state (running,
// exited, …); `admin_url` is filled only for running (reachable) sites.
#[derive(serde::Serialize)]
struct SiteStatus {
    name: String,
    state: String,
    admin_url: String,
}

// Resolve a site's admin URL = <base>/<login_path>. Most sites use the default
// `/wp-admin/`, but some clients change the login path (WPS Hide Login, Wordfence, …);
// that's recorded as an optional `login_path` field on the client in the mandos registry.
// Dev sites (and any lookup failure) fall back to `/wp-admin/`.
fn resolve_admin_url(name: &str, base_url: &str) -> String {
    let mut path = String::new();
    if let Ok(out) = Command::new("/usr/local/bin/mandos")
        .args(["client", "get", name, "login_path"])
        .env("PATH", "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin")
        .output()
    {
        if out.status.success() {
            path = String::from_utf8_lossy(&out.stdout).trim().to_string();
        }
    }
    if path.is_empty() {
        path = "/wp-admin/".to_string();
    }
    if !path.starts_with('/') {
        path = format!("/{path}");
    }
    format!("{}{}", base_url.trim_end_matches('/'), path)
}

#[tauri::command]
fn get_site_statuses() -> Result<Vec<SiteStatus>, String> {
    // `wpsite status` lists every site that HAS a container — i.e. is BUILT — one row:
    // "<name> <kind> <state> <url>" (header → stderr). A built-but-stopped site appears
    // with state != running. We return name + state for ALL of them (built = present),
    // plus the resolved admin URL for the running (reachable) ones. NO_COLOR=1 keeps the
    // columns plain. Best-effort: on any failure (docker down, no config) → empty set.
    let output = Command::new("/usr/local/bin/wpsite")
        .arg("status")
        .env("PATH", "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin")
        .env("NO_COLOR", "1")
        .output();

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            let sites: Vec<SiteStatus> = stdout
                .lines()
                .filter_map(|line| {
                    let mut cols = line.split_whitespace();
                    let name = cols.next()?;
                    let _kind = cols.next()?;
                    let state = cols.next()?;
                    let base = cols.next()?; // http://<host>
                    let admin_url = if state == "running" {
                        resolve_admin_url(name, base)
                    } else {
                        String::new()
                    };
                    Some(SiteStatus {
                        name: name.to_string(),
                        state: state.to_string(),
                        admin_url,
                    })
                })
                .collect();
            Ok(sites)
        }
        Err(_) => Ok(vec![]),
    }
}

// Shared: turn a `wpsite list --names/--dev-names` invocation into a clean Vec of names.
fn parse_name_lines(output: std::io::Result<std::process::Output>) -> Result<Vec<String>, String> {
    match output {
        Ok(out) => {
            if out.status.success() {
                let stdout = String::from_utf8_lossy(&out.stdout);
                let names: Vec<String> = stdout
                    .lines()
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
                    .collect();
                Ok(names)
            } else {
                let stderr = String::from_utf8_lossy(&out.stderr);
                Err(format!("wpsite list failed: {}", stderr))
            }
        }
        Err(e) => Err(format!("Failed to run wpsite: {}", e)),
    }
}

#[tauri::command]
fn run_wpsite_command(
    app: tauri::AppHandle,
    cmd: String,
    client: Option<String>,
    extra: Option<Vec<String>>,
) -> Result<(), String> {
    tauri::async_runtime::spawn(async move {
        // Construct arguments
        let mut proc_args = vec![];

        // Split cmd by whitespace to allow commands like "proxy status" or "mail status"
        for part in cmd.split_whitespace() {
            proc_args.push(part.to_string());
        }

        // The primary target (client or dev site), if any.
        if let Some(ref c) = client {
            proc_args.push(c.clone());
        }

        // Extra positional args / flags, e.g. clone's <devname> + "--light", or new's <name>.
        if let Some(args) = extra {
            for a in args {
                proc_args.push(a);
            }
        }

        // Emit initial start message
        let command_str = format!("wpsite {}", proc_args.join(" "));
        let _ = app.emit("wpsite-log", format!("$ {}\n", command_str));

        // Spawn command
        let mut child = match Command::new("/usr/local/bin/wpsite")
            .args(&proc_args)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .env("PATH", "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin")
            .spawn()
        {
            Ok(c) => c,
            Err(e) => {
                let err_msg = format!("wpsite konnte nicht gestartet werden: {}", e);
                let _ = app.emit("wpsite-log", format!("Fehler: {}\n", err_msg));
                let _ = app.emit("wpsite-finished", ());
                return;
            }
        };

        let stdout = child.stdout.take();
        let stderr = child.stderr.take();

        // Spawn threads to read stdout and stderr concurrently
        let app_clone = app.clone();
        let stdout_handle = std::thread::spawn(move || {
            if let Some(out) = stdout {
                let reader = BufReader::new(out);
                for line in reader.lines() {
                    if let Ok(l) = line {
                        let _ = app_clone.emit("wpsite-log", format!("{}\n", l));
                    }
                }
            }
        });

        let app_clone2 = app.clone();
        let stderr_handle = std::thread::spawn(move || {
            if let Some(err) = stderr {
                let reader = BufReader::new(err);
                for line in reader.lines() {
                    if let Ok(l) = line {
                        let _ = app_clone2.emit("wpsite-log", format!("{}\n", l));
                    }
                }
            }
        });

        // Wait for threads to finish
        let _ = stdout_handle.join();
        let _ = stderr_handle.join();

        // Wait for process to exit
        let status = child.wait();
        match status {
            Ok(s) => {
                let exit_msg = if s.success() {
                    format!("Befehl erfolgreich abgeschlossen.\n")
                } else {
                    format!("Befehl mit Status beendet: {}\n", s)
                };
                let _ = app.emit("wpsite-log", exit_msg);
            }
            Err(e) => {
                let _ = app.emit("wpsite-log", format!("Fehler beim Warten auf den Prozess: {}\n", e));
            }
        }

        // Notify frontend that command finished
        let _ = app.emit("wpsite-finished", ());
    });

    Ok(())
}

// On launch: if the offline caches aren't warmed yet (`wpsite prefetch --check` fails),
// kick off `wpsite prefetch` ONCE in the background, streaming its output to the console
// — without gating the UI (no wpsite-finished event, so isRunning stays false).
#[tauri::command]
fn prefetch_if_needed(app: tauri::AppHandle) -> Result<(), String> {
    let already = Command::new("/usr/local/bin/wpsite")
        .args(["prefetch", "--check"])
        .env("PATH", "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin")
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if already {
        return Ok(());
    }

    let _ = app.emit(
        "wpsite-log",
        "\n[Einmaliges Vorab-Laden für den Offline-Betrieb im Hintergrund gestartet …]\n".to_string(),
    );

    tauri::async_runtime::spawn(async move {
        let mut child = match Command::new("/usr/local/bin/wpsite")
            .arg("prefetch")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .env("PATH", "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin")
            .spawn()
        {
            Ok(c) => c,
            Err(_) => return,
        };

        let stdout = child.stdout.take();
        let stderr = child.stderr.take();
        let a1 = app.clone();
        let out_h = std::thread::spawn(move || {
            if let Some(out) = stdout {
                for line in BufReader::new(out).lines() {
                    if let Ok(l) = line {
                        let _ = a1.emit("wpsite-log", format!("{}\n", l));
                    }
                }
            }
        });
        let a2 = app.clone();
        let err_h = std::thread::spawn(move || {
            if let Some(err) = stderr {
                for line in BufReader::new(err).lines() {
                    if let Ok(l) = line {
                        let _ = a2.emit("wpsite-log", format!("{}\n", l));
                    }
                }
            }
        });
        let _ = out_h.join();
        let _ = err_h.join();
        let _ = child.wait();
        let _ = app.emit("wpsite-log", "[Vorab-Laden abgeschlossen.]\n".to_string());
    });

    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .setup(|_app| {
            #[cfg(target_os = "macos")]
            set_dock_icon();
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![greet, get_clients, get_dev_sites, get_backups, get_redirects, get_site_statuses, run_wpsite_command, prefetch_if_needed, get_setup_status, check_prerequisites])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
