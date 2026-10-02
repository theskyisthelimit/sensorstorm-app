# Funktionsanalyse, Verbesserungen und Roadmap

Stand 2. Oktober 2026, Code auf `9a32a7c` (Build 16). Grundlage ist der ganze Quellcode
(rund 24 000 Zeilen Swift in App, Core-Paket und Uhr), dazu README, `docs/TODO.md`, die
Store-Texte in `Tools/store/` und der Website-Generator in `web/build.py`.

Aufbau: Kapitel 1 sagt, was die App heute kann. Kapitel 2 listet, was im Bestehenden
fehlerhaft oder lückenhaft ist. Kapitel 3 zeigt, wo der Alleinstellungswert liegt.
Kapitel 4 nennt die Zielgruppen, die genau das brauchen. Kapitel 5 enthält die
Vorschläge als Umsetzungskarten. Kapitel 6 behandelt das Geschäftsmodell, Kapitel 7 die
Reihenfolge.

Jede Umsetzungskarte nennt **was** gebaut wird, **wo** im Code, **welche Daten** dazukommen,
**wie es getestet** wird, **was es kostet** (S ≤ 1 Tag, M = 2–5 Tage, L = 1–3 Wochen,
jeweils ohne Übersetzung) und **wo die Grenze gratis / Pro / Inspektion** liegt.
„Inspektion“ ist ein vorgeschlagenes neues Paket für Organisationen (Kapitel 6).

---

## 0. Kurzfazit

1. **Sensorstorm sind heute zwei Apps in einer.** Die eine ist ein Sensor-Logger. Gegen
   sie stehen Sensor Logger, phyphox und SensorLog. Die andere ist ein Werkzeug, um Schäden
   im Feld zu erfassen. Gegen sie stehen Survey123, QField, PlanRadar und Vialytics. Beide
   Hälften sind technisch sauber gebaut. Sie **reden aber kaum miteinander**: In den Daten
   verbindet sie nur `recordingID` und `hostTime`, in der Oberfläche ein einziger Satz in
   `SurveyDetailView`.
2. **Als reiner Logger lässt sich wenig gewinnen.** phyphox ist gratis, Sensor Logger hat
   die Reichweite, und Sensorstorm ist dort ein besserer Nachbau mit sauberer Zeitbasis.
   Das ist ein gutes Fundament, aber kein Geschäft für CHF 19 einmalig.
3. **Der eigentliche Alleinstellungswert ist die Verbindung der beiden Hälften.** Video,
   IMU, GPS und Beobachtung laufen auf derselben Uhr. Dazu kommen eine ausgewiesene
   Lagegenauigkeit, LV95 und keine Cloud. Daraus lässt sich bauen, was heute nur teure
   SaaS-Plattformen bieten: **den Zustand einer Strasse beim Darüberfahren messen,
   Auffälligkeiten mit Videobild auf die Karte legen, sie vor Ort bestätigen und als
   Protokoll abgeben.** Ohne Abo-Plattform und ohne dass Daten die Gemeinde verlassen.
4. **Die zahlungskräftigste Zielgruppe sind Gemeinden, Werkhöfe, Tiefbauämter und die
   Ingenieurbüros, die für sie Strassen erheben.** Der rechtliche Druck ist in allen drei
   Ländern derselbe: die Werkeigentümerhaftung (Art. 58 OR) in der Schweiz, die
   Verkehrssicherungspflicht in Deutschland, die Wegehalterhaftung (§ 1319a ABGB) in
   Österreich. Wer belegen kann, dass er regelmässig kontrolliert hat, steht im
   Schadenfall besser da. Dafür fehlen heute vier Dinge: der gelaufene **Weg als
   Nachweis**, ein **PDF-Protokoll**, ein **Status je Mangel** und ein **Schadenkatalog**.
5. Daneben gibt es Nischen, in denen die gemeinsame Uhr allein schon das Produkt ist:
   **Fahrqualität von Aufzügen**, **Fahrkomfort im ÖV**, **Erschütterungs-Screening auf
   Baustellen** und **gelabelte Bewegungsdatensätze für Machine Learning**.
6. **Vier Befunde sollten sofort behoben werden:**
   - Regeln verpassen kurze Spitzen. Sie sehen bei 100 Hz nur jeden zehnten Messwert.
   - Routen zeichnen ihren Weg nicht auf.
   - Es gibt einen Gesamtexport, aber keinen Import. Ohne iCloud-Backup bedeutet ein
     Gerätewechsel deshalb Datenverlust.
   - Website und Store widersprechen sich und dem Code bei der Frage, was gratis ist.

---

## 1. Bestandsaufnahme

### 1.1 Messen — Tab „Aufnehmen“

| Bereich | Stand | Einschätzung |
|---|---|---|
| Zeitbasis | Alle Ströme auf `mach_absolute_time` (`HostClock`), Video über `AVAssetWriter`, Stabilisierung aus | **Stärkste technische Eigenschaft.** Kein Mitbewerber im Preissegment dokumentiert das so konsequent. |
| Ströme | 22 (`SensorID`): IMU roh und fusioniert, Orientierung, Kompass, Barometer, GPS, Lautstärke, Schritte, Aktivität, Batterie, Helligkeit, Netz, Bluetooth, AirPods, Uhr (Puls, Handgelenk), Kamerapose | Vollständig. Es fehlen abgeleitete Grössen (vertikale Beschleunigung, Betrag) und der Wärmezustand des Geräts. |
| Raten | 10–400 Hz, über 200 Hz nur mit Pro | ok |
| Video | 720p/1080p/4K, vorne/hinten, ARKit-Modus mit Pose und Intrinsics je Bild | ok. Der 3D-Weg ist laut TODO unbefriedigend, siehe M7. |
| Detailansicht | `SensorDetailView`: grosser Wert, Verlauf, startet sofort | **TODO Nr. 4 ist erledigt**, `docs/TODO.md` ist hier veraltet. |
| Markierungen | Punkt mit Text (`Annotation`) | Keine Intervalle, keine Label-Spuren (siehe M5) |
| Regeln | Messwert / Geofence / Dauer / MQTT, kombiniert mit *und*; Aktionen: Benachrichtigung, Markierung, Stopp; Auswertung mit 10 Hz | Guter Anfang. Kurze Spitzen gehen verloren (F1), es gibt kein „Start“ und keine Webhook-Aktion. |
| Live | HTTP-Push im Format von Sensor Logger, MQTT mit Abos, Webserver auf `:8080` (JSON) | Kompatibilität mit dem Ökosystem ist klug. Der Webserver liefert nur JSON, kein Dashboard. |
| Bluetooth | Zählung, Rohlog, Decoder (Ruuvi, BTHome, ATC/pvvx), GATT (Puls, Leistung, Trittfrequenz, Laufsensor), eigene JS-Decoder | Funktional stark, strukturell überladen (TODO Nr. 3, F12) |
| Zeitserver | NTP gemessen, gespeichert, nie angewendet | vorbildlich ehrlich |

### 1.2 Auswerten — Tab „Aufnahmen“

| Bereich | Stand | Einschätzung |
|---|---|---|
| Wiedergabe | Video und Kurven synchron, Zoom, Werte am Abspielkopf | gut |
| Exporte | CSV je Sensor (gratis), GPX/KML-Track (gratis), Rohdaten, Blender-Szene, Fotogrammetrie/COLMAP, Sensor Logger, Gyroflow, kombinierte CSV, JSON, SQLite, Excel; Gesamtexport mit `manifest.json` und SHA-256 | Breiter als jede Konkurrenz |
| Fehlt | **keine Karte**, keine Statistik über einen Bereich, keine abgeleiteten Kanäle, keine Frequenzanalyse, kein Zuschneiden, keine Qualitätsangaben (tatsächliche Rate, Lücken) | Für Ingenieure und Forschung sind das Grundfunktionen |

### 1.3 Erfassen — Tab „Beobachtungen“

| Bereich | Stand | Einschätzung |
|---|---|---|
| Modell | Route (`Survey`) → Beobachtung (`GroundFinding`) mit Fotos/Clips, Bewertung 1–10, freiem Label, Notiz, Bereich (Kreis/Polygon, m²) | sauber, rückwärtskompatibel dekodiert |
| Position | Quelle `gps` / `averaged` / `manual`; bei Korrektur bleiben beide Positionen erhalten; Unsicherheitskreis massstäblich; LV95 | **Alleinstellungsmerkmal**, das niemand sonst so ehrlich macht |
| Exporte | CSV (gratis), GeoJSON/GPX/KML/Bündel (Pro) | gut |
| Fehlt | **Weg der Route**, **Status**, Katalog/Kategorien, Adresse, Protokoll, Import/Zusammenführen, Schweizer Grundkarten, Messen (Neigung, Länge, Tiefe), Wiederholungsbegehung | Genau das unterscheidet ein Hobbywerkzeug von einem, das eine Gemeinde einsetzt |

### 1.4 Geschäftsmodell

- Gratis: alle Sensoren, Wiedergabe, **eine** Route, CSV, dazu GPX/KML für Aufnahmen.
- Pro: **CHF 19 einmalig** (`Tools/asc_iap.py`). Das schaltet 400 Hz, 4K, ARKit, alle
  Profi-Formate, Live-Übertragung, Webserver und unbegrenzt Routen frei.
- 27 Sprachen, kein Konto, keine Cloud, kein Tracking.

### 1.5 Technische Basis

Das Core-Paket ist reine Logik und gut getestet (158 Tests). CI prüft den Vertrag mit
Blender, das adaptive Layout, RTL und die Lokalisierung. `SWIFT_STRICT_CONCURRENCY: complete`
ist gesetzt. Gestaltung und Kommentare sind ungewöhnlich sorgfältig.

**Für jede Umsetzung gilt:** Jeder neue sichtbare Text muss in `Localizable.xcstrings` und
über `Tools/l10n.py sync/translate` in 26 Sprachen. Das ist bei jeder Karte als Aufwand
einzurechnen. Neue Logik gehört nach `Sources/SensorstormCore` und wird dort getestet, so
wie bisher.

---

## 2. Befunde im Bestehenden

### F1 — Regeln verpassen kurze Spitzen *(Fehler)*

