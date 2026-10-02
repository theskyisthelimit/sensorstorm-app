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

## 3. Bluetooth (Tab „Funk“)

- [ ] Scanner listet Geräte mit dBm, Hersteller, Diensten. Suche, Filter, Favoriten, Alias.
- [ ] RuuviTag, BTHome, ATC/pvvx, Herzfrequenzgurt, Leistungsmesser: decodierte Werte erscheinen
  und werden als Ströme in der Aufnahme gespeichert.
- [ ] GATT-Explorer: verbinden, Dienste und Merkmale auflisten, lesen, **schreiben**
  (Rückfrage), abonnieren. Merkmal aufzeichnen (Benachrichtigung und fester Takt).
- [ ] Hintergrund: Bildschirm sperren während einer Aufnahme mit Gurt. Verbundene Geräte laufen
  weiter; Zustandswiederherstellung nach Beenden der App durch iOS ist **ungeprüft**.
- [ ] `bluetooth_devices.csv` im Export neben `bluetooth_advertisements.csv`.
- [ ] Externer GNSS-Empfänger (Bluetooth-Seriell, NMEA): abonnieren, Strom `gnss.…` mit
  Qualität (RTK fix/float), Satelliten, Genauigkeit.

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
