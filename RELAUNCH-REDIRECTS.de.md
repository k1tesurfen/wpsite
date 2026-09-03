# Weiterleitungen beim Relaunch mit wpsite

Ein Leitfaden, um die **alten URLs bei einem Relaunch** als `.htaccess`-Weiterleitungen in die
neue Seite zu übernehmen – mit `wpsite redirect`. Der Ablauf: **URL-Bestand aufnehmen → im Google
Sheet alt → neu zuordnen → als CSV exportieren → mit wpsite importieren → prüfen → überwachen.**

Der schwierige Teil ist nicht der Import, sondern die **Bestandsaufnahme**: herauszufinden,
**welche alten URLs überhaupt wichtig sind** (indexiert, bringen Traffic, haben Backlinks) – damit
wir genau diese weiterleiten und keine Arbeit in tote URLs stecken. Schritt 1 ist der Kern dieses
Leitfadens.

---

## 0. Voraussetzungen

- Der Kunde ist in der gemeinsamen Registry angelegt (`mandos client add …`) und erreichbar:
  ```bash
  wpsite test <kunde>      # SSH + wp_root + WP-CLI/DB müssen grün sein
  ```
- Die **Live-Domain** ist bekannt und wir haben Zugriff auf die **Google Search Console (GSC)** für
  diese Property. Die GSC ist die mit Abstand wichtigste Quelle unten – ist die Property beim Kunden
  noch nicht verifiziert, das **zuerst** erledigen (die Daten brauchen bis zu einem Tag, also früh
  anfangen).

---

## 1. Bestandsaufnahme – den „Alt-URL“-Bestand aufbauen

Keine einzelne Quelle ist vollständig. Wir ziehen aus mehreren und führen sie dann zusammen
(dedupliziert). Grob nach Priorität:

### 1a. Google Search Console – *was Google tatsächlich indexiert & ausliefert* (primär)
Das ist die maßgebliche Antwort auf die Frage „Welche URLs zeigt Google?“.

1. **Indexierung → Seiten** → auf **„Indexiert“** klicken → **Exportieren** (oben rechts). Das ist
   die Menge, die Google aktuell in den Suchergebnissen ausliefert.
2. **Leistung → Suchergebnisse** → Tab **Seiten** → Zeitraum auf **16 Monate** (Maximum) stellen →
   **Exportieren**. Das sind die URLs mit **Impressionen/Klicks** – also genau die, deren Verlust
   einer fehlenden Weiterleitung wirklich wehtut. Nach Klicks/Impressionen sortieren; der obere Teil
   dieser Liste ist unsere Pflicht-Menge.

> Die GSC liefert **vollständige URLs**. Für die CSV-Spalte `source` (§2) entfernen wir die Domain
> und behalten nur den **Pfad**.

### 1b. Aktuelle XML-Sitemap – *was die alte Seite selbst veröffentlicht*
```bash
# Übliche Orte durchprobieren; Yoast/RankMath liefern einen Sitemap-Index mit Unter-Sitemaps.
curl -s https://<domain>/sitemap_index.xml
curl -s https://<domain>/sitemap.xml
```
Alle `<loc>`-URLs herausziehen. Das fängt veröffentlichte Seiten ab, die wenige Klicks haben, aber
trotzdem existieren.

