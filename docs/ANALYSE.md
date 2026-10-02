# Funktionsanalyse, Verbesserungen und Roadmap

Stand 2. Oktober 2026, Code auf `9a32a7c` (Build 16). Grundlage ist der ganze Quellcode
(rund 24 000 Zeilen Swift in App, Core-Paket und Uhr), dazu README, `docs/TODO.md`, die
Store-Texte in `Tools/store/` und der Website-Generator in `web/build.py`.

Aufbau: Kapitel 1 sagt, was die App heute kann. Kapitel 2 listet, was im Bestehenden
fehlerhaft oder lückenhaft ist. Kapitel 3 zeigt, wo der Alleinstellungswert liegt.
Kapitel 4 nennt die Zielgruppen, die genau das brauchen. Kapitel 5 enthält die
Vorschläge als Umsetzungskarten. Kapitel 6 deckt Bluetooth, Netzwerk und alle übrigen
Quellen ab, die iOS freigibt. Kapitel 7 behandelt das Geschäftsmodell, Kapitel 8 die
Reihenfolge.

Jede Umsetzungskarte nennt **was** gebaut wird, **wo** im Code, **welche Daten** dazukommen,
**wie es getestet** wird, **was es kostet** (S ≤ 1 Tag, M = 2–5 Tage, L = 1–3 Wochen,
jeweils ohne Übersetzung) und **wo die Grenze gratis / Pro / Inspektion** liegt.
„Inspektion“ ist ein vorgeschlagenes neues Paket für Organisationen (Kapitel 7).

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
6. **Fünf Befunde sollten sofort behoben werden:**
   - Regeln verpassen kurze Spitzen. Sie sehen bei 100 Hz nur jeden zehnten Messwert.
   - Routen zeichnen ihren Weg nicht auf.
   - Es gibt einen Gesamtexport, aber keinen Import. Ohne iCloud-Backup bedeutet ein
     Gerätewechsel deshalb Datenverlust.
   - Website und Store widersprechen sich und dem Code bei der Frage, was gratis ist.
   - Der Text der Bluetooth-Berechtigung verspricht „keine Verbindung“. Seit Build 16
     verbindet sich die App aber mit gekoppelten Sensoren (F17).
7. **Für die Logger-Hälfte heisst der Hebel: alles, was iOS zulässt.** Dazu gehören ein
   vollwertiger Bluetooth-Scanner mit GATT-Explorer, ein Netzwerkscanner und jede weitere
   Quelle, die iOS freigibt (UWB, NFC, iBeacon, HomeKit, absolute Höhe, die Uhr mit 800 Hz
   …). Der Unterschied zu nRF Connect, LightBlue und Fing: Sensorstorm zeigt die Werte
   nicht nur an, sondern **zeichnet sie auf der gemeinsamen Uhr auf**. Die Grundlage dafür
   sind dynamische Ströme (D1). Kapitel 6 sagt auch, was iOS nicht hergibt, und was man
   stattdessen misst: WLAN-Signalstärke, Mobilfunkpegel, MAC-Adressen, Bluetooth Classic.

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
| Bluetooth | Zählung, Rohlog, Decoder (Ruuvi, BTHome, ATC/pvvx), GATT (Puls, Leistung, Trittfrequenz, Laufsensor), eigene JS-Decoder | Funktional stark, strukturell überladen (F12). Der Scanner läuft nur auf dem Aufnahme-Bildschirm, decodierte Werte sind keine echten Ströme (F15), RR-Intervalle gehen verloren (F14). Ausbau: Kapitel 6.2 |
| Netzwerk | `NWPathMonitor`: Typ, „teuer“, „eingeschränkt“ | Kein Scanner, keine Qualitätsmessung, keine Details zu WLAN und Mobilfunk. Ausbau: Kapitel 6.3 |
| weitere iOS-Quellen | – | Absolute Höhe, UWB, NFC, iBeacon, HomeKit, die Uhr mit 800 Hz und mehr sind ungenutzt. Kapitel 6.4 |
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
Spital oder Schule ist das nützlicher als eine einzelne dBm-Zahl. Ausgearbeitet als N4
in Kapitel 6.3.

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
Die Aufteilung ist die Grundlage für den Ausbau in Kapitel 6.2 (B1–B8).

### F13 — 3D-Modus (TODO Nr. 1)

Die Ursache liegt im Ansatz, nicht im Feinschliff. Bilder aus einem Video sind komprimiert
und bei 30 fps mit langer Belichtung oft bewegungsunscharf. Die Auswahl findet das
schärfste Bild eines Abschnitts, aber sie kann keine Schärfe herstellen. Der grundsätzlich
andere Weg ist M7.

### F14 — RR-Intervalle gehen verloren *(Fehler)*

`BLEDecoders.heartRate` (`Sources/SensorstormCore/Bluetooth/BLEDecoders.swift:248`) behält
je Benachrichtigung nur das **letzte** RR-Intervall. Ein Paket kann aber mehrere enthalten,
etwa bei langsamem Puls oder wenn der Gurt bündelt. Für die Herzratenvariabilität (HRV)
fehlen damit Schläge, und RMSSD wird falsch.

**Behebung:** Alle RR-Werte ausgeben, je mit zurückgerechneter Zeit (Paketzeit minus die
Summe der folgenden Intervalle), als eigener ereignisgesteuerter Strom (B4, D1).

**Test:** Ein Paket mit drei RR-Werten ergibt drei Messwerte in der richtigen Reihenfolge
und mit den richtigen Zeiten.

**Aufwand:** S.

### F15 — Der Bluetooth-Teil ist kein Werkzeug für sich

- Gesucht wird nur, solange der Aufnahme-Bildschirm offen und der Strom „Bluetooth“ scharf
  ist. `BluetoothSensorsView` sagt deshalb: „Öffne den Aufnahme-Bildschirm, damit gesucht
  wird.“
- Decodierte Werte sind keine Ströme. Sie stehen in einer langen Tabelle (`BLEReadingLog`),
  nicht in Wiedergabe, Diagrammen, Regeln oder kombinierten Exporten.
- Verbunden wird nur mit den vier Sportprofilen. Beliebige GATT-Geräte lassen sich weder
  ansehen noch lesen.

Behebung: D1, B1–B3.

### F16 — „Ungefährer Standort“ wird nicht erkannt

Seit iOS 14 kann man einer App nur den ungefähren Standort erlauben. Core Location liefert
dann Positionen mit einer Genauigkeit im Kilometerbereich. Im Code wird
`accuracyAuthorization` nirgends abgefragt. Eine Beobachtung bekommt dann einen Kreis von
mehreren Kilometern, ohne dass jemand sagt, warum.

**Behebung:**

- `accuracyAuthorization == .reducedAccuracy` prüfen.
- In der Aufnahme und beim Erfassen einen Hinweis zeigen.
- `requestTemporaryFullAccuracyAuthorization(withPurposeKey:)` mit einem Zwecktext in
  `NSLocationTemporaryUsageDescriptionDictionary` anbieten.
- Den Zustand in die Metadaten der Aufnahme bzw. in die Beobachtung schreiben.

Auch `NEHotspotNetwork` (N1) braucht die genaue Ortung.

**Aufwand:** S.

### F17 — Der Text der Bluetooth-Berechtigung stimmt nicht mehr

`NSBluetoothAlwaysUsageDescription` in `project.yml` sagt: „Es wird keine Verbindung zu
ihnen aufgebaut.“ Seit Build 16 verbindet sich die App aber mit gekoppelten Gurten,
Leistungsmessern und Laufsensoren. Ein Zwecktext, der nicht stimmt, ist ein
Ablehnungsgrund im App Review und ein Vertrauensbruch gegenüber den Nutzern.

