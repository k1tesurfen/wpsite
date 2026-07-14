use tauri::Emitter;
use std::process::{Command, Stdio};
use std::io::{BufRead, BufReader};

// Learn more about Tauri commands at https://tauri.app/develop/calling-rust/
#[tauri::command]
fn greet(name: &str) -> String {
    format!("Hello, {}! You've been greeted from Rust!", name)
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

    match output {
        Ok(out) => {
            if out.status.success() {
                let stdout = String::from_utf8_lossy(&out.stdout);
                let clients: Vec<String> = stdout
                    .lines()
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
                    .collect();
                Ok(clients)
            } else {
                let stderr = String::from_utf8_lossy(&out.stderr);
                Err(format!("wpsite list failed: {}", stderr))
            }
        }
        Err(e) => Err(format!("Failed to run wpsite: {}", e)),
    }
}

// Onboarding (`wpsite setup`) and key install are INTERACTIVE (prompts, SSH host-key
// confirmations, server passwords), which the piped command runner below cannot drive.
// So open Terminal.app and run it there, where the user has a real interactive shell.
#[tauri::command]
fn open_setup_terminal() -> Result<(), String> {
    Command::new("osascript")
        .arg("-e")
        .arg("tell application \"Terminal\" to do script \"wpsite setup\"")
        .arg("-e")
        .arg("tell application \"Terminal\" to activate")
        .spawn()
        .map(|_| ())
        .map_err(|e| format!("Terminal konnte nicht geöffnet werden: {}", e))
}

#[tauri::command]
fn run_wpsite_command(app: tauri::AppHandle, cmd: String, client: Option<String>) -> Result<(), String> {
    tauri::async_runtime::spawn(async move {
        // Construct arguments
        let mut proc_args = vec![];
        
        // Split cmd by whitespace to allow commands like "proxy status" or "mail status"
        for part in cmd.split_whitespace() {
            proc_args.push(part.to_string());
        }

        if let Some(ref c) = client {
            proc_args.push(c.clone());
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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![greet, get_clients, run_wpsite_command, open_setup_terminal])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
