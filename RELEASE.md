# Release-Runbook

Feste Werte für diese App:

| | |
|---|---|
| Apple Team ID | `E3CQ6W7CY2` |
| Bundle ID | `ch.sensorstorm.app` (Portal-ID `YB5MVW8ZP5`) |
| App Store Connect App-ID | `6795648479` |
| Provisioning-Profil | `Sensorstorm CI Distribution` |
| ASC API Key | `F5T7U925KM`, Issuer `69a6de84-dfc7-47e3-e053-5b8c7c11a4d1` |
| TestFlight-Gruppe | `Intern` (`fafeb017-823d-43cd-aec4-46bde0cec150`), intern, `hasAccessToAllBuilds` |
| .p8 | `~/.appstoreconnect/private_keys/AuthKey_F5T7U925KM.p8` |
| CI-Signing | `~/.appstoreconnect/ci-signing/` — **team-weit geteilt, niemals löschen** |

Die Key-Variablen stehen nicht im Shell-Profil. Jedem Aufruf voranstellen:

```bash
export ASC_KEY_ID=F5T7U925KM ASC_ISSUER_ID=69a6de84-dfc7-47e3-e053-5b8c7c11a4d1
```

## Nach jeder grünen Iteration

```bash
swift test && xcodegen generate && xcodebuild -project Sensorstorm.xcodeproj -scheme Sensorstorm \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
git add -A && git commit && git push
```

## Vollständiger Release

Vor dem Hochzählen von `CURRENT_PROJECT_VERSION` prüfen, welche Build-Nummer ASC
schon kennt — `altool` weist ein Duplikat mit
`409 ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE` ab:

```bash
python3 Tools/asc.py GET '/v1/builds?filter[app]=6795648479&sort=-version&limit=1'
```

Dann `CURRENT_PROJECT_VERSION` in `project.yml` erhöhen und:

```bash
xcodegen generate
xcodebuild -scheme Sensorstorm -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/Sensorstorm.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" archive
bash Tools/publish_ios.sh build/Sensorstorm.xcarchive
```

Signiert wird erst beim Export, nicht beim Archivieren — dadurch braucht das
Archiv keine Xcode-Sitzung und kein Cloud-Autosigning.

Verarbeitung dauert 10–30 Minuten, danach ist der Build in TestFlight.

Die Gruppe `Intern` hat `hasAccessToAllBuilds`: jeder neue Build erscheint dort
automatisch, ohne Beta-Review und ohne weiteres Zutun. Nur die „Neuerungen“ pro
Build sind noch von Hand zu setzen:

```bash
python3 Tools/asc.py GET '/v1/builds/<BUILD_ID>/betaBuildLocalizations'
python3 Tools/asc.py POST /v1/betaBuildLocalizations whatsnew.json
```

Soll das Archiv im Organizer auftauchen, direkt dorthin archivieren:
`~/Library/Developer/Xcode/Archives/<JJJJ-MM-TT>/Sensorstorm <TT.MM.JJJJ, HH.MM>.xcarchive`.
Ein bestehendes `build/*.xcarchive` nie überschreiben — das kann das Archiv einer
parallelen Sitzung sein.

## Store-Metadaten

`Tools/asc_metadata.py` ist die Quelle der Wahrheit für den Listing-Text, nicht die
ASC-Weboberfläche. Idempotent, jeder Schreibvorgang ist ein GET-dann-PATCH-oder-POST.

```bash
python3 Tools/asc_metadata.py --dry-run
python3 Tools/asc_metadata.py
python3 Tools/asc_metadata.py --attach-build 3
```

## Bewusst nicht automatisiert

* **Einreichen zur Prüfung** — bleibt eine bewusste menschliche Handlung.
* **Preise und Verfügbarkeit** — einmalig in der Weboberfläche.

## Offen für 1.0.0

Stand: Build 1 ist hochgeladen, Listing-Text (de-DE, en-US, en-GB), Kategorien und
Content-Rights sind gesetzt. Es fehlen:

Braucht eine Entscheidung oder eine URL:

* **Support-URL** und **Datenschutz-URL** für alle drei Locales.
  `Tools/asc_metadata.py --support-url https://… --privacy-url https://…`
* **App-Review-Kontakt** (Name, Telefon, E-Mail) — ASC-Weboberfläche.
* **Preis und Verfügbarkeit** — ASC-Weboberfläche, einmalig.

Braucht noch Arbeit:

* **Screenshots.** `Tools/asc_capture_screenshots.py` ist noch die Homeshift-Fassung.
  Sie braucht die Launch-Hooks (`SS_FIXTURE` / `SS_SCREEN`) in der App plus eine
  `App/ScreenshotFixtures.swift`, die eine Beispielaufnahme einspielt — sonst zeigen
  die Bilder eine leere Bibliothek. Vorlage: `~/.claude/skills/ios-ship/assets/`.
* **Build anhängen**, sobald die Verarbeitung durch ist:
  `Tools/asc_metadata.py --attach-build 1`

Auf echter Hardware verifizieren — der Simulator hat davon nichts:

* Videoaufnahme samt Bild-zu-Sensor-Versatz (`video.startHostTime`)
* Barometer, Schrittzähler, echte IMU bei 200 und 400 Hz
* AirPods-Kopfbewegung
* GPS im Hintergrund bei gesperrtem Bildschirm
