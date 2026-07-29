# Sensorstorm

iOS-App, die die Sensoren des iPhones **gleichzeitig** aufzeichnet und danach wieder
abspielt — Video, GPS, Beschleunigung und Neigung auf einer gemeinsamen Uhr.

## Warum eine gemeinsame Uhr

Jeder Messwert wird mit `mach_absolute_time`-Sekunden gestempelt. Das ist dieselbe
Zeitbasis, die `CMLogItem.timestamp` benutzt und die die Capture-Session als
`synchronizationClock` führt. Darum liegen ein Videobild und der
Beschleunigungswert dazu ohne Umrechnung, ohne Kalibrierung und ohne Drift
aufeinander.

Deshalb schreibt die App das Video mit `AVAssetWriter` statt mit
`AVCaptureMovieFileOutput`: der Movie-File-Output sagt einem *dass* er gestartet
ist, nicht *wann*. Über den Writer sieht man den Präsentationszeitstempel jedes
einzelnen Sample-Buffers und kann den des ersten Bildes in die Metadaten schreiben.

Die Bildstabilisierung bleibt aus — sie entkoppelt das Bild von der IMU.

## Kamerapose: Bilder in einer 3D-Szene platzieren

Eine gemeinsame Uhr sagt, *wann* ein Bild aufgenommen wurde. Um es in Blender auf eine
3D-Karte zu legen, braucht es zusätzlich, *wo* die Kamera war, *wohin* sie schaute und mit
welcher *Brennweite*. Dafür gibt es einen zweiten Aufnahmemodus.

| | klassisch | ARKit |
|---|---|---|
| Kamera-Stack | `AVCaptureSession` | `ARWorldTrackingConfiguration` |
| Position | nur GPS, ±3–10 m | visuell-inertial, zentimetergenau |
| Blickrichtung | — | 6-DoF, driftfrei |
| Intrinsics | pro Bild | pro Bild |
| Video | horizontlagerichtig gedreht | **unrotiert**, damit die Intrinsics passen |

Der ARKit-Modus schreibt zu jedem gespeicherten Bild eine Probe in den Strom `cameraPose`.
Der Export als **3D-Szene** liefert daraus ein Bündel mit `frames.csv` (eine Zeile pro Bild:
Position in Metern, Orientierung, Brennweite, WGS84 und LV95), `scene.json`, dem Video und dem
GPS-Track als GPX/KML. [Tools/blender/sensorstorm_import.py](Tools/blender/sensorstorm_import.py)
liest das als Blender-Add-on ein und erzeugt eine animierte Kamera.

Die Anfangs-Nordausrichtung von ARKit stammt aus dem Magnetometer und kann einige Grad
danebenliegen, driftet danach aber nicht. Der Exporter korrigiert das mit einer einzigen
starren Yaw-Drehung gegen den GPS-Track und schreibt die verbleibende Unsicherheit nach
`scene.json` — eine kurze Aufnahme kann keine Nordrichtung festlegen, und das soll man sehen,
statt es zu raten.

**Achsen und Einheiten stehen in [docs/COORDINATES.md](docs/COORDINATES.md) und
[docs/UNITS.md](docs/UNITS.md).** Fünf Koordinatensysteme sind beteiligt, drei sehen gleich
aus, und zweimal drehen ist der häufigste Fehler in dieser Kette.

## Aufbau

```
Sources/SensorstormCore/   reine Logik, ohne UIKit: Speicherformat, Zeitbasis, Export
  Time/HostClock           die gemeinsame Uhr
  Storage/                 .ssbin-Format, Writer, Reader, Ablage auf der Platte
  Geo/                     WGS84/ECEF/ENU, LV95, ARKit→Blender, Yaw-Fit gegen GPS
  Export/                  CSV, Rohdaten, 3D-Szene, Sensor Logger, Gyroflow, GPX/KML
App/
  Recording/               Sensorquellen, Sink, Videoaufnahme, ARKit-Pose, Koordination
  UI/                      SwiftUI: Aufnehmen, Bibliothek, Wiedergabe mit Diagrammen
Tools/
  blender/                 Blender-Add-on plus Vertragsprüfung gegen den Swift-Exporter
  *.py, *.sh               Signieren, Hochladen, Store-Metadaten (siehe RELEASE.md)
docs/                      Koordinatensysteme und Einheiten
```

`Package.swift` ist ein lokales SPM-Paket, `project.yml` erzeugt via XcodeGen das
Xcode-Projekt. Das `.xcodeproj` ist **nicht** eingecheckt: es wird generiert, und
eine Änderung von Hand ginge beim nächsten `xcodegen generate` verloren.

## Speicherformat

Pro Sensor eine `.ssbin`-Datei mit 16-Byte-Kopf und Sätzen fester Grösse
(`float64` Zeit + n × `float64` Wert, little endian). Feste Satzgrösse heisst:
wahlfreier Zugriff ist reine Arithmetik — kein Index, kein Parsen. Genau das macht
das Scrubben einer halbstündigen 200-Hz-Aufnahme verzögerungsfrei.

Eine Aufnahme ist ein Ordner:

```
Documents/Recordings/<uuid>/
  metadata.json          Startzeit auf beiden Uhren, Streams, Video-Versatz
  annotations.json
  accelerometer.ssbin  gyroscope.ssbin  …
  video.mov | audio.m4a
```

## Entwickeln

```bash
swift test
xcodegen generate
xcodebuild -project Sensorstorm.xcodeproj -scheme Sensorstorm \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Der Blender-Importer und der Swift-Exporter sind in verschiedenen Sprachen und kein Compiler
sieht den anderen — Spaltenreihenfolge und JSON-Schlüssel hält nur Absprache zusammen. Der
Vertrag lässt sich gegen ein echtes Bündel prüfen:

```bash
SS_BUNDLE_OUT=/tmp/ss-bundle swift test --filter bundleContents
python3 Tools/blender/check_bundle.py /tmp/ss-bundle
```

Der Simulator hat weder IMU noch Barometer noch Kamera — und **kein ARKit**, der
Posenmodus lässt sich dort also nicht prüfen. `SyntheticSource` erzeugt
dort plausible Kurven für alle Sensoren, die keine echte Quelle liefern — sonst
liesse sich weder die Live-Ansicht noch die Wiedergabe ohne Gerät in der Hand
prüfen. Auf echter Hardware läuft sie nie.

Release: siehe [RELEASE.md](RELEASE.md).
