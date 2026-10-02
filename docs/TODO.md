# TODO

Offene Punkte, noch nicht umgesetzt. Nur Notizen – keine Implementierung.

## 1. 3D-Modus überarbeiten
Der 3D-Modus ist in der aktuellen Form nicht gut. Die aus dem Video extrahierten
Bilder sind teilweise verschwommen. Der Ansatz muss grundsätzlich anders gelöst
werden (nicht nur nachbessern).

## 2. WLAN-Signalstärke anzeigen *(gebaut, ungeprüft)*
`NetworkQualitySource` schreibt `net.wifi.signal`; der Wert kommt aus
`NEHotspotNetwork.fetchCurrent`, braucht die Capability und den Standort. Auf dem Gerät
prüfen — siehe `docs/HARDWARE-TEST.md`.

## 3. Bluetooth aufräumen *(gebaut, ungeprüft)*
Scanner, GATT-Explorer, Decoder, Fremdströme, Peripherie-Dienst, Zweit-iPhone. Gerät fehlt.

## 4. Detailansicht je Sensorwert
Tap auf einen einzelnen Sensorwert öffnet eine Detailansicht:
- Wert live und gross dargestellt
- Verlauf über die Zeit, aber nur für diesen einen Wert
- läuft sofort beim Öffnen los, ohne dass eine Aufnahme gestartet werden muss
- die eigentliche Aufnahme startet weiterhin auf der Hauptseite

## 5. Übersetzungen für Build 17 nachziehen
54 neue Texte (Regeln, Bluetooth-Sensoren, Webserver, MQTT-Abos, Excel) stehen
nur auf Deutsch im Katalog. Für alle 26 Sprachen: `Tools/l10n.py pack`,
füllen, `import`, `verify`. Dazu die zwei Kern-Texte aus `ScriptDecoders`.

## 6. Uhr auf echter Hardware bestätigen, dann ASC-Feedback aufräumen
Build 17 behebt den Absturz der Uhr („kackt immer ab“, Build 16). Erst wenn er
auf der Uhr bestätigt ist, die sieben Einträge in ASC löschen
(`DELETE /v1/betaFeedbackScreenshotSubmissions/{id}`).

## 7. Bluetooth-Decoder an echten Geräten prüfen
RuuviTag, BTHome, ATC/pvvx, Herzfrequenzgurt, Leistungsmesser, Laufsensor und
eine eigene Decoder-Datei — der Simulator hat kein Bluetooth.

## 8. Übersetzungen der neuen Texte
Rund 450 Texte seit der Analyse stehen nur auf Deutsch im Katalog (App, Uhr, `InfoPlist`):
Netzwerk, Funk, Route, Auswertung, Profile, Kurzbefehle, Weitere Quellen, Zweit-iPhone,
Ereignisaufnahme. Für alle 26 Sprachen: `Tools/l10n.py pack`, füllen, `import`, `verify`.
Dazu: die Siri-Sätze der Kurzbefehle (`AppShortcuts.xcstrings`) und die neuen Berechtigungstexte
(`NSHealthShareUsageDescription`, `NSHomeKitUsageDescription`, `NFCReaderUsageDescription`).

## 9. Nicht gebaut
- **Live Activity und Widget (S8).** Braucht ein eigenes Bundle (Erweiterung) mit eigener
  App-ID und eigenem Profil, dazu `ExportOptions-CI.plist` und `ensure_profiles.py`.
- **Fotogrammetrie mit Standbildern (M7).** `captureHighResolutionFrame` mit IMU-Auslöser; die
  Intrinsics des Standbilds weichen von denen der Videobilder ab, `cameras.csv` und der
  COLMAP-Export müssen sie je Bild führen.
- **UWB (I4)** — braucht den Austausch der Token über den Peripherie-Dienst, der nun steht.
- **Körper- und Handhaltung (I8)** — ARKit-Körper-Tracking ist eine eigene Konfiguration und
  schliesst das Weltmodell aus, das die Pose braucht.
- **Uhr mit 800 Hz (I10)** — der Transfer pro Probe als Wörterbuch trägt das nicht; es braucht
  ein binäres Paketformat wie in `PeerPayload`.
- **Staffelung in Free und Pro.** Die neuen Werkzeuge sind nicht hinter `ProAccess`; die
  Stufen der Analyse (Kapitel 8) sind nicht verdrahtet.
- **Multicast/Broadcast** (Wake-on-LAN) braucht die Apple-Berechtigung.