`SensorHub.evaluateRules()` (`App/Recording/SensorHub.swift:674`) baut den `RuleContext` aus
`live` auf. `live` ist `sink.snapshot()` (`App/Recording/SampleSink.swift:56`) und enthält **nur
den neuesten Wert** jedes Stroms. Ausgewertet wird alle 100 ms. Daraus folgt:

- Bei 100 Hz erreichen 9 von 10 Messwerten die Regeln nie, bei 400 Hz 39 von 40.
- Ein Schlag durch ein Schlagloch dauert 20–60 ms. Eine Regel wie
  „Beschleunigung z > 0,8 g → Markierung“ feuert deshalb nur zufällig.

Ausgerechnet der naheliegendste Anwendungsfall der Regeln funktioniert also nicht
zuverlässig. Behebung: S1.

### F2 — Schwellen hängen an der Geräteachse

Eine Regel prüft „Kanal z von `userAcceleration`“. In einer Halterung steht das Telefon
aber selten genau senkrecht, und z ist dann nicht „oben“. Gebraucht wird eine **vertikale
Beschleunigung im Erdsystem** und ein **Betrag**, die beide unabhängig von der Lage sind.
Behebung: S2. Das ist die Voraussetzung für U3, M1, M2 und M3.

### F3 — Eine „Route“ ohne Weg

In der Oberfläche heisst es „Route“, `Survey` speichert aber nur Beobachtungen. Den
gelaufenen Weg gibt es nur, wenn zufällig eine Messaufnahme mitläuft. Für eine Kontrolle
ist aber gerade der Weg der Nachweis: wo jemand wann war, und welche Strasse **ohne**
Befund begangen wurde. Behebung: S3.

### F4 — Export ohne Import

`ArchiveExporter` schreibt ein vollständiges, prüfsummengesichertes Archiv. Einen Weg
zurück gibt es nicht. Für eine App, die ausdrücklich keine Cloud hat, ist das Archiv das
einzige Backup. Ein Gerätewechsel ohne iCloud-Gerätebackup oder ein Kollege, der eine
Route übernehmen soll, endet heute in einer Sackgasse. Behebung: S4, danach U12.

### F5 — Website und Store widersprechen sich und dem Code

- `web/build.py`, Abschnitt „Gratis und Pro“: Unter *Gratis* steht nur „CSV-Export“, unter
  *Pro* steht „GeoJSON/GPX/KML“. Der Code (`ProAccess.freeRecordingFormats`) und der
  Store-Text sagen dagegen, dass GPX und KML für Aufnahmen gratis sind. Weiter oben
  schreibt dieselbe Seite selbst „ohne Pro“.
- Store und Website erwähnen die Neuerungen aus Build 16 nicht: Regeln, Webserver im WLAN,
  MQTT-Abos, Bluetooth-Sensoren mit eigenen Decodern, Excel.

Behebung: S11.

### F6 — Lautstärke nur in dBFS

dBFS ist ein Pegel relativ zur Vollaussteuerung, kein Schallpegel. Für alle
Lärmfragen (Baustelle, Veranstaltung, Nachbarschaft) ist der Wert deshalb nicht
verwendbar. Die Audio-Session läuft bereits im Modus `.measurement`. Die halbe Arbeit für
dB(A) ist damit schon getan. Siehe M4.

### F7 — Beobachtungen ohne Status

Ein Mangel ist entweder offen oder erledigt. Ohne dieses Feld lässt sich keine Arbeit
zuteilen und kein Fortschritt zeigen. Für Werkhöfe ist das der wichtigste Grund, eine App
überhaupt zu nutzen. Behebung: S5.

### F8 — Freitext-Labels verhindern jede Auswertung

„Schlagloch“, „schlagloch“, „Loch“ und „Ausbruch“ sind für eine Statistik vier
verschiedene Dinge. Der Kommentar in `GroundFinding.label` begründet den Freitext zu Recht
damit, dass eine feste Liste immer das vermisst, was gerade vor einem liegt. Die Antwort
darauf ist aber kein Freitext, sondern **ein Katalog mit Freitext als Ausweg**. Behebung:
S7 und U5.

### F9 — Koordinaten statt Adressen

Ein Werkhof teilt Arbeit nach „Bahnhofstrasse 12“ zu, nicht nach `2600123 / 1200456`. Ohne
Adresse wird jede Beobachtung im Büro von Hand nachgeschlagen. Behebung: S6.

### F10 — Bedienung nur am Bildschirm

Wer fährt, kann das Telefon nicht bedienen, und darf es auch nicht. Kurzbefehle, Siri,
die Aktionstaste und die Uhr als Fernbedienung fehlen. Behebung: S8 und U11.

### F11 — WLAN-Signalstärke (TODO Nr. 2) ist so nicht machbar

iOS liefert die WLAN-Signalstärke nicht über eine öffentliche Schnittstelle.
`NEHotspotNetwork.fetchCurrent` gibt SSID und BSSID heraus, und das nur mit der Berechtigung
„Access WiFi Information“ und Ortungsfreigabe. `signalStrength` ist laut Apple nur für
Hotspot-Helper-Apps gültig, und dafür braucht es eine Sonderfreigabe von Apple. Eine
ehrliche Alternative mit demselben Zweck („ist das WLAN hier gut?“):

- Strom `networkQuality`: Umlaufzeit zum Gateway bzw. zu einem frei wählbaren Host, alle
  1–5 s; optional ein kurzer Durchsatztest.
- Dazu die BSSID (mit Berechtigung). Damit wird sichtbar, wann das Telefon den
  Access-Point wechselt.

Das zeigt Funklöcher, überlastete Access-Points und Roaming. Für die Ausleuchtung in Lager,
Spital oder Schule ist das nützlicher als eine einzelne dBm-Zahl.

### F12 — Bluetooth-Struktur (TODO Nr. 3)

`BluetoothSource` (342 Zeilen) erledigt vier Aufgaben in einer Klasse: Zählen, Rohlog,
Decodieren und GATT-Verbindungen. Vorgeschlagene Aufteilung, ohne neue Funktion:

| neu | Inhalt | Ort |
|---|---|---|
| `BluetoothScanner` | `CBCentralManager`, Entdecken, Freigabe | App |
| `AdvertisementSummary` | Zählung, stärkster und mittlerer RSSI je Fenster, rein und getestet | Core |
| `AdvertisementDecoding` | gibt es schon (`BLEDecoders`, `ScriptDecoders`) | Core |
| `GATTConnections` | Koppeln, Wiederverbinden, Profile | App |

Dazu **ein** Bildschirm „Bluetooth“ mit drei klar getrennten Abschnitten: *Umgebung*
(Zählung), *Sensoren* (decodiert und gekoppelt) und *Rohdaten* (Schalter, Datenschutzhinweis).

### F13 — 3D-Modus (TODO Nr. 1)

Die Ursache liegt im Ansatz, nicht im Feinschliff. Bilder aus einem Video sind komprimiert
und bei 30 fps mit langer Belichtung oft bewegungsunscharf. Die Auswahl findet das
schärfste Bild eines Abschnitts, aber sie kann keine Schärfe herstellen. Der grundsätzlich
andere Weg ist M7.

---

## 3. Der Alleinstellungswert

### 3.1 Was niemand sonst zusammen hat

| | Sensorstorm heute | Sensorstorm mit Kap. 5 | Sensor Logger / phyphox | Survey123 / QField | PlanRadar / SafetyCulture | Vialytics / RoadAI / Roadroid |
|---|---|---|---|---|---|---|
| Sensoren synchron zum Video | ✓ | ✓ | teilweise | – | – | intern |
| Zustand aus der Fahrt | – | ✓ (U3) | – | – | – | ✓ |
| Beobachtung mit ausgewiesener Genauigkeit | ✓ | ✓ | – | teilweise | – | – |
| Schweizer Koordinaten und Karten | LV95 | LV95 + swisstopo (U9) | – | ✓ (QField) | – | teilweise |
| Ohne Cloud, ohne Konto | ✓ | ✓ | ✓ | teilweise | – | – |
| Protokoll / Nachweis | – | ✓ (U4) | – | ✓ | ✓ | ✓ |
| Preis | CHF 19 einmalig | Jahreslizenz im zwei- bis tiefen dreistelligen Bereich (Kap. 6) | gratis / Abo | Lizenz / gratis | Abo pro Nutzer | Plattform-Abo pro Gemeinde |

*Die Angaben zu Mitbewerbern stützen sich auf deren öffentliche Produktbeschreibungen.
Bevor sie im Marketing verwendet werden, sind sie im Einzelnen nachzuprüfen.*

### 3.2 Die Positionierung in einem Satz

> **Sensorstorm misst den Zustand eines Weges beim Darüberfahren, legt jede Auffälligkeit
> mit Videobild und ehrlicher Genauigkeit auf die Karte und macht daraus vor Ort bestätigte
> Beobachtungen und ein Protokoll. Ohne Cloud, ohne Plattform-Abo, in LV95.**

Die gemeinsame Uhr ist heute ein technisches Versprechen, das der Nutzer nur im README
sieht. Mit U1–U3 wird sie zur sichtbaren Funktion: Man tippt auf den Ausschlag in der
Kurve und bekommt Bild und Ort dazu.

### 3.3 Der Schweizer Graben

Mit LV95, swisstopo-Daten (swissALTI3D ist schon im Blender-Werkzeug, dazu U9), Adressen
und EGID (S6), Schweizer Normen als Katalogvorlage (U5) und dem Hinweis „Daten bleiben in
der Gemeinde“ lässt sich ein Heimmarkt besetzen. Internationale Plattformen bedienen ihn
nur nebenbei. Deutschland und Österreich folgen mit basemap.de und basemap.at
(offene Grundkarten) sowie mit ihren eigenen Katalogen.

---

## 4. Zielgruppen

Sortiert nach Zahlungsbereitschaft und danach, wie gut Sensorstorm schon passt. Die
Spalte „fehlt“ verweist auf die Karten in Kapitel 5.

### Z1 — Gemeinden, Werkhöfe, Tiefbauämter *(Priorität 1)*

- **Wer:** rund 2100 Gemeinden in der Schweiz, rund 10 800 in Deutschland und rund 2100 in
  Österreich. Dazu städtische Tiefbauämter (Zürich, Bern, Basel, Winterthur, Luzern,
  St. Gallen …), Strassenmeistereien und kantonale Tiefbauämter für Nebenstrassen.
