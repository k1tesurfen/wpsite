import { useState, useEffect, useRef } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import "./App.css";

type ActiveTab = "client" | "global";

interface CommandDescription {
  name: string;
  cmd: string;
  description: string;
  destructive?: boolean;
}

function App() {
  const [clients, setClients] = useState<string[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [activeTab, setActiveTab] = useState<ActiveTab>("client");
  const [selectedClient, setSelectedClient] = useState<string | null>(null);
  const [logs, setLogs] = useState<string>("");
  const [isRunning, setIsRunning] = useState<boolean>(false);
  
  // Destructive operations safety
  const [confirmOp, setConfirmOp] = useState<CommandDescription | null>(null);
  const [confirmInput, setConfirmInput] = useState<string>("");

  const terminalRef = useRef<HTMLPreElement>(null);

  // Client commands configuration
  const clientCommands: CommandDescription[] = [
    { name: "Build", cmd: "build", description: "Synthesizes Compose, sets up proxy routing, and starts container replica." },
    { name: "Backup", cmd: "backup", description: "Saves a complete backup of DB, plugins, themes, and uploads as a compressed tarball." },
    { name: "Test Remote", cmd: "test", description: "Verifies remote SSH, system commands (tar, php, mysql), folder paths, and WP-CLI database readiness." },
    { name: "Start", cmd: "start", description: "Powers up the containerized replica container if it was stopped." },
    { name: "Stop", cmd: "stop", description: "Gracefully powers down the replica container without losing any data." },
    { name: "Upgrade", cmd: "upgrade", description: "Upgrades WordPress core, themes, and plugins with a review step." },
    { name: "Apply Backup", cmd: "apply", description: "Extracts a client's backup over the current containerized replica (Destructive).", destructive: true },
    { name: "Destroy", cmd: "destroy", description: "Completely removes container, volume, and proxy route (Destructive).", destructive: true },
  ];

  // Global commands configuration
  const globalCommands: CommandDescription[] = [
    { name: "System Status", cmd: "status", description: "Lists running containers and general status of all client replicas." },
    { name: "Stop All Replicas", cmd: "stop --all", description: "Gracefully stops all running client replicas at once." },
    { name: "Doctor Check", cmd: "doctor", description: "Validates host dependencies, Docker daemon status, and local configs." },
    { name: "Proxy Status", cmd: "proxy status", description: "Displays status of the shared Traefik reverse proxy and wildcard DNS." },
    { name: "Mail Status", cmd: "mail status", description: "Displays status of the shared Mailpit container trapping replica emails." },
  ];

  // Fetch clients from backend
  const fetchClients = async () => {
    try {
      const list = await invoke<string[]>("get_clients");
      setClients(list);
      setError(null);
      if (list.length > 0 && !selectedClient) {
        setSelectedClient(list[0]);
      }
    } catch (err: any) {
      setError(err.toString());
    }
  };

  useEffect(() => {
    fetchClients();
  }, []);

  // Listen to Tauri backend events for real-time logs and state changes
  useEffect(() => {
    let unlistenLog: () => void;
    let unlistenFinished: () => void;

    async function setupListeners() {
      unlistenLog = await listen<string>("wpsite-log", (event) => {
        setLogs((prev) => prev + event.payload);
      });

      unlistenFinished = await listen<void>("wpsite-finished", () => {
        setIsRunning(false);
      });
    }

    setupListeners();

    return () => {
      if (unlistenLog) unlistenLog();
      if (unlistenFinished) unlistenFinished();
    };
  }, []);

  // Auto-scroll terminal on logs change
  useEffect(() => {
    if (terminalRef.current) {
      terminalRef.current.scrollTop = terminalRef.current.scrollHeight;
    }
  }, [logs]);

  const executeCommand = async (cmdDesc: CommandDescription) => {
    if (isRunning) return;

    if (cmdDesc.destructive) {
      setConfirmOp(cmdDesc);
      setConfirmInput("");
      return;
    }

    await runCommand(cmdDesc.cmd, activeTab === "client" ? selectedClient : null);
  };

  const handleConfirmDestructive = async () => {
    if (!confirmOp || !selectedClient) return;

    if (confirmInput !== selectedClient) {
      alert(`Confirmation failed. You must type "${selectedClient}" exactly.`);
      return;
    }

    const cmdToRun = confirmOp.cmd;
    setConfirmOp(null);
    setConfirmInput("");

    await runCommand(cmdToRun, selectedClient);
  };

  const runCommand = async (cmd: string, clientName: string | null) => {
    setIsRunning(true);
    try {
      await invoke("run_wpsite_command", { cmd, client: clientName });
    } catch (err: any) {
      setLogs((prev) => prev + `\n[GUI Error]: Failed to start command: ${err}\n`);
      setIsRunning(false);
    }
  };

  const handleClientSelect = (client: string) => {
    if (isRunning) return;
    setActiveTab("client");
    setSelectedClient(client);
  };

  const handleGlobalSelect = () => {
    if (isRunning) return;
    setActiveTab("global");
    setSelectedClient(null);
  };

  return (
    <div className="app-container">
      {/* macOS Sidebar */}
      <aside className="sidebar">
        <div className="sidebar-header">
          <div className="app-brand">
            <span className="brand-dot"></span>
            <h1 className="brand-title">wpsite GUI</h1>
          </div>
        </div>

        <nav className="sidebar-nav">
          <div className="nav-section">
            <div className="section-header">
              <span>CLIENTS</span>
              <button 
                onClick={fetchClients} 
                disabled={isRunning} 
                className="refresh-btn" 
                title="Refresh clients from config"
              >
                ⟳
              </button>
            </div>
            <ul className="nav-list">
              {clients.map((client) => (
                <li key={client}>
                  <button
                    className={`nav-item ${activeTab === "client" && selectedClient === client ? "active" : ""}`}
                    onClick={() => handleClientSelect(client)}
                    disabled={isRunning && selectedClient !== client}
                  >
                    <span className="client-icon">📁</span>
                    <span className="client-name">{client}</span>
                  </button>
                </li>
              ))}
              {clients.length === 0 && !error && (
                <li className="empty-state">No clients found in wpsite.yml</li>
              )}
              {error && (
                <li className="error-state" title={error}>Error loading config</li>
              )}
            </ul>
          </div>

          <div className="nav-section">
            <div className="section-header">SYSTEM</div>
            <ul className="nav-list">
              <li>
                <button
                  className={`nav-item ${activeTab === "global" ? "active" : ""}`}
                  onClick={handleGlobalSelect}
                  disabled={isRunning}
                >
                  <span className="client-icon">⚙️</span>
                  <span>Global Operations</span>
                </button>
              </li>
            </ul>
          </div>
        </nav>
      </aside>

      {/* macOS Main Detail Panel */}
      <main className="main-content">
        <header className="content-header">
          <div className="header-info">
            <h2 className="current-title">
              {activeTab === "client" ? `Client: ${selectedClient}` : "Global Operations"}
            </h2>
            <p className="current-subtitle">
              {activeTab === "client" 
                ? `Manage local WordPress replica environment for ${selectedClient}` 
                : "System-wide diagnostic, reverse proxy, and mail status actions"
              }
            </p>
          </div>
          <div className="status-indicator">
            {isRunning ? (
              <div className="status-badge running">
                <span className="spinner"></span>
                Running Command
              </div>
            ) : (
              <div className="status-badge idle">
                <span className="dot"></span>
                System Ready
              </div>
            )}
          </div>
        </header>

        {/* Command Action Buttons */}
        <section className="actions-section">
          {confirmOp ? (
            <div className="confirm-overlay">
              <div className="confirm-card">
                <h3>⚠️ Critical Action Required</h3>
                <p>
                  You are about to execute a destructive command <strong>wpsite {confirmOp.cmd}</strong> on client <strong>{selectedClient}</strong>.
                </p>
                <p className="confirm-desc">
                  {confirmOp.description}
                </p>
                <div className="confirm-form">
                  <label htmlFor="confirm-input">
                    Please type <strong>{selectedClient}</strong> below to confirm:
                  </label>
                  <input
                    id="confirm-input"
                    type="text"
                    value={confirmInput}
                    onChange={(e) => setConfirmInput(e.target.value)}
                    placeholder={selectedClient || ""}
                    autoFocus
                  />
                  <div className="confirm-buttons">
                    <button className="btn-cancel" onClick={() => setConfirmOp(null)}>
                      Cancel
                    </button>
                    <button 
                      className="btn-danger" 
                      onClick={handleConfirmDestructive}
                      disabled={confirmInput !== selectedClient}
                    >
                      Confirm and Run
                    </button>
                  </div>
                </div>
              </div>
            </div>
          ) : (
            <div className="actions-grid">
              {(activeTab === "client" ? clientCommands : globalCommands).map((cmdDesc) => (
                <button
                  key={cmdDesc.name}
                  onClick={() => executeCommand(cmdDesc)}
                  disabled={isRunning}
                  className={`action-card ${cmdDesc.destructive ? "destructive" : ""}`}
                >
                  <div className="action-card-header">
                    <span className="action-title">{cmdDesc.name}</span>
                    <span className="action-cmd">wpsite {cmdDesc.cmd}</span>
                  </div>
                  <p className="action-desc">{cmdDesc.description}</p>
                </button>
              ))}
            </div>
          )}
        </section>

        {/* Dark-themed Monospace Terminal Emulator Panel */}
        <section className="terminal-section">
          <div className="terminal-header">
            <span className="terminal-title">CONSOLE OUTPUT</span>
            <div className="terminal-actions">
              <button 
                onClick={() => setLogs("")} 
                className="btn-clear-logs"
                title="Clear terminal window"
              >
                Clear Log
              </button>
            </div>
          </div>
          <div className="terminal-body">
            <pre ref={terminalRef} className="terminal-pre">
              {logs || "Console is empty. Run a command from above to view output..."}
            </pre>
          </div>
        </section>
      </main>
    </div>
  );
}

export default App;
