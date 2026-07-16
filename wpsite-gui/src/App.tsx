import { useState, useEffect, useRef } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { openUrl } from "@tauri-apps/plugin-opener";
import { RefreshCw, Folder, FlaskConical, Settings, ExternalLink } from "lucide-react";
import "./App.css";

interface SiteStatus {
  name: string;
  state: string;       // docker container state: running | exited | …
  admin_url: string;   // set only for running (reachable) sites
}

type ActiveTab = "client" | "dev" | "global";

interface CommandDescription {
  name: string;
  cmd: string;
  description: string;
  destructive?: boolean;
  form?: "clone" | "new";    // needs an input form (name / options) before running
  // Precondition on the selected site's local state — the card is disabled otherwise:
  //   "built"   → a replica exists (running or stopped)
  //   "running" → the replica is up
  //   "stopped" → built but not running
  requires?: "built" | "running" | "stopped";
}

// A DNS-label-safe site name (mirrors the CLI's _valid_site_name): lowercase
// letters, digits and hyphens, not starting/ending with a hyphen.
const SITE_NAME_RE = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/;

function App() {
  const [clients, setClients] = useState<string[]>([]);
  const [devSites, setDevSites] = useState<string[]>([]);
  const [siteStatuses, setSiteStatuses] = useState<SiteStatus[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [activeTab, setActiveTab] = useState<ActiveTab>("client");
  const [selectedClient, setSelectedClient] = useState<string | null>(null);
  const [selectedDev, setSelectedDev] = useState<string | null>(null);
  const [logs, setLogs] = useState<string>("");
  const [isRunning, setIsRunning] = useState<boolean>(false);

  // Destructive operations safety (type-the-name confirm)
  const [confirmOp, setConfirmOp] = useState<CommandDescription | null>(null);
  const [confirmInput, setConfirmInput] = useState<string>("");

  // Input form for clone / new (needs a name + options)
  const [formOp, setFormOp] = useState<CommandDescription | null>(null);
  const [formName, setFormName] = useState<string>("");
  const [formLight, setFormLight] = useState<boolean>(false);
  const [formBackups, setFormBackups] = useState<string[]>([]); // existing backups to clone from
  const [formBackup, setFormBackup] = useState<string>("");     // "" = fresh backup from server

  const terminalRef = useRef<HTMLPreElement>(null);

  // The currently selected target (client or dev site), or null on the global tab.
  const currentTarget =
    activeTab === "client" ? selectedClient : activeTab === "dev" ? selectedDev : null;

  // Sites that are BUILT (have a container) vs the RUNNING subset (name -> admin URL).
  const builtSites = new Set(siteStatuses.map((s) => s.name));
  const runningAdminUrls = new Map(
    siteStatuses.filter((s) => s.state === "running").map((s) => [s.name, s.admin_url]),
  );

  // Whether a command can run against the currently selected site (state precondition).
  const targetBuilt = currentTarget ? builtSites.has(currentTarget) : false;
  const targetRunning = currentTarget ? runningAdminUrls.has(currentTarget) : false;
  const cmdAvailable = (c: CommandDescription): boolean => {
    switch (c.requires) {
      case "running": return targetRunning;
      case "stopped": return targetBuilt && !targetRunning;
      case "built": return targetBuilt;
      default: return true;
    }
  };
  const unavailableReason = (c: CommandDescription): string | undefined => {
    switch (c.requires) {
      case "running": return "Nur verfügbar, wenn die Seite läuft.";
      case "stopped": return "Nur verfügbar, wenn die Seite gebaut, aber gestoppt ist.";
      case "built": return "Nur verfügbar, wenn die Seite gebaut ist.";
      default: return undefined;
    }
  };

  // Open a running site's admin (backend) in the default browser.
  const openSite = async (url: string) => {
    try {
      await openUrl(url);
    } catch (err: any) {
      setLogs((prev) => prev + `\n[Fehler]: Browser konnte nicht geöffnet werden: ${err}\n`);
    }
  };

  // Kunden-Aktionen
  const clientCommands: CommandDescription[] = [
    { name: "Bauen", cmd: "build", description: "Erstellt die lokale Kopie aus dem neuesten Backup, richtet das Proxy-Routing ein und startet sie unter http://<kunde>.test." },
    { name: "Backup", cmd: "backup", description: "Lädt ein vollständiges Backup (Datenbank, Plugins, Themes, Medien) vom Live-Server und legt es lokal + in der Cloud ab." },
    { name: "Klonen", cmd: "clone", form: "clone", description: "Erstellt aus diesem Kunden eine lokale Dev-Seite (Sandbox) – mit frischem Backup. Medien echt (Standard) oder als Platzhalter (leicht)." },
    { name: "Starten", cmd: "start", requires: "stopped", description: "Startet eine gestoppte lokale Kopie wieder. Die Daten bleiben erhalten." },
    { name: "Stoppen", cmd: "stop", requires: "running", description: "Hält die laufende lokale Kopie an, ohne Daten zu verlieren – jederzeit wieder startbar." },
    { name: "Datenbank", cmd: "db", requires: "running", description: "Öffnet die Datenbank der lokalen Kopie im Browser (bereits eingeloggt). Die Kopie muss gebaut und gestartet sein." },
    { name: "Server testen", cmd: "test", description: "Prüft die SSH-Verbindung, Server-Befehle (tar, php, mysql), Pfade und ob WP-CLI und die Datenbank bereit sind. Nur lesend – jederzeit sicher." },
    { name: "Update", cmd: "upgrade", requires: "built", description: "Aktualisiert WordPress-Core, Themes und Plugins auf der lokalen Kopie – mit Screenshot-Vergleich vorher/nachher zur Kontrolle." },
    { name: "Update LIVE", cmd: "apply", destructive: true, description: "Führt das geprobte Update auf dem LIVE-Server des Kunden aus (macht vorher ein frisches Backup). Unwiderruflich – vorher immer lokal mit „Update“ testen!" },
    { name: "Entfernen", cmd: "destroy", destructive: true, requires: "built", description: "Entfernt die lokale Kopie vollständig – Container, Datenbank-Volume und Proxy-Route. Backups bleiben erhalten." },
  ];

  // Dev-Seiten-Aktionen (build/backup/apply gibt es hier nicht – die sind kundenspezifisch)
  const devCommands: CommandDescription[] = [
    { name: "Datenbank", cmd: "db", requires: "running", description: "Öffnet die Datenbank der Dev-Seite im Browser (bereits eingeloggt). Die Dev-Seite muss laufen." },
    { name: "Plugin einbinden", cmd: "inject", requires: "built", description: "Bindet ein lokales Plugin (Standard: ~/git/aule) live in die Dev-Seite ein – Änderungen sind sofort sichtbar." },
    { name: "Starten", cmd: "start", requires: "stopped", description: "Startet eine gestoppte Dev-Seite wieder. Die Daten bleiben erhalten." },
    { name: "Stoppen", cmd: "stop", requires: "running", description: "Hält die laufende Dev-Seite an, ohne Daten zu verlieren – jederzeit wieder startbar." },
    { name: "Entfernen", cmd: "destroy", destructive: true, description: "Entfernt die Dev-Seite vollständig – Container, Datenbank-Volume, Proxy-Route und Konfigurations-Eintrag." },
  ];

  // Globale Aktionen. Hinweis: Kunden anlegen/bearbeiten/entfernen und die
  // Rechner-Einrichtung laufen jetzt über das separate `mandos`-Tool, nicht hier.
  const globalCommands: CommandDescription[] = [
    { name: "Neue Dev-Seite", cmd: "new", form: "new", description: "Erstellt eine frische, leere Dev-Seite (WordPress-Neuinstallation) unter http://<name>.test." },
    { name: "Status", cmd: "status", description: "Zeigt alle laufenden lokalen Kopien und ihre Adressen." },
    { name: "Alle stoppen", cmd: "stop --all", description: "Hält alle laufenden lokalen Kopien auf einmal an (Daten bleiben erhalten)." },
    { name: "Systemcheck", cmd: "doctor", description: "Prüft Abhängigkeiten, den Docker-Dienst, die Team-Konfiguration und ob Google Drive erreichbar ist." },
    { name: "Proxy-Status", cmd: "proxy status", description: "Zeigt den Status des gemeinsamen Traefik-Proxys und der *.test-DNS-Auflösung." },
    { name: "Mail-Status", cmd: "mail status", description: "Zeigt den Status von Mailpit, das alle E-Mails der lokalen Kopien abfängt (Postfach unter localhost:8025)." },
  ];

  // Fetch clients + dev sites from backend, pruning any selection that vanished.
  const refreshSites = async () => {
    try {
      const [cl, dv] = await Promise.all([
        invoke<string[]>("get_clients"),
        invoke<string[]>("get_dev_sites"),
      ]);
      setClients(cl);
      setDevSites(dv);
      setError(null);
      setSelectedClient((prev) => (prev && cl.includes(prev) ? prev : cl[0] ?? null));
      setSelectedDev((prev) => (prev && dv.includes(prev) ? prev : null));
    } catch (err: any) {
      setError(err.toString());
    }
    // Which sites are running (green dot). Best-effort + independent of the lists:
    // a docker hiccup should only drop the dots, never break the sidebar.
    try {
      const st = await invoke<SiteStatus[]>("get_site_statuses");
      setSiteStatuses(st);
    } catch {
      setSiteStatuses([]);
    }
  };

  useEffect(() => {
    refreshSites();
    // First launch only: warm the offline caches (images + wp-cli) in the background.
    invoke("prefetch_if_needed").catch(() => {});
  }, []);

  // If the selected dev site disappears (e.g. destroyed), fall back to the client tab.
  useEffect(() => {
    if (activeTab === "dev" && !selectedDev) setActiveTab("client");
  }, [activeTab, selectedDev]);

  // Listen to Tauri backend events for real-time logs and state changes.
  // NOTE: registering the listeners is async, so under React.StrictMode (which
  // mounts→unmounts→remounts once in dev) the cleanup can run BEFORE the
  // `await listen(...)` promises resolve. If we only unlisten inside the cleanup,
  // that first cleanup is a no-op (handles still undefined), the promise then
  // resolves leaving an orphaned listener, and the remount registers a second one
  // — so every "wpsite-log" event fires setLogs twice and each line is doubled.
  // Guard with a `cancelled` flag: if we were torn down before registration
  // finished, unlisten immediately when the promise resolves.
  useEffect(() => {
    let cancelled = false;
    const unlisteners: Array<() => void> = [];

    async function setupListeners() {
      const unlistenLog = await listen<string>("wpsite-log", (event) => {
        setLogs((prev) => prev + event.payload);
      });
      const unlistenFinished = await listen<void>("wpsite-finished", () => {
        setIsRunning(false);
        // A finished command may have created/removed a site — refresh the sidebar.
        refreshSites();
      });

      if (cancelled) {
        unlistenLog();
        unlistenFinished();
        return;
      }
      unlisteners.push(unlistenLog, unlistenFinished);
    }

    setupListeners();

    return () => {
      cancelled = true;
      unlisteners.forEach((u) => u());
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

    // Commands needing an input form (clone, new).
    if (cmdDesc.form) {
      setFormOp(cmdDesc);
      setFormName("");
      setFormLight(false);
      setFormBackup("");
      setFormBackups([]);
      // For clone, offer the client's existing on-disk backups (so you can clone offline
      // from one instead of taking a fresh backup).
      if (cmdDesc.form === "clone" && selectedClient) {
        try {
          setFormBackups(await invoke<string[]>("get_backups", { client: selectedClient }));
        } catch {
          setFormBackups([]);
        }
      }
      return;
    }

    if (cmdDesc.destructive) {
      setConfirmOp(cmdDesc);
      setConfirmInput("");
      return;
    }

    await runCommand(cmdDesc.cmd, currentTarget);
  };

  const handleConfirmDestructive = async () => {
    if (!confirmOp || !currentTarget) return;

    if (confirmInput !== currentTarget) {
      alert(`Bestätigung fehlgeschlagen. Bitte „${currentTarget}“ genau so eingeben.`);
      return;
    }

    const cmdToRun = confirmOp.cmd;
    const target = currentTarget;
    setConfirmOp(null);
    setConfirmInput("");

    await runCommand(cmdToRun, target);
  };

  const nameValid = SITE_NAME_RE.test(formName);
  const nameTaken = clients.includes(formName) || devSites.includes(formName);
  const formReady = nameValid && !nameTaken;

  const handleFormSubmit = async () => {
    if (!formOp || !formReady) return;
    const op = formOp;
    const name = formName;
    const light = formLight;
    const backup = formBackup;
    setFormOp(null);
    setFormName("");
    setFormLight(false);
    setFormBackup("");
    setFormBackups([]);

    if (op.form === "clone") {
      if (!selectedClient) return;
      // A chosen backup clones from disk (offline); the light/full media mode is then
      // fixed by that backup, so --light only applies to a fresh backup.
      const extra = backup ? [name, "--backup", backup] : light ? [name, "--light"] : [name];
      await runCommand("clone", selectedClient, extra);
    } else if (op.form === "new") {
      await runCommand("new", null, [name]);
    }
  };

  const runCommand = async (cmd: string, target: string | null, extra?: string[]) => {
    setIsRunning(true);
    try {
      await invoke("run_wpsite_command", { cmd, client: target, extra: extra ?? null });
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

  const handleDevSelect = (dev: string) => {
    if (isRunning) return;
    setSelectedDev(dev);
    setActiveTab("dev");
  };

  const handleGlobalSelect = () => {
    if (isRunning) return;
    setActiveTab("global");
  };

  const activeCommands =
    activeTab === "client" ? clientCommands : activeTab === "dev" ? devCommands : globalCommands;

  const headerTitle =
    activeTab === "client"
      ? `Kunde: ${selectedClient}`
      : activeTab === "dev"
      ? `Dev-Seite: ${selectedDev}`
      : "Globale Aktionen";

  const headerSubtitle =
    activeTab === "client"
      ? `Lokale WordPress-Kopie für ${selectedClient} verwalten`
      : activeTab === "dev"
      ? `Lokale Dev-Seite ${selectedDev} verwalten`
      : "Dev-Seiten, Systemcheck, Proxy und Mail – für das ganze System";

  return (
    <div className="app-container">
      {/* macOS Sidebar */}
      <aside className="sidebar">
        <div className="sidebar-header">
          <div className="app-brand">
            <img className="brand-logo" src="/wpsite-logo-solo.png" alt="wpsite" />
            <h1 className="brand-title">wpsite</h1>
          </div>
        </div>

        <nav className="sidebar-nav">
          <div className="nav-section">
            <div className="section-header">
              <span>KUNDEN</span>
              <button
                onClick={refreshSites}
                disabled={isRunning}
                className="refresh-btn"
                title="Kunden- und Dev-Liste neu laden"
              >
                <RefreshCw size={18} strokeWidth={2} />
              </button>
            </div>
            <ul className="nav-list">
              {clients.map((client) => {
                const adminUrl = runningAdminUrls.get(client);
                const built = builtSites.has(client);
                return (
                  <li key={client}>
                    <button
                      className={`nav-item ${activeTab === "client" && selectedClient === client ? "active" : ""}`}
                      onClick={() => handleClientSelect(client)}
                      disabled={isRunning && !(activeTab === "client" && selectedClient === client)}
                    >
                      <span className={`running-dot ${adminUrl ? "on" : ""}`} title={adminUrl ? "läuft" : undefined} />
                      <span className="client-icon" title={built ? "gebaut" : undefined}><Folder size={16} strokeWidth={2} fill={built ? "currentColor" : "none"} /></span>
                      <span className="client-name">{client}</span>
                      {adminUrl && (
                        <span
                          className="open-site-inline"
                          role="button"
                          tabIndex={-1}
                          title={`Admin im Browser öffnen (${adminUrl})`}
                          onClick={(e) => { e.stopPropagation(); openSite(adminUrl); }}
                        >
                          <ExternalLink size={14} strokeWidth={2} />
                        </span>
                      )}
                    </button>
                  </li>
                );
              })}
              {clients.length === 0 && !error && (
                <li className="empty-state">Keine Kunden gefunden – ist Google Drive verbunden?</li>
              )}
              {error && (
                <li className="error-state" title={error}>Konfiguration konnte nicht geladen werden</li>
              )}
            </ul>
          </div>

          <div className="nav-section">
            <div className="section-header">DEV-SEITEN</div>
            <ul className="nav-list">
              {devSites.map((dev) => {
                const adminUrl = runningAdminUrls.get(dev);
                const built = builtSites.has(dev);
                return (
                  <li key={dev}>
                    <button
                      className={`nav-item ${activeTab === "dev" && selectedDev === dev ? "active" : ""}`}
                      onClick={() => handleDevSelect(dev)}
                      disabled={isRunning && !(activeTab === "dev" && selectedDev === dev)}
                    >
                      <span className={`running-dot ${adminUrl ? "on" : ""}`} title={adminUrl ? "läuft" : undefined} />
                      <span className="client-icon" title={built ? "gebaut" : undefined}><FlaskConical size={16} strokeWidth={2} fill={built ? "currentColor" : "none"} /></span>
                      <span className="client-name">{dev}</span>
                      {adminUrl && (
                        <span
                          className="open-site-inline"
                          role="button"
                          tabIndex={-1}
                          title={`Admin im Browser öffnen (${adminUrl})`}
                          onClick={(e) => { e.stopPropagation(); openSite(adminUrl); }}
                        >
                          <ExternalLink size={14} strokeWidth={2} />
                        </span>
                      )}
                    </button>
                  </li>
                );
              })}
              {devSites.length === 0 && (
                <li className="empty-state">Noch keine Dev-Seiten – klone einen Kunden oder lege eine neue an.</li>
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
                  <span className="client-icon"><Settings size={16} strokeWidth={2} /></span>
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
            <h2 className="current-title">{headerTitle}</h2>
            <p className="current-subtitle">{headerSubtitle}</p>
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
                  Du bist dabei, den unwiderruflichen Befehl <strong>wpsite {confirmOp.cmd}</strong> für <strong>{currentTarget}</strong> auszuführen.
                </p>
                <p className="confirm-desc">
                  {confirmOp.description}
                </p>
                <div className="confirm-form">
                  <label htmlFor="confirm-input">
                    Zum Bestätigen bitte <strong>{currentTarget}</strong> eingeben:
                  </label>
                  <input
                    id="confirm-input"
                    type="text"
                    value={confirmInput}
                    onChange={(e) => setConfirmInput(e.target.value)}
                    placeholder={currentTarget || ""}
                    autoFocus
                  />
                  <div className="confirm-buttons">
                    <button className="btn-cancel" onClick={() => setConfirmOp(null)}>
                      Abbrechen
                    </button>
                    <button
                      className="btn-danger"
                      onClick={handleConfirmDestructive}
                      disabled={confirmInput !== currentTarget}
                    >
                      Bestätigen und ausführen
                    </button>
                  </div>
                </div>
              </div>
            </div>
          ) : formOp ? (
            <div className="confirm-overlay form">
              <div className="confirm-card">
                <h3>{formOp.form === "clone" ? "Kunde klonen" : "Neue Dev-Seite"}</h3>
                <p>
                  {formOp.form === "clone" ? (
                    <>Erstellt aus <strong>{selectedClient}</strong> eine neue lokale Dev-Seite.</>
                  ) : (
                    <>Erstellt eine frische, leere WordPress-Dev-Seite.</>
                  )}
                </p>
                <div className="confirm-form">
                  <label htmlFor="form-name">Name der Dev-Seite (Kleinbuchstaben, Ziffern, Bindestriche):</label>
                  <input
                    id="form-name"
                    type="text"
                    value={formName}
                    onChange={(e) => setFormName(e.target.value)}
                    placeholder="z. B. acme-dev"
                    autoFocus
                  />
                  {formName.length > 0 && !nameValid && (
                    <span className="form-hint error">Nur Kleinbuchstaben, Ziffern und Bindestriche (nicht am Anfang/Ende).</span>
                  )}
                  {formName.length > 0 && nameValid && nameTaken && (
                    <span className="form-hint error">„{formName}“ ist bereits als Kunde oder Dev-Seite vergeben.</span>
                  )}
                  {formOp.form === "clone" && (
                    <>
                      <label htmlFor="form-backup">Backup-Quelle:</label>
                      <select
                        id="form-backup"
                        className="form-select"
                        value={formBackup}
                        onChange={(e) => setFormBackup(e.target.value)}
                      >
                        <option value="">Frisches Backup vom Server holen (Standard)</option>
                        {formBackups.map((b) => (
                          <option key={b} value={b}>{b}</option>
                        ))}
                      </select>
                      {formBackup === "" ? (
                        <label className="checkbox-row">
                          <input
                            type="checkbox"
                            checked={formLight}
                            onChange={(e) => setFormLight(e.target.checked)}
                          />
                          <span>Leichte Kopie – Platzhalter statt echter Medien (schneller, kleiner)</span>
                        </label>
                      ) : (
                        <span className="form-hint">Klont von diesem vorhandenen Backup – funktioniert auch offline; die Medien-Variante ist durch das Backup vorgegeben.</span>
                      )}
                    </>
                  )}
                  <div className="confirm-buttons">
                    <button className="btn-cancel" onClick={() => setFormOp(null)}>
                      Abbrechen
                    </button>
                    <button
                      className="btn-primary"
                      onClick={handleFormSubmit}
                      disabled={!formReady}
                    >
                      {formOp.form === "clone" ? "Klonen" : "Anlegen"}
                    </button>
                  </div>
                </div>
              </div>
            </div>
          ) : (
            <div className="actions-grid">
              {activeCommands.map((cmdDesc) => {
                const available = cmdAvailable(cmdDesc);
                return (
                  <button
                    key={cmdDesc.name}
                    onClick={() => executeCommand(cmdDesc)}
                    disabled={isRunning || !available}
                    title={!available ? unavailableReason(cmdDesc) : undefined}
                    className={`action-card ${cmdDesc.destructive ? "destructive" : ""}`}
                  >
                    <div className="action-card-header">
                      <span className="action-title">{cmdDesc.name}</span>
                      <span className="action-cmd">wpsite {cmdDesc.cmd}</span>
                    </div>
                    <p className="action-desc">{cmdDesc.description}</p>
                  </button>
                );
              })}
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