**Behebung:** Den Text neu fassen, z. B. „Sensorstorm sucht Bluetooth-Geräte in der
Umgebung, zeichnet ihre Signalstärke und Messwerte auf und verbindet sich mit Sensoren, die
du auswählst.“ Danach über `l10n.py` in alle Sprachen.

**Aufwand:** S, sofort.

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
| Preis | CHF 19 einmalig | Jahreslizenz im zwei- bis tiefen dreistelligen Bereich (Kap. 7) | gratis / Abo | Lizenz / gratis | Abo pro Nutzer | Plattform-Abo pro Gemeinde |

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
Spalte „fehlt“ verweist auf die Karten in Kapitel 5 und 6.

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
  Fahrt, U7 Wiederholung, U8 GeoPackage, U9 swisstopo, U10 Anonymisierung, U12 Team, I5
  NFC-Kontrollpunkte.
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
- **Fehlt:** U5 Kataloge, U8 GeoPackage, M6 externes RTK-GNSS, I5 NFC an Hydranten und
  Schächten, I6 Beleuchtung entlang der Strasse. M6 ist der eine Punkt, an dem „ehrliche
  Genauigkeit“ zu Zentimetern wird.

### Z5 — Liegenschaftsverwaltung, Facility Management, Hauswartung *(Priorität 3)*

- **Schmerz:** Umgebungskontrollen, Spielplatzkontrolle nach EN 1176-7 (regelmässige
  Sichtkontrolle) und der **Winterdienst-Nachweis**: Wer wann wo geräumt und gestreut hat,
  ist im Haftungsfall die entscheidende Frage.
- **Fehlt:** S3 Weg mit Zeitstempeln (ist schon der Nachweis), U4 PDF, U5 Checklisten-Kataloge,
  I5 NFC-Kontrollpunkte an Spielgeräten.

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
- **Fehlt:** M5 Labels, Vergleich zweier Aufnahmen. Dazu I10 (Uhr mit 800 Hz und
  Laufmetriken), I8 (Gelenkwinkel aus der Kamera) und B4 (Fitness Machine, alle
  RR-Intervalle). Eher Marketing-Geschichte als Umsatz.

### Z13 — Film, VFX, Drohnen *(bestehende Nische)*

Blender-Szene, swissALTI3D und Gyroflow sind schon da. Pflegen, nicht ausbauen.

### Z14 — IT-Dienstleister, Netzwerk- und Elektroinstallateure, Smart-Home-Integratoren *(Priorität 2)*

- **Wer:** IT-Supportfirmen für KMU, Elektroinstallateure mit Netzwerk- und
  Smart-Home-Angebot, die IT von Schulen und Gemeinden.
- **Schmerz:** Für eine Abnahme braucht es heute fünf Apps: Fing, nRF Connect, einen
  Speedtest, Ping und Notizen. Das Protokoll für den Kunden entsteht von Hand.
- **Fehlt:** N1–N7, B1/B2, I12. Das Abnahmeprotokoll (N7) ist das Produkt.

### Z15 — Hardware-, IoT- und BLE-Entwickler, Maker, Hochschullabore *(Priorität 2)*

- **Wer:** Entwicklungsteams für BLE-Produkte, Elektronik-Studiengänge, Maker.
- **Schmerz:** nRF Connect und LightBlue zeigen Werte, zeichnen aber nichts synchron zu
  einer Referenz auf. Wer einen Sensor-Prototyp prüft, will die iPhone-IMU, Video und GPS
  als Referenz auf derselben Uhr.
- **Fehlt:** B2 GATT-Explorer, B3 Werte als Ströme, B6 Telefon als BLE-Peripherie, D1. Die
  JS-Decoder gibt es schon.

### Z16 — Funkabdeckung: Spitäler, Schulen, Lager, Veranstalter, Blaulichtorganisationen *(Priorität 3)*

- **Schmerz:** „Hier bricht das WLAN ab“, „auf dem Festgelände gibt es kein Netz“. Messen
  lässt sich das heute nur mit Spezialgeräten.
- **Fehlt:** N4 mit U2 als Abdeckungskarte. Ohne Signalstärke, dafür mit Latenz, Verlust,
  Durchsatz und Wechseln des Access-Points.

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

## 6. Alles, was iOS zulässt: Bluetooth, Netzwerk und jede weitere Quelle

**Ziel:** Sensorstorm erfasst alles, was ein iPhone messen oder empfangen darf, und legt es
auf die gemeinsame Uhr.

**Warum das zugleich ein Vertriebskanal ist:** „Bluetooth Scanner“, „BLE“, „Netzwerk
Scanner“ und „WLAN“ gehören zu den gefragtesten Suchbegriffen bei den Dienstprogrammen.
nRF Connect, LightBlue und Fing zeigen, wie gross die Nachfrage ist.

**Der Unterschied zu diesen Apps:** Sie *zeigen* Werte an. Sensorstorm *zeichnet sie auf*,
synchron mit Video, GPS und IMU, auf der Karte (U2), mit Regeln (S1) und exportierbar.

> **Positionierung für diese Hälfte:** *Alles, was dein iPhone messen und empfangen kann,
> auf einer Uhr.*

Dieses Kapitel ist so aufgebaut:

- 6.1: eine Grundlage, ohne die der Rest nicht geht
- 6.2: Bluetooth
- 6.3: Netzwerk
- 6.4: alle übrigen Quellen, die iOS freigibt
- 6.5: was iOS nicht hergibt, und was man stattdessen misst
- 6.6: Berechtigungen und App Review

### 6.1 Grundlage: dynamische Ströme (D1)

**Problem:** Die Identität eines Stroms ist heute der feste Enum `SensorID`. Was erst zur
Laufzeit auftaucht, passt da nicht hinein, etwa ein RuuviTag, eine beliebige
GATT-Charakteristik, die Umlaufzeit zu einem Host oder ein MQTT-Wert. Deshalb landen die
decodierten Bluetooth-Werte heute in einer langen Tabelle `bluetooth_sensors.csv`
(`BLEReadingLog`) statt in der Wiedergabe, den Diagrammen, den Regeln, im Webserver und in
den kombinierten Exporten.

**Lösung:** Das Dateiformat `.ssbin` ist schon generisch, die Kanalzahl steht im Kopf
(`StreamFormat`). Es fehlt nur eine zweite Art von Strom-Identität:

```swift
// Sources/SensorstormCore/Model/ExternalStream.swift (neu)
public struct ExternalStreamInfo: Codable, Sendable, Hashable, Identifiable {
    public enum Source: String, Codable, Sendable { case bluetooth, network, mqtt, beacon, uwb, homeKit, accessory }
    /// Stabil über Aufnahmen hinweg: "ble.<geräte-uuid>.<dienst>.<charakteristik>",
    /// "net.rtt.<host>", "mqtt.<topic>.<json-pfad>" …
    public var id: String
    public var source: Source
    public var title: String                 // "RuuviTag 4F2A · Temperatur"
    public var channels: [String]
    public var channelUnits: [String]
    public var sampleCount: Int
    public var effectiveRateHz: Double
    public var fileName: String { "ext-\(Self.slug(id)).ssbin" }
}
// RecordingMetadata:
public var externalStreams: [ExternalStreamInfo]?
```

**Warum ein eigenes Feld statt einer Änderung an `StreamInfo`?** Ältere App-Versionen
ignorieren unbekannte JSON-Schlüssel. Eine Aufnahme mit neuen Strömen öffnet sich dort
weiter, nur ohne diese Ströme. Mit `StreamInfo.sensor` als Optional wäre das nicht so.

**Was sonst angepasst wird:**

