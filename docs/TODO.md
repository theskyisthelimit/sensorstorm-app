# TODO

Offene Punkte, noch nicht umgesetzt. Nur Notizen – keine Implementierung.

## 1. 3D-Modus überarbeiten
Der 3D-Modus ist in der aktuellen Form nicht gut. Die aus dem Video extrahierten
Bilder sind teilweise verschwommen. Der Ansatz muss grundsätzlich anders gelöst
werden (nicht nur nachbessern).

## 2. WLAN-Signalstärke anzeigen
Die WiFi-Signalstärke soll als Messwert anzeigbar sein.

## 3. Bluetooth aufräumen
Der Bluetooth-Teil ist ein Chaos und muss überarbeitet werden.

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
