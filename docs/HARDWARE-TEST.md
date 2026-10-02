# Hardware-Test

Alles, was seit der Analyse (`docs/ANALYSE.md`) gebaut wurde, ist gegen den Compiler und die
Kern-Tests geprüft, **aber noch an keinem Gerät**. Der Simulator hat weder Bluetooth noch
NFC, LiDAR, Barometer, Uhr oder ein richtiges Netz. Diese Liste ist die Reihenfolge, in der
man es am Gerät abarbeitet. Jeder Punkt nennt, was man sehen muss.

Vorher, einmalig, auf dem Mac: `Tools/ensure_profiles.py` laufen lassen (macht
Capabilities und Profil der Telefon-App aktuell — siehe „Vor dem nächsten Build“ unten).

## 1. Start und Profile

- [ ] Erster Start zeigt die Profilauswahl. Ein Profil setzt Sensoren, Rate und Katalog.
- [ ] Einstellungen → Arbeitsprofil wechselt das Profil; einzelne Schalter bleiben danach änderbar.

## 2. Netzwerk (Tab „Funk“ → Netzwerk)

Auf einem **echten WLAN**, nicht im Simulator.

- [ ] Übersicht: Schnittstellen, IPv4, Netzmaske, Router. WLAN-Name erscheint erst, wenn der
  Standort erlaubt ist und die Capability „Access WiFi Information“ im Profil steckt.
- [ ] Scan: „Lokales Netzwerk“ wird abgefragt (Text kommt aus der Info.plist). Nach Erlauben
  erscheinen Geräte mit Namen aus Bonjour, NetBIOS und SSDP. Ports werden geprüft.
- [ ] Ohne Erlaubnis meldet die Ansicht „Zugriff verweigert“ statt einer leeren Liste.
- [ ] Zweiter Scan zeigt Änderungen zum ersten (neu, weg, Ports).
- [ ] Ping, Traceroute (Zwischenstationen kommen nur, wenn iOS die Zeitüberschreitungen
  durchreicht — **unsicher**), DNS-Abfrage, Portscan, Zertifikat, MQTT-Probe.
- [ ] Geschwindigkeit: Download, Upload, Antwortzeit im Leerlauf und unter Last.
- [ ] iperf3: gegen `iperf3 -s` im LAN. **Protokoll nur gegen die Spezifikation gebaut**, nie
  gegen einen echten Server getestet. Vorwärts und mit „Rückrichtung“.
- [ ] Wake-on-LAN: Das Paket geht an die Broadcast-Adresse; ohne die Apple-Berechtigung
  „Multicast Networking“ blockiert iOS das. Erwartung: Fehler oder Wirkungslosigkeit. Antrag
  siehe unten.
- [ ] Abnahmeprotokoll (PDF) aus dem Scan: Befunde, Geräte, Geschwindigkeit.
- [ ] „Netzqualität mitschreiben“ in einer Aufnahme: Antwortzeit Router und Internet,
  WLAN-Signal als Ströme; beim Gehen durch das Haus sinkt das Signal.
- [ ] **Hardware-Adressen:** Nach einem Scan stehen unter den Geräten MAC und Hersteller
  (Nachbartabelle über `sysctl`, **ob iOS 18 sie herausgibt, ist offen**). Bleibt es leer,
  steht in der Detailansicht kein Eintrag; das ist der erwartete Rückfall. Geräte, die weder
  Ping noch Ports beantworten, tauchen mit der Quelle `arp` auf, wenn die Tabelle da ist.
  Zufallsadressen (Telefone mit privater WLAN-Adresse) zeigen „Zufällige Adresse“.
- [ ] Kürzel (G, W, S, F, P, U, B, N, D, M, Q) neben den Geräten, Legende über das Symbol
  „Kürzel“ in der Leiste.
- [ ] Traceroute mit „Netzbetreiber und Land nachschlagen“: je öffentlichem Router
  erscheinen AS-Nummer, Name und Flagge (Namensabfrage bei Team Cymru über den DNS-Server des
  Netzes). Aus: keine Abfrage. Das Ergebnis lässt sich als Text teilen.
- [ ] DNS „Alle gängigen Typen“: A, AAAA, CNAME, MX, NS, SOA (siebenteilig), CAA, TXT mit
  Flags, ID, TTL und Antwortzeit.
- [ ] Portscan zeigt geschlossene Bereiche als „Geschlossen 1 bis 21“ zwischen den offenen.
- [ ] Verbindung: DNS-Server (kleine C-Funktion mit `res_ninit`, **ungeprüft**), Proxy,
  Verschlüsselungsart und Hersteller des Access Points, IPv4 und IPv6 der öffentlichen Adresse
  mit Anbieter.
