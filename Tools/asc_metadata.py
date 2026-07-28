#!/usr/bin/env python3
"""Push the App Store listing metadata for Sensorstorm to App Store Connect.

Idempotent: every write is a GET-then-PATCH-or-POST, so running it twice changes
nothing. The listing copy lives in `LISTING` below — this file is the source of
truth for it, not the ASC web UI, so a future version starts from a diff instead
of from a blank text area.

Usage:
  export ASC_KEY_ID=... ASC_ISSUER_ID=...        # see Tools/asc.py
  Tools/asc_metadata.py --dry-run                # show what would change
  Tools/asc_metadata.py
  Tools/asc_metadata.py --support-url https://... --privacy-url https://...
  Tools/asc_metadata.py --attach-build 12        # point the version at a build

Deliberately NOT done here:
  * submitting for review — that stays a human decision;
  * price and territory availability — one-way-ish setup, better done once in
    the UI with the tax/banking forms in front of you;
  * in-app purchases — Sensorstorm 1.0.0 has none.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc import request  # noqa: E402

APP_ID = "6795648479"
PRIMARY_CATEGORY = "UTILITIES"
SECONDARY_CATEGORY = "PRODUCTIVITY"
VERSION_STRING = "1.0.0"

# App Store locale -> copy. The app ships de/en, so the listing covers the same
# two. German is the primary locale.
#
# Limits enforced below: subtitle <= 30 chars, keywords <= 100 *bytes*
# (accented and CJK characters cost more than one), promotionalText <= 170,
# description <= 4000.
LISTING: dict[str, dict[str, str]] = {
    "de-DE": {
        "name": "Sensorstorm: Sensor Logger",
        "subtitle": "Alle Sensoren aufzeichnen",
        "promotionalText": (
            "Video, GPS, Beschleunigung und Neigung gleichzeitig aufzeichnen — alles auf "
            "einer Uhr. Danach abspielen, scrubben, als CSV exportieren."
        ),
        "keywords": "Sensor,Logger,Messung,GPS,Gyroskop,Barometer,Kompass,IMU,CSV,Datenlogger",
        "description": """Sensorstorm zeichnet die Sensoren deines iPhones gleichzeitig auf — und spielt sie danach wieder ab.

Ein Tippen startet alles auf einmal: Beschleunigung, Drehrate, Orientierung, Magnetfeld, GPS, Barometer, Lautstärke, Schritte, Gerätezustand. Auf Wunsch dazu ein Video in 720p, 1080p oder 4K.

EINE UHR FÜR ALLES

Alle Ströme liegen auf derselben Zeitbasis wie die Videobilder. Ein Bild und der Beschleunigungswert dazu gehören exakt zusammen — ohne Nachkalibrieren, ohne Drift. Genau dafür gibt es diese App.

Die Bildstabilisierung bleibt bewusst aus: sie würde das Bild von den Bewegungsdaten entkoppeln und jede Auswertung, die beides verbindet, still verfälschen.

WIEDERGEBEN STATT NUR SAMMELN

Jede Aufnahme lässt sich abspielen. Video und Kurven laufen synchron, der Abspielkopf steht in jedem Diagramm an derselben Stelle, und daneben stehen die Zahlenwerte an genau diesem Zeitpunkt. Zoomen auf eine einzelne Sekunde, springen zu einer Markierung, Werte ablesen.

AUFGEZEICHNET WERDEN

• Beschleunigung, roh und sensorfusioniert
• Gravitation
• Drehrate, roh und kalibriert
• Orientierung als Roll/Pitch/Yaw und Quaternion
• Magnetfeld, roh und kalibriert
• Kompass, an Nordrichtung ausgerichtet
• Barometer: Luftdruck und relative Höhe
• GPS: Position, Höhe, Geschwindigkeit, Kurs, jeweils mit Genauigkeit
• Lautstärke in dBFS, Mittelwert und Spitze
• Video mit Ton, Vorder- oder Rückkamera
• Audioaufnahme ohne Video
• Schrittzähler, Batterie, Helligkeit, Netzwerk
• AirPods-Kopfbewegung
• Markierungen mit Zeitstempel und Text

Abtastrate wählbar von 10 bis 400 Hz.

EXPORT, DER SICH WEITERVERWENDEN LÄSST

