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

### Vom Bündel zur texturierten Szene

```bash
# Terrain für den Aufnahmeort holen (swisstopo swissALTI3D, offene Daten)
python3 Tools/blender/fetch_swissalti3d.py <bündel> --radius 300

# Szene bauen: Kamera, Terrain, Videoprojektion
blender --background --python Tools/blender/build_scene.py -- <bündel> szene.blend ENU
```

Oder interaktiv über `File ▸ Import ▸ Sensorstorm Scene`. Die Projektion ist ein
`UV Project`-Modifier auf dem Terrain, Projektor ist die animierte Kamera — das Bild wird
also aus genau der Pose geworfen, aus der es aufgenommen wurde, und wandert beim Abspielen
mit. Das Material ist bewusst Emission: die Aufnahme trägt das Licht schon, das damals auf
die Strasse fiel.

Zwei Dinge, die dabei nicht funktionieren können und es auch nicht sollen. Kameraprojektion
kennt keine Verdeckung — was hinter einem Haus liegt, bekommt die Pixel des Hauses; auf
einem groben Terrain ohne Gebäude verschmiert eine Strassenaufnahme entsprechend. Und die
**Höhe über Grund ist nicht gemessen**: ARKit misst relativ zum Sessionstart, der Anker kommt
aus der GPS-Höhe, deren Vertikalgenauigkeit zweistellig in Metern liegt. Der Importer setzt
den Track deshalb auf das Terrain und addiert eine angegebene Augenhöhe (Standard 1.5 m) —
eine eingestandene Annahme statt einer unbrauchbaren Messung.

## Fälle: Schäden auf der Strasse dokumentieren

Der zweite Grund, mit dem Telefon durch eine Strasse zu laufen, ist nicht Messen, sondern
Festhalten. Eine **Begehung** ist ein Weg, ein **Fall** eine Schadenstelle darauf. Zu einem
Fall gehören beliebig viele Fotos und Clips, seine Position mitsamt der Abweichung, eine
Bewertung von **1 bis 10**, wie schlimm es ist, und — wenn die Stelle grösser ist als ein
Punkt — der markierte **Bereich**. Das ist der Tab „Fälle“.

Ein Schlagloch ist nicht ein Bild. Es ist eine Übersicht, eine Nahaufnahme, eines mit dem
Zollstock daneben und dreissig Sekunden Video darum herum — und all das ist **ein** Punkt auf
der Karte, nicht vier. Aufnahmen lassen sich später jederzeit ergänzen, beim zweiten Besuch
derselben Stelle.

```
Documents/Surveys/<uuid>/
  survey.json            die Begehung und jeder Fall darin
  <medien-uuid>.jpg      jedes Foto
  <medien-uuid>.mov      jeder Clip
```

### Wie genau ist die Position — und woher kommt sie

Die Frage, die eine Schadensmeldung brauchbar oder wertlos macht. GPS auf einer Strasse ist
ein Kreis, kein Punkt: zwischen Häusern sind ±10 m ein guter Tag. Deshalb steht bei jedem
Fall, woher seine Koordinate stammt, und die App zeigt es, statt es zu verstecken:

| Quelle | was sie bedeutet | Fehlerangabe |
|---|---|---|
| `gps` | ein einzelner Fix, aufgenommen beim ersten Foto | `horizontalAccuracy`, der Radius, den das Gerät für sich beansprucht |
| `averaged` | Mittel aus den Fixes von zehn Sekunden Stillstehen | `positionSpread` — wie weit die Fixes tatsächlich auseinanderlagen |
| `manual` | Nadel von Hand auf der Karte gesetzt | keine. Dafür `gpsLatitude`/`gpsLongitude` und `manualOffset`: was GPS gesagt hatte und wie weit die Nadel davon entfernt liegt |

Auf der Karte wird der Unsicherheitskreis massstäblich gezeichnet. Eine Nadel in einem 30-m-
Kreis ist eine andere Aussage als eine in einem 3-m-Kreis, und ohne den Kreis sehen die
beiden gleich aus.

**Mitteln** heisst: zehn Sekunden ruhig stehen, und die Fixes werden mit 1/Genauigkeit²
gewichtet gemittelt. Die ersten Fixes nach dem Aufwachen des Empfängers sind die schlechtesten;
sie gleich stark zählen zu lassen wie einen guten hiesse, den Grund fürs Mitteln wegzuwerfen.
Ausgegeben wird nicht die behauptete Genauigkeit, sondern die **gemessene Streuung** der
Fixes um ihren Mittelwert — die ehrlichere der beiden Zahlen, und meist die grössere.