### 1c. Live-Seite crawlen – *was intern verlinkt ist* (Screaming Frog o. Ä.)
Den [Screaming Frog SEO Spider](https://www.screamingfrog.co.uk/seo-spider/) auf die Live-Domain
ansetzen und crawlen. Die kostenlose Version deckt 500 URLs ab (für die meisten Seiten genug). Die
Liste **Internal → HTML** der 200-OK-URLs exportieren. Bonus: Frog an die **GSC- und GA4-API**
anbinden – dann zieht er Klicks/Impressionen/Sitzungen pro URL in ein Blatt (Abkürzung für 1a + 1e).

### 1d. Server-Zugriffs-Logs – *echte Aufrufe, inkl. Lesezeichen & externer Links* (optional, per SSH)
Ein Crawl findet nur *verlinkte* URLs. Die Logs zeigen alles, was tatsächlich angefragt wurde –
auch Deeplinks von anderen Seiten und Lesezeichen. Den SSH-Zugang haben wir bereits:
```bash
# Log-Pfad je nach Hoster anpassen (hier Apache-Combined-Format angenommen)
wpsite test <kunde>    # bestätigt das SSH-Ziel
ssh <ssh-ziel> "awk '{print \$7}' /var/www/logs/access.log | sort | uniq -c | sort -rn | head -300"
```
Die häufig aufgerufenen Pfade behalten, die noch nicht in der Liste stehen.

### 1e. Analytics – *organische Top-Einstiegsseiten* (optional)
In **GA4** (oder Matomo): *Interaktionen → Landingpage*, letzte 12 Monate, nach Sitzungen sortieren.
Die Top-Landingpages exportieren – das sind Einstiegspunkte über Google/Links, die überleben müssen.

### 1f. Backlinks – *Seiten mit externem Link-Wert* (optional, falls Tool vorhanden)
In **Ahrefs / SEMrush**: *Top-Seiten nach Backlinks* („Best by links“). Ein Relaunch, der eine
stark verlinkte URL kaputt macht, wirft Ranking weg. Diese URLs bekommen Priorität bei der
Zielzuordnung, auch wenn der Traffic gering ist.

### 1g. Vorhandenes Redirection-Plugin – *Weiterleitungen, die die alte Seite schon hatte*
Nutzt die alte Seite das **Redirection**-Plugin, tippen wir diese nicht ab – wpsite liest sie in
Schritt 3 direkt von der Produktion aus (`wpsite redirect migrate`). Nur vermerken, dass sie
existieren, damit wir sie nicht doppelt im Sheet erfassen.

### Zusammenführen und Daten bereinigen

Ziel: aus den vielen Roh-Exporten **eine saubere, deduplizierte, priorisierte Pfad-Liste** machen,
die wir am Ende nur noch in die Vorlage kopieren müssen. Schritt für Schritt in Google Sheets:

**1) Ein Arbeits-Sheet mit je einem Tab pro Quelle anlegen.**
Neues Google Sheet anlegen und für jeden Export einen eigenen Reiter füllen – z. B. `GSC-Indexiert`,
`GSC-Leistung`, `Sitemap`, `Crawl`, `Logs`, `Analytics`, `Backlinks`. CSV-Exporte über
**Datei → Importieren → Hochladen** einlesen und dabei **„Neue Blätter einfügen“** wählen (so bleibt
jede Quelle getrennt und nachvollziehbar). Kleinere Listen einfach per Copy-&-Paste einfügen.

**2) Ein `Master`-Tab: alle URLs in EINE Spalte stapeln.**
Aus jedem Quell-Tab die URL-Spalte kopieren und im `Master`-Tab in Spalte `A` **untereinander**
einfügen (alles in eine lange Liste). Beim Einfügen **Bearbeiten → Einfügen → Nur Werte einfügen**
(Cmd/Strg + Shift + V) benutzen, damit keine Formeln/Formate mitkommen.

**3) Auf reine Pfade kürzen (Domain und Parameter weg) – per Suchen & Ersetzen mit Regex.**
Das ist zuverlässiger als Formeln (und unabhängig von der Sprach-/Trennzeichen-Einstellung).
Spalte `A` markieren, dann **Bearbeiten → Suchen und ersetzen** (Cmd/Strg + H), Häkchen bei
**„Mit regulären Ausdrücken suchen“** und **„Nur in diesem Bereich suchen“** setzen. Nacheinander:

| Suchen (Regex) | Ersetzen durch | Bewirkt |
|----------------|----------------|---------|
| `^https?://[^/]+` | *(leer)* | Protokoll + Domain entfernen → übrig bleibt der Pfad `/…` |
| `[?#].*$` | *(leer)* | Query-String (`?…`) und Anker (`#…`) abschneiden |

Danach steht in `A` überall nur noch der Pfad (z. B. `/produkte/alt`). Die Startseite wird dabei zu
einem leeren Feld – diese Zeile löschen (die Startseite muss man nicht auf sich selbst leiten).

**4) Bereinigen.**
- **Rauschen entfernen:** **Daten → Filter erstellen**, dann pro Muster nach **„Text enthält“**
  filtern und die Treffer-Zeilen löschen. Typischerweise raus: `/wp-admin`, `/wp-login`, `/wp-json`,
  `/xmlrpc`, `/wp-content/`, `/wp-includes/` (Assets), `/feed`, `/comments/feed`, interne Suche
  (`?s=` – ist nach Schritt 3 ohnehin weg), Paginierung `/page/…`. Diese brauchen selten eigene
  Weiterleitungen.
- **Parameter-URLs aussortieren:** Falls trotz Schritt 3 noch welche mit `?` übrig sind, in einen
  separaten Tab `Parameter` auslagern – wpsite überspringt sie beim Import (sie brauchen ein
  `RewriteCond`) und sie werden von Hand nachbearbeitet.
- **Leerzeichen bereinigen:** **Daten → Datenbereinigung → Leerzeichen entfernen**.
- **Duplikate entfernen:** **Daten → Datenbereinigung → Duplikate entfernen**. (Tipp: vorher
  entscheiden, ob mit oder ohne abschließenden Slash – am besten einheitlich; wpsite toleriert beim
  Abgleich zwar `/pfad` und `/pfad/`, aber für saubere Duplikat-Erkennung im Sheet hilft
  Einheitlichkeit. Optional per Suchen & Ersetzen: `(.+)/$` → `$1`, um End-Slashes zu entfernen.)