- **Schmerz:** Strassenkontrollen auf Papier oder in Excel. Im Schadenfall (Velosturz
  wegen Schlagloch) fehlt der Nachweis, wann zuletzt kontrolliert wurde. Für die
  Erhaltungsplanung fehlt ein Schadenkataster. SaaS-Lösungen sind für kleine Gemeinden zu
  teuer oder scheitern am Datenschutz (Cloud im Ausland).
- **Schon da:** Beobachtungen mit Fotos, Genauigkeit, LV95, GeoJSON/KML, keine Cloud.
- **Fehlt:** S3 Weg, S5 Status, S6 Adresse, S7/U5 Katalog, U4 PDF, U1/U3 Erfassung aus der
  Fahrt, U7 Wiederholung, U8 GeoPackage, U9 swisstopo, U10 Anonymisierung, U12 Team.
- **Kanal:** Pilot mit 3–5 Werkhöfen. Fachorganisation Kommunale Infrastruktur, VSS
  (Schweizerischer Verband der Strassen- und Verkehrsfachleute), Messe Suisse Public in
  Bern, in Deutschland Kommunalmessen und Bauhof-Fachzeitschriften.

### Z2 — Ingenieurbüros für Erhaltungsmanagement *(Priorität 1)*

- **Wer:** Büros, die für Gemeinden die visuelle Zustandserhebung nach VSS-Norm
  (Erhaltungsmanagement, SN 640 925) oder in Deutschland nach E EMI machen. Dazu
  Geometerbüros.
- **Schmerz:** Begehung mit Tablet und Formular. Fotos und Positionen werden im Büro
  zusammengeführt, das Ergebnis per Hand ins GIS übertragen.
- **Fehlt:** U5 Katalog mit Normbezug und Schwere/Ausmass, U8 GeoPackage (direkt in QGIS
  und ArcGIS), U3 Rauheit als Ergänzung, U12 mehrere Erheber zusammenführen.
- **Wert:** Ein Büro, das pro Gemeinde Tage spart, zahlt problemlos eine Jahreslizenz pro
  Gerät.

### Z3 — Velo, Fussverkehr, Hindernisfreiheit *(Priorität 2)*

- **Wer:** Velo- und Fussverkehrsfachstellen von Städten und Kantonen, Pro Velo,
  Fussverkehr Schweiz, ADFC; Fachstellen für hindernisfreies Bauen, Procap. Dazu die
  Inventare der Bushaltestellen (Behindertengleichstellungsgesetz, BehiG).
- **Schmerz:** Wie holprig ist der Veloweg? Wie steil ist die Rampe, wie schräg das
  Trottoir? Das wird mit Wasserwaage und Augenmass erhoben.
- **Schon da:** IMU mit 100–400 Hz, Video, GPS.
- **Fehlt:** S2 vertikale Beschleunigung, U3 mit Velo-Profil (Komfort je Abschnitt), U6
  Neigung messen, U5 Katalog „Velo/Fussweg/Hindernisfreiheit“.

### Z4 — Werke und Netzbetreiber *(Priorität 2)*

- **Wer:** Wasserversorgungen, Elektrizitätswerke, Gas, Fernwärme, Strassenbeleuchtung.
- **Schmerz:** Kontrollgänge (Hydranten, Schachtdeckel, Kandelaber) und die Dokumentation
  von Leitungsschäden. Die Lage muss oft auf Dezimeter stimmen.
- **Fehlt:** U5 Kataloge, U8 GeoPackage, M6 externes RTK-GNSS. M6 ist der eine Punkt, an
  dem „ehrliche Genauigkeit“ zu Zentimetern wird.

### Z5 — Liegenschaftsverwaltung, Facility Management, Hauswartung *(Priorität 3)*

- **Schmerz:** Umgebungskontrollen, Spielplatzkontrolle nach EN 1176-7 (regelmässige
  Sichtkontrolle) und der **Winterdienst-Nachweis**: Wer wann wo geräumt und gestreut hat,
  ist im Haftungsfall die entscheidende Frage.
- **Fehlt:** S3 Weg mit Zeitstempeln (ist schon der Nachweis), U4 PDF, U5 Checklisten-Kataloge.

### Z6 — Versicherungen und Schadenexperten *(Priorität 3)*

- **Wer:** kantonale Gebäudeversicherungen, Privatversicherer, unabhängige Schadenexperten
  bei Hagel- und Elementarschäden.
- **Fehlt:** S6 Adresse und **EGID** (eidgenössischer Gebäudeidentifikator), U4 PDF, U10
  Anonymisierung, U12 Zusammenführen mehrerer Experten.

### Z7 — Aufzugsbranche *(Nische mit hoher Zahlungsbereitschaft)*

- **Wer:** Schindler (aus der Schweiz), KONE, Otis, TK Elevator, Schweizer
  Mittelständler wie Emch oder AS Aufzüge. Dazu Liftinspektoren, Gutachter und
  Facility-Manager grosser Gebäude.
- **Schmerz:** Die Fahrqualität (Beschleunigung, Ruck, Schwingung, Geräusch) wird nach
  ISO 18738-1 mit Spezialgeräten gemessen, die ein Vielfaches eines iPhones kosten. Für
  Abnahme, Wartungsvergleich und Reklamationen braucht es eine schnelle Vorabmessung.
- **Schon da:** 400 Hz, Barometer (Stockwerke), gemeinsame Uhr, Video der Tür.
- **Fehlt:** M1, also S2 plus ein Auswerteprofil mit Bericht.

### Z8 — Bahn, Tram, Bus *(Nische)*

- **Wer:** SBB, BLS, RhB, SOB, Zentralbahn, städtische Verkehrsbetriebe (VBZ, Bernmobil,
  BVB, TPG …), Rollmaterialhersteller wie Stadler, Besteller im ÖV.
- **Schmerz:** Fahrkomfort (EN 12299) und Auffälligkeiten im Gleis bzw. in der Fahrbahn
  (Weichen, Stösse, Spurrinnen auf Busspuren) werden mit Messfahrzeugen erhoben, die
  selten fahren.
- **Fehlt:** M2.

### Z9 — Bau: Erschütterungen und Beweissicherung *(Nische)*

- **Wer:** Bauunternehmen, Spezialtiefbau, Ingenieurbüros, Eigentümer neben Baustellen.
- **Schmerz:** Erschütterungsklagen und Rissprotokolle vor Baubeginn. Das amtliche Messen
  nach SN 640 312 / DIN 4150-3 braucht geeichte Geräte, das Screening und die Dokumentation
  nicht.
- **Fehlt:** M3, dazu U5 mit einem Katalog „Gebäude/Risse“.

### Z10 — Veranstalter, Clubs, Tontechnik *(Nische, Schweiz)*

- **Schmerz:** Die Schall- und Laserverordnung (SLV) verlangt je nach Pegelklasse
  Überwachung und teils Aufzeichnung des Pegels über 60 Minuten in dB(A).
- **Fehlt:** M4. Ehrlich bleiben: Für die amtliche Pflicht braucht es ein Messgerät nach
  den Anforderungen der SLV. Sensorstorm taugt als Zweitprotokoll und für die
  Orientierung.

### Z11 — Forschung, Hochschulen, ML-Teams *(Priorität 2, kleine Beträge, grosse Sichtbarkeit)*

- **Wer:** ETH, EPFL, Fachhochschulen (ZHAW, HSLU, FHNW …), Start-ups im Wearable-Bereich,
  Telematik-Forschung von Versicherern.
- **Schmerz:** Gelabelte Bewegungsdaten. Das Video ist die Wahrheit, mit der man die IMU
  labelt, und genau dafür braucht es die gemeinsame Uhr. Heute synchronisieren Teams
  Kamera und IMU nachträglich mit Klatschen ins Mikrofon.
- **Fehlt:** M5 Intervall-Labels, S12 Qualitätsbericht, Metadaten zur Sitzung.

### Z12 — Sport und Biomechanik *(Priorität 3)*

- **Wer:** BASPO Magglingen, Verbände, Bikefitter, Physiotherapie, Trainer.
- **Schon da:** Puls (Uhr), Leistung und Trittfrequenz (BLE), Video und IMU auf einer Uhr.
  Das ist erstaunlich viel.
- **Fehlt:** M5 Labels, Vergleich zweier Aufnahmen. Eher Marketing-Geschichte als Umsatz.

### Z13 — Film, VFX, Drohnen *(bestehende Nische)*

Blender-Szene, swissALTI3D und Gyroflow sind schon da. Pflegen, nicht ausbauen.

---

## 5. Vorschläge — Umsetzungskarten

### Übersicht

