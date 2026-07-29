# Koordinatensysteme

Jeder Fehler, der ein Bild in Blender an die falsche Stelle legt, ist ein Achsenfehler. Nicht
weil die Umrechnung schwierig wäre, sondern weil fünf Systeme beteiligt sind, drei davon
gleich aussehen und keines sich selbst benennt. Dieses Dokument schreibt alle fünf hin.

Kurzfassung für Eilige: **der Exporter liefert bereits Blender-Konvention.** Wer ein
`frames.csv` liest, dreht nichts mehr. Zweimal drehen ist der häufigste Fehler überhaupt.

---

## 1. Gerätesystem (CoreMotion)

Das iPhone flach hingelegt, Bildschirm nach oben, Home-Kante unten:

| Achse | Richtung |
|-------|----------|
| +X | nach rechts (kurze Kante) |
| +Y | nach oben (lange Kante, Richtung Frontkamera) |
| +Z | aus dem Bildschirm heraus, zum Betrachter |

Rechtshändig. In diesem System liegen `accelerometer`, `gyroscope`, `magnetometer`,
`userAcceleration`, `gravity`, `rotationRate` und `magneticField`.

**Die Rückkamera schaut entlang −Z**, also in den Bildschirm hinein und hinten heraus. Das ist
kein Zufall und gleich wichtig: −Z ist auch die Blickrichtung einer Blender-Kamera und einer
ARKit-Kamera. Die drei Kamerakonventionen sind identisch, nur die *Weltsysteme* unterscheiden
sich.

## 2. Attitude-Referenzrahmen (CMAttitude)

Das Quaternion in `orientation` beschreibt die Lage des Geräts relativ zu einem Referenzrahmen.
Welcher das ist, entscheidet die App zur Laufzeit — und ohne diese Angabe ist der Gierwinkel
wertlos, weshalb sie in `metadata.json` als `attitudeReferenceFrame` landet.

| Wert | CoreMotion | Bedeutung |
|------|-----------|-----------|
| `trueNorth` | `.xTrueNorthZVertical` | +X zeigt nach geografisch Nord, +Z nach oben, +Y nach Westen. Gierwinkel ist ein Kompasskurs und über Aufnahmen hinweg vergleichbar. |
| `arbitraryCorrected` | `.xArbitraryCorrectedZVertical` | +Z nach oben, +X irgendwohin — dorthin, wo das Gerät beim Start zufällig zeigte. Innerhalb einer Aufnahme konsistent, zwischen zwei Aufnahmen bedeutungslos. |

`SensorHub` wählt `trueNorth`, sobald Standortfreigabe vorliegt
([SensorHub.swift](../App/Recording/SensorHub.swift), `motionSource.usesTrueNorthReference`).
Ohne Freigabe gibt es keinen True-North-Rahmen, also fällt CoreMotion auf den willkürlichen
zurück. Aufnahmen von Build 1 haben das Feld nicht — dort steht `null`, und das heisst *wir
wissen es nicht*, nicht *es war willkürlich*.

## 3. ARKit-Weltsystem

`ARWorldTrackingConfiguration` mit `worldAlignment = .gravityAndHeading`:

| Achse | Richtung |
|-------|----------|
| +X | Ost |
| +Y | oben (entgegen der Schwerkraft) |
| +Z | **Süd** |

Ungewohnt, aber rechtshändig: Ost × Oben = Süd. Der Ursprung liegt dort, wo die Session
gestartet wurde.

Die Nordausrichtung stammt beim Start aus dem Magnetometer und kann einige Grad danebenliegen.
Danach driftet sie **nicht** — die visuell-inertiale Odometrie hält sie fest. Genau deshalb
korrigiert der Exporter mit einer einzigen starren Yaw-Drehung gegen den GPS-Track
([CameraPose.swift](../Sources/SensorstormCore/Geo/CameraPose.swift), `TrajectoryAlignment`)
und nicht pro Bild.

## 4. Exportsystem (ENU)

Alles in `frames.csv` und `scene.json`:

| Achse | Richtung |
|-------|----------|
| +X | Ost |
| +Y | Nord |
| +Z | oben |

Meter, relativ zum Anker der Aufnahme (erster brauchbarer GPS-Fix, ≤ 50 m Genauigkeit). Das
ist zugleich Blenders Konvention für eine Z-up-Szene, weshalb der Importer nichts mehr dreht.

### Die Umrechnung ARKit → ENU

```
(x, y, z)_ARKit  →  (x, −z, y)_ENU
```

Das ist eine Drehung um **+90° um die Ostachse**, Determinante +1. Als Quaternion:
`simd_quatd(angle: .pi/2, axis: (1,0,0))`.

Probe:

| ARKit | bedeutet | → ENU | stimmt |
|-------|----------|-------|--------|
| (1, 0, 0) | Ost | (1, 0, 0) | Ost ✓ |
| (0, 1, 0) | oben | (0, 0, 1) | oben ✓ |
| (0, 0, 1) | Süd | (0, −1, 0) | Süd ✓ |

Das **kameralokale** System bleibt unangetastet, weil ARKit und Blender dort ohnehin
übereinstimmen. Es dreht sich nur die Welt:

```
R_Blender = R_fix · R_ARKit
```

Getestet in [GeodesyTests.swift](../Tests/SensorstormCoreTests/GeodesyTests.swift), inklusive
der Prüfung, dass Quaternion und Positions-Swizzle dasselbe tun — sonst landen Punkte und
Posen in zwei verschiedenen Welten.

## 5. Kameralokales System

Identisch in ARKit, Blender und diesem Export:

| Achse | Richtung |
|-------|----------|
| −Z | Blickrichtung |
| +Y | oben im Bild |
| +X | rechts im Bild |