**5) Priorisieren (Klicks anhängen und sortieren).**
Damit wir die wichtigen URLs zuerst sehen: den `GSC-Leistung`-Tab in Schritt 3 ebenfalls auf Pfade
kürzen, dann im `Master` eine Spalte `Klicks` per Verweis füllen. In Spalte `B` neben dem Pfad in `A`:

```text
=WENNFEHLER(XVERWEIS(A2; 'GSC-Leistung'!$A:$A; 'GSC-Leistung'!$B:$B); 0)
```

> Hinweis zur Spracheinstellung: In deutschsprachigen Google-Sheets heißen die Funktionen
> `WENNFEHLER`/`XVERWEIS` (statt `IFERROR`/`XLOOKUP`) und das Argument-Trennzeichen ist `;` statt `,`.
> Wer `XVERWEIS` nicht hat, nimmt `SVERWEIS`. `'GSC-Leistung'!$B:$B` ist die Klick-Spalte des Exports.

Anschließend **Daten → Bereich sortieren nach Spalte** `B` (Klicks), absteigend. Backlink-starke
Seiten (aus dem `Backlinks`-Tab) zusätzlich nach oben ziehen – sie haben Priorität, auch bei wenig
Traffic. Jetzt steht oben, was einen Redirect wirklich braucht.

**6) Ziel zuordnen.**
Neben `source` (Spalte `A`) eine Spalte `target` anlegen und die neue Ziel-URL/​-Pfad eintragen
(Faustregeln siehe unten in §2). Von oben nach unten arbeiten – Pareto: die obersten (meiste
Klicks/Backlinks) zuerst und gründlich, der lange Schwanz darf grober sein oder auf 404 laufen. Wir
brauchen **nicht** für jede URL eine Weiterleitung; eine irreführende Weiterleitung ist schlechter
als ein ehrlicher 404.

**7) In die Redirect-Vorlage übertragen.**
In die Blueprint-Vorlage (Spalten `source,target,code,regex`) die fertigen Werte übernehmen –
wieder **„Nur Werte einfügen“**, damit keine Formeln/Verweise mitwandern. `code` durchgehend auf
`301` und `regex` auf `0` ziehen (Sonderfälle einzeln setzen). Danach die Vorlage als CSV
exportieren (§2, Ende) und mit wpsite importieren (§3).

---

## 2. Die Weiterleitungs-Zuordnung bauen (Google Sheet → CSV)

Für jede relevante Alt-URL das **neue Ziel** festlegen. Das Blueprint-Sheet mit diesen Spalten
befüllen (genau das importiert wpsite):

| Spalte   | Bedeutung | Beispiel |
|----------|-----------|----------|
| `source` | **Alter Pfad** (ohne Domain, mit führendem Slash). | `/alte-produktseite` |
| `target` | Neuer Pfad **oder** vollständige URL (extern). | `/produkte/neu` · `https://shop.example/x` |
| `code`   | HTTP-Status. Relaunch = **301** (dauerhaft). `302` nur temporär. | `301` |
| `regex`  | `0` = exakter Pfad (Normalfall). `1` = die Quelle ist ein Regex-Muster. | `0` |

Die **erste Zeile im Google Sheet muss die Kopfzeile** `source,target,code,regex` sein (wpsite
erkennt und überspringt sie). Dann **Datei → Herunterladen → Komma-getrennte Werte (.csv)**.

### Faustregeln für die Zuordnung
- **Auf die nächstpassende Seite leiten.** Ein eingestelltes Produkt → seine Kategorie oder den
  Nachfolger, **nicht** die Startseite. Alles auf `/` zu leiten wirkt für Google wie ein Soft-404
  und verliert das Ranking.
- **301 beim Relaunch** – überträgt Ranking-Signale auf die neue URL.
- **Keine Ketten, keine Schleifen.** Jede Alt-URL *direkt* auf das Endziel zeigen lassen. Niemals
  `source == target`.
- **Eine Zeile pro Alt-URL.** Schleichen sich Duplikate ein, gewinnt beim Import das *letzte*.
- **Pfade statt vollständiger URLs in `source`** – `https://<domain>` entfernen, alles ab dem ersten
  `/` behalten. `?query=strings` weglassen (siehe Hinweis zu Übersprungenem unten).
- **`regex: 1` sparsam einsetzen** – z. B. einen ganzen Baum verschieben: `source ^/blog/(.*)$`,
  `target /news/$1`, `regex 1`. Eigene Anker setzen; migrierte Regex wird case-sensitiv ausgegeben
  (bei Bedarf `(?i)` voranstellen).