- **`SampleSink`:** bekommt `ingest(external:time:values:)`. Der Schreiber entsteht beim
  ersten Messwert, weil Geräte mitten in der Aufnahme auftauchen. Ändert ein Gerät seinen
  Feldsatz, entsteht ein neuer Strom mit Suffix statt einer kaputten Datei.
- **Live, Regeln, Wiedergabe:** Live-Kacheln, `Rule.Condition.external(streamID:channel:…)`,
  Diagramme und Wiedergabe lesen externe Ströme wie eingebaute.
- **Exporte:** CSV je Strom, kombinierte CSV, JSON, SQLite, Excel, Manifest des
  Gesamtexports, Live-Push und Webserver.
- **MQTT:** Mit D1 wird Sensorstorm nebenbei auch zum **MQTT-Logger**. Ein abonniertes
  Topic mit Zahl oder JSON-Pfad ergibt einen Strom.

**Tests:**

- Hin und zurück.
- Eine alte `metadata.json` dekodiert weiter.
- Der Schreiber entsteht erst beim ersten Wert.
- Ein Feldwechsel ergibt einen zweiten Strom.
- Die Dateinamen sind stabil und kollisionsfrei.

**Aufwand:** M–L. **Voraussetzung für B3, N4, I3, I4 und I12.**

### 6.2 Bluetooth, vollwertig

#### Was iOS erlaubt und was nicht

| iOS erlaubt | iOS erlaubt nicht |
|---|---|
| Im Vordergrund jedes BLE-Advertisement sehen: Name, Dienste, Herstellerdaten, Dienstdaten, Sendeleistung, verbindbar | **Bluetooth Classic** (BR/EDR) suchen; nur MFi-Zubehör über `ExternalAccessory` |
| Mit jedem verbindbaren Gerät verbinden, alle Dienste, Charakteristiken und Deskriptoren lesen, schreiben und abonnieren; Pairing über den Systemdialog | **MAC-Adressen** sehen; iOS gibt jeder App eine eigene zufällige UUID je Gerät |
| L2CAP-Kanäle (CoC) für Datenströme | **iBeacon** über CoreBluetooth; iOS filtert diese Pakete heraus, sie sind nur über Core Location mit bekannter UUID erreichbar (I3) |
| Selbst Peripherie sein: eigene GATT-Dienste anbieten, mit Name und Dienst-UUIDs werben | Beliebige Herstellerdaten selbst aussenden |
| Im Hintergrund verbundene Geräte weiter bedienen, Zustand wiederherstellen, gezielt nach Dienst-UUIDs suchen | Im Hintergrund **ohne Dienstfilter** suchen; im Hintergrund werden Duplikate zusammengefasst |
| BLE-5-Erweiterungen empfangen (`supports(.extendedScanAndConnect)`) | PHY wählen (Long Range erzwingen), Rohpakete mitschneiden (HCI), LE Audio/Auracast |
| AccessorySetupKit (iOS 18): Kopplung über die Systemauswahl, ohne allgemeine Bluetooth-Freigabe | |

#### B1 — Bluetooth-Scanner als eigener Bildschirm

**Was:** Ein Scanner, der **ohne Aufnahme** läuft. Heute steht in `BluetoothSensorsView`
noch: „Öffne den Aufnahme-Bildschirm, damit gesucht wird“ (F15).

**Je Gerät eine Zeile:**

- Name (aus Advertisement oder GATT) und eigener Alias
- RSSI als Zahl und Mini-Verlauf
- geschätztes Werbeintervall
- Sendeleistung (`CBAdvertisementDataTxPowerLevelKey`)
- ob es verbindbar ist
- Hersteller aus der Company-ID
- Dienste mit Namen
- zuletzt gesehen

**Filter und Sortierung:** nach RSSI, Name, Hersteller, Dienst, „nur verbindbar“ und „nur
mit Daten“. Favoriten werden oben angeheftet.

**Gerätedetail:**

- RSSI-Diagramm über die Zeit
- alle Advertisement-Felder roh (Hex) und decodiert
- Verlauf der Herstellerdaten (welche Bytes sich ändern, ist der schnellste Weg zum
  eigenen Decoder)
- Knopf „Decoder dafür schreiben“ öffnet die Vorlage mit Company-ID bzw. Dienst-UUID schon
  eingesetzt

**Namen für Nummern:** die Listen der Bluetooth SIG (Company Identifiers, Service- und
Characteristic-UUIDs) als komprimierte JSON-Ressource im Core. Sie sind öffentlich
veröffentlicht; die Nutzungsbedingungen beim Einbinden prüfen.

**Eingebaute Beacon-Formate:**

- Eddystone UID/URL/TLM (Dienst `FEAA`); TLM liefert Batteriespannung und Temperatur
- AltBeacon

**Ehrlich bleiben:** Viele Telefone, Uhren und Kopfhörer wechseln ihre Adresse alle paar
Minuten. „37 Geräte“ in einer Minute sind deshalb eher 37 Adressen als 37 Geräte. Das steht
beim Zähler.

**Umsetzung:**

- `BluetoothScanner` aus F12 bekommt einen eigenen Scan-Besitzer (Referenzzählung):
  Aufnahme und Scanner-Bildschirm teilen sich eine Suche.
- Core: `AdvertisementParser` (rein, getestet) und `AssignedNumbers`.

**Aufwand:** M.

#### B2 — GATT-Explorer

**Was:**

- Verbinden mit jedem verbindbaren Gerät.
- Alle Dienste (auch eingeschlossene), Charakteristiken und Deskriptoren entdecken.
- Eigenschaften anzeigen (read, write, write without response, notify, indicate).
- **Lesen, Schreiben und Abonnieren**. Schreiben als Hex, Text oder Zahl (u8/u16/u32/s16/
  float, Little/Big Endian).
- Maximale Schreiblänge (`maximumWriteValueLength`) anzeigen, RSSI des verbundenen Geräts.

**Automatisch decodieren:**

- Deskriptor `0x2901` liefert den Klartextnamen.
- **Deskriptor `0x2904` (Presentation Format)** liefert Format, Exponent und Einheit. Jedes
  Gerät, das ihn setzt, wird damit ohne Decoder lesbar, mit Einheit.
- Bekannte Charakteristiken aus der GATT-Spezifikation:

| UUID | Grösse | Format |
|---|---|---|
| `2A6E` | Temperatur | sint16, 0,01 °C |
| `2A6F` | Feuchte | uint16, 0,01 % |
| `2A6D` | Druck | uint32, 0,1 Pa |
| `2A19` | Batterie | % |
| `2A1C` | Temperaturmessung | IEEE-11073-FLOAT |
| `2A9D` | Gewicht | – |
| `2A5F` | SpO₂ | – |
| `2AD2` | Indoor-Bike-Daten | – |
| `2A67` | Ort und Geschwindigkeit | – |

**Gerät:** Den Dienst Device Information (`180A`) automatisch lesen: Hersteller, Modell,
Firmware. Das wird in die Metadaten der Aufnahme geschrieben, damit eine Messung
reproduzierbar ist.

**Protokoll:** Jede Lese-, Schreib- und Benachrichtigungsaktion mit Host-Zeit als
JSON-Zeilen in der Aufnahme bzw. Sitzung (`gatt_log.jsonl`).

**Sicherheit:**

- Schreiben braucht eine ausdrückliche Bestätigung je Charakteristik, weil ein falscher
  Wert ein Gerät verstellen kann.
- Verschlüsselte Charakteristiken lösen den iOS-Kopplungsdialog aus. Das ist richtig so und
  wird erklärt.

**Aufwand:** M.

#### B3 — Jeder Bluetooth-Wert als Messstrom *(braucht D1)*

**Was:** Jede Charakteristik mit Zahlenwert und jedes decodierte Advertisement-Feld bekommt
einen Schalter „aufzeichnen“. Daraus wird ein dynamischer Strom mit Einheit: Kachel,
Diagramm, Wiedergabe, Karte (U2), Regel, Export, Push.

