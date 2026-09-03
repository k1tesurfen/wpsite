import { useState, useEffect, useRef } from "react";
import { invoke } from "@tauri-apps/api/core";
import { open } from "@tauri-apps/plugin-dialog";
import { FolderOpen, FileText, CheckCircle2, XCircle, RotateCw, Lock } from "lucide-react";

// First-run machine onboarding. Collects the three paths `wpsite setup` needs
// (base_dir + team_config + cloud_base — all required here) and, once the
// prerequisites are present, shells out to `wpsite setup … --no-keys --no-test`.
// SSH-key install is deferred: clients are added via `mandos client add`, so there's
// nothing to key onboard on a fresh machine — a later "reconnect" action can re-run it.
//
// SAFETY: `wpsite setup` only ever writes LOCAL, per-machine config — the wpsite config's
// `base_dir` and mandos's LOCAL config (`~/.config/mandos/mandos.yml`, a pointer to the
// team file + this machine's Drive path). It NEVER writes the shared client registry on
// Drive. Still, to avoid repointing a machine that's already correctly configured, any
// value mandos already has is shown LOCKED (read-only) and must be explicitly unlocked
// with "Ändern" before it can be changed.

interface Prerequisite {
  name: string;
  installed: boolean;
  hint: string;
}

interface SetupStatus {
  base_dir: string;
  team_config: string;
  cloud_base: string;
  complete: boolean;
}

interface SetupScreenProps {
  logs: string;
  isRunning: boolean;
  // Kick off `wpsite setup` with the given flag vector (via the shared piped runner).
  onRunSetup: (args: string[]) => void;
}

type FieldKey = "base_dir" | "team_config" | "cloud_base";

