# wpsite installieren — Schritt für Schritt (keine Programmierkenntnisse nötig)

> 🇬🇧 English version: [INSTALL.md](INSTALL.md)

Diese Anleitung bringt **wpsite** auf deinem Mac zum Laufen. Es dauert etwa
**20–30 Minuten** und du machst es nur einmal. Folge einfach den Schritten der Reihe
nach und kopiere die Befehle genau so, wie sie hier stehen.

`wpsite` erstellt eine sichere lokale Kopie der Website eines Kunden auf deinem eigenen
Mac, damit du Änderungen und Updates testen kannst, ohne die Live-Seite anzufassen.

> Jeder Befehl unten wird in die App **Terminal** eingegeben. „Einfügen“ heißt: ins
> Terminal-Fenster klicken, die Zeile einfügen und **Return** drücken. Wenn ein Befehl
> nach einem Passwort fragt, ist dein **Mac-Anmeldepasswort** gemeint (während des
> Tippens siehst du nichts — das ist normal — einfach tippen und Return drücken).

---

## Bevor du loslegst — die Checkliste

Du brauchst:

1. **Einen Mac** (dieses Tool läuft nur unter macOS).
2. **Dein Mac-Administrator-Passwort** (du gibst es ein paar Mal ein).
3. **Google Drive for Desktop**, angemeldet mit deinem **@artismedia.de**-Konto, mit
   sichtbarer geteilter Ablage **`01_Projekte`** im Finder.
   - Nicht sicher? Öffne den **Finder** → in der Seitenleiste unter *Orte* sollte
     **Google Drive** stehen. Klick drauf und suche nach **Geteilte Ablagen → 01_Projekte**.
     Falls das fehlt, installiere zuerst Google Drive for Desktop und melde dich an —
     komm dann hierher zurück.

---

## Schritt 1 — Terminal öffnen

1. Drücke **⌘ (Command) + Leertaste**, um Spotlight zu öffnen.
2. Tippe **Terminal** und drücke **Return**.

Ein kleines Fenster mit Text öffnet sich. Dort kommen alle Befehle hinein.

---

## Schritt 2 — Homebrew und die Hilfsprogramme installieren

**Homebrew** ist ein sicherer, verbreiteter Installer für Mac-Tools. Füge diese Zeile
ein und drücke Return:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

- Es fragt evtl. nach deinem Mac-Passwort und möchte die „Command Line Tools“
  installieren — bestätige das. Dieser Teil kann einige Minuten dauern. Lass ihn
  durchlaufen.
- Wenn es fertig ist, zeigt es evtl. **„Next steps“** mit zwei Zeilen zum Ausführen an.
  Falls du sie siehst, kopiere und führe sie aus. Auf den meisten aktuellen Macs sind es
  diese beiden (beide einfügen):

  ```bash
  echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
  eval "$(/opt/homebrew/bin/brew shellenv)"
  ```

Jetzt die Tools installieren, die wpsite braucht (die ganze Zeile einfügen):

```bash
brew install yq imagemagick ffmpeg
```

---

## Schritt 3 — Docker Desktop installieren

wpsite lässt die Website-Kopien in **Docker** laufen. Installiere es:

```bash
brew install --cask docker
```

Dann **Docker einmal öffnen**, damit es die Einrichtung abschließen kann:

1. Öffne **Finder → Programme → Docker** (Doppelklick).
2. Bestätige die Abfragen. Warte, bis das kleine **Wal-Symbol** oben in der Menüleiste
   erscheint und aufhört zu animieren. Lass Docker laufen.

---

## Schritt 4 — Das wpsite-Programm aus Google Drive kopieren

1. Gehe im **Finder** zu **Google Drive → Geteilte Ablagen → 01_Projekte → 01_Global →
   wpsite**.
2. Du siehst einen Ordner namens **`wpsite`** (das Programm) — diesen kopierst du.
3. **Kopiere ihn auf deinen Mac** (nicht aus Google Drive heraus starten): einmal
   anklicken, **⌘C** drücken, dann in deinen Ordner **Programme** (oder deinen
   Benutzerordner) gehen und **⌘V** drücken.