**Quellen:**

- **Notify/Indicate:** jeder Wert mit der Host-Zeit seines Eintreffens.
- **Nur lesbar:** periodisch lesen, Intervall einstellbar (1–60 s).

**Für Geräte ohne Standard:** eine Parse-Vorlage ohne JavaScript. Offset, Typ, Endian,
Faktor, Versatz und Einheit reichen für die meisten Fälle. Die JS-Decoder nehmen künftig
auch GATT-Werte an (`characteristic: "…"` neben `manufacturerId`).

**Folge:** Die lange Tabelle `bluetooth_sensors.csv` ist nur noch eine Übergangslösung und
wird für eine Version parallel geschrieben.

**Aufwand:** M.

#### B4 — Eingebaute Geräte und Profile

Die Liste orientiert sich an dem, was im Feld tatsächlich herumliegt. Jeder Eintrag ist
eine kleine reine Funktion im Core mit Testvektoren.

| Familie | Weg | Werte | wofür |
|---|---|---|---|
| **Environmental Sensing** `181A` | GATT | Temperatur, Feuchte, Druck, CO₂ … | jeder normkonforme Umweltsensor |
| Health Thermometer `1809`, Pulsoximeter `1822`, Waage `181D`, Körperzusammensetzung `181B`, Blutdruck `1810` | GATT | Messwerte | Sport, Forschung |
| **Fitness Machine** `1826` | GATT | Leistung, Trittfrequenz, Geschwindigkeit von Indoor-Bike, Laufband, Rudergerät | Sport (Z12) |
| **Location and Navigation** `1819` | GATT | Position, Geschwindigkeit | externe GNSS-Empfänger mit Standardprofil (ergänzt M6) |
| Battery `180F`, Device Information `180A` | GATT | Ladestand, Modell, Firmware | jedes Gerät |
| **Herzfrequenz `180D`: alle RR-Intervalle** | GATT | RR je Schlag, daraus HRV (RMSSD) | behebt F14 |
| Eddystone TLM, AltBeacon | Advertisement | Batterie, Temperatur, Zähler | Beacon-Flotten |
| Govee, Inkbird, SwitchBot, Qingping, ThermoPro | Advertisement | Temperatur, Feuchte | verbreitete Billigsensoren |
| **Aranet4** (mit Smart-Home-Integration) | Advertisement | **CO₂**, Temperatur, Feuchte, Druck | Schulen, Büros, Raumklima |
| Xiaomi MiBeacon | Advertisement, neuere Modelle mit Bind-Key verschlüsselt (AES-CCM) | Temperatur, Feuchte | sehr verbreitet |
| **Victron Instant Readout** | Advertisement, AES-CTR mit Geräteschlüssel (CommonCrypto) | Batterie, Solar, Spannung, Strom | Wohnmobil, Boot, Inselanlagen |
| Mopeka | Advertisement | Füllstand Gastank | Wohnmobil, Gewerbe |

**Lizenz:** Decoder aus offenen Spezifikationen und Dokumentationen der Hersteller
schreiben. Code aus GPL-Projekten wird nicht übernommen, weil GPL und App Store nicht
zusammenpassen. Bibliotheken unter MIT oder Apache sind mit Quellenangabe möglich.

**App Review:** Mitgelieferte Decoder gehören ins Binary. Eine nachladbare
Online-Bibliothek mit ausführbarem JavaScript wäre nach Richtlinie 2.5.2 heikel. Eigene
Dateien, die der Nutzer selbst importiert, bleiben wie heute möglich.

**Aufwand:** je Familie S; zusammen M.

#### B5 — Umgebung, Nähe, Suchen

- **Entfernung schätzen:** aus RSSI mit Pfadverlustmodell (Sendeleistung bei 1 m aus dem
  Advertisement oder kalibriert, Exponent einstellbar). Ehrlich ausgewiesen: Der Fehler
  liegt leicht beim Faktor 2–3, deshalb steht der Bereich da, nicht eine Zahl.
- **„Suchen“ (Geigerzähler):** Ein Gerät wählen, der RSSI wird als Ton und Haptik
  ausgegeben, lauter und schneller, je näher man kommt. Damit findet man einen verlegten
  Sensor, ein Tag im Lager oder einen versteckten Sender.
- **Anwesenheit:** Je Gerät wird festgehalten, wann es zuerst und zuletzt gesehen wurde und
  wie lange es da war. Das funktioniert nur für Geräte mit fester Adresse (Sensoren,
  Beacons). Telefone rotieren ihre Adresse.
- **Begleiter-Hinweis:** Ein Gerät mit fester Adresse wird an mindestens drei Orten
  gesehen, die mehr als 1 km auseinander liegen. Ein Hinweis, kein Alarm. iOS warnt bei
  AirTags und kompatiblen Trackern selbst; das hier ergänzt die übrigen.

**Aufwand:** S–M.

#### B6 — Das iPhone als BLE-Sensor, und mehrere iPhones auf einer Uhr

**Peripherie:** Mit `CBPeripheralManager` bietet Sensorstorm einen eigenen GATT-Dienst an.
Je gewähltem Live-Wert gibt es eine Charakteristik mit Notify (Orientierung,
Beschleunigung, Position, Puls der Uhr …). Ein ESP32, ein Raspberry Pi, ein Mac oder ein
zweites iPhone abonniert die Werte **ohne WLAN und ohne Server**.

**Mehrgeräte-Aufnahme:** Ein zweites iPhone mit Sensorstorm verbindet sich als Central.
Beide messen ihren Uhrversatz über BLE wie NTP: Ping und Pong, die halbe Umlaufzeit,
wiederholt, und der Median gewinnt. Gespeichert werden der Versatz **und seine
Unsicherheit** (typisch Millisekunden). Beide starten und stoppen gemeinsam.

Beispiele:

- Velo: Rahmen und Lenker
- Aufzug: Kabine und Maschinenraum
- Biomechanik: zwei Körpersegmente
- Fahrzeug: Karosserie und Achse

Das ist die gemeinsame Uhr über Gerätegrenzen. Bei der Uhr (Watch) gibt es heute nur die
schwächere Wanduhr-Zeit; dasselbe Verfahren verbessert auch sie.

**Grenzen:** Im Hintergrund wirbt iOS nur mit der Dienst-UUID. Die Mehrgeräte-Aufnahme
braucht deshalb beide Apps im Vordergrund, oder eine laufende Verbindung, die im
Hintergrund bestehen bleibt.

**Später:** ab iOS 26 Wi-Fi Aware für höhere Datenraten zwischen Geräten (prüfen).

**Aufwand:** L.

#### B7 — Hintergrund und Wiederverbinden

- `UIBackgroundModes` um `bluetooth-central` erweitern (und `bluetooth-peripheral` für B6).
  Heute hält nur der Ortungsmodus die App wach.
- **State Restoration** (`CBCentralManagerOptionRestoreIdentifierKey`): Gekoppelte Gurte
  und Leistungsmesser werden wieder verbunden, auch wenn iOS die App zwischendurch beendet
  hat.
- **Dokumentiert und in der App gezeigt:** welche Geräte bei gesperrtem Bildschirm
  weiterlaufen. Verbundene GATT-Geräte laufen weiter. Werbepakete ohne Dienst-UUID (Ruuvi,
  viele Billigsensoren) kommen im Hintergrund selten oder gar nicht. BTHome (`FCD2`) lässt
  sich gezielt suchen. Beim Start einer Aufnahme mit solchen Sensoren erscheint ein Hinweis:
  „Bildschirm anlassen“. `keepsScreenAwake` existiert schon.

**Aufwand:** S.