Ein Export enthält pro Sensor eine CSV-Datei, dazu Video, Ton und die Metadaten — als ZIP. Jede Zeile trägt die Zeit seit Aufnahmebeginn und die Unix-Zeit, sodass eine Zeile in einer Datei exakt zur Zeile mit derselben Zeit in jeder anderen passt. Eine README im Archiv beschreibt jede Spalte und ihre Einheit. Wer die volle Auflösung will, exportiert die Rohdaten.

KEINE WOLKE

Alles bleibt auf dem Gerät. Kein Konto, kein Tracking, keine Analyse im Hintergrund. Aufnahmen verlassen das iPhone nur, wenn du sie exportierst.

Sensorstorm gibt es auf Deutsch und Englisch.""",
    },
    "en-US": {
        "name": "Sensorstorm: Sensor Logger",
        "subtitle": "Record every sensor at once",
        "promotionalText": (
            "Record video, GPS, acceleration and tilt at the same time — all on one clock. "
            "Then play it back, scrub it, export it as CSV."
        ),
        "keywords": "sensor,logger,recorder,GPS,gyroscope,barometer,compass,IMU,CSV,datalogger",
        "description": """Sensorstorm records your iPhone's sensors at the same time — and plays them back afterwards.

One tap starts all of it: acceleration, rotation rate, orientation, magnetic field, GPS, barometer, loudness, steps, device state. Plus video in 720p, 1080p or 4K if you want it.

ONE CLOCK FOR EVERYTHING

Every stream sits on the same time base as the video frames. A frame and the acceleration value that belongs to it line up exactly — no calibration step, no drift. That is the whole reason this app exists.

Video stabilisation stays off on purpose: it decouples the image from the motion data and would quietly invalidate any analysis that correlates the two.

PLAYBACK, NOT JUST COLLECTION

Every recording plays back. Video and curves run in sync, the playhead sits at the same instant in every chart, and the numeric values for that instant are printed right next to it. Zoom into a single second, jump to a marker, read off values.

WHAT GETS RECORDED

• Acceleration, raw and sensor-fused
• Gravity vector
• Rotation rate, raw and calibrated
• Orientation as roll/pitch/yaw and quaternion
• Magnetic field, raw and calibrated
• Compass, referenced to true north
• Barometer: pressure and relative altitude
• GPS: position, altitude, speed, course, each with its accuracy
• Loudness in dBFS, average and peak
• Video with audio, front or back camera
• Audio recording without video
• Pedometer, battery, brightness, network
• AirPods head motion
• Annotations with timestamp and text

Sample rate selectable from 10 to 400 Hz.

AN EXPORT YOU CAN ACTUALLY USE

An export contains one CSV per sensor, plus the video, the audio and the metadata — as a ZIP. Every row carries the time since the recording started and the Unix time, so a row in one file lines up exactly with the row at the same time in every other one. A README in the archive documents each column and its unit. If you want full fidelity, export the raw data instead.

NO CLOUD

Everything stays on the device. No account, no tracking, no background analytics. Recordings leave your iPhone only when you export them.

