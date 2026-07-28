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

## Aufbau

```
Sources/SensorstormCore/   reine Logik, ohne UIKit: Speicherformat, Zeitbasis, Export
  Time/HostClock           die gemeinsame Uhr
  Storage/                 .ssbin-Format, Writer, Reader, Ablage auf der Platte
  Export/                  CSV-Bundle und ZIP
App/
  Recording/               Sensorquellen, Sink, Videoaufnahme, Koordination
  UI/                      SwiftUI: Aufnehmen, Bibliothek, Wiedergabe mit Diagrammen
Tools/                     Signieren, Hochladen, Store-Metadaten (siehe RELEASE.md)
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

Der Simulator hat weder IMU noch Barometer noch Kamera. `SyntheticSource` erzeugt
dort plausible Kurven für alle Sensoren, die keine echte Quelle liefern — sonst
liesse sich weder die Live-Ansicht noch die Wiedergabe ohne Gerät in der Hand
prüfen. Auf echter Hardware läuft sie nie.

Release: siehe [RELEASE.md](RELEASE.md).
