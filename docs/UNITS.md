# Einheiten

Massgeblich ist `SensorCatalog` in
[SensorID.swift](../Sources/SensorstormCore/Model/SensorID.swift) — dort stehen Kanäle und
Einheiten, und aus derselben Quelle schreibt der Exporter die CSV-Köpfe. Diese Tabelle ist die
lesbare Fassung davon, nicht eine zweite Wahrheit.

Achsen und Referenzrahmen: siehe [COORDINATES.md](COORDINATES.md).

## Zeit

Jede Datei trägt dieselbe Uhr.

| Spalte | Einheit | Bedeutung |
|--------|---------|-----------|
| `time` (CSV-Export) | s | Sekunden seit Aufnahmestart |
| `epoch` (CSV-Export) | s | Unix-Zeit UTC |
| `time` (Sensor-Logger-Export) | **ns** | Unix-Zeit in Nanosekunden, ganzzahlig |
| `host_time` (`frames.csv`) | s | rohe Host-Clock, `mach_absolute_time` in Sekunden |

Die Host-Clock ist der Grund, warum die App existiert: `CMLogItem.timestamp`,
`CMClockGetHostTimeClock()` und `ARFrame.timestamp` liegen alle darauf. Deshalb passen
Videobilder und IMU-Proben ohne Kalibrierschritt zusammen.

---

## Bewegung

| Sensor | Kanäle | Einheit | Anmerkung |
|--------|--------|---------|-----------|
| `accelerometer` | x, y, z | **g** | Roh, ungefiltert, inklusive Schwerkraft. Nicht m/s² — für SI mit 9.80665 multiplizieren. |
| `gyroscope` | x, y, z | rad/s | Roh, ungefiltert. |
| `magnetometer` | x, y, z | µT | Roh, **unkalibriert** — enthält den Geräteoffset. |
| `userAcceleration` | x, y, z | g | Fusioniert, Schwerkraft herausgerechnet. |
| `gravity` | x, y, z | g | Fusioniert, nur der Schwerkraftanteil. Betrag ≈ 1. |
| `rotationRate` | x, y, z | rad/s | Fusioniert, biasbereinigt. |
| `orientation` | roll, pitch, yaw | ° | Lage im Referenzrahmen aus `attitudeReferenceFrame`. |
| | qx, qy, qz, qw | — | Dasselbe als Quaternion, **xyzw**. Ohne Einheit. |
| `magneticField` | x, y, z | µT | Fusioniert, kalibriert. |
| | accuracy | — | `CMMagneticFieldCalibrationAccuracy`: −1 unkalibriert, 0 niedrig, 1 mittel, 2 hoch. |
| `headphoneOrientation` | roll, pitch, yaw | ° | AirPods, eigener Referenzrahmen — nicht mit dem des Geräts vergleichbar. |
| | ax, ay, az | g | Beschleunigung im Kopfhörersystem. |

Roh **und** fusioniert werden parallel aufgezeichnet. Für Auswertungen nimmt man die
fusionierten; die rohen sind für eigene Sensorfusion da.

## Position

| Sensor | Kanäle | Einheit | Anmerkung |
|--------|--------|---------|-----------|
| `location` | latitude, longitude | ° | WGS84. |
| | altitude | m | **Orthometrisch** (≈ Meereshöhe). |
| | ellipsoidalAltitude | m | **Ellipsoidisch** (WGS84). In der Schweiz 46–52 m höher als `altitude`. |
| | speed | m/s | Negativ, wenn ungültig. |
| | speedAccuracy | m/s | Negativ, wenn ungültig. |
| | course | ° | Kurs über Grund, 0 = Nord, im Uhrzeigersinn. Negativ, wenn ungültig. |
| | courseAccuracy | ° | Negativ, wenn ungültig. |
| | horizontalAccuracy | m | **Negativ heisst: kein Fix.** Der Exporter verwirft solche Zeilen, statt sie auf (0, 0) zu legen. |
| | verticalAccuracy | m | Negativ, wenn die Höhe ungültig ist. |
| `compass` | true | ° | Kurs zu geografisch Nord. |
| | magnetic | ° | Kurs zu magnetisch Nord. |
| | accuracy | ° | Negativ heisst unkalibriert. |