### Was wpsite überspringt (und meldet)
Beim Import/Migrieren werden Zeilen, die keine einfache Regel werden können, mit Begründung nach
`<base_dir>/clients/<kunde>/redirects/<zeitstempel>.skipped.txt` geschrieben – diese von Hand
nacharbeiten. Das betrifft: eine **literale Quelle mit `?`** (Query-String – braucht ein
`RewriteCond`), ein **leeres Ziel** und (bei `migrate`) Plugin-Weiterleitungen mit
**bedingten/komplexen Match-Typen** (Cookie/Header/Login usw.). Kommata innerhalb eines Feldes
werden in v1 nicht unterstützt.

---

## 3. Import in wpsite

Erst durchführen, **wenn die relaunchte Seite die Live-Seite auf der Domain ist** (die
Weiterleitungen liegen in der `.htaccess` der neuen Seite; die `source`-Pfade sind die alten, die
es dort nicht mehr gibt).

### Falls die alte Seite das Redirection-Plugin nutzte – zuerst migrieren
```bash
wpsite redirect migrate <kunde>                       # alle Gruppen in den htaccess-Block holen
wpsite redirect migrate <kunde> --deactivate-plugin   # …und das Plugin danach abschalten
```

### Die CSV importieren
```bash
wpsite redirect import <kunde> /pfad/zu/weiterleitungen.csv          # in den verwalteten Block einfügen
wpsite redirect import <kunde> /pfad/zu/weiterleitungen.csv --replace # die CSV als alleinige Quelle setzen
```
wpsite zeigt eine Zusammenfassung und fragt nach Bestätigung. Es **sichert die `.htaccess` vorher**
(eine `.bak` auf dem Server plus eine lokale Kopie unter `…/clients/<kunde>/redirects/`), schreibt
atomar, prüft, ob die Startseite weiterhin antwortet, und **rollt bei einem Serverfehler automatisch
zurück** – eine fehlerhafte Regel kann die Seite also nicht lahmlegen.

### Oder über die GUI
Kunden auswählen → Karte **„Weiterleitungen“** → **CSV importieren** (Dateiauswahl) oder **Aus
Redirection-Plugin übernehmen**. Die aktuellen Regeln erscheinen in einer Tabelle; einzelne lassen
sich inline hinzufügen und mit 🗑 entfernen. (Gleiche Sicherung/Prüfung/Rollback im Hintergrund.)

---

## 4. Prüfen

```bash
wpsite redirect list <kunde>           # was jetzt im verwalteten Block steht
# ein paar wichtige Alt-URLs stichprobenartig testen (301 auf das richtige Ziel?):
curl -sI https://<domain>/alte-produktseite | grep -iE 'HTTP/|location'
#   erwartet:  HTTP/… 301
#              location: https://<domain>/produkte/neu
```
Ein paar aus der Top-Klicks-Liste prüfen, ein externes Ziel und jede Regex-Regel.

---

## 5. Nachbereitung & Monitoring (die Feedback-Schleife)

1. **Neue Sitemap in der GSC einreichen** (Sitemaps → `sitemap_index.xml` hinzufügen).
2. In den nächsten Wochen **GSC → Indexierung → Seiten → „Nicht gefunden (404)“** und den Bericht
   **Seitenindexierung** beobachten. Taucht dort eine alte, noch relevante URL als 404 auf, ist das
   eine vergessene Weiterleitung – ergänzen:
   ```bash
   wpsite redirect add <kunde> /vergessene-url /richtiges-ziel     # schnelles Einzel-Add
   ```
   oder ins Sheet ergänzen und neu importieren.
3. Prüfen, dass die Einträge aus `…/redirects/<zeitstempel>.skipped.txt` (Schritt 3) jeweils
   nachgearbeitet wurden.

---

## Spickzettel

```bash
wpsite test <kunde>                                    # 0. SSH/WP erreichbar?
wpsite redirect migrate <kunde> --deactivate-plugin    # 3. (nur bei altem Redirection-Plugin)
wpsite redirect import  <kunde> weiterleitungen.csv     # 3. gemappte CSV importieren
wpsite redirect list    <kunde>                         # 4. prüfen
wpsite redirect add     <kunde> /alt /neu               #    einmalig / später vergessene URL
wpsite redirect remove  <kunde> /alt                    #    eine entfernen
```

CSV-Kopfzeile: `source,target,code,regex` – alter Pfad → neuer Pfad/URL, `301`, `0` (bzw. `1` für Regex).
Priorität der Bestandsaufnahme: **GSC (indexiert + Leistung/Seiten) → Sitemap → Crawl → Logs/Analytics/Backlinks.**
