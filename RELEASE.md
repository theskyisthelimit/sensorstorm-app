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

## Screenshots

```bash
python3 Tools/asc_capture_screenshots.py --langs de --devices iphone_67   # ein Durchgang
python3 Tools/asc_capture_screenshots.py                                  # alle Sprachen × Geräte
python3 Tools/asc_capture_screenshots.py --upload                         # schiessen und hochladen
```

Die Sprachen kommen aus `Resources/Localizable.xcstrings`, nicht aus dem Skript.
Eine Sprache dort ergänzen genügt. Die Inhalte stellt `App/ScreenshotFixtures.swift`,
gesteuert über `SS_FIXTURE` / `SS_TAB` / `SS_SCREEN` — dieselbe Begehung und dieselbe
Aufnahme aus festen UUIDs, damit acht Geräte in zwei Sprachen dieselben Zahlen zeigen.

## Website

`sensorstorm.bognar.net` liefert die zwei URLs, ohne die Apple die Einreichung ablehnt.

```bash
python3 web/build.py && python3 web/check.py
```

Cloudflare Pages, Projekt `sensorstorm-site` im Konto `pbognar@gmail.com`. `dist/` ist
nicht eingecheckt — dieselbe Abmachung wie beim `.xcodeproj`. Deployt wird mit dem
wrangler, der bei homeshift liegt und dort per OAuth angemeldet ist; ein API-Token braucht
es nicht:

```bash
python3 web/build.py
~/GitHub/homeshift-app/server/node_modules/.bin/wrangler pages deploy web/dist \
  --project-name sensorstorm-site --branch main --commit-dirty=true
```

Die eigene Domain hängt **nicht** am wrangler dieser Fassung (`pages domain` gibt es dort
nicht): `sensorstorm.bognar.net` einmalig im Cloudflare-Dashboard unter Pages →
`sensorstorm-site` → Custom domains eintragen. Der DNS-Eintrag entsteht dabei von selbst,
weil die Zone im selben Konto liegt. Bis dahin antwortet nur
`https://sensorstorm-site.pages.dev`.

Die `OWNER`-Angaben in `web/build.py` sind Name, Land und ein Postfach — dieselbe Form wie
bei homeshift.ch: verantwortlich ist eine erreichbare Adresse, nicht die Wohnadresse einer
Privatperson. `street` und `city` bleiben leer, solange es keine Firma zu nennen gibt.

Die drei URLs setzen:

```bash
python3 Tools/asc_metadata.py \
  --support-url https://sensorstorm.bognar.net/support.html \
  --privacy-url https://sensorstorm.bognar.net/datenschutz.html \
  --marketing-url https://sensorstorm.bognar.net/
```

## Monetarisierung

Ein einmaliger, nicht verbrauchbarer Kauf: **`ch.sensorstorm.app.pro`**. Kein Abo,
kein Server, kein Konto — StoreKit 2 prüft den Anspruch gegen den Apple-Account.

Lokal testen geht ohne ASC: das Schema lädt `Resources/Sensorstorm.storekit`
(in `project.yml` an die Run-Action gebunden, nicht an Archive). Im Simulator kaufen,
App löschen und neu installieren, „Wiederherstellen" drücken, und in den
StoreKit-Transaktionen zurückerstatten — **jede vorhandene Begehung muss danach
weiterhin lesbar und als CSV exportierbar sein.** Das ist die Zusage, auf der die
ganze Sperrlogik steht; `swift test --filter ProAccessTests` hält sie fest.

Angelegt wird der Kauf aus dem Repo, nicht in der Weboberfläche:

```bash
python3 Tools/asc_iap.py --report              # was existiert, was fehlt
python3 Tools/asc_iap.py                       # Produkt, elf Sprachen, Preis, Länder
python3 Tools/asc_iap.py --capture-screenshot  # Kaufblatt schiessen und hochladen
```

Der Review-Screenshot kommt aus der App selbst: `SS_SCREEN=paywall` öffnet das Kaufblatt,
und weil ein per `simctl` gestarteter Simulator keine StoreKit-Konfiguration kennt,
liefert `ScreenshotFixture.price` den Betrag, den auch `Resources/Sensorstorm.storekit`
und App Store Connect führen. Der Shot liegt in `screenshots-review/` und kann so nie in
einen Produktseiten-Upload geraten.

## Wenn altool „UPLOAD SUCCEEDED" sagt und nichts erscheint