CoreLocation schreibt bei fehlendem Fix eine negative Genauigkeit statt eines Fehlers. Wer
darauf nicht prüft, bekommt Messpunkte im Golf von Guinea.

## Umgebung

| Sensor | Kanäle | Einheit | Anmerkung |
|--------|--------|---------|-----------|
| `barometer` | pressure | **kPa** | Nicht hPa/mbar — Apple liefert kPa. 101.325 kPa ist Normaldruck. |
| | relativeAltitude | m | Relativ zum Start der Aufzeichnung, nicht absolut. Kurzfristig deutlich genauer als GPS-Höhe. |

## Audio

| Sensor | Kanäle | Einheit | Anmerkung |
|--------|--------|---------|-----------|
| `loudness` | average, peak | dBFS | 0 dBFS ist Vollaussteuerung, alle Werte ≤ 0. Kein dB SPL — ohne kalibriertes Mikrofon gibt es keinen absoluten Schalldruck. |

## Aktivität

| Sensor | Kanäle | Einheit | Anmerkung |
|--------|--------|---------|-----------|
| `pedometer` | steps | — | Kumulativ seit Aufnahmestart. |
| | distance | m | Kumulativ, Schätzung. |
| | cadence | Schritte/s | |
| | pace | **s/m** | Sekunden pro Meter, nicht m/s. Der Kehrwert der Geschwindigkeit. |
| | floorsAscended, floorsDescended | — | Kumulative Stockwerke. |

Der Schrittzähler liefert `Date`-Zeitstempel statt Host-Clock-Werte und ist der einzige Strom,
der über den Wanduhr-Offset umgerechnet wird.

## Gerät

| Sensor | Kanäle | Einheit | Anmerkung |
|--------|--------|---------|-----------|
| `battery` | level | % | 0–100. `NaN` (leeres CSV-Feld), solange iOS den Stand nicht meldet. |
| | state | — | `UIDevice.BatteryState`: 0 unbekannt, 1 entladend, 2 ladend, 3 voll. |
| `brightness` | level | % | 0–100. |
| `network` | type | — | 0 keins, 1 WLAN, 2 Mobilfunk, 3 Kabel, 4 anderes. |
| | expensive, constrained | — | 0 oder 1. |

## Kamera

| Sensor | Kanäle | Einheit | Anmerkung |
|--------|--------|---------|-----------|
| `cameraPose` | px, py, pz | m | Position im Weltsystem der Aufnahme-Engine. **`NaN` im klassischen Pfad** — der kennt keine Pose. |
| | qx, qy, qz, qw | — | Orientierung, xyzw, kameralokal → Welt. `NaN` im klassischen Pfad. |
| | fx, fy, cx, cy | px | Pinhole-Intrinsics im gespeicherten Bild. Pro Bild, weil der Autofokus `fx` verändert. |
| | trackingState | — | 0 normal, 1 eingeschränkt, 2 nicht verfügbar. |
| | trackingReason | — | Nur bei 1: 1 Initialisierung, 2 zu viel Bewegung, 3 zu wenig Struktur, 4 Relokalisierung. |

Eine Probe pro gespeichertem Videobild. Dieser Strom ist nicht einzeln schaltbar — er folgt
aus der Kameraeinstellung ([`SensorID.engineControlled`](../Sources/SensorstormCore/Model/SensorID.swift)).

---

## Fehlende Werte

`NaN` in der Binärdatei, **leeres Feld** in jedem CSV-Export. Kein `0`, kein `-999`. Ein leeres
Feld liest `pandas` als `NaN`, und niemand rechnet versehentlich damit weiter.

Zahlen werden mit `%.12g` geschrieben: genug, um eine geografische Breite deutlich unter einen
Millimeter genau zurückzulesen, und knapp genug, um kein `0.30000000000000004` zu erzeugen.

## Abtastraten

Die eingestellte Rate (10–400 Hz) gilt für die Bewegungssensoren. GPS, Barometer, Schrittzähler
und die Gerätezustände liefern in ihrem eigenen Takt — im Katalog als `isEventDriven`
markiert.

Die tatsächlich erreichte Rate steht pro Strom in `metadata.json` als `effectiveRateHz`,
gemessen über die gesamte Aufnahme. Reale Abtastung ist nie gleichmässig; wer interpolieren
will, prüft vorher die Abstände auf Lücken.