#### B8 — Export und Protokoll

- `bluetooth_devices.csv` je Aufnahme: Kennung, gesehene Namen, Hersteller, Dienste,
  zuerst und zuletzt gesehen, RSSI-Statistik.
- `gatt_log.jsonl` aus B2.
- Die dynamischen Ströme laufen über D1 in alle bestehenden Formate.
- Einen echten Paketmitschnitt (pcap) erlaubt iOS Apps nicht. Apples
  Bluetooth-Logging-Profil für Entwickler läuft über die Systemdiagnose, nicht über eine
  App. Das steht in der Hilfe.

**Aufwand:** S.

### 6.3 Netzwerk, vollwertiger Scanner

#### Was iOS erlaubt und was nicht

| iOS erlaubt | iOS erlaubt nicht |
|---|---|
| Schnittstellen, IPv4/IPv6-Adressen, Netzmaske (`getifaddrs`), Gateways und Fähigkeiten des Pfads (`NWPath.gateways`, `supportsIPv4/IPv6/DNS`, `isExpensive`, `isConstrained`) | **MAC-Adressen** anderer Geräte und damit der Hersteller über die OUI; die ARP-Tabelle ist seit iOS 11 gesperrt |
| WLAN: SSID, BSSID, Sicherheitstyp (`NEHotspotNetwork.fetchCurrent`, mit Berechtigung „Access WiFi Information“ und genauer Ortung) | **WLAN-Signalstärke**, Kanal, Rauschen; **umliegende WLANs** auflisten |
| Mobilfunk: Funktechnik je SIM (LTE, 5G NSA/SA …; `CTTelephonyNetworkInfo`) | Mobilfunk-Signalstärke (RSRP/RSRQ), Zellen-ID, Nachbarzellen; der Netzbetreibername ist seit iOS 16 ein Platzhalter |
| ICMP-Ping und Traceroute (ICMP über `SOCK_DGRAM`, TTL setzen) | Rohe Sockets: SYN-Scan, ARP-Scan, Paketmitschnitt im Netz |
| TCP-Verbindungstests auf beliebige Ports, Banner und Header lesen, TLS-Zertifikate prüfen | Dauerhafter Scan im Hintergrund |
| Bonjour/mDNS-Suche nach Diensttypen, die in `NSBonjourServices` deklariert sind, samt TXT-Records | Beliebige Diensttypen ohne Deklaration |
| Multicast und Broadcast (SSDP/UPnP, Wake-on-LAN, LLMNR): **nur mit der Berechtigung `com.apple.developer.networking.multicast`**, die bei Apple zu beantragen ist | – |
| Ethernet über USB-C-Adapter (iPhone 15 und neuer): dieselben Werkzeuge im Kabelnetz | – |

#### N1 — Netzwerk-Übersicht

**Ein Bildschirm, der alles über die aktuelle Verbindung zeigt:**

- Schnittstellen (`en0` WLAN, `en*` Ethernet über USB-C, `pdp_ip*` Mobilfunk, `utun*` VPN)
  mit Adressen und Präfix
- Gateway, DNS-Server, IPv6 ja/nein, „teuer“ und „Datensparmodus“
- WLAN mit SSID, BSSID und Sicherheit
- Mobilfunktechnik je SIM
- VPN aktiv?
- öffentliche IP und Provider, nur auf Tipp und ausdrücklich, weil das eine Anfrage an
  einen Dritten ist (z. B. `https://1.1.1.1/cdn-cgi/trace`)

**Umsetzung:**

- `NWPathMonitor` gibt es schon (`DeviceStateSource`).
- Core: `InterfaceList` aus `getifaddrs` (rein, getestet mit Fixtures).
- Neue Berechtigung „Access WiFi Information“ in `project.yml`.

**Aufwand:** S.

#### N2 — Geräte im lokalen Netz finden

**Mehrere Wege zusammen**, weil jeder einzelne Geräte übersieht:

1. **Bonjour:** Browsen über eine deklarierte Liste von rund 40 Diensttypen. Beispiele:
   `_http._tcp`, `_https._tcp`, `_ipp._tcp`, `_printer._tcp`, `_airplay._tcp`, `_raop._tcp`,
   `_googlecast._tcp`, `_hap._tcp`, `_matter._tcp`, `_ssh._tcp`, `_smb._tcp`, `_afpovertcp._tcp`,
   `_rfb._tcp`, `_mqtt._tcp`, `_home-assistant._tcp`, `_esphomelib._tcp`, `_hue._tcp`,
   `_sonos._tcp`, `_spotify-connect._tcp`, `_workstation._tcp`, `_device-info._tcp`,
   `_companion-link._tcp`, `_sleep-proxy._udp` usw. Die TXT-Records liefern oft das Modell
   (`model=`, `md=`, `ty=`).
2. **Ping-Sweep** über das eigene Subnetz (bis /22), höchstens 32 gleichzeitig, mit Timeout.
3. **TCP-Proben** auf häufige Ports für Geräte, die nicht auf Ping antworten.
4. **Reverse DNS** über den Router.
5. **NetBIOS-Namensabfrage** (UDP 137, unicast) für Windows-Rechner und NAS.
6. **Mit Multicast-Berechtigung:** SSDP/UPnP mit Hersteller, Modell und Gerätename aus der
   Beschreibungs-XML.

**Gerätetyp** aus offenen Ports, Diensttypen und Namen: Drucker, NAS, Kamera, Fernseher,
Lautsprecher, Router, Smart-Home-Gerät, Rechner.

**Ehrlich ausgewiesen:** Ohne MAC-Adresse gibt es keine Herstellererkennung aus der
Hardware. Was die App über ein Gerät weiss, steht mit seiner Quelle da (Bonjour, UPnP, DNS,
Port).

**Aufwand:** M–L.

#### N3 — Werkzeuge je Host

- **Portscan:** TCP-Connect auf die Top 100 / Top 1000 oder einen eigenen Bereich, mit
  Banner (SSH-Version, HTTP-`Server`, Titel der Seite).
- **TLS:** Zertifikat mit Aussteller, Gültigkeit und Kette. Ein Warnhinweis erscheint,
  wenn es in weniger als 30 Tagen abläuft.
- **Ping:** RTT-Statistik, Verlust, Jitter, als Diagramm.
- **Traceroute:** ICMP mit steigender TTL.
- **DNS-Abfrage:** A, AAAA, CNAME, MX, TXT, SRV gegen einen wählbaren Resolver.
- **HTTP-Tester:** Methode, Header, Antwortzeit. Passt zu Live-Push und Webserver.
- **MQTT-Tester:** Den Client gibt es schon (`MQTTTransport`); Verbinden, Abonnieren und
  Senden gehören auf den Bildschirm.
- **Wake-on-LAN**, sobald die Multicast-Berechtigung vorliegt.

**Aufwand:** M.

#### N4 — Netzqualität als Messstrom *(ersetzt TODO Nr. 2, braucht D1)*

**Neuer Strom `networkQuality`, 1 Hz:**

| Kanal | Inhalt |
|---|---|
| `rttGateway` | Umlaufzeit zum Gateway |
| `rttTarget` | Umlaufzeit zu einem gewählten Ziel, ohne Ziel aus |
| `loss` | Verlust in % über 10 s |
| `jitter` | – |
| `dnsTime` | – |
| `radio` | Funktechnik als Code |
| `apChanges` | Zähler der Wechsel des Access-Points |

Die BSSID selbst ist ein Text und kommt ins Nebenprotokoll.

**Auf Wunsch:** alle 60 s ein kurzer Durchsatztest gegen einen gewählten Server, mit
Hinweis auf das Datenvolumen.