| ID | Vorschlag | Aufwand | Paket | Hebel für |
|---|---|---|---|---|
| **S1** | Regeln sehen Spitzen | S | gratis | alle |
| **S2** | Vertikale und horizontale Beschleunigung als Strom | S–M | gratis | Z1, Z3, Z7–Z9 |
| **S3** | Route zeichnet ihren Weg auf | M | gratis (Anzeige), Pro (Export) | Z1, Z5 |
| **S4** | Archiv importieren | S → M | gratis | alle |
| **S5** | Status je Beobachtung | S | gratis | Z1, Z4–Z6 |
| **S6** | Adresse (und EGID) je Beobachtung, Hinführen | S | gratis, opt-in | Z1, Z6 |
| **S7** | Label-Vorschläge | S | gratis | Z1–Z5 |
| **S8** | Kurzbefehle, Siri, Aktionstaste, Live-Aktivität | M | gratis | Z1, Z3, Z11 |
| **S9** | Web-Dashboard im Browser | S–M | Pro | Z11, Lehre |
| **S10** | Wärmezustand und Stromsparmodus als Strom | S | gratis | Z11 |
| **S11** | Website und Store aus einer Quelle | S | – | Vertrieb |
| **S12** | Qualitätsbericht je Aufnahme | M | gratis (Anzeige), Pro (Export) | Z7–Z9, Z11 |
| **S13** | Arbeitsprofile beim ersten Start | M | gratis | alle |
| **U1** | Beobachtung aus der Wiedergabe (Standbild + Ort) | M | Pro | Z1, Z2, Z6 |
| **U2** | Karte zur Aufnahme mit eingefärbtem Track | M | gratis | alle |
| **U3** | Fahrbahnzustand automatisch (Rauheit + Schlag-Kandidaten) | L | Inspektion | Z1–Z3 |
| **U4** | Begehungsprotokoll / Kontrollnachweis als PDF | M | Inspektion | Z1, Z2, Z5, Z6 |
| **U5** | Kataloge und Attribute | M–L | gratis (Standard), Inspektion (eigene) | Z1–Z6, Z9 |
| **U6** | Neigung, Masse, Menge und Material | S–L | Pro / Inspektion | Z1, Z3 |
| **U7** | Wiederholungsbegehung und Verlauf | M | Inspektion | Z1, Z2 |
| **U8** | GeoPackage und KMZ mit Fotos | M | Pro | Z1, Z2, Z4 |
| **U9** | swisstopo-Grundkarten, offline | M | Inspektion (offline), gratis (online) | Z1–Z4 |
| **U10** | Anonymisierung von Gesichtern und Kennzeichen | M | Inspektion | Z1, Z6 |
| **U11** | Apple Watch als Fernbedienung | M | gratis | Z1, Z3 |
| **U12** | Team ohne Cloud: Routen zusammenführen | M | Inspektion | Z1, Z2, Z6 |
| **M1** | Aufzug-Fahrqualität | L | Profil „Aufzug“ | Z7 |
| **M2** | Fahrkomfort ÖV und Gleisauffälligkeiten | L | Profil „ÖV“ | Z8 |
| **M3** | Erschütterungs-Screening | L | Profil „Bau“ | Z9 |
| **M4** | Schallpegel in dB(A) mit Kalibrierung | M | Pro | Z10, Z7, Z9 |
| **M5** | Datensätze für Machine Learning | M | Pro | Z11, Z12 |
| **M6** | Externes GNSS/RTK über Bluetooth | L | Inspektion | Z4, Z2 |
| **M7** | Fotogrammetrie neu: Standbilder statt Videobilder | L | Pro | Z13, Z2 |
| **M8** | Weiterleitung an Mängelsysteme (Webhook, Open311) | M | Inspektion | Z1 |
| **M9** | Ereignis-Ringpuffer („Dashcam“) | L | Pro | Z1, Z6 |

---

### Stufe S — sofort: Fehler und schnelle Gewinne

#### S1 — Regeln sehen Spitzen *(behebt F1)*

**Was:** Jede Regel mit einer `.value`-Bedingung sieht das Minimum und das Maximum jedes
Kanals **seit der letzten Auswertung**, nicht nur den letzten Wert.

**Umsetzung:**

```swift
// App/Recording/SampleSink.swift
struct ChannelRange: Sendable { var minimum: [Double]; var maximum: [Double] }
private var extremes: [SensorID: ChannelRange] = [:]

// in ingest(_:time:values:), unter dem bestehenden Lock:
if var range = extremes[sensor], range.minimum.count == values.count {
    for i in values.indices where values[i].isFinite {
        range.minimum[i] = range.minimum[i].isFinite ? min(range.minimum[i], values[i]) : values[i]
        range.maximum[i] = range.maximum[i].isFinite ? max(range.maximum[i], values[i]) : values[i]
    }
    extremes[sensor] = range
} else {
    extremes[sensor] = ChannelRange(minimum: values, maximum: values)
}

/// Kleinster und grösster Wert je Kanal seit dem letzten Aufruf. Ein Schlag von 30 ms
/// fällt neun von zehn Mal zwischen zwei Auswertungen, die 100 ms auseinanderliegen.
func drainExtremes() -> [SensorID: ChannelRange] {
    lock.lock(); defer { extremes = [:]; lock.unlock() }
    return extremes
}
```

```swift
// Sources/SensorstormCore/Rules/Rule.swift
public struct RuleContext: Sendable {
    public var values: [SensorID: [Double]]
    /// Extremwerte seit der vorigen Auswertung. Fehlen sie, gilt der letzte Wert.
    public var minimum: [SensorID: [Double]] = [:]
    public var maximum: [SensorID: [Double]] = [:]
    …
}
// in holds(_:in:), Fall .value:
let pool = comparison == .above ? (context.maximum[sensor] ?? values)
                                : (context.minimum[sensor] ?? values)
```

`SensorHub.evaluateRules()` übergibt `sink.drainExtremes()`. Die Kosten sind zwei
Vergleiche je Kanal und Messwert, unter dem Lock, der ohnehin genommen wird.

**Test** (`Tests/SensorstormCoreTests/AutomationTests.swift`): Eine Spitze von 1,4 g im
Maximum bei einem letzten Wert von 0,02 g lässt die Regel feuern. Ohne Maximum bleibt das
bisherige Verhalten (Rückwärtskompatibilität). `onChange` feuert genau einmal pro Spitze.

**Aufwand:** S, keine neuen Texte.

#### S2 — Vertikale und horizontale Beschleunigung als eigener Strom *(behebt F2)*

**Was:** Ein neuer Strom `verticalAcceleration` mit den Kanälen
`["vertical", "horizontal"]` in g, aus **demselben** `CMDeviceMotion`-Sample berechnet
wie `userAcceleration` und `gravity`:

- `vertical = −(a · ĝ)`, positiv nach oben
- `horizontal = |a − (a · ĝ) ĝ|`

Dabei ist `a` = `userAcceleration` und `ĝ` = `gravity` normiert. Das Ergebnis ist
unabhängig davon, wie das Telefon in der Halterung steckt.

**Umsetzung:**

- `Sources/SensorstormCore/Geo/Kinematics.swift` (neu): eine reine Funktion
  `verticalHorizontal(user:gravity:) -> (Double, Double)` auf `simd_double3`.
- `SensorID.verticalAcceleration` mit Kategorie `.motion` und `defaultEnabled: false`. Der
  Rohwert ist ab Auslieferung eingefroren.
- `MotionSource`: im Device-Motion-Handler einen weiteren `sink.ingest(...)` mit demselben
  Zeitstempel.
- `docs/UNITS.md`: Definition und Vorzeichen.
- Diagramm: in `preferredChannels` beide Kanäle.

**Warum ein Strom und keine abgeleitete Regelbedingung?** So steht der Wert sofort in
Diagrammen, Exporten, Live-Push, Webserver und Regeln, ohne dass ein einziger dieser Pfade
angepasst werden muss.

**Test:** Telefon flach (`gravity = (0,0,−1)`), Stoss `a = (0,0,0.5)`: vertikal = 0,5,
horizontal = 0. Um 90° gekippt: dasselbe Ergebnis. Mit NaN: NaN.

**Aufwand:** S–M, etwa drei Texte (Name, zwei Kanäle).

#### S3 — Route zeichnet ihren Weg auf *(behebt F3)*

**Was:** Solange eine Route offen ist, schreibt sie einen ausgedünnten GPS-Weg mit:

- ein Punkt, sobald man sich um mindestens `max(5 m, Genauigkeit)` bewegt hat oder 30 s
  vergangen sind;
- dazu ein ausdrücklicher Zustand „Route beenden“.

**Daten:**

- `Survey.endedAt: Date?` und `Survey.inspector: String?` (für U4). Beide optional und damit
  rückwärtskompatibel.
- Der Weg liegt in `Documents/Surveys/<uuid>/track.csv` und wird **zeilenweise angehängt**.
  Das ist absturzsicher, und `survey.json` bleibt klein.
- Spalten: `time_iso, latitude, longitude, altitude, horizontal_accuracy, speed`.
  Den Dateinamen in `SurveyTests.onDiskNamesAreFrozen` aufnehmen.

**Umsetzung:**

- `SurveyStore.appendTrack(_:to:)` und `track(of:) -> [SurveyTrackPoint]` im Core.
- `SurveyLocationProvider` hält die Ortung, solange die Route offen ist, und setzt
  `allowsBackgroundLocationUpdates`. `UIBackgroundModes: location` ist schon gesetzt, und
  „Beim Verwenden“ reicht, wenn die Ortung im Vordergrund gestartet wurde.
- `SurveyDetailView`: `MapPolyline` des Weges unter den Nadeln.
- Exporte (`SurveyExporter`):
  - GeoJSON: Feature `LineString` mit `kind: "track"`
  - GPX: `<trk>`
  - KML: `LineString`
  - Bündel und Archiv: zusätzlich `track.csv`

**Test:** Ausdünnung (Punkte im Stand werden nicht geschrieben), Hin und zurück über die
Datei, GeoJSON enthält genau einen `LineString`, eine alte Route ohne Datei lädt weiter.

**Aufwand:** M, etwa acht Texte.

#### S4 — Archiv importieren *(behebt F4)*

**Stufe 1 (S): Ordner importieren.** Die Dateien-App entpackt ein Zip mit einem Tippen.
`fileImporter(allowedContentTypes: [.folder])` nimmt den entpackten
`Sensorstorm-Export-…`-Ordner an. Damit braucht die erste Fassung keinen Zip-Leser.

**Stufe 2 (M): Zip direkt importieren.** Ein kleiner Zip-Leser im Core: Central Directory,
Einträge mit `stored` und `deflate`, letzteres über `zlib` `inflate` mit `-15` windowBits
(`zlib` ist im Core schon eingebunden, siehe `XLSXExporter`).

**Umsetzung `ArchiveImporter` (Core):**

1. `manifest.json` lesen, `schema == "sensorstorm.archive"` und `schemaVersion` prüfen.
2. Jede Datei gegen ihre SHA-256 prüfen (`CryptoKit` ist schon da). Fehlt eine Datei oder
   ist sie verändert, steht das im Bericht, und es wird nichts halb importiert.
3. Routen: `survey.json` und Medien in den `SurveyStore`. Gleiche UUID: überspringen,
   ausser der Inhalt weicht ab, dann fragen „ersetzen / beide behalten“.
4. Aufnahmen: Das Archiv enthält heute CSV, kein `.ssbin`. Vorschlag: eine
   Archiv-Option „**für Wiederherstellung**“, die den Aufnahmeordner unverändert
   (`.ssbin`, `metadata.json`, Video) mitnimmt. Der Import kopiert ihn dann einfach
   zurück. Die CSV-Variante bleibt die maschinenlesbare.

**Test:** Export → Import ergibt dieselben Routen (Gleichheit der Modelle). Eine
manipulierte Datei wird erkannt. Ein doppelter Import ist idempotent.