> Warum herauskopieren? Programme, die direkt in Google Drive liegen, können sich
> seltsam verhalten, weil Drive ständig synchronisiert. Eine lokale Kopie ist zuverlässig.

---

## Schritt 5 — Den Befehl `wpsite` installieren

1. Zurück im **Terminal**: tippe `cd ` (die Buchstaben c, d und ein **Leerzeichen**) —
   aber drücke noch **nicht** Return:

   ```bash
   cd 
   ```

2. Zieh jetzt den kopierten **`wpsite`-Ordner** aus dem Finder direkt ins Terminal-Fenster.
   Der Speicherort wird automatisch eingefügt. Drücke **Return**.

3. Führe den Installer aus (einfügen):

   ```bash
   ./install.sh
   ```

   Es fragt evtl. nach deinem Mac-Passwort. Am Ende erscheint ein ✓.

4. Prüfen, ob es geklappt hat (einfügen):

   ```bash
   wpsite doctor
   ```

   Du solltest eine Liste grüner ✓-Häkchen sehen. (Eine Warnung zur Team-Konfiguration
   ist in Ordnung — der nächste Schritt behebt das.)

---

## Schritt 6 — Mit dem Team verbinden

Der Kundenzugang wird von einem kleinen Hilfsprogramm namens **mandos** verwaltet. Falls es
noch nicht auf deinem Mac ist, bitte Beren, es dir einzurichten (einmalig). Sobald es da ist,
erledigt **ein Befehl** die ganze Einrichtung. Einfügen:

```bash
wpsite setup
```

Es stellt ein paar Fragen. Genau das machst du bei jeder:

1. **„Local data dir (base_dir)“** → einfach **Return** drücken (die Voreinstellung passt).

2. **„Shared client registry…“** → Gehe im Finder zu **Google Drive → Geteilte Ablagen →
   01_Projekte → 01_Global → mandos** und finde die Datei **`mandos.team.yml`**. **Zieh
   diese Datei ins Terminal-Fenster** und drücke **Return**.

3. **„Cloud backup root (cloud_base)…“** → Gehe im Finder zu **Google Drive → Geteilte
   Ablagen → 01_Projekte** und finde den Ordner **`LIVE_WEB`**. **Zieh diesen Ordner ins
   Terminal-Fenster** und drücke **Return**.

4. **Deinen SSH-Schlüssel erstellen** (nur beim ersten Mal): Es erstellt einen sicheren
   „Schlüssel“, damit du die Kundenserver erreichst. Wenn es nach einer **passphrase**
   fragt, ist die einfachste Wahl, **zweimal Return** zu drücken (keine Passphrase). Dann
   geht es weiter.

5. **Verbindung zu jedem Kunden** → Für jeden Kunden fragt es evtl.:
   - *„Are you sure you want to continue connecting?“* → **`yes`** tippen und Return drücken.
   - Ein **Passwort für diesen Server** → gib es ein, falls du es hast (frag Beren, wenn
     unsicher). Fehlt dir das Passwort eines Servers, wird dieser Kunde übersprungen — die
     anderen funktionieren trotzdem, und du kannst ihn später mit `wpsite setup --keys-only`
     nachholen.

Am Ende listet es auf, welche Kunden bereit sind. 🎉

Alles prüfen:

```bash
wpsite doctor
wpsite list
```

`wpsite list` sollte die gemeinsame Kundenliste zeigen. Du kannst jetzt eine lokale Kopie
jedes Kunden erstellen, z. B.:

```bash
wpsite backup ehmann     # frischen Snapshot holen
wpsite build ehmann      # lokale Kopie bauen → öffnet unter http://ehmann.test
```

---

## Schritt 7 — Die Desktop-App installieren (optional, aber angenehmer)

Wenn du lieber klickst als tippst, gibt es eine **wpsite**-Desktop-App.

1. Gehe im **Finder** zu **Google Drive → Geteilte Ablagen → 01_Projekte → 01_Global →
   wpsite → app** und finde **`wpsite.app`**.