function SetupScreen({ logs, isRunning, onRunSetup }: SetupScreenProps) {
  const [baseDir, setBaseDir] = useState("");
  const [teamConfig, setTeamConfig] = useState("");
  const [cloudBase, setCloudBase] = useState("");
  const [prereqs, setPrereqs] = useState<Prerequisite[]>([]);
  const [checking, setChecking] = useState(true);

  // Which fields mandos/wpsite ALREADY had configured at first load — captured once so a
  // later prereq re-check doesn't relock a field the user just started editing.
  const [configured, setConfigured] = useState<Record<FieldKey, boolean>>({
    base_dir: false,
    team_config: false,
    cloud_base: false,
  });
  // Fields the user has explicitly chosen to change (unlocked). base_dir being local to
  // wpsite is low-risk, but we treat all three the same for consistency.
  const [override, setOverride] = useState<Record<FieldKey, boolean>>({
    base_dir: false,
    team_config: false,
    cloud_base: false,
  });
  const capturedInitial = useRef(false);

  const setters: Record<FieldKey, (v: string) => void> = {
    base_dir: setBaseDir,
    team_config: setTeamConfig,
    cloud_base: setCloudBase,
  };
  const values: Record<FieldKey, string> = {
    base_dir: baseDir,
    team_config: teamConfig,
    cloud_base: cloudBase,
  };

  // Load prerequisites + prefill any values a previous (partial) setup already wrote.
  const recheck = async () => {
    setChecking(true);
    try {
      const [pr, st] = await Promise.all([
        invoke<Prerequisite[]>("check_prerequisites"),
        invoke<SetupStatus>("get_setup_status"),
      ]);
      setPrereqs(pr);
      setBaseDir((v) => v || st.base_dir);
      setTeamConfig((v) => v || st.team_config);
      setCloudBase((v) => v || st.cloud_base);
      // Capture the already-configured set exactly once (the initial state of the machine).
      if (!capturedInitial.current) {
        capturedInitial.current = true;
        setConfigured({
          base_dir: st.base_dir.trim() !== "",
          team_config: st.team_config.trim() !== "",
          cloud_base: st.cloud_base.trim() !== "",
        });
      }
    } catch {
      setPrereqs([]);
    }
    setChecking(false);
  };

  useEffect(() => {
    recheck();
  }, []);

  const pickDir = async (set: (v: string) => void) => {
    const sel = await open({ directory: true, multiple: false });
    if (typeof sel === "string") set(sel);
  };

  const pickFile = async (set: (v: string) => void) => {
    const sel = await open({ directory: false, multiple: false });
    if (typeof sel === "string") set(sel);
  };

  const prereqsOk = prereqs.length > 0 && prereqs.every((p) => p.installed);
  const pathsOk = baseDir.trim() && teamConfig.trim() && cloudBase.trim();
  const canSave = !!prereqsOk && !!pathsOk && !isRunning;

  const handleSave = () => {
    if (!canSave) return;
    // All three are passed (locked ones keep their current, unchanged value). `wpsite setup`
    // requires --team-config; re-writing an unchanged value is a safe, local-only no-op.
    onRunSetup([
      "--base-dir", baseDir.trim(),
      "--team-config", teamConfig.trim(),
      "--cloud-base", cloudBase.trim(),
      "--no-keys",
      "--no-test",
    ]);
  };

  // Render one path field: locked summary (if already configured and not being changed)
  // or an editable input + picker.
  const renderField = (
    key: FieldKey,
    label: string,
    desc: string,
    placeholder: string,
    kind: "dir" | "file",
    cloudNote: boolean,
  ) => {
    const locked = configured[key] && !override[key];
    const pick = () => (kind === "dir" ? pickDir(setters[key]) : pickFile(setters[key]));
    const Icon = kind === "dir" ? FolderOpen : FileText;

    return (
      <div className="setup-field">
        <span className="setup-label">
          {label}
          <span className="setup-desc">{desc}</span>
        </span>
        {locked ? (
          <div className="setup-locked-row">
            <CheckCircle2 size={15} strokeWidth={2} className="setup-locked-ok" />
            <code className="setup-locked-value">{values[key]}</code>
            <span className="setup-locked-badge">bereits konfiguriert</span>
            <button
              className="setup-change"
              onClick={() => setOverride((o) => ({ ...o, [key]: true }))}
            >
              <Lock size={13} strokeWidth={2} /> Ändern
            </button>
          </div>
        ) : (
          <>
            <div className="setup-input-row">
              <input
                type="text"
                value={values[key]}
                onChange={(e) => setters[key](e.target.value)}
                placeholder={placeholder}
              />
              <button className="setup-browse" onClick={pick}>
                <Icon size={15} strokeWidth={2} /> Wählen
              </button>
            </div>
            {configured[key] && override[key] && cloudNote && (
              <span className="setup-field-warn">
                Ändert nur die Konfiguration dieses Rechners. Die geteilte Kundenliste in
                der Cloud bleibt unberührt.
              </span>
            )}
          </>
        )}
      </div>
    );
  };

  return (
    <div className="setup-screen">
      <div className="setup-card">
        <div className="setup-brand">
          <img className="brand-logo" src="/wpsite-logo-solo.png" alt="wpsite" />
          <div>
            <h1 className="setup-title">Willkommen bei wpsite</h1>
            <p className="setup-subtitle">
              Richte diesen Rechner einmalig ein. Alle Angaben werden benötigt.
            </p>
          </div>
        </div>

        {/* Prerequisites gate */}
        <div className="setup-section">
          <div className="setup-section-head">
            <h3>Voraussetzungen</h3>
            <button className="setup-recheck" onClick={recheck} disabled={checking} title="Erneut prüfen">
              <RotateCw size={15} strokeWidth={2} /> Prüfen
            </button>
          </div>
          <ul className="prereq-list">
            {prereqs.map((p) => (
              <li key={p.name} className={p.installed ? "ok" : "missing"}>
                {p.installed ? (
                  <CheckCircle2 size={16} strokeWidth={2} />
                ) : (
                  <XCircle size={16} strokeWidth={2} />
                )}
                <span className="prereq-name">{p.name}</span>
                {!p.installed && <span className="prereq-hint">{p.hint}</span>}
              </li>
            ))}
            {checking && prereqs.length === 0 && <li className="prereq-checking">Prüfe …</li>}
          </ul>
          {!prereqsOk && !checking && (
            <p className="setup-warn">
              Bitte fehlende Programme installieren, dann erneut prüfen. Die Einrichtung
              lässt sich erst danach abschließen.
            </p>
          )}
        </div>

        {/* Paths */}
        <div className="setup-section">
          <h3>Speicherorte</h3>
          <p className="setup-note">
            Diese Angaben betreffen nur diesen Rechner (lokale Konfiguration). Die
            gemeinsame Kundenliste in Google Drive wird dabei nie verändert.
          </p>

          {renderField(
            "base_dir",
            "Lokaler Ordner für die Seiten",
            "Hier werden Kopien und Backups gespeichert (base_dir).",
            "z. B. ~/websites",
            "dir",
            false,
          )}
          {renderField(
            "team_config",
            "Kunden-Registry (Datei)",
            "Die gemeinsame Kundenliste in Google Drive (mandos-Team-Datei).",
            "z. B. …/LIVE_WEB/mandos.team.yml",
            "file",
            true,
          )}
          {renderField(
            "cloud_base",
            "Cloud-Backup-Ordner",
            "Der Projekt-Stammordner in Google Drive, in den Backups gespiegelt werden (cloud_base).",
            "z. B. …/LIVE_WEB",
            "dir",
            true,
          )}
        </div>

        <div className="setup-actions">
          <button className="btn-primary setup-save" onClick={handleSave} disabled={!canSave}>
            {isRunning ? "Wird eingerichtet …" : "Einrichtung abschließen"}
          </button>
        </div>

        {logs && <pre className="setup-console">{logs}</pre>}
      </div>
    </div>
  );
}

export default SetupScreen;