- [ ] Routingtabelle (`NET_RT_DUMP`, **ob iOS sie herausgibt, ist offen**): Standardroute
  `UGSc`, das lokale Netz, Hosts. Ohne Zugriff erscheint der Hinweis.

## 3. Bluetooth (Tab „Funk“)

- [ ] Scanner listet Geräte mit dBm, Hersteller, Diensten. Suche, Filter, Favoriten, Alias.
- [ ] RuuviTag, BTHome, ATC/pvvx, Herzfrequenzgurt, Leistungsmesser: decodierte Werte erscheinen
  und werden als Ströme in der Aufnahme gespeichert.
- [ ] GATT-Explorer: verbinden, Dienste und Merkmale auflisten, lesen, **schreiben**
  (Rückfrage), abonnieren. Merkmal aufzeichnen (Benachrichtigung und fester Takt).
- [ ] Hintergrund: Bildschirm sperren während einer Aufnahme mit Gurt. Verbundene Geräte laufen
  weiter; Zustandswiederherstellung nach Beenden der App durch iOS ist **ungeprüft**.
- [ ] `bluetooth_devices.csv` im Export neben `bluetooth_advertisements.csv`.
- [ ] Explorer: Eigenschafts-Kürzel R, W, WWR, N, I, ASW, NENC, IENC an jedem Merkmal; ein
  Wert lässt sich als Hex, Text, Dezimal, Ganzzahl, Fliesskomma oder binär lesen; lange Werte
  erscheinen als Hexdump.
- [ ] Verlauf der Funde (Uhr-Symbol im Scanner): „Funde mitschreiben“ einschalten, durch ein
  Gebäude gehen, Zeit des ersten und letzten Pakets und Signalspanne je Gerät prüfen, als
  Tabelle teilen, löschen.
- [ ] Externer GNSS-Empfänger (Bluetooth-Seriell, NMEA): abonnieren, Strom `gnss.…` mit
  Qualität (RTK fix/float), Satelliten, Genauigkeit.

## 3a. NFC-Werkzeug (Tab „Funk“ → NFC)

Mit echten Tags: NTAG213/215/216, ein MIFARE-Ultralight-Aufkleber, nach Möglichkeit ein
ISO-15693-Tag und eine Chipkarte (Zutritt oder Bank: es sollen nur Art und Seriennummer
erscheinen).

- [ ] Lesen: Art, Chip (bei NTAG und Ultralight aus GET_VERSION), Hersteller, Seriennummer,
  NDEF-Status, Belegung in Byte, Inhalt je Eintrag, Rohdaten, Speicherauszug.
- [ ] Schreiben: URL, Text, Telefon, E-Mail, SMS, Ort, WLAN, Kontakt, Bluetooth, eigener Typ.
  Danach liest die App zurück („der Inhalt stimmt“). Das iPhone öffnet die URL beim Antippen
  des Tags im Hintergrund; ein Android-Gerät tritt dem WLAN bei.
- [ ] Zu grosse Nachricht (über 144 Byte auf NTAG213) meldet den Fehler vor dem Schreiben.
- [ ] Kopieren: zuerst den Quell-Tag, dann den Ziel-Tag. Die Seriennummer bleibt anders.
- [ ] Löschen: danach „Der Tag ist leer“.
- [ ] Schreibschutz: **nur an einem Wegwerf-Tag**, nicht rückgängig zu machen.
- [ ] Bibliothek: sichern, umbenennen, auf einen neuen Tag schreiben.
- [ ] Die Info.plist-Schlüssel für ISO 7816 und FeliCa müssen im Build stehen, sonst startet
  die Sitzung mit ISO 14443 nicht.

## 4. Route (Beobachtungen)

- [ ] Weg aufzeichnen mit gesperrtem Bildschirm (blauer Streifen).
- [ ] Beobachtung mit Foto, Schweregrad, Katalog, Messwerten (Neigung, Tiefe, Fläche,
  Volumen), Statuswechsel, Adresse (swisstopo/Apple), Nachher-Foto.
- [ ] Karte mit swisstopo-Kacheln; Karte offline laden und im Flugmodus öffnen.
- [ ] Wiederholungsbegehung, Zusammenführen, Archiv exportieren und auf einem zweiten Gerät
  einlesen.