**Zusammen mit U2** wird daraus eine **Abdeckungskarte**: Latenz, Verlust und Funktechnik
entlang des Weges. Dazu die Stellen, an denen das Telefon den Access-Point wechselt.

**Warum das ehrlicher ist als dBm:** Für jemanden, der wissen will, ob das WLAN im
3. Stock taugt, sagen Latenz und Verlust mehr als die Signalstärke. Und sie sind messbar.

**Aufwand:** M.

#### N5 — Inventar und Vergleich

- **Scans als Schnappschuss** speichern (Zeit, Ort, Netz).
- **Zwei Scans vergleichen:** neue Geräte, verschwundene Geräte, neu offene Ports („Port 23
  ist neu offen“).
- **Export:** CSV und JSON, im Protokoll (U4).
- **Regel:** „neues Gerät im Netz“, solange die App offen ist.
- **Ehrlich:** iOS erlaubt keinen verlässlichen Dauerscan im Hintergrund. Das steht da,
  statt dass `BGAppRefreshTask` so tut als ob.

**Aufwand:** M.

#### N6 — Durchsatz messen (iperf3-Client)

IT-Techniker betreiben iperf3-Server ohnehin. Ein iperf3-Client misst damit TCP und UDP,
upstream und downstream, mit Jitter und Verlust bei UDP. Das Protokoll ist offen (Steuerung
über TCP mit JSON). Ohne eigenen Server gibt es einen HTTP-Download- und Upload-Test gegen
eine wählbare Adresse.

**Aufwand:** M.

#### N7 — Abnahmeprotokoll für WLAN und Netz

Raumweise Messpunkte als Beobachtungen in einer Route (Werkzeuge aus Kapitel 5):

- je Messpunkt Latenz, Verlust, Durchsatz, Access-Point und Funktechnik
- Gerätebestand und offene Ports
- als PDF (U4) für den Kunden

Das ist das Produkt für Installateure und IT-Dienstleister (Z14). Ohne Signalstärke, dafür
mit dem, was der Kunde tatsächlich spürt.

**Aufwand:** M, auf U4.

### 6.4 Jede weitere Quelle, die iOS freigibt

Die Spalte **heute** zeigt, ob Sensorstorm die Quelle schon nutzt.

| ID | Quelle | iOS-Schnittstelle | Berechtigung | heute | Vorschlag | Nutzen |
|---|---|---|---|---|---|---|
| I1 | **Absolute Höhe** (GPS + Barometer fusioniert) | `CMAltimeter.startAbsoluteAltitudeUpdates` (iOS 15) | Bewegung | – | Strom `absoluteAltitude`: Höhe, Genauigkeit, Präzision | genauer als die GPS-Höhe allein; Stockwerke, Gefälle |
| I2 | **Herkunft der Position** | `CLLocation.sourceInformation` (simuliert / von Zubehör), `CLFloor` | Ort | – | zwei Kanäle im `location`-Strom bzw. ein Nebenstrom, Stockwerk in Gebäuden mit Indoor-Karte | Ehrlichkeit: ein simulierter Fix ist kein Messwert |
| I3 | **iBeacon** | `CLBeaconIdentityConstraint` (Ranging) | Ort | – | UUIDs eintragen, je Beacon RSSI, Nähe, Entfernung als dynamischer Strom (D1) | Indoor-Zonen; Tilt-Hydrometer (Brauen: Temperatur und Stammwürze im Major/Minor) |
| I4 | **UWB Nearby Interaction** | `NISession` mit zweitem iPhone oder UWB-Zubehör | Nähe | – | Distanz (cm) und Richtung (Azimut, Elevation) je Gegenstelle als Strom; Token-Austausch über B6 | „Messband zwischen zwei iPhones“, Abstand zwischen Athleten, Ortung im Raum mit UWB-Ankern |
| I5 | **NFC** | Core NFC: NDEF lesen und schreiben, ISO 15693 / 7816 / MIFARE / FeliCa | NFC-Tag-Lesen | – | **Kontrollpunkte**: NFC-Aufkleber an Hydrant, Kandelaber, Spielgerät, Schacht; Scannen belegt die Anwesenheit am Objekt und füllt die Beobachtung mit der Objekt-ID; Sensor-Tags nach ISO 15693 auslesen | Z1, Z4, Z5: Wächterkontrolle, Inventar |
| I6 | **Umgebungslicht über die Kamera** | ARKit `lightEstimate` (Lumen, Farbtemperatur) bzw. Belichtung (ISO, Zeit, Blende) → EV → Lux-Schätzung | Kamera | – | Strom `illuminance` (geschätzt, kalibrierbar); der Umgebungslichtsensor selbst ist nur über SensorKit erreichbar | Strassenbeleuchtung entlang des Weges (Z4), Arbeitsplätze; ehrlich als Schätzung |
| I7 | **LiDAR-Tiefe** | `sceneDepth` / `smoothedSceneDepth` mit Konfidenz | Kamera | – | Tiefenkarte je Bild (M7), Entfernung zur Bildmitte als Strom („Laser-Distanzmesser“ bis rund 5 m), Tiefe von Schäden (U6) | Messen ohne Zollstock |
| I8 | **Körper, Hand, Gesicht** | `ARBodyTrackingConfiguration` (3D-Skelett), Vision `VNDetectHumanBodyPose3DRequest` (iOS 17), Hand-Pose, TrueDepth-Gesicht | Kamera | – | Gelenkwinkel (Knie, Hüfte, Rumpf, Ellbogen) je Bild als Strom, auf der Uhr mit IMU und Puls | Sport und Physio (Z12); Ergonomie (Rumpfbeugung beim Heben) für die Arbeitssicherheit |
| I9 | **Audio, erweitert** | `AVAudioEngine` + Accelerate (FFT), `SoundAnalysis` (eingebauter Klassifikator mit Hunderten Klassen, iOS 15) | Mikrofon | dBFS | Terzbänder, dominante Frequenz, **Geräuschklasse mit Konfidenz** (Sirene, Hund, Motor, Musik …) als Strom; dazu M4 dB(A) | Lärmdokumentation: nicht nur *wie laut*, sondern *was* |
| I10 | **Apple Watch, voll ausgenutzt** | `CMBatchedSensorManager` (watchOS 10, neuere Modelle, während eines Workouts); `HKLiveWorkoutBuilder`; `CMWaterSubmersionManager` (Ultra) | Bewegung, Health | 50 Hz, Puls | **Beschleunigung 800 Hz und Device Motion 200 Hz** statt 50 Hz; Laufmetriken (Leistung, Schrittlänge, vertikale Oszillation, Bodenkontaktzeit); GPS der Uhr als zweiter Ortsstrom; Wassertiefe und -temperatur (Ultra, mit Berechtigung) | Sport, Biomechanik, Schwimmen und Tauchen |
| I11 | **Health-Daten zum Zeitraum** | HealthKit auf dem iPhone | Health | – | Proben im Zeitfenster der Aufnahme (Puls, HRV, SpO₂, Schritte, Atemfrequenz) als Ströme importieren | Forschung (Z11) |
| I12 | **HomeKit und Matter** | HomeKit-Framework: Merkmale der Geräte im eigenen Zuhause lesen und abonnieren | HomeKit | – | Raumtemperatur, Feuchte, CO₂, Luftqualität, Lux, Kontakt und Bewegung als dynamische Ströme während der Aufnahme | Bauphysik, Raumklima, Smart-Home-Integratoren (Z14) |
| I13 | **Gerät und System** | `UIDevice.proximityState`, `ProcessInfo.thermalState`, Stromsparmodus, freier Speicher, Audioroute und Lautstärke (`AVAudioSession`), Ausrichtung | – | Batterie, Helligkeit, Netz | Ströme `proximity` (nur wenn ausdrücklich scharf, weil der Sensor den Bildschirm ausschaltet), `thermal` (S10), `storage`, `audioRoute` | erklärt Aussetzer; Näherungssensor als Zähler (Vorbeigehen, Klappe) |
| I14 | **Zubehör über USB-C und MFi** | USB-Audio (auch mehrkanalig), `ExternalAccessory` (MFi-GNSS) | Mikrofon | – | **USB-Messmikrofone mit Kalibrierdatei** (z. B. miniDSP UMIK) für belastbare dB(A); **USB-Audio-Beschleunigungsaufnehmer** (es gibt Modelle, die sich als Audiogerät melden, z. B. von Digiducer) für echte Schwingungsmessung mit 48 kHz und bekannter Empfindlichkeit; MFi-GNSS-Empfänger | macht M1, M3 und M4 messtechnisch ernsthaft |
| I15 | **SensorKit** | `SRSensorReader` | nur für von Apple genehmigte Forschungsstudien | – | erst mit einer Hochschulkooperation: Umgebungslicht (Lux), Handgelenktemperatur, PPG/EKG-Rohdaten der Uhr u. a. | Z11; der einzige legale Weg zum Lichtsensor |