**Aufwand:** S plus M, etwa zehn Texte.

#### S5 — Status je Beobachtung *(behebt F7)*

**Daten** (`GroundFinding`, alle optional und mit Standardwert im `init(from:)`):

```swift
public enum FindingStatus: String, Codable, Sendable, CaseIterable {
    case open, scheduled, resolved, noAction
}
public var status: FindingStatus          // Standard .open
public var statusChangedAt: Date?
public var resolutionNote: String         // Standard ""
```

`CaseMedia.role: MediaRole?` mit `.before` / `.after`: Ein Foto nach der Reparatur gehört
zum selben Fall.

**Oberfläche:**

- `FindingDetailView`: Status als Menü.
- `SurveyDetailView`: Filter „offene / alle“. Erledigte Beobachtungen grau auf der Karte.

**Exporte:** Spalte bzw. Property `status` und `status_changed_at`. In KML erhalten
erledigte Beobachtungen einen eigenen Stil.

**Test:** Altes `survey.json` ohne Feld wird als `.open` gelesen. Spalte im CSV.

**Aufwand:** S, etwa zehn Texte.

#### S6 — Adresse und EGID je Beobachtung, Hinführen *(behebt F9)*

**Was:**

- Beim Sichern ermittelt die App optional die Adresse über `CLGeocoder.reverseGeocodeLocation`
  (Strasse, Hausnummer, PLZ, Ort).
- In der Schweiz kann sie zusätzlich die nächste Gebäudeadresse samt **EGID** über
  `api3.geo.admin.ch` (Layer `ch.bfs.gebaeude_wohnungs_register`, Endpunkt `identify`)
  abfragen.
- **Opt-in**, mit einem klaren Satz in den Einstellungen: „sendet die Koordinate an Apple
  bzw. swisstopo“. Die Datenschutzseite in `web/build.py` muss nachgeführt werden.

**Daten:** `GroundFinding.address: PostalAddress?` (Strasse, Nummer, PLZ, Ort, Land, EGID),
optional.

**Hinführen:**

- Knopf „Hinführen“ öffnet `MKMapItem.openInMaps` (zu Fuss oder mit dem Auto).
- „Ort teilen“ erzeugt einen `https://maps.apple.com/?ll=…&q=…`-Link für den Reparaturtrupp.

**Exporte:** Spalten `street`, `house_number`, `postcode`, `locality` und `egid`. Im PDF
(U4) erscheint die Adresse als Überschrift.

**Aufwand:** S, etwa acht Texte.

#### S7 — Label-Vorschläge *(Teil von F8)*

**Was:** Unter dem Label-Feld erscheinen bis zu acht Chips: die bisher am häufigsten
verwendeten Labels (über alle Routen, nach Häufigkeit), danach die Einträge des aktiven
Katalogs (U5).

**Umsetzung:** `LabelSuggestions.rank(_ surveys: [Survey], prefix: String) -> [String]`
im Core. Die Funktion normalisiert Gross- und Kleinschreibung und Leerzeichen und gibt die
häufigste Schreibweise zurück.

**Test:** „Schlagloch“ ×3 und „schlagloch“ ×1 ergeben „Schlagloch“. Ein Präfix filtert.

**Aufwand:** S, keine neuen Texte.

#### S8 — Kurzbefehle, Siri, Aktionstaste, Live-Aktivität *(behebt F10)*

**App Intents** (`App/Intents/`):

| Intent | Wirkung |
|---|---|
| `StartRecordingIntent` | startet die Aufnahme mit den aktuellen Einstellungen |
| `StopRecordingIntent` | beendet sie |
| `AddMarkerIntent(text:)` | setzt eine Markierung |
| `QuickFindingIntent(label:severity:)` | legt in der offenen Route eine Beobachtung an der aktuellen Position an, ohne Foto (das Foto lässt sich später ergänzen) |

`AppShortcutsProvider` mit Phrasen wie „Schlagloch melden mit Sensorstorm“. Damit kann ein
Fahrer **ohne Hand am Telefon** einen Befund festhalten: per Siri, über die Aktionstaste
(iPhone 15 Pro und neuer) oder mit einem Steuerelement im Kontrollzentrum
(`ControlWidget`, iOS 18).

**Live-Aktivität:** Sie zeigt auf dem Sperrbildschirm und in der Dynamic Island die
Laufzeit, die Zahl der Messwerte und der Markierungen und hat einen Stopp-Knopf. Das
braucht ein Widget-Extension-Target in `project.yml`.

**Umsetzung:** `SensorHub` wird über `AppDependencyManager` in die Intents gereicht.

**Aufwand:** M, etwa 15 Texte, Phrasen pro Sprache.

#### S9 — Web-Dashboard im Browser

**Was:** `LocalWebServer` liefert zusätzlich eine eingebaute HTML-Seite (ohne externe
Bibliotheken, `<canvas>`, rund 150 Zeilen) mit Live-Kurven aller Ströme, dazu `/events`
als Server-Sent Events für flüssige Kurven.

**Kompatibilität:** `/data` bleibt JSON. Auf `/` gibt es HTML nur, wenn der Browser
`Accept: text/html` schickt. Skripte, die heute `/` abfragen, bekommen also weiter JSON.

**Wofür:**

- Unterricht: iPhone in der Hand, Kurven gross am Beamer.
- Labor: Laptop daneben, Telefon im Prüfling.
- Aufzug (M1): Telefon am Kabinenboden, Kurven auf dem Laptop im Gang.

**Umsetzung:** In `serve(_:)` den Pfad und den Accept-Header unterscheiden. Für `/events`
die Verbindung offen halten, alle 200 ms senden, höchstens 4 Clients.

**Aufwand:** S–M.

#### S10 — Wärmezustand und Stromsparmodus als Strom

**Was:** Ein neuer Strom `thermal` mit den Kanälen `["state", "lowPower"]`. `state` ist
0–3 (`ProcessInfo.ThermalState`), ereignisgesteuert über
`thermalStateDidChangeNotification` und `NSProcessInfoPowerStateDidChange`. Ab `.serious`
zeigt die Aufnahme einen Hinweis.

**Wozu:** Bei 4K mit 400 Hz drosselt iOS. Wer danach fehlende Bilder oder eine sinkende
Rate sieht, findet die Ursache in der Kurve statt in Vermutungen.

**Aufwand:** S.

#### S11 — Website und Store aus einer Quelle *(behebt F5)*

**Was:** Die Liste „gratis / Pro“ steht genau einmal, als `web/features.json`.
`web/build.py` erzeugt daraus den Abschnitt „Gratis und Pro“. `web/check.py` vergleicht
die Formate darin mit `ProAccess.freeRecordingFormats` und `freeSurveyFormats` in
`Sources/SensorstormCore/Store/ProFeature.swift` (einfaches Regex-Parsing, wie es
`Tools/l10n_literals.py` schon macht). Store-Texte und Website um die Funktionen aus
Build 16 ergänzen.

**Aufwand:** S.

#### S12 — Qualitätsbericht je Aufnahme

**Was:** `RecordingQuality.analyze(_ metadata:, store:) -> QualityReport` (Core, rein):

| je Strom | Video | GPS | Zeit |
|---|---|---|---|
| tatsächliche Rate gegenüber der verlangten, Zahl und Länge der Lücken (> 3 × Nennintervall), Jitter (Standardabweichung der Intervalle) | Bildrate, ausgefallene Bilder | Median und 95-%-Quantil der `horizontalAccuracy`, Rate der Fixes | NTP-Versatz, falls gemessen |

**Anzeige:** eine Karte „Qualität“ in `RecordingDetailView`.

**Export:** `quality.json` in jedem Bündel und im Manifest.

**Wozu:** Forschung und Gutachten brauchen eine Aussage darüber, wie gut die Daten sind.
Das passt genau zur Haltung der App, Unsicherheit auszuweisen statt sie zu verstecken.

**Test:** Synthetische Ströme mit eingebauten Lücken.

**Aufwand:** M.

#### S13 — Arbeitsprofile beim ersten Start

**Was:** Beim ersten Start fragt die App: *Messen & Experimentieren · Strassen und Wege
kontrollieren · Gebäude & Bau · Forschung & Datensätze*. Das Profil setzt Vorgaben:

- welche Sensoren scharf sind,
- welcher Tab vorne steht,
- welcher Katalog aktiv ist (U5),
- welche Regeln vorgeschlagen werden (z. B. „Schlag > 0,6 g → Markierung“ für Strassen).

Später lässt es sich in den Einstellungen wechseln.

**Wozu:** Ein Werkhof-Mitarbeiter soll 22 Sensoren nie sehen müssen. Ein Physiklehrer
soll nie „Route“ sehen müssen.

**Aufwand:** M.

---

### Stufe U — der Alleinstellungswert: Messen und Erfassen verbinden

#### U1 — Beobachtung aus der Wiedergabe

**Was:** In der Wiedergabe gibt es den Knopf „**Als Beobachtung**“. Er legt am Abspielkopf
eine Beobachtung an:

- **Position:** GPS der Aufnahme, zur Zeit des Abspielkopfs linear interpoliert. Quelle
  `.gps`, Genauigkeit vom nächsten Fix.
- **Foto:** das Videobild genau dieses Moments, über den vorhandenen
  `VideoFrameImageProvider`, in voller Auflösung; optional ein Clip von ±3 s.
- **Verknüpfung:** `recordingID`, `hostTime`.
- **Route:** wählbar zwischen bestehender und neuer Route.

**Wozu:** Das ist der Arbeitsablauf der teuren Plattformen, ohne KI und ohne Cloud:
**einmal mit dem Telefon an der Scheibe durchs Quartier fahren**, im Büro durch das Video
tippen und aus jedem Schaden mit zwei Tippern eine Beobachtung machen. Mit 4K ist das
Standbild gut genug für die Dokumentation.

**Umsetzung:**

- Core: `TrackInterpolation.position(at hostTime:, in reader: StreamReader) -> FindingLocation?`,
  getestet.
- App: `RecordingDetailView` → Sheet mit Routenwahl, Bewertung und Label (Komponenten aus
  `FindingCaptureView` wiederverwenden). `SurveyModel.addFinding` nimmt ein Foto aus
  `Data`, das gibt es schon.