- [ ] Export: CSV, GeoJSON, GPX, KML, KMZ, GeoPackage (in QGIS öffnen), Excel.
- [ ] Bericht als PDF: Karte, Fotos, Zusammenfassung; Nachweis „nichts gefunden“.
- [ ] Anonymisieren: Gesichter und Kennzeichen werden verpixelt, **nur im Export**.
- [ ] Weiterleiten: Webhook (eigener Empfänger) und Open311.
- [ ] NFC-Kontrollpunkt: Aufkleber mit Text-Eintrag scannen → Beobachtung „Kontrollpunkt“,
  Status „kein Handlungsbedarf“.
- [ ] Kurzbefehle: „Beobachtung an meinem Standort“ auf die Aktionstaste legen; Siri-Sätze.

## 5. Aufnahme und Auswertung

- [ ] Auswertung: Qualitätsprüfung, Strassenrauheit, Aufzug, Fahrkomfort, Erschütterung (DIN
  4150-3), Datensatz für Training. Bericht als PDF.
- [ ] Schallpegel dB(A): Mikrofon mit Kalibrator abgleichen (Einstellungen → Mikrofon kalibrieren).
- [ ] Gesundheitsdaten holen (Aufnahme-Detail): erst nach einigen Minuten, wenn die Uhr
  synchronisiert hat. Health-Freigabe erscheint beim ersten Mal.
- [ ] Weitere Quellen (Einstellungen): absolute Höhe, Speicher/Audio-Route, iBeacons (UUID
  eintragen), HomeKit, Frequenzbänder, Geräuschklassen (Notizen mit Zeit), Helligkeit und
  LiDAR-Abstand (nur ARKit-Modus, LiDAR-Gerät).
- [ ] Ereignisaufnahme: Schwelle 2,5 g, Telefon schütteln → Aufnahme „Ereignis …“ mit 30 s
  Vorlauf; Record-Bildschirm muss offen sein.
- [ ] Web-Dashboard (`http://<IP>:8080`) im selben WLAN.

## 6. Uhr

- [ ] Uhr als Fernbedienung: Aufnahme am Telefon starten, markieren, beenden. Zustand erscheint
  auf der Uhr (Application Context).
- [ ] Uhr-Aufnahme bestätigt den Absturz-Fix aus Build 17 (siehe `docs/TODO.md`).

## 7. Zwei Telefone

- [ ] Telefon A: Einstellungen → „Bluetooth-Dienst und zweites iPhone“ → „Als Bluetooth-Sensor
  anbieten“, „Fernsteuerung erlauben“.
- [ ] Telefon B: „Zweites iPhone suchen“, verbinden. Uhrversatz und Unsicherheit erscheinen
  (typisch wenige Millisekunden).
- [ ] Aufnahme auf B starten: A startet mit („Gemeinsam starten“). Ströme von A erscheinen in
  B als `peer.…`, die Metadaten nennen Versatz und Unsicherheit.
- [ ] Ein ESP32 oder ein Mac abonniert die Merkmale (Dienst `53454E53-4F52-5354-4F52-4D5000000001`).

## Vor dem nächsten Build

Die Telefon-App bekam eine `.entitlements`-Datei (`Resources/Sensorstorm.entitlements`):

| Entitlement | Wofür |
|---|---|
| `com.apple.developer.networking.wifi-info` | WLAN-Name und Signal im Netzwerk-Scanner |
| `com.apple.developer.healthkit` | Gesundheitsdaten zur Aufnahme importieren (nur lesen) |
| `com.apple.developer.homekit` | Sensoren des eigenen Zuhauses |
| `com.apple.developer.nfc.readersession.formats` | NFC-Kontrollpunkte |

`Tools/ensure_profiles.py` aktiviert die Capabilities `ACCESS_WIFI_INFORMATION`, `HEALTHKIT`,
`HOMEKIT` und `NFC_TAG_READING` an der App-ID und erneuert das Profil. Ohne diesen Lauf
wirft `codesign` die Entitlements beim Export weg (so verlor die Uhr einmal HealthKit).

**Nicht** enthalten und nur auf Antrag bei Apple zu haben:

- *Multicast Networking* (`com.apple.developer.networking.multicast`) — für Wake-on-LAN und
  eigenes Multicast/Broadcast.
- *SensorKit* — nur für genehmigte Forschungsstudien.
- *Wassertiefe* der Uhr (Ultra).

## Bekannt ungeprüft

Ohne Gerät gebaut, ohne dass ein Test es belegen könnte: iperf3 gegen einen echten Server,
GATT-Schreiben, State Restoration, Traceroute-Zwischenstationen, Bonjour-Verhalten auf iOS 18,
`NEHotspotNetwork` mit Capability, HomeKit-Benachrichtigungen, SoundAnalysis auf dem Gerät,
ARKit-Licht und -Tiefe, der Peripherie-Dienst gegen einen fremden Central.
