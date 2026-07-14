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
  terminal?: boolean;   // runs interactively in Terminal.app instead of the piped runner
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

  // Kunden-Aktionen
  const clientCommands: CommandDescription[] = [
    { name: "Bauen", cmd: "build", description: "Erstellt die lokale Kopie aus der neuesten Sicherung, richtet das Proxy-Routing ein und startet sie unter http://<kunde>.test." },
    { name: "Sicherung", cmd: "backup", description: "Lädt eine vollständige Sicherung (Datenbank, Plugins, Themes, Medien) vom Live-Server und legt sie lokal + in der Cloud ab." },
    { name: "Server testen", cmd: "test", description: "Prüft die SSH-Verbindung, Server-Befehle (tar, php, mysql), Pfade und ob WP-CLI und die Datenbank bereit sind. Nur lesend – jederzeit sicher." },
    { name: "Starten", cmd: "start", description: "Startet eine gestoppte lokale Kopie wieder. Die Daten bleiben erhalten." },
    { name: "Stoppen", cmd: "stop", description: "Hält die laufende lokale Kopie an, ohne Daten zu verlieren – jederzeit wieder startbar." },
    { name: "Aktualisieren", cmd: "upgrade", description: "Aktualisiert WordPress-Core, Themes und Plugins auf der lokalen Kopie – mit Screenshot-Vergleich vorher/nachher zur Kontrolle." },
    { name: "Auf Produktion anwenden", cmd: "apply", description: "Führt das geprobte Update auf dem LIVE-Server des Kunden aus (macht vorher eine frische Sicherung). Unwiderruflich – vorher immer lokal mit „Aktualisieren“ testen!", destructive: true },
    { name: "Entfernen", cmd: "destroy", description: "Entfernt die lokale Kopie vollständig – Container, Datenbank-Volume und Proxy-Route. Sicherungen bleiben erhalten.", destructive: true },
  ];

  // Globale Aktionen
  const globalCommands: CommandDescription[] = [
    { name: "Einrichten", cmd: "setup", description: "Richtet diesen Rechner ein: lokale Konfiguration + SSH-Zugang zu allen Team-Kunden. Öffnet dafür das Terminal (fragt ggf. nach Passwörtern).", terminal: true },
    { name: "Status", cmd: "status", description: "Zeigt alle laufenden lokalen Kopien und ihre Adressen." },
    { name: "Alle stoppen", cmd: "stop --all", description: "Hält alle laufenden lokalen Kopien auf einmal an (Daten bleiben erhalten)." },
    { name: "Systemcheck (Doctor)", cmd: "doctor", description: "Prüft Abhängigkeiten, den Docker-Dienst, die Team-Konfiguration und ob Google Drive erreichbar ist." },
    { name: "Proxy-Status", cmd: "proxy status", description: "Zeigt den Status des gemeinsamen Traefik-Proxys und der *.test-DNS-Auflösung." },
    { name: "Mail-Status", cmd: "mail status", description: "Zeigt den Status von Mailpit, das alle E-Mails der lokalen Kopien abfängt (Postfach unter localhost:8025)." },
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

    // Interactive commands (e.g. Einrichten) run in a real Terminal window.
    if (cmdDesc.terminal) {
      try {
        await invoke("open_setup_terminal");
        setLogs((prev) => prev + `\n[Terminal geöffnet: wpsite ${cmdDesc.cmd}]\n`);
      } catch (err: any) {
        setLogs((prev) => prev + `\n[Fehler]: Terminal konnte nicht geöffnet werden: ${err}\n`);
      }
      return;
    }

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
      alert(`Bestätigung fehlgeschlagen. Bitte „${selectedClient}“ genau so eingeben.`);
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
      setLogs((prev) => prev + `\n[GUI-Fehler]: Befehl konnte nicht gestartet werden: ${err}\n`);
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
            <h1 className="brand-title">wpsite</h1>
          </div>
        </div>

        <nav className="sidebar-nav">
          <div className="nav-section">
            <div className="section-header">
              <span>KUNDEN</span>
              <button
                onClick={fetchClients}
                disabled={isRunning}
                className="refresh-btn"
                title="Kundenliste neu laden"
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
                <li className="empty-state">Keine Kunden gefunden – ist Google Drive verbunden?</li>
              )}
              {error && (
                <li className="error-state" title={error}>Konfiguration konnte nicht geladen werden</li>
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
                  <span>Globale Aktionen</span>
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
              {activeTab === "client" ? `Kunde: ${selectedClient}` : "Globale Aktionen"}
            </h2>
            <p className="current-subtitle">
              {activeTab === "client"
                ? `Lokale WordPress-Kopie für ${selectedClient} verwalten`
                : "Einrichtung, Systemcheck, Proxy und Mail – für das ganze System"
              }
            </p>
          </div>
          <div className="status-indicator">
            {isRunning ? (
              <div className="status-badge running">
                <span className="spinner"></span>
                Befehl läuft
              </div>
            ) : (
              <div className="status-badge idle">
                <span className="dot"></span>
                Bereit
              </div>
            )}
          </div>
        </header>

        {/* Command Action Buttons */}
        <section className="actions-section">
          {confirmOp ? (
            <div className="confirm-overlay">
              <div className="confirm-card">
                <h3>⚠️ Kritische Aktion</h3>
                <p>
                  Du bist dabei, den unwiderruflichen Befehl <strong>wpsite {confirmOp.cmd}</strong> für den Kunden <strong>{selectedClient}</strong> auszuführen.
                </p>
                <p className="confirm-desc">
                  {confirmOp.description}
                </p>
                <div className="confirm-form">
                  <label htmlFor="confirm-input">
                    Zum Bestätigen bitte <strong>{selectedClient}</strong> eingeben:
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
                      Abbrechen
                    </button>
                    <button
                      className="btn-danger"
                      onClick={handleConfirmDestructive}
                      disabled={confirmInput !== selectedClient}
                    >
                      Bestätigen und ausführen
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
            <span className="terminal-title">KONSOLENAUSGABE</span>
            <div className="terminal-actions">
              <button
                onClick={() => setLogs("")}
                className="btn-clear-logs"
                title="Konsole leeren"
              >
                Leeren
              </button>
            </div>
          </div>
          <div className="terminal-body">
            <pre ref={terminalRef} className="terminal-pre">
              {logs || "Die Konsole ist leer. Führe oben einen Befehl aus, um die Ausgabe zu sehen …"}
            </pre>
          </div>
        </section>
      </main>
    </div>
  );
}

export default App;