**Aufwand:** M, etwa sechs Texte. **Das ist der schnellste Weg, den Alleinstellungswert
sichtbar zu machen. Er kann vor U3 erscheinen.**

#### U2 — Karte zur Aufnahme, Track eingefärbt nach einem Kanal

**Was:** `RecordingDetailView` bekommt eine Kartenkarte, sobald es einen `location`-Strom gibt:

- Der Track ist in Abschnitte geteilt und nach einem **wählbaren Kanal** eingefärbt:
  Geschwindigkeit, Höhe, vertikale Beschleunigung (S2, als RMS je Abschnitt), Lautstärke,
  Bluetooth-Dichte, Puls …
- Ein Punkt auf der Karte folgt dem Abspielkopf. Ein Tipp auf die Karte springt zur
  nächstgelegenen Zeit.

**Wozu:** Lärmkarte, Rauheitskarte, Funkabdeckung, Pulskarte einer Velotour: dieselbe
Funktion für alle Zielgruppen. Die gemeinsame Uhr wird damit sichtbar.

**Umsetzung:**

- Core: `TrackColoring.segments(track:values:window:) -> [ColoredSegment]`. Die Werte
  werden zeitlich auf die Track-Abschnitte gebinnt, mit Min/Max für die Skala.
- App: `Map` mit mehreren `MapPolyline` und Legende.

**Aufwand:** M.

#### U3 — Fahrbahnzustand automatisch

**Was:** Eine Auswertung über eine Aufnahme mit `verticalAcceleration` (S2) und `location`:

1. **Abschnitte nach Distanz** (Standard 20 m, für die Übersicht 100 m). Die kumulierte
   Distanz kommt aus GPS und wird zeitlich interpoliert.
2. **Je Abschnitt:** mittlere Geschwindigkeit, RMS der vertikalen Beschleunigung nach einem
   Bandpass (etwa 0,5–40 Hz), Spitzenwert, Zahl der Schläge.
3. **Rauheitsindex:** RMS, normiert auf die Geschwindigkeit. Verglichen werden nur
   Abschnitte aus demselben Geschwindigkeitsband (z. B. 30–50 km/h). Ausgewiesen wird ein
   **relativer** Index mit Klassen (gut / mittel / schlecht).
4. **Kalibrierung, optional:** Wer einen Referenzabschnitt mit bekanntem IRI oder einer
   bekannten Klasse fährt, setzt einen Faktor pro Fahrzeug und Halterung.
5. **Schlag-Kandidaten:** Spitzen über einer Schwelle (Auto etwa 0,5 g, Velo höher,
   einstellbar), mindestens 10 m oder 2 s auseinander. Jeder Kandidat hat Zeit, Position
   (interpoliert) mit Genauigkeit, Spitze, Geschwindigkeit und ein Videobild.

**Ehrlich bleiben, im Stil der App:**

- Der Index ist **kein IRI**. Der Zusammenhang hängt von Fahrzeug, Reifendruck, Halterung
  und Geschwindigkeit ab.
- Das steht in der Anzeige und in `road.json`, so wie heute die Nordunsicherheit in
  `scene.json` steht.

**Arbeitsablauf:**

- Karte mit eingefärbten Abschnitten (U2).
- Liste der Kandidaten mit Vorschaubild, jeweils mit „übernehmen“ (→ U1), „verwerfen“
  oder „später prüfen“.
- Übernommene Kandidaten werden zu Beobachtungen mit Status `open` (S5) und einer
  vorgeschlagenen Bewertung aus der Spitze.

**Daten und Export:**

- `road.json` mit Methode, Parametern und Unsicherheit.
- `road_segments.geojson` als LineStrings mit Index und Klasse.
- `road_events.csv`.

**Umsetzung:**

- Core: `RoadProfile.analyze(vertical: StreamReader, location: StreamReader, parameters:) -> RoadProfile`.
  Rein, getestet mit synthetischen Profilen (Sinuswelligkeit plus eingestreute Schläge,
  verschiedene Geschwindigkeiten).
- Filter: Biquad-Kaskade im Core (`simd`, ohne Accelerate-Zwang).
- App: Auswerte-Bildschirm. Halterungshinweis „starr an Scheibe oder Lenker“.

**Profile:** Auto, Velo (Komfort je Abschnitt, Z3), Rollstuhl/Kinderwagen (Gehweg,
Z3), Bus (Z8).

**Aufwand:** L, etwa 30 Texte. **Der grösste Einzelschritt im Alleinstellungswert.**

#### U4 — Begehungsprotokoll und Kontrollnachweis als PDF

**Was:** Ein A4-PDF aus einer Route. Die Gliederung kommt aus dem Core
(`SurveyReport`: Sortierung, Gruppierung, Statistik, Seitenplan), gezeichnet wird in der
App mit `UIGraphicsPDFRenderer`.

1. **Deckblatt:** Titel, Auftraggeber bzw. Gemeinde, Bearbeiter (`Survey.inspector`),
   Datum und Uhrzeit von–bis, gelaufene Strecke (S3).
2. **Übersichtskarte:** `MKMapSnapshotter` mit Weg und nummerierten Nadeln in den Farben
   der Bewertung.
3. **Zusammenfassung:** Anzahl je Kategorie und Bewertung, markierte Fläche, geschätzte
   Menge (U6), offen/erledigt (S5).
4. **Je Beobachtung ein Block:** Nummer, Kategorie, Bewertung, Status, Adresse (S6),
   LV95 E/N, Quelle und Genauigkeit der Position, Notiz, 2–4 Fotos.
5. **Methodik:** was „gemittelt“ und „Nadel von Hand“ bedeuten, also die Texte aus dem
   README in kurz.
6. **Unterschriftszeile.**

**Variante Kontrollnachweis:** eine Route **ohne** Befund. „Strecke X kontrolliert am
… von … bis …, keine Mängel festgestellt“, mit Karte des Weges. Das ist genau das
Dokument, das im Haftungsfall gebraucht wird.

**Aufwand:** M, etwa 25 Texte. Die PDF-Texte müssen in der Sprache des Protokolls
erscheinen, nicht zwingend in der Sprache der App.

#### U5 — Kataloge und Attribute *(löst F8 grundsätzlich)*

**Daten:**

```swift
public struct FindingCatalog: Codable, Sendable, Hashable {
    public var id: String            // "ch.vss.road" …
    public var version: Int
    public var name: String
    public var categories: [Category]
    public struct Category: Codable, Sendable, Hashable {
        public var id: String        // stabil, geht in den Export
        public var name: String
        public var defaultSeverity: Int?
        public var attributes: [AttributeDefinition]  // Zahl, Text, Auswahl, Ja/Nein, Einheit
    }
}
// GroundFinding:
public var categoryID: String?
public var attributes: [String: AttributeValue]?
// Survey:
public var catalogID: String?; public var catalogVersion: Int?
```

`label` bleibt erhalten, als Anzeigename und als Ausweg im Freitext.

**Mitgelieferte Kataloge** (als JSON-Ressourcen):

| Katalog | Inhalt |
|---|---|
| Strasse | angelehnt an die Schadenbilder der VSS-Norm zur Zustandserhebung, mit Schwere und Ausmass als Attribute |
| Velo / Fussweg | – |
| Hindernisfreiheit | Neigung (U6), Stufenhöhe, Breite |
| Spielplatz | Sichtkontrolle als Checkliste |
| Beleuchtung / Signalisation | – |
| Gebäude / Risse | Rissbreite in mm, Länge, Richtung (Z9) |

Den genauen Normbezug mit einer Fachperson abgleichen. Die Bewertung 1–10 lässt sich je
Katalog auf Normklassen abbilden (z. B. 1–3 leicht, 4–7 mittel, 8–10 schwer) und erscheint
als zusätzliche Spalte `severity_class`.

**Eigene Kataloge:** eine JSON-Datei importieren, nach demselben Muster wie
`DecoderLibrary` mit den JS-Decodern: beim Import prüfen, ins App-Verzeichnis kopieren.

**Exporte:** Jedes Attribut wird eine Spalte in CSV und GeoPackage (U8) und eine Property
in GeoJSON.

**Aufwand:** M–L, viele Texte. Die Kataloginhalte werden über `l10n.py` übersetzt.

#### U6 — Neigung, Masse, Menge und Material

**Neigung (S):** Das Telefon liegt flach auf der Fläche, 3 s werden gemittelt. Daraus:

- Neigungswinkel `θ = acos(|g_z| / |g|)`, angegeben in % (`tan θ · 100`) und in Grad;
- Fallrichtung aus dem Kompass.

Core: `Inclination.from(gravity:)`, getestet. Das Ergebnis wird als Attribut gespeichert.
Wofür: Rampen und Trottoir-Querneigung (Hindernisfreiheit), Gefälle für die Entwässerung.

**Länge und Breite (M):** Im ARKit-Modus zwei Punkte antippen (`raycast`). Das Ergebnis
sind Länge und Breite in cm als Attribut.

**Tiefe (L):** Mit LiDAR (`sceneDepth`, iPhone Pro) die tiefste Stelle unter der Ebene des
umgebenden Belags. Ohne LiDAR: Eingabe von Hand („Zollstock“).

**Menge und Material (S, sobald die Tiefe da ist):**

- Volumen = markierte Fläche (schon da: `FindingArea.squareMetres`) × Tiefe.
- Daraus Tonnen Mischgut (Dichte einstellbar, Standard 2,4 t/m³) und Kosten (CHF/t
  einstellbar).
- In der Zusammenfassung der Route steht dann: „geschätzt 1,8 t Mischgut“.

**Wozu:** Für den Werkhof ist das der Unterschied zwischen einer Liste und einem Auftrag.

#### U7 — Wiederholungsbegehung und Verlauf

**Was:** „**Route wiederholen**“ legt eine neue Route mit `previousSurveyID` an. Die offenen
Beobachtungen der Vorgängerin erscheinen dort als Nadeln „zu prüfen“. Je Nadel gibt es
drei Antworten:

- unverändert
- verschlechtert (neue Bewertung, neues Foto)
- behoben (Foto, Status `resolved`)

**Daten:** `GroundFinding.lineageID: UUID?`. Sie ist allen Beobachtungen derselben Stelle
über alle Begehungen gemeinsam. Daraus entstehen ein Verlauf der Bewertung je Stelle und
der Schadenkataster über die Jahre.