Sensorstorm is available in German and English.""",
    },
}

LIMITS = {"subtitle": 30, "promotionalText": 170, "description": 4000}


def check_limits() -> None:
    """Fail before touching the API, not halfway through it."""
    problems = []
    for locale, copy in LISTING.items():
        for field, limit in LIMITS.items():
            if len(copy.get(field, "")) > limit:
                problems.append(f"{locale}.{field}: {len(copy[field])} chars > {limit}")
        # Keywords are capped in *bytes*, and accented characters cost two.
        kw_bytes = len(copy.get("keywords", "").encode("utf-8"))
        if kw_bytes > 100:
            problems.append(f"{locale}.keywords: {kw_bytes} bytes > 100")
    if problems:
        raise SystemExit("copy exceeds App Store limits:\n  " + "\n  ".join(problems))


def get(path: str):
    status, raw = request("GET", path)
    if status >= 400:
        raise SystemExit(f"GET {path} failed {status}: {raw}")
    return json.loads(raw)


def write(method: str, path: str, body: dict, label: str, dry_run: bool) -> None:
    if dry_run:
        print(f"  [dry-run] {method} {path}  ({label})")
        return
    status, raw = request(method, path, body)
    if status >= 400:
        raise SystemExit(f"{method} {path} failed {status}: {raw}")
    print(f"  {label}")


def ios_version_id() -> str:
    data = get(f"/v1/apps/{APP_ID}/appStoreVersions?filter[platform]=IOS&limit=10")["data"]
    editable = [v for v in data if v["attributes"]["appStoreState"] == "PREPARE_FOR_SUBMISSION"]
    if not editable:
        raise SystemExit("no editable (PREPARE_FOR_SUBMISSION) iOS version on the app")
    return editable[0]["id"]


def app_info_id() -> str:
    data = get(f"/v1/apps/{APP_ID}/appInfos")["data"]
    editable = [i for i in data if i["attributes"]["state"] == "PREPARE_FOR_SUBMISSION"]
    if not editable:
        raise SystemExit("no editable appInfo on the app")
    return editable[0]["id"]


def sync_categories(info_id: str, dry_run: bool) -> None:
    print("categories")
    body = {"data": {
        "type": "appInfos", "id": info_id,
        "relationships": {
            "primaryCategory": {"data": {"type": "appCategories", "id": PRIMARY_CATEGORY}},
            "secondaryCategory": {"data": {"type": "appCategories", "id": SECONDARY_CATEGORY}},
        },
    }}
    write("PATCH", f"/v1/appInfos/{info_id}", body, f"{PRIMARY_CATEGORY} / {SECONDARY_CATEGORY}", dry_run)


def sync_content_rights(dry_run: bool) -> None:
    print("content rights")
    body = {"data": {"type": "apps", "id": APP_ID,
                     "attributes": {"contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"}}}
    write("PATCH", f"/v1/apps/{APP_ID}", body, "does not use third-party content", dry_run)


def sync_version(version_id: str, dry_run: bool) -> None:
    print("version")
    # ASC created the record as "1.0" while every uploaded build carries the
    # marketing version 1.0.0 from project.yml. They have to match or the build
    # cannot be attached.
    body = {"data": {"type": "appStoreVersions", "id": version_id,
                     "attributes": {"versionString": VERSION_STRING, "releaseType": "AFTER_APPROVAL"}}}
    write("PATCH", f"/v1/appStoreVersions/{version_id}", body, f"versionString {VERSION_STRING}", dry_run)


def sync_app_info_localizations(info_id: str, privacy_url: str | None, dry_run: bool) -> None:
    """name + subtitle + privacy policy URL. These live on the appInfo, not on
    the version, because they survive across versions."""
    print("app info localizations (name, subtitle, privacy URL)")
    existing = {loc["attributes"]["locale"]: loc["id"]
                for loc in get(f"/v1/appInfos/{info_id}/appInfoLocalizations?limit=50")["data"]}

    for locale, copy in LISTING.items():
        attrs = {"name": copy["name"], "subtitle": copy["subtitle"]}
        if privacy_url:
            attrs["privacyPolicyUrl"] = privacy_url
        if locale in existing:
            body = {"data": {"type": "appInfoLocalizations", "id": existing[locale], "attributes": attrs}}
            write("PATCH", f"/v1/appInfoLocalizations/{existing[locale]}", body, f"{locale} updated", dry_run)
        else:
            attrs["locale"] = locale
            body = {"data": {"type": "appInfoLocalizations", "attributes": attrs,
                             "relationships": {"appInfo": {"data": {"type": "appInfos", "id": info_id}}}}}
            write("POST", "/v1/appInfoLocalizations", body, f"{locale} created", dry_run)


def sync_version_localizations(version_id: str, support_url: str | None, marketing_url: str | None,
                               dry_run: bool) -> None:
    """description + keywords + promo text + support/marketing URL, per locale."""
    print("version localizations (description, keywords, promo text)")
    existing = {loc["attributes"]["locale"]: loc["id"]
                for loc in get(f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations?limit=50")["data"]}

    for locale, copy in LISTING.items():
        attrs = {
            "description": copy["description"],
            "keywords": copy["keywords"],
            "promotionalText": copy["promotionalText"],
        }
        # No "What's New" on a first release — Apple rejects the field there.
        if support_url:
            attrs["supportUrl"] = support_url
        if marketing_url:
            attrs["marketingUrl"] = marketing_url
        if locale in existing:
            body = {"data": {"type": "appStoreVersionLocalizations", "id": existing[locale], "attributes": attrs}}
            write("PATCH", f"/v1/appStoreVersionLocalizations/{existing[locale]}", body,
                  f"{locale} updated", dry_run)
        else:
            attrs["locale"] = locale
            body = {"data": {"type": "appStoreVersionLocalizations", "attributes": attrs,
                             "relationships": {"appStoreVersion": {
                                 "data": {"type": "appStoreVersions", "id": version_id}}}}}
            write("POST", "/v1/appStoreVersionLocalizations", body, f"{locale} created", dry_run)


def attach_build(version_id: str, build_number: str, dry_run: bool) -> None:
    print(f"build {build_number}")
    builds = get(f"/v1/builds?filter[app]={APP_ID}&limit=50"
                 "&fields[builds]=version,processingState,expired")["data"]
    match = [b for b in builds if b["attributes"]["version"] == build_number]
    if not match:
        raise SystemExit(f"build {build_number} not found on the app")
    build = match[0]
    if build["attributes"]["processingState"] != "VALID":
        raise SystemExit(f"build {build_number} is {build['attributes']['processingState']}, not VALID")
    body = {"data": {"type": "builds", "id": build["id"]}}
    write("PATCH", f"/v1/appStoreVersions/{version_id}/relationships/build", body,
          f"attached build {build_number} ({build['id']})", dry_run)


def report(version_id: str, info_id: str) -> None:
    """What still blocks 'Submit for Review'. Cheaper than reading the web UI's
    progressive error list, which only shows a few problems at a time."""
    print("\n--- remaining gaps ---")
    gaps = []

    for loc in get(f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations?limit=50")["data"]:
        a, locale = loc["attributes"], loc["attributes"]["locale"]
        for field in ("description", "keywords", "supportUrl"):
            if not a.get(field):
                gaps.append(f"{locale}: {field} missing")
        sets = get(f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets")["data"]
        if not sets:
            gaps.append(f"{locale}: no screenshots (run Tools/asc_capture_screenshots.py --upload)")
    for loc in get(f"/v1/appInfos/{info_id}/appInfoLocalizations?limit=50")["data"]:
        a, locale = loc["attributes"], loc["attributes"]["locale"]
        if not a.get("privacyPolicyUrl"):
            gaps.append(f"{locale}: privacyPolicyUrl missing")

    # A missing to-one relationship answers 200 with `data: null`, not 404 —
    # checking only the status code would report this as present.
    status, raw = request("GET", f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail")
    if status >= 400 or not json.loads(raw).get("data"):
        gaps.append("app review contact details missing (name, phone, email)")

    version = get(f"/v1/appStoreVersions/{version_id}"
                  "?fields[appStoreVersions]=versionString,appStoreState")["data"]
    print(f"version {version['attributes']['versionString']} · {version['attributes']['appStoreState']}")

    status, raw = request("GET", f"/v1/appStoreVersions/{version_id}/build")
    if status >= 400 or not json.loads(raw).get("data"):
        gaps.append("no build attached to the version")

    # RELEASE.md advertises this script as the source of truth for the age
    # rating, so report() has to actually check it rather than assume.
    status, raw = request("GET", f"/v1/appInfos/{info_id}/ageRatingDeclaration")
    if status >= 400 or not (json.loads(raw).get("data") or {}).get("attributes", {}).get("ageRatingOverrideV2"):
        gaps.append("age rating declaration not set")

    status, _ = request("GET", f"/v1/appPriceSchedules/{APP_ID}")
    if status >= 400:
        gaps.append("no price schedule (set the price in the ASC web UI)")
    status, raw = request("GET", f"/v1/apps/{APP_ID}/appAvailabilityV2")
    if status >= 400 or not json.loads(raw).get("data"):
        gaps.append("territory availability not configured (ASC web UI → Pricing and Availability)")

    if gaps:
        for gap in gaps:
            print(f"  ✗ {gap}")
    else:
        print("  nothing missing — ready to submit from the ASC web UI")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="print the writes without sending them")
    parser.add_argument("--support-url", help="support page URL (required by Apple)")
    parser.add_argument("--privacy-url", help="privacy policy URL (required by Apple)")
    parser.add_argument("--marketing-url", help="optional marketing page URL")
    parser.add_argument("--attach-build", help="build number (CFBundleVersion) to attach to the version")
    parser.add_argument("--report-only", action="store_true", help="only list what is still missing")
    args = parser.parse_args()

    check_limits()
    version_id = ios_version_id()
    info_id = app_info_id()
    print(f"app {APP_ID} · version {version_id} · appInfo {info_id}\n")

    if not args.report_only:
        sync_version(version_id, args.dry_run)
        sync_categories(info_id, args.dry_run)
        sync_content_rights(args.dry_run)
        sync_app_info_localizations(info_id, args.privacy_url, args.dry_run)
        sync_version_localizations(version_id, args.support_url, args.marketing_url, args.dry_run)
        if args.attach_build:
            attach_build(version_id, args.attach_build, args.dry_run)

    if not args.dry_run:
        report(version_id, info_id)


if __name__ == "__main__":
    main()