Die Prüfung läuft zweimal: `altool` prüft lokal, App Store Connect prüft danach noch
einmal — und was dort scheitert, taucht in `/v1/builds` nie auf. Nachsehen:

```bash
python3 Tools/asc.py GET '/v1/apps/6795648479/buildUploads?limit=1'
```

Build 9 ist genau so verschwunden: `90683`, fehlendes `NSHealthUpdateUsageDescription` im
Bundle der Watch-App. Der Schlüssel ist Pflicht, sobald die HealthKit-Berechtigung im
Paket liegt, auch wenn nur gelesen wird.

## Bewusst nicht automatisiert

* **Einreichen zur Prüfung** — bleibt eine bewusste menschliche Handlung.
* **Der Preis der App selbst** und die Verträge dahinter — Weboberfläche, siehe unten.

## Offen für 1.0.0

**Zuerst, weil es am längsten dauert und alles andere wertlos macht:**

1. **Agreements, Tax, and Banking** in ASC. Ohne angenommenen
   Paid-Applications-Vertrag und vollständige Steuer- und Bankangaben ist der IAP
   auch nach der Freigabe unverkäuflich. Apple braucht dafür Tage bis Wochen.
2. **Apple Small Business Program** anmelden — 15 % statt 30 % Provision unter
   1 Mio. USD Jahresumsatz. Einmalig, wirkt ab dem Folgemonat.

Dazu in der Weboberfläche, weil es dort keine Schnittstelle gibt:

* **Custom domain** `sensorstorm.bognar.net` auf das Pages-Projekt legen (siehe oben).
  Bis dahin zeigen Datenschutz- und Support-URL — und der Link im Kaufblatt der App — auf
  eine Adresse, die nicht antwortet; Apple lehnt dafür ab.

Erledigt und im Repo festgehalten, nicht mehr von Hand zu tun:

* Der Kauf `ch.sensorstorm.app.pro` samt elf Sprachen, CHF 19 mit Basisland Schweiz,
  Familienfreigabe, 174 Länder und Review-Screenshot — `Tools/asc_iap.py`. Er wird
  *zusammen mit* der Version eingereicht, nicht davor.
* Altersfreigabe, Länderverfügbarkeit und App-Review-Kontakt — `Tools/asc_metadata.py`,
  die Antworten stehen dort als `AGE_RATING`, `EXCLUDED_TERRITORIES` und
  `REVIEW_CONTACT`.

**Die Watch-App wird mit eingereicht.** Sie ist ein eigenes Ziel mit eigenem Bundle
(`ch.sensorstorm.app.watchkitapp`), also braucht sie ein eigenes Provisioning-Profil und
eine eigene App-ID mit HealthKit — sonst schlägt die Signierung in
`Tools/publish_ios.sh` mit einem Profilfehler fehl, der nicht sagt, welches Ziel gemeint
ist. In ASC erscheint sie nicht als eigene App, aber der Fragebogen zur Altersfreigabe
und die Datenschutzangaben decken sie mit ab: gelesen wird nur die Herzfrequenz, und
geschrieben wird in „Health" nichts.

Aus dem Repo:

* `python3 web/build.py` → `wrangler pages deploy` (siehe oben), dann die drei URLs setzen.
* `python3 Tools/asc_capture_screenshots.py --upload`
* `python3 Tools/asc_metadata.py` (Listing, elf Locales)
* `python3 Tools/asc_metadata.py --attach-build <n>`, sobald die Verarbeitung durch ist
* `python3 Tools/asc_metadata.py --report-only` — listet auf, was noch blockiert.
  Ziel: „nothing missing — ready to submit".
* `python3 Tools/asc_iap.py --report` — dasselbe für den Kauf.

Auf echter Hardware verifizieren — der Simulator hat davon nichts:

* Videoaufnahme samt Bild-zu-Sensor-Versatz (`video.startHostTime`)
* Barometer, Schrittzähler, echte IMU bei 200 und 400 Hz
* AirPods-Kopfbewegung
* GPS im Hintergrund bei gesperrtem Bildschirm
* Der Kauf gegen die echte Sandbox, nicht nur gegen die `.storekit`-Datei
* Die englische Oberfläche samt der fünf Systemdialoge für Kamera, Mikrofon, Ort
  und Bewegung — die kommen aus `Resources/InfoPlist.xcstrings`, nicht aus dem
  String-Katalog, und sind die Stelle, an der eine Lokalisierung am sichtbarsten
  danebengeht