**Aufwand:** M.

#### U8 — GeoPackage und KMZ mit Fotos

**GeoPackage** (OGC, SQLite-basiert): QGIS, QField, ArcGIS Pro und FME lesen es nativ.
`libsqlite3` ist schon eingebunden (`SQLiteExporter`).

- Tabellen `gpkg_spatial_ref_sys` (EPSG:4326 und **EPSG:2056**), `gpkg_contents`,
  `gpkg_geometry_columns`.
- Layer `findings` (POINT), `areas` (POLYGON) und `track` (LINESTRING), je in 4326 und
  optional in 2056.
- Geometrie als GeoPackage-Binary: Kopf `GP`, Version, Flags, `srs_id`, dann WKB.
- Spalten: alle Felder aus dem CSV, dazu die Attribute (U5) und die relativen Medienpfade.
- Prüfung: ein Python-Skript im Stil von `Tools/blender/check_bundle.py`, mit dem
  `sqlite3`-Modul (Pflichttabellen, Header-Bytes, Envelope). Es läuft in CI ohne GDAL.

**KMZ:** `doc.kml` plus `images/` (auf 1280 px verkleinert) in einem Zip. Die Beschreibung
jeder Nadel zeigt die Fotos, sodass Google Earth beim Auftraggeber die Bilder anzeigt. Der
Zip-Schreiber aus `XLSXExporter` lässt sich wiederverwenden.

**Später, nur auf Nachfrage:** INTERLIS, der Schweizer Standard für den Austausch
amtlicher Geodaten. Er lohnt sich erst mit einem konkreten Datenmodell eines Kunden.

**Aufwand:** M.

#### U9 — swisstopo-Grundkarten, offline

**Was:** Wählbare Grundkarten über die WMTS-Dienste von geo.admin.ch in Web-Mercator:

```
https://wmts.geo.admin.ch/1.0.0/{layer}/default/current/3857/{z}/{x}/{y}.jpeg
```

- `ch.swisstopo.swissimage`: Luftbild, in der Schweiz deutlich schärfer als das
  Satellitenbild in Apple-Karten. Die Nadel sitzt damit auf der richtigen Fuge.
- `ch.swisstopo.pixelkarte-farbe`: Landeskarte.
- Überlagerung der amtlichen Vermessung (Parzellen) als PNG-Layer.
- Quellenangabe „© swisstopo“ (offene Behördendaten).
- Für Deutschland basemap.de, für Österreich basemap.at.

**Offline:** „Kartenausschnitt für diese Route laden“ speichert die Kacheln der Bounding
Box in den Zoomstufen 15–20 im Cache. Eine `MKTileOverlay`-Unterklasse liest zuerst von
der Platte.

**Umsetzung:** SwiftUI `Map` kann keine Kachel-Overlays. Die drei Karten (Übersicht,
`PinEditorView`, `AreaEditorView`) brauchen deshalb ein `MKMapView` über
`UIViewRepresentable`. Die Datenschutzseite muss nachgeführt werden, weil
Kachelabfragen das Gebiet verraten.

**Aufwand:** M.

#### U10 — Anonymisierung von Gesichtern und Kennzeichen

**Was:** Vor dem Export bzw. Protokoll werden auf Fotos Gesichter
(`VNDetectFaceRectanglesRequest`) und Kennzeichen (Textregionen aus
`VNRecognizeTextRequest`, gefiltert mit Mustern für CH/DE/AT) mit `CIFilter` verpixelt.
Die Originale bleiben auf dem Gerät. Der Schalter heisst „anonymisiert exportieren“.

**Ehrlich bleiben:** Die Erkennung ist „nach bestem Vermögen“ und nicht garantiert. Das
steht im Dialog. Clips kommen später, weil die Verarbeitung Bild für Bild teuer ist.

**Wozu:** Gemeinden dürfen Fotos mit Personen und Kennzeichen nicht ohne Weiteres in
Gemeinderatsunterlagen oder an Dritte geben (DSG/DSGVO).

**Aufwand:** M.

#### U11 — Apple Watch als Fernbedienung

**Was:** Die Uhr-App bekommt drei grosse Knöpfe:

- **Start/Stopp**
- **Markierung**
- **Beobachtung**, mit Bewertung über die Krone

Eine `WatchConnectivity`-Nachricht genügt. Das Telefon legt die Markierung bzw. die
Schnellbeobachtung (wie in S8) **mit seiner eigenen Position und Host-Zeit** an. Die Uhr
bestätigt mit einer Haptik. Auf neueren Uhren löst die Doppeltipp-Geste die Markierung
aus: Die Hände bleiben am Lenker.

**Umsetzung:** `Watch/WatchRootView.swift`, `App/Recording/WatchLink.swift` (Empfang)
und `SensorHub.addAnnotation`.

**Aufwand:** M.

#### U12 — Team ohne Cloud

**Was:**

- Routen lassen sich als eigener Dateityp `.sensorstorm-route` teilen (UTType-Export,
  AirDrop öffnet direkt die App). Beim Import werden sie **zusammengeführt**: Beobachtungen
  über `id`, bei Konflikt gewinnt das neuere `modifiedAt` (neues Feld).
- Der Bearbeiter steht je Route (`inspector`) und je Beobachtung (`author`).
- Die Daten laufen über die eigenen Kanäle der Organisation (AirDrop, Mail, SharePoint,
  Teams). Das Versprechen „keine Cloud bei uns“ bleibt.

**Grundlage:** S4.

**Aufwand:** M.

---

### Stufe M — neue Märkte auf derselben Plattform

Jedes „Profil“ ist eine Auswertung plus ein Bericht über bestehende Ströme. Die Aufnahme
selbst ändert sich nicht. Das hält den Aufwand begrenzt.

#### M1 — Aufzug-Fahrqualität *(Z7)*

**Kennwerte je Fahrt, angelehnt an ISO 18738-1:**

- maximale Beschleunigung und Verzögerung
- maximaler Ruck
- Schwingung vertikal und horizontal als A95 (Spitze zu Spitze)
- Fahrgeschwindigkeit (integriert, gegen die Barometerhöhe geprüft)
- Fahrzeit und Stockwerke (Barometer)
- Kabinenpegel in dB(A) (M4)

**Ablauf:** Telefon auf den Kabinenboden, Aufnahme mit 400 Hz (Pro). Die Fahrten werden
automatisch getrennt (Stillstand ↔ Bewegung). Je Fahrt gibt es eine Zeile und ein Diagramm,
dazu ein PDF wie U4.

**Kennzeichnung:** „Angelehnt an ISO 18738-1, kein kalibriertes Messgerät.“ Die genaue
Norm (Filter, Fenster) beim Umsetzen gegen den Normtext prüfen.

**Core:** `ElevatorRide.analyze(...)` mit synthetischen Fahrkurven getestet.

**Aufwand:** L.

#### M2 — Fahrkomfort ÖV und Gleisauffälligkeiten *(Z8)*

**Komfortindex:** angelehnt an EN 12299, vereinfachte Methode:
`N_MV = 6·√((a_XP95^Wd)² + (a_YP95^Wd)² + (a_ZP95^Wb)²)`, mit frequenzbewerteter
Beschleunigung, 5-s-RMS und 95-%-Quantil über 5 min.

**Fahrzeugachsen:** Längs- und Querachse kommen aus dem GPS-Kurs (Erdsystem → Fahrzeug).

**Auffälligkeiten:** Spitzen quer und vertikal mit Ort, wiederholt über mehrere Fahrten
derselben Strecke. Was bei jeder Fahrt an derselben Stelle auftaucht, ist das Gleis und
nicht der Zufall.

**Aufwand:** L.

#### M3 — Erschütterungs-Screening *(Z9)*

**Was:**

- Schwinggeschwindigkeit je Achse durch Integration (Hochpass gegen Drift), daraus der
  Spitzenwert (PPV) und die dominante Frequenz (FFT bzw. Nulldurchgänge).
- Darstellung PPV über Frequenz mit **einstellbaren** Bezugslinien statt fest
  eingebrannter Normwerte.
- Ereignisliste mit Uhrzeit und Video.

**Ehrlich bleiben:** Das Rauschen des Telefon-Beschleunigungssensors begrenzt das
Messbare nach unten. Die Funktion dient Screening und Dokumentation, nicht dem amtlichen
Nachweis.

**Aufwand:** L.

#### M4 — Schallpegel in dB(A) mit Kalibrierung *(behebt F6)*

**Was:**

- **A-Bewertung** als Biquad-Kaskade in `AudioLevelMeter`. Der Modus `.measurement` ist
  schon gesetzt.
- **Kalibrieroffset** in dB: mit einem Kalibrator (94 dB bei 1 kHz) oder gegen ein
  Referenzgerät. Der Offset wird in den Metadaten gespeichert.
- **Kennwerte:** LAeq gleitend über 1 und 60 min, LAFmax, LA10, LA90.
- Neuer Strom `soundLevel`, die bisherige `loudness` in dBFS bleibt unverändert.
- **Regeln:** Schwellen z. B. nach den Pegelklassen der SLV.

**Kennzeichnung:** „Kein Schallpegelmesser der Klasse 1/2.“

**Aufwand:** M.

#### M5 — Datensätze für Machine Learning *(Z11, Z12)*

**Was:**

- `Annotation` wird zu Intervallen erweitert: `endHostTime: Double?` und `track: String?`
  (Label-Spur). Rückwärtskompatibel, weil beide optional sind.
- In der Wiedergabe: einen Bereich ziehen und ein Label aus einer Liste wählen.
- Metadaten zur Sitzung: Proband (Pseudonym), Trageort (Hosentasche, Hand, Lenker,
  Armaturenbrett) und Tags.
- **Export:** `labels.csv` mit `start, end, track, label` sowie ein Fenster-Export (z. B.
  2 s, 50 % Überlappung) mit einem Label je Fenster.
- Stapelexport vieler Aufnahmen in einen Datensatzordner mit `index.csv`.

**Aufwand:** M.

#### M6 — Externes GNSS/RTK über Bluetooth *(Z4, Z2)*

**Was:**