**Aufwand:** I1, I2, I13 je S; I3, I6, I7, I9, I11, I12 je M; I4, I5 je M; I8, I10, I14 je
M–L; I15 hängt am Antrag.

### 6.5 Was iOS nicht hergibt, und was man stattdessen misst

| gewünscht | auf iOS | stattdessen |
|---|---|---|
| WLAN-Signalstärke, Kanal, umliegende Netze | nicht verfügbar (F11) | N4: Latenz, Verlust, Durchsatz, Wechsel des Access-Points |
| Mobilfunk-Signal, Zellen-ID | nicht verfügbar | N4: Funktechnik, Latenz, Durchsatz entlang des Wegs |
| GNSS-Rohdaten (Pseudoranges) | nicht verfügbar (anders als Android) | M6: externer Empfänger mit eigenen Rohdaten bzw. RTK |
| MAC-Adressen, Hersteller-OUI | nicht verfügbar | N2: Bonjour, UPnP, DNS, Ports; B1: Company-ID aus Herstellerdaten |
| Bluetooth Classic | nur MFi | BLE; Classic-Geräte mit MFi über `ExternalAccessory` |
| Umgebungslichtsensor | nur SensorKit (Forschung) | I6: Schätzung über die Kamera |
| Temperatur, Feuchte | keine Sensoren im iPhone | B4: BLE-Sensoren (Ruuvi, Aranet, Environmental Sensing …), I12: HomeKit |
| Batterietemperatur, Ladeleistung | nicht verfügbar | I13: Wärmezustand (`thermalState`) |
| Paketmitschnitt, Monitor-Modus | nicht verfügbar | N3: Werkzeuge auf Verbindungsebene |
| Dauerscan im Hintergrund (BLE ohne Filter, Netz) | nicht verfügbar | Aufnahme im Vordergrund, Bildschirm aktiv (gibt es schon); Hinweis beim Start |

### 6.6 Berechtigungen, Texte und App Review

Was in `project.yml` und in den Texten dazukommt bzw. sich ändert:

| Eintrag | wofür | Hinweis |
|---|---|---|
| `NSBluetoothAlwaysUsageDescription` | **neu formulieren** | Der heutige Text sagt „Es wird keine Verbindung zu ihnen aufgebaut.“ Seit Build 16 verbindet sich die App mit gekoppelten Geräten (F17) |
| `NSLocalNetworkUsageDescription` | um das Scannen erweitern | heute nur „sendet die Messwerte an die Adresse …“ |
| `NSBonjourServices` | Liste der Diensttypen (N2) | ohne sie findet Bonjour nichts |
| `com.apple.developer.networking.wifi-info` | SSID/BSSID (N1, N4) | – |
| `com.apple.developer.networking.multicast` | SSDP/UPnP, Wake-on-LAN | **bei Apple beantragen**, mit Begründung |
| `NFCReaderUsageDescription`, `com.apple.developer.nfc.readersession.formats` | I5 | – |
| `NSNearbyInteractionUsageDescription` | I4 | – |
| `NSHomeKitUsageDescription`, HomeKit-Capability | I12 | – |
| `UIBackgroundModes`: `bluetooth-central`, `bluetooth-peripheral` | B6, B7 | – |
| Watch: `com.apple.developer.healthkit` (gibt es), Wassertiefe (I10) | – | Wassertiefe ist eine eigene, zu beantragende Berechtigung |

**Datenschutz:** Alles bleibt auf dem Gerät. Die Angabe „keine Daten gesammelt“ bleibt
richtig.

**Was auf die Website gehört (`web/build.py`):**

- Scans laufen nur auf ausdrückliche Aktion.
- Bluetooth-Kennungen und Netzwerkgeräte werden nur gespeichert, wenn eine Aufnahme oder
  ein Schnappschuss das verlangt.
- Abfragen an Dritte (öffentliche IP, Durchsatztest, Kartenkacheln, Adressen) sind opt-in
  und benannt.

**App Review:** Netzwerk- und Bluetooth-Werkzeuge sind im Store üblich (Fing, nRF Connect,
LightBlue). Wichtig sind die zutreffenden Zwecktexte und dass nichts ungefragt im
Hintergrund scannt.

### 6.7 Übersicht dieses Kapitels

| ID | Vorschlag | Aufwand | Paket |
|---|---|---|---|
| **D1** | Dynamische Ströme | M–L | Grundlage |
| **B1** | Bluetooth-Scanner als eigener Bildschirm | M | gratis |
| **B2** | GATT-Explorer | M | gratis (live), Pro (Protokoll-Export) |
| **B3** | Jeder Bluetooth-Wert als Messstrom | M | Pro |
| **B4** | Eingebaute Geräte und Profile | M | gratis |
| **B5** | Entfernung, Suchen, Anwesenheit | S–M | gratis |
| **B6** | iPhone als BLE-Sensor, Mehrgeräte-Aufnahme | L | Pro |
| **B7** | Hintergrund und Wiederverbinden | S | gratis |
| **B8** | Export und Protokoll | S | Pro |
| **N1** | Netzwerk-Übersicht | S | gratis |
| **N2** | Geräte im Netz finden | M–L | gratis |
| **N3** | Werkzeuge je Host (Ports, TLS, Ping, Traceroute, DNS, HTTP, MQTT) | M | gratis (Ping/DNS), Pro (Rest) |
| **N4** | Netzqualität als Messstrom, Abdeckungskarte | M | Pro |
| **N5** | Inventar und Vergleich | M | Pro |
| **N6** | iperf3-Client | M | Pro |
| **N7** | Abnahmeprotokoll WLAN/Netz | M | Inspektion |
| **I1–I15** | weitere Quellen (Tabelle 6.4) | S bis L | Quellen gratis wie alle Sensoren; Auswertungen Pro |

**Grundsatz für die Paketgrenze:** Wie bei den bisherigen Sensoren ist das *Sehen* gratis,
und was aufgezeichnet wurde, ist immer als CSV exportierbar. Pro verkauft das Aufzeichnen
beliebiger Fremdgeräte, die Profi-Werkzeuge und die Automatisierung.

---

## 7. Geschäftsmodell und Vertrieb

### 7.1 Drei Stufen