Das Quaternion in `frames.csv` dreht **kameralokale Vektoren in die Welt**. Ein Vorwärtsvektor
prüft sich so:

```python
forward = quaternion.act((0, 0, -1))   # ergibt die Blickrichtung in ENU
```

### Quaternion-Reihenfolge

| Ort | Reihenfolge |
|-----|-------------|
| `frames.csv` (`qx,qy,qz,qw`) | **xyzw** |
| `simd_quatd.vector` | xyzw |
| Blender `obj.rotation_quaternion` | **wxyz** |

Der Importer sortiert beim Lesen um. Ein vertauschtes `w` normalisiert sich sauber und fällt
deshalb erst auf, wenn die Szene falsch aussieht — [check_bundle.py](../Tools/blender/check_bundle.py)
prüft die Reihenfolge direkt gegen die Datei.

---

## Geodäsie

### WGS84 → ECEF → ENU

Standardkette, implementiert in [Geodesy.swift](../Sources/SensorstormCore/Geo/Geodesy.swift).
Der Rückweg ECEF → geodätisch nutzt Bowrings geschlossene Lösung: millimetergenau und ohne
Konvergenzverhalten, über das man nachdenken müsste.

### WGS84 → LV95 (EPSG:2056)

Die swisstopo-Näherungsformeln, rund **1 m** genau in der Lage und 2 m in der Höhe.

Das ist Absicht, keine Schlamperei: ein Handy-GPS liefert bestenfalls ±3 m. Die exakte
CHENyx06-Gitterlösung würde Präzision hinzufügen, die die Eingabe nie hatte, und dafür eine
Datendatei mitschleppen.

Die Konstanten sind um die alte Berner Sternwarte herum geschrieben. Setzt man genau diesen
Punkt ein, fallen alle Terme ausser dem konstanten weg — das prüft
`lv95Origin()` in den Tests und pinnt damit jede Ziffer auf einmal.

`scene.json` führt `anchor.lv95IsInRange`. Die Projektion rechnet auch in Portugal fröhlich
weiter und liefert eine Zahl; das Flag sagt, ob man ihr glauben darf.

### Höhen — die eine Verwechslung, die alles schweben lässt

Zwei Höhen, überall parallel geführt:

| Feld | Bezug | Quelle |
|------|-------|--------|
| `alt_ellipsoidal`, `z_enu` | WGS84-Ellipsoid | `CLLocation.ellipsoidalAltitude` |
| `alt_msl`, `h_lv95` | Geoid (orthometrisch, ≈ Meereshöhe) | `CLLocation.altitude` |

In der Schweiz liegen dazwischen **46–52 m**. Genug, dass eine Szene sichtbar über dem Terrain
schwebt; wenig genug, dass es nach einem plausiblen GPS-Fehler aussieht.

Welche Karte welche will:

| Kartenquelle | Höhe |
|--------------|------|
| swisstopo swissALTI3D / swissBUILDINGS3D | orthometrisch (`h_lv95`) |
| Google 3D Tiles über Blosm | ellipsoidal (`z_enu`) |
| BlenderGIS / OSM | je nach geladenem Höhenmodell — meist orthometrisch |

Beispiel Bern, Ellipsoidhöhe 590 m: orthometrisch rund 540 m. Wer 590 auf swissALTI3D legt,
bekommt eine Kamera 50 m über dem Boden und wundert sich über die Perspektive.

---

## Kamera-Intrinsics

`fx`, `fy`, `cx`, `cy` in **Pixeln des gespeicherten Bildes**, pro Bild geschrieben — der
Autofokus verändert die Brennweite während der Aufnahme.

Nach Blender:

```
lens_mm  = fx · sensor_width / image_width      (sensor_width = 36 mm)
shift_x  = (cx − W/2) / max(W, H)
shift_y  = (H/2 − cy) / max(W, H)
```

`shift_y` dreht das Vorzeichen um, weil Bildkoordinaten nach unten wachsen und Blenders Shift
nach oben.

### Die Rotationsfalle

Der klassische Aufnahmepfad setzt `videoRotationAngle` auf der Capture-Connection, damit das
Video horizontlagerichtig gespeichert wird. Damit sind die **Pixel gedreht, die Intrinsics
aber nicht** — sie beschreiben weiterhin den Sensor.

Deshalb:

- `VideoInfo.appliedRotationAngle` hält den tatsächlich angewandten Winkel fest (zurückgelesen
  von der Connection, nicht angenommen).
- `VideoInfo.isSensorNative` ist nur `true` bei Winkel 0 und ohne Spiegelung.
- `null` heisst *unbekannt*, nicht *null Grad* — Aufnahmen aus Build 1 wurden ebenfalls
  gedreht, nur weiss niemand mehr um wie viel.

**Der ARKit-Pfad speichert das Video unrotiert.** Genau darum: `frame.camera.intrinsics`
beschreibt `capturedImage`, und jede Drehung auf dem Weg zur Datei würde jede Brennweite
stillschweigend entwerten. Die Anzeigerotation ist ein Wiedergabeproblem und bleibt in den
Metadaten.

---

## Was wo steht

| Datei | Inhalt |
|-------|--------|
| `frames.csv` | eine Zeile pro gespeichertem Videobild, ENU + Quaternion + Intrinsics + WGS84 + LV95 |
| `scene.json` | Anker, Achsenkonventionen im Klartext, Video-Geometrie, Qualität des Yaw-Fits |
| `track.gpx` / `track.kml` | GPS-Track, orthometrische Höhe (Konvention beider Formate) |
| `metadata.json` | die unveränderte Aufnahme-Metadatei |

Siehe [UNITS.md](UNITS.md) für die Einheiten je Sensorkanal.