- NMEA über BLE (Nordic UART Service oder herstellerspezifisch) lesen: GGA, RMC und **GST**
  (GST liefert echte Fehlerellipsen). Der Fix-Typ wird ausgewiesen (autonom / DGPS / RTK
  float / RTK fixed).
- Neue `PositionSource.rtk`. Alte App-Versionen können diesen Wert nicht lesen; das ist zu
  dokumentieren oder beim Export abzubilden.
- Geeignete Geräte: Empfänger auf Basis u-blox ZED-F9P (u-blox sitzt in Thalwil), Emlid
  Reach und ähnliche.
- Korrekturdaten (swipos von swisstopo über NTRIP) liefern viele Empfänger über ihre
  eigene App. Ein NTRIP-Client in Sensorstorm kann später folgen.
- Ein NMEA-Parser im Core ist rein und gut testbar.

**Aufwand:** L.

#### M7 — Fotogrammetrie neu: Standbilder statt Videobilder *(TODO Nr. 1, F13)*

**Was:**

- Im ARKit-Modus nimmt `ARSession.captureHighResolutionFrame` (iOS 16+) echte
  **Standbilder** in voller Sensorauflösung auf, mit **Pose und Intrinsics desselben
  ARFrame**. Dafür muss
  `ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing`
  gesetzt sein.
- **IMU-gesteuerter Auslöser:** Die App löst aus, wenn man sich seit dem letzten Bild weit
  genug bewegt oder gedreht hat (die bestehende Logik aus `PhotoSet`) **und** die Drehrate
  unter einer Schwelle liegt, das Telefon also gerade ruhig ist. Hier liefert die
  gemeinsame Uhr genau das, was gebraucht wird: Die IMU sagt, wann ein Bild scharf wird.
- Mit LiDAR wird zu jedem Bild die Tiefenkarte (`sceneDepth`) gespeichert, als Vorgabe für
  Metashape und COLMAP und für U6.
- Export wie heute: EXIF, `cameras.csv`, COLMAP. Das Video wird optional.
- Falls die Haltung „diese App rechnet kein 3D-Modell“ einmal fällt: Apples Object Capture
  rechnet auf iPhones mit LiDAR direkt auf dem Gerät.

**Aufwand:** L.

#### M8 — Weiterleitung an Mängelsysteme *(Z1)*

**Was:**

- Neue Regel- bzw. Routenaktion **Webhook**: Beim Sichern einer Beobachtung geht ein
  POST mit dem Beobachtungs-JSON an eine eingetragene Adresse, nach demselben Muster wie
  `LiveStreamer`. Damit lässt sich jedes System anbinden (n8n, Power Automate, eigenes
  Ticketing).
- **Open311 GeoReport v2**, wo eine Stadt es anbietet (z. B. Bürgermeldeplattformen).
  Vorher prüfen, welche Schweizer Plattformen eine offene Schnittstelle haben.

**Aufwand:** M.

#### M9 — Ereignis-Ringpuffer („Dashcam“)

**Was:** Video in Segmenten von 10 s in einen Ringpuffer der letzten N Minuten. Ein
Ereignis (Regel aus S1, Tipp, Uhr, Siri) sichert ±30 s um den Zeitpunkt samt allen
Strömen.

**Wozu:** Lange Fahrten werden möglich, ohne Gigabytes zu sammeln. Dazu kommt Beweismaterial
bei Unfällen und Schlägen.

**Umsetzung:** `AVAssetWriter` mit Segmentwechsel und gemeinsamer Zeitbasis, plus
Bereinigung der Ströme.

**Aufwand:** L.

---

### Bewusst nicht vorgeschlagen

| Idee | Warum nicht |
|---|---|
| **Eigene Cloud bzw. Sync-Server** | Bricht das stärkste Vertrauensargument gegenüber Gemeinden. U12 löst das Teamproblem ohne Cloud. |
| **KI-Schadenerkennung im Video, jetzt** | Braucht Trainingsdaten und wirft Haftungsfragen auf. Später interessant: Die bestätigten Beobachtungen aus U1/U3 *sind* ein gelabelter Datensatz (Bild + Kategorie + Bewertung), auf dem sich ein CoreML-Modell auf dem Gerät trainieren liesse. |
| **CarPlay, jetzt** | Apple lässt CarPlay nur für bestimmte App-Kategorien zu, mit eigener Freigabe und sehr eingeschränkter Oberfläche. Ein einzelner Knopf „Schaden markieren“ könnte unter die Kategorie „Driving Task“ fallen. Das ist prüfenswert, aber erst nach S8 und U11, die die Bedienung während der Fahrt ohnehin lösen. |
| **Android** | Ausserhalb des Rahmens. Wenn, dann erst nach dem Nachweis, dass Werkhöfe zahlen. |

---

## 6. Geschäftsmodell und Vertrieb

### 6.1 Drei Stufen

| | Gratis | Pro (CHF 19, einmalig, bleibt) | **Inspektion** (neu) |
|---|---|---|---|
| für | Neugierige, Lehre | Bastler, Forschung, Film | Gemeinden, Büros, Werke, Verwaltungen |
| enthält | alle Sensoren, Wiedergabe, Karte (U2), eine Route, Status, Adresse, CSV/GPX/KML | wie heute, dazu Web-Dashboard, GeoPackage/KMZ, dB(A), Labels, Qualitätsbericht-Export | Fahrbahnauswertung, PDF-Protokoll, eigene Kataloge, Wiederholung, offline-Karten, Anonymisierung, Team-Zusammenführung, Webhook, Profile Aufzug/ÖV/Bau |
| Preisidee | 0 | 19 | Jahreslizenz pro Gerät im zwei- bis tiefen dreistelligen CHF-Bereich |

**Prinzip, das bleibt:** Die eigenen Daten sind immer als CSV und im Archiv erreichbar, auch
nach Ablauf einer Lizenz. Das ist der Satz aus `ProAccess`, auf Organisationen übertragen.

**Einordnung:** Spezialisierte Plattformen für Gemeinden werden als Jahresabo verkauft;
konkrete Preise sind meist nicht öffentlich und vor einem Preisentscheid zu erfragen. Eine
Inspektionslizenz pro Gerät kann ein Vielfaches des heutigen Erlöses pro Kunde bringen und
bleibt trotzdem ein Bruchteil eines Plattform-Abos.

### 6.2 Kauf durch Organisationen

Gemeinden kaufen nicht mit der Kreditkarte eines Mitarbeiters. Nach meinem Stand sind
**In-App-Käufe über den Volumenkauf im Apple Business Manager nicht erhältlich**, nur
kostenpflichtige Apps. Das ist vor einem Entscheid bei Apple zu verifizieren. Optionen:

1. **Eigene App „Sensorstorm Inspektion“** als zweites Ziel in `project.yml`, mit
   demselben Core-Paket. Sie ist kostenpflichtig oder eine Custom App über den Apple
   Business Manager. Dazu kommen ein eigener Store-Eintrag mit passenden Stichwörtern
   (Strassenkontrolle, Werkhof, Mängel) und ein eigenes Icon. Das löst gleichzeitig das
   Positionierungsproblem: „Sensorstorm: Sensor Logger“ findet kein Werkhofleiter.
2. **Angebotscodes** für In-App-Käufe, verkauft gegen Rechnung. Apple hat Angebotscodes
   auf weitere Kaufarten ausgeweitet; welche Typen genau abgedeckt sind, ist zu prüfen.
3. Für grosse Kunden: Lizenzdatei bzw. MDM-Konfiguration (Managed App Config), z. B. um
   Kataloge und den Webhook zentral vorzugeben.

### 6.3 Vertrieb Schweiz zuerst

- **Pilot:** 3–5 Werkhöfe bzw. Tiefbauämter unterschiedlicher Grösse, kostenlos gegen
  Rückmeldung und Referenz.
- **Eigene Seiten im Website-Generator** (`PAIRS` in `web/build.py`): *Gemeinden &
  Werkhöfe*, *Aufzug-Fahrqualität*, *Forschung & Datensätze*, je mit eigenem SEO-Titel.
- **Kanäle:** Fachorganisation Kommunale Infrastruktur, VSS-Tagungen, Suisse Public (Bern),
  Fachhochschulen mit Studiengängen in Bau und Geomatik als Multiplikatoren.
- **Botschaft:** „Kontrolliert. Belegt. In LV95. Ohne Cloud.“

---

## 7. Empfohlene Reihenfolge

| Phase | Dauer | Inhalt | Ergebnis |
|---|---|---|---|
| 1 | 1–2 Wochen | S1, S2, S5, S6, S7, S10, S11, F11 und TODO bereinigen | Die bekannten Fehler sind weg, das Datenmodell ist bereit für alles Weitere |
| 2 | 2 Wochen | S3, S4, S8, U2 | Routen sind Nachweise, Daten lassen sich sichern, Bedienung ohne Hand |
| 3 | 3–4 Wochen | **U1, U3, U4, U5** | Der Alleinstellungswert ist da, Pilot-reif |
| 4 | parallel zum Pilot | U6, U7, U8, U9, U10, U12, S13 | was die Piloten verlangen, in ihrer Reihenfolge |
| 5 | danach | M1 (Aufzug) oder M5 (Forschung), je nach Echo; M4, M7 | zweiter Markt |

**Wenn nur drei Dinge gebaut werden:**

1. **U1** (Beobachtung aus der Wiedergabe)
2. **S3 + U4** (Weg und PDF-Nachweis)
3. **S5 + U5** (Status und Katalog)

Damit wird aus zwei guten Hälften ein Werkzeug, für das eine Gemeinde eine Rechnung
bezahlt.

---

## 8. Zu den offenen Punkten in `docs/TODO.md`

| Nr. | Punkt | Stand / Vorschlag |
|---|---|---|
| 1 | 3D-Modus überarbeiten | M7: Standbilder mit `captureHighResolutionFrame`, ausgelöst durch die IMU, statt Videobilder |
| 2 | WLAN-Signalstärke | So nicht machbar (F11). Ersatz: Strom `networkQuality` (Umlaufzeit, BSSID) |
| 3 | Bluetooth aufräumen | F12: in vier Teile zerlegen, ein Bildschirm mit drei Abschnitten |
| 4 | Detailansicht je Sensorwert | **Erledigt** (`App/UI/SensorDetailView.swift`). Den Eintrag aus der TODO-Liste streichen. |