2. **Zieh `wpsite.app` in deinen Programme-Ordner.**
3. Beim **ersten** Öffnen: **Rechtsklick** auf die App → **Öffnen** → im Dialog nochmal
   **Öffnen**. (macOS fragt das einmalig bei Apps, die nicht aus dem App Store sind;
   danach kannst du sie normal öffnen.)

Die App nutzt alles, was du oben eingerichtet hast — deshalb müssen die **Schritte 1–6
vorher erledigt sein**; die App funktioniert nicht allein.

---

## wpsite im Alltag nutzen

- Am einfachsten: In **Claude Code** **`/wpsite`** tippen und auf Deutsch beschreiben, was
  du willst (z. B. *„Sicherung für Ehmann erstellen und lokale Kopie bauen“*). Es führt die
  richtigen Befehle aus.
- Oder die Desktop-App nutzen.
- Oder Befehle selbst tippen — `wpsite` allein listet alle auf.

---

## Wenn etwas nicht klappt

- **„command not found: wpsite“** → Terminal schließen, neu öffnen, nochmal versuchen.
  Klappt es weiterhin nicht, Schritt 5 wiederholen.
- **Keine Kunden aufgelistet / „not found“** → Google Drive ist nicht fertig synchronisiert,
  oder mandos zeigt noch nicht auf die gemeinsame Liste. Finder öffnen, Google Drive anklicken,
  prüfen, ob **01_Projekte** da ist, eine Minute warten, dann Schritt 6.1 (`mandos config init …`)
  erneut ausführen.
- **Docker-/Build-Fehler** → Sicherstellen, dass Docker Desktop läuft (Wal-Symbol in der
  Menüleiste). Falls nicht, aus **Programme** öffnen.
- **Die Schlüssel-Installation für einen Server schlug fehl** → Dir fehlte das Server-Passwort.
  Besorg es und führe `mandos client setup-key <kunde>` erneut aus, oder frag Beren.
- **Immer noch fest?** Schick Beren einen Screenshot des Terminals — der Fehlertext sagt
  ihm genau, was los ist.

---

## Für die Person, die das pflegt (Admin-Hinweise)

Damit die Schritte oben funktionieren, muss die geteilte Ablage unter
**`01_Projekte/01_Global/`** Folgendes enthalten:

1. **`mandos/mandos.team.yml`** — die gemeinsame Kundenliste, die mandos liest (Schritt 6.1).
2. **Eine Kopie des `wpsite`-Programmordners** (dieses Repository) unter `wpsite/`. Aktualisiere
   sie dort, wann immer du Änderungen auslieferst, damit Kollegen die aktuelle Version kopieren.
3. **Die gebaute Desktop-App** unter **`…/wpsite/app/wpsite.app`** (einmal mit den Schritten
   in [`GUI-Install.md`](GUI-Install.md) bauen, dann die `.app` dort ablegen). Bei Updates
   neu bauen + ersetzen.

Außerdem braucht jeder Kollege das **`mandos`-Hilfsprogramm** auf seinem Mac (`make install`
im mandos-Repo, oder ihm eine gebaute Binary geben).

Hinweise:
- Kundenidentität, SSH-Schlüssel-Einrichtung und der Google-Drive-Stamm liegen jetzt in
  **mandos** (`mandos config init` schreibt die `~/.config/mandos/mandos.yml` jedes Kollegen).
  wpsites eigene Konfiguration enthält nur noch `base_dir`.
- Der Pfad zur Team-Datei und `cloud_base` sind **pro Person** (der Google-Drive-Pfad jedes
  Kollegen enthält sein eigenes Konto), weshalb Schritt 6 sie per Drag-and-drop ausfüllt statt
  mit einem festen Pfad.
- SSH-Schlüssel sind **pro Person**: das Teilen der Kundenliste teilt keinen Serverzugang.
  Jeder Kollege führt `mandos client setup-key <kunde>` aus, das seinen Schlüssel erstellt und
  auf dem Server installiert (die Passwortabfrage). Zugang erteilen/entziehen, indem der
  Schlüssel der Person auf den Servern hinzugefügt/entfernt wird.
- Die Aufbewahrung ist fest auf **5 Backups** pro Kunde; niemand muss das konfigurieren.