**Die Nadel** ist die genaueste Quelle, obwohl sie keine Fehlerangabe hat. Wer vor dem Riss
steht, sieht auf dem Luftbild, um welche Fuge es geht; das Gerät sieht das nie. Darum liegt
die Karte im Nadel-Editor auf Satellitenbild, das Fadenkreuz steht fest und die Karte wandert
darunter — so verdeckt kein Finger das Ziel. Der GPS-Fix bleibt mit seinem Kreis sichtbar, der
Abstand wird laufend in Metern angezeigt, und **beide Positionen werden gespeichert**: eine
korrigierte Koordinate, die die Messung wegwirft, wäre weniger wert als jede der beiden für
sich, weil hinterher niemand mehr sagen könnte, ob die Nadel steht, wo der Empfänger sagte,
oder wo jemand entschied.

### Der Bereich

Zwei Formen, weil es im Feld zwei Situationen gibt. Vor der Stelle stehend ist ein Radius ein
Regler und drei Sekunden Arbeit; wenn die Form zählt, tippt man die Ecken auf der Karte an oder
läuft den Rand ab und setzt an jeder Ecke einen Punkt an der eigenen Position. Die Fläche wird
im lokalen metrischen System gerechnet (`Geodesy.enu`), nicht in Grad — die Schuhbandformel
direkt auf Längen- und Breitengraden läge in der Schweiz um ein Drittel daneben.

### Weiterverwenden

| Format | wofür |
|---|---|
| GeoJSON | QGIS, Leaflet, Mapbox — Punkte *und* Bereiche als Polygone |
| CSV | Tabelle oder Datenbank, WGS84 und LV95 nebeneinander |
| GPX | Wegpunkte, um dieselbe Stelle wiederzufinden |
| KML | Google Earth, nach Bewertung eingefärbt |
| Bündel | alle vier plus jedes Foto und jeden Clip, gezippt |

Quelle, Genauigkeit, Streuung, gemessener Fix und Versatz stehen in jedem Format, das Felder
dafür hat. Ein Kreis wird überall dort zum Ring, wo ein Polygon erwartet wird — GeoJSON und KML
sehen nur Polygone, damit auf der anderen Seite niemand zwei Fälle unterscheiden muss. GPX
bekommt keine Bereiche: das Format kennt keine Flächen, und ein geschlossener Track wäre ein
Weg, den nie jemand gegangen ist.

### Verhältnis zur Messaufnahme

Die Kamera für die Fälle ist bewusst nicht die des Messpfads. `VideoRecorder` existiert, um ein
Videobild auf dieselbe Uhr wie einen Beschleunigungswert zu legen, und zahlt dafür mit
`AVAssetWriter` und ohne Fotos; ein Fall will das Gegenteil: ein Foto in voller Qualität und
einen kurzen Clip mit Ton. Läuft gerade eine Messung mit Video, gehört die Kamera ihr — die App
sagt das, statt ein schwarzes Rechteck zu zeigen, und der Fall lässt sich trotzdem ohne Foto
erfassen. Wird eine Begehung während einer laufenden Aufnahme gestartet, merkt sich jeder Fall
deren ID und seine Host-Zeit; damit liegt das Foto einer Stelle auf derselben Uhr wie die
Sensordaten, die beim Darüberfahren entstanden. Nötig ist das nicht — eine Begehung braucht
keine Messung.

## Aufbau

```
Sources/SensorstormCore/   reine Logik, ohne UIKit: Speicherformat, Zeitbasis, Export
  Time/HostClock           die gemeinsame Uhr
  Storage/                 .ssbin-Format, Writer, Reader, Ablage auf der Platte
  Geo/                     WGS84/ECEF/ENU, LV95, ARKit→Blender, Yaw-Fit gegen GPS
  Export/                  CSV, Rohdaten, 3D-Szene, Sensor Logger, Gyroflow, GPX/KML
  Model/                   Aufnahme-Metadaten, Sensoren, Fälle und Begehungen
App/
  Recording/               Sensorquellen, Sink, Videoaufnahme, ARKit-Pose, Koordination
  Survey/                  Fälle: Kamera für Foto und Clip, Ortung, Modell
  UI/                      SwiftUI: Aufnehmen, Bibliothek, Wiedergabe mit Diagrammen
  UI/Survey/               Karte, Erfassung, Nadel- und Bereichseditor
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