| | Gratis | Pro (CHF 19, einmalig, bleibt) | **Inspektion** (neu) |
|---|---|---|---|
| für | Neugierige, Lehre | Bastler, Forschung, Film, IT, Entwickler | Gemeinden, Büros, Werke, Verwaltungen, Installateure |
| enthält | alle Sensoren und iOS-Quellen, Wiedergabe, Karte (U2), eine Route, Status, Adresse, CSV/GPX/KML; Bluetooth-Scanner und GATT live; Netzwerk-Übersicht, Gerätesuche, Ping, DNS | wie heute, dazu Web-Dashboard, GeoPackage/KMZ, dB(A), Labels, Qualitätsbericht-Export; beliebige Bluetooth-Werte als Ströme, Mehrgeräte-Aufnahme, Netzqualität, Portscan, TLS, iperf3, Netz-Inventar | Fahrbahnauswertung, PDF-Protokoll, eigene Kataloge, Wiederholung, offline-Karten, Anonymisierung, Team-Zusammenführung, Webhook, Profile Aufzug/ÖV/Bau, Netz-Abnahmeprotokoll, NFC-Kontrollpunkte |
| Preisidee | 0 | 19 | Jahreslizenz pro Gerät im zwei- bis tiefen dreistelligen CHF-Bereich |

**Prinzip, das bleibt:** Die eigenen Daten sind immer als CSV und im Archiv erreichbar, auch
nach Ablauf einer Lizenz. Das ist der Satz aus `ProAccess`, auf Organisationen übertragen.

**Einordnung:** Spezialisierte Plattformen für Gemeinden werden als Jahresabo verkauft;
konkrete Preise sind meist nicht öffentlich und vor einem Preisentscheid zu erfragen. Eine
Inspektionslizenz pro Gerät kann ein Vielfaches des heutigen Erlöses pro Kunde bringen und
bleibt trotzdem ein Bruchteil eines Plattform-Abos.

### 7.2 Kauf durch Organisationen

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

### 7.3 Vertrieb Schweiz zuerst

- **Pilot:** 3–5 Werkhöfe bzw. Tiefbauämter unterschiedlicher Grösse, kostenlos gegen
  Rückmeldung und Referenz.
- **Eigene Seiten im Website-Generator** (`PAIRS` in `web/build.py`): *Gemeinden &
  Werkhöfe*, *Aufzug-Fahrqualität*, *Forschung & Datensätze*, je mit eigenem SEO-Titel.
- **Kanäle:** Fachorganisation Kommunale Infrastruktur, VSS-Tagungen, Suisse Public (Bern),
  Fachhochschulen mit Studiengängen in Bau und Geomatik als Multiplikatoren.
- **Store-Stichwörter für die Funk-Seite** je Sprache in `Tools/store/` (Bluetooth Scanner,
  BLE, GATT, Netzwerk Scanner, WLAN, Ping). Das sind Begriffe mit viel Suchvolumen, die heute
  gar nicht vorkommen. Dazu eine Website-Seite *Bluetooth & Netzwerk*.
- **Botschaft:** „Kontrolliert. Belegt. In LV95. Ohne Cloud.“ Für die Logger-Hälfte: „Alles,
  was dein iPhone messen und empfangen kann, auf einer Uhr.“

---

## 8. Empfohlene Reihenfolge

| Phase | Dauer | Inhalt | Ergebnis |
|---|---|---|---|
| 1 | 1–2 Wochen | S1, S2, S5, S6, S7, S10, S11, **F16, F17**, F11 und TODO bereinigen | Die bekannten Fehler sind weg, das Datenmodell ist bereit für alles Weitere |
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

### Die Funk-Spur, parallel dazu

| Phase | parallel zu | Inhalt | Ergebnis |
|---|---|---|---|
| F-a | Phase 1 | F14, F15 (Scanner-Bildschirm aus B1, noch ohne Explorer), B7, N1, I1, I2, I13 | Fehler weg, sofort sichtbare Erweiterungen |
| F-b | Phase 2 | **D1**, B1, B2, B4 | vollwertiger Bluetooth-Scanner und GATT-Explorer |
| F-c | Phase 3 | B3, N2, N3, N4 | Fremdgeräte als Ströme, Netzwerkscanner, Abdeckungskarte |
| F-d | danach | B5, B6, B8, N5–N7, I3–I12 nach Nachfrage | Mehrgeräte-Aufnahme, Netz-Abnahmeprotokoll, weitere Quellen |

**Wenn auf der Funk-Seite nur drei Dinge gebaut werden:**

1. **D1 + B3** (jeder Bluetooth-Wert als Strom)
2. **B1 + B2** (Scanner und Explorer)
3. **N1 + N2 + N4** (Übersicht, Gerätesuche, Netzqualität)

Damit ist Sensorstorm der einzige Bluetooth- und Netzwerkscanner, der aufzeichnet, und die
Suchbegriffe bringen Nutzer, die heute nie auf „Sensor Logger“ stossen.

---

## 9. Zu den offenen Punkten in `docs/TODO.md`

| Nr. | Punkt | Stand / Vorschlag |
|---|---|---|
| 1 | 3D-Modus überarbeiten | M7: Standbilder mit `captureHighResolutionFrame`, ausgelöst durch die IMU, statt Videobilder |
| 2 | WLAN-Signalstärke | So nicht machbar (F11). Ersatz: N4 Netzqualität, als Abdeckungskarte mit U2 (Kapitel 6.3) |
| 3 | Bluetooth aufräumen | F12 aufteilen, dann zum vollwertigen Werkzeug ausbauen: B1–B8 auf D1 (Kapitel 6.2); dazu F14, F15, F17 |
| 4 | Detailansicht je Sensorwert | **Erledigt** (`App/UI/SensorDetailView.swift`). Den Eintrag aus der TODO-Liste streichen. |

---

## Umsetzungsstand (2026-10-02)

Gebaut gegen den Compiler und die Kern-Tests (CI grün), **an keinem Gerät geprüft**. Die
Reihenfolge zum Prüfen steht in [HARDWARE-TEST.md](HARDWARE-TEST.md).

| Gruppe | Gebaut | Teilweise | Nicht gebaut |
|--------|--------|-----------|--------------|
| **S** Schnelle Gewinne | S1–S7, S9, S10, S12, S13 | S8 (Kurzbefehle, Siri, Aktionstaste; keine Live-Aktivität), S11 (Datenschutzseite; Store-Texte nicht) | – |
| **U** Oberfläche und Route | U1–U12 | – | – |
| **M** Auswertung | M1–M4, M6, M8, M9 | M5 (Datensatz; ohne Beschriftung, ohne Vergleich zweier Aufnahmen), M6 (Strom, nicht als Position für Beobachtungen) | M7 |
| **D** Dynamische Ströme | D1 | – | – |
| **B** Bluetooth | B1–B8 | B8 (Geräteliste; kein GATT-Protokoll als Datei) | – |
| **N** Netzwerk | N1–N7 | – | – |
| **I** Weitere Quellen | I1–I7, I9, I11–I13 | I7 (Abstand zur Bildmitte, keine Tiefenkarte je Bild), I10 (800 Hz Beschleunigung, ohne Device Motion), I13 (Speicher und Audio-Route; kein Näherungssensor) | I8, I14, I15 |

Warum nicht gebaut:

- **M7** Standbilder für die Fotogrammetrie: die Intrinsics des Standbilds weichen von denen der
  Videobilder ab, `cameras.csv` und der COLMAP-Export müssen sie je Bild führen.
- **S8 Live-Aktivität** braucht eine Widget-Erweiterung mit eigener App-ID und eigenem Profil.
- **I8** Körper-Tracking ist eine eigene ARKit-Konfiguration und schliesst das Weltmodell aus,
  das die Kamerapose braucht.
- **I14** USB-Messmikrofone mit Kalibrierdatei und MFi-GNSS: eigene Quelle, ohne Gerät nicht zu
  entwickeln.
- **I15** SensorKit gibt es nur für von Apple genehmigte Forschungsstudien.
- **Staffelung in Gratis und Pro** (Kapitel 8): die neuen Werkzeuge hängen nicht an `ProAccess`.
