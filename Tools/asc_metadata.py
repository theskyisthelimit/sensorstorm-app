#!/usr/bin/env python3
"""Push the App Store listing metadata for Sensorstorm to App Store Connect.

Idempotent: every write is a GET-then-PATCH-or-POST, so running it twice changes
nothing. The listing copy lives in `Tools/store/<locale>.json`, one file per App
Store locale; those files are the source of truth, not the ASC web UI, so a
future version starts from a diff instead of from a blank text area.

Usage:
  export ASC_KEY_ID=... ASC_ISSUER_ID=...        # see Tools/asc.py
  Tools/asc_metadata.py --dry-run                # show what would change
  Tools/asc_metadata.py
  Tools/asc_metadata.py --support-url https://... --privacy-url https://...
  Tools/asc_metadata.py --attach-build 12        # point the version at a build

Also written from here: the age rating answers, the territory availability and the App
Review contact — all three are release decisions, so they belong in a diff rather than in
a web form nobody can review afterwards.

Deliberately NOT done here:
  * submitting for review — that stays a human decision;
  * the price of the app itself, and the Paid Applications agreement with its tax and
    banking forms. Nothing sells until those are signed — see RELEASE.md;
  * the in-app purchase. `Tools/asc_iap.py` is its sibling for `ch.sensorstorm.app.pro`;
    the purchase is reviewed *together with* the version.
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc import request  # noqa: E402

APP_ID = "6795648479"
PRIMARY_CATEGORY = "UTILITIES"
SECONDARY_CATEGORY = "PRODUCTIVITY"
VERSION_STRING = "1.0.0"

# App Store locale -> copy, gelesen aus `Tools/store/<locale>.json`.
#
# Eine Datei je Locale, und sie ist die Quelle: Name, Untertitel, Werbetext,
# Keywords, Beschreibung, „Neu in dieser Version“ und die Texte des In-App-Kaufs.
# `Tools/l10n.py` schreibt und prüft sie (`store-copy`, `sync`, `verify --surface
# store`); dieses Skript liest nur noch. Vorher standen dieselben Texte hier als
# Python-Literal, und jede neue Sprache hiess: ein Block mehr in dieser Datei.
#
# Nicht zh-Hans: seit 2023 verlangt der App Store auf dem chinesischen Festland
# eine ICP-Registrierung, die eine chinesische Rechtsperson halten muss.
#
# Grenzen unten geprüft: subtitle <= 30 Zeichen, keywords <= 100 *Bytes*
# (akzentuierte Zeichen kosten zwei, CJK drei), promotionalText <= 170,
# description <= 4000.

STORE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "store")
_LISTING_FIELDS = ("name", "subtitle", "promotionalText", "keywords", "description")


def _load_listing() -> dict[str, dict[str, str]]:
    if not os.path.isdir(STORE_DIR):
        sys.exit(f"{STORE_DIR} fehlt — ohne Store-Dateien gibt es nichts zu senden.")
    found: dict[str, dict[str, str]] = {}
    for name in sorted(os.listdir(STORE_DIR)):
        if not name.endswith(".json"):
            continue
        with open(os.path.join(STORE_DIR, name), encoding="utf-8") as handle:
            data = json.load(handle)
        copy = {field: data[field] for field in _LISTING_FIELDS if data.get(field)}
        if not copy.get("description"):
            continue          # eine angelegte, noch leere Sprache blockiert nichts
        found[name[:-len(".json")]] = copy
    if not found:
        sys.exit(f"{STORE_DIR} enthält kein Listing mit Beschreibung.")
    return found


LISTING: dict[str, dict[str, str]] = _load_listing()

LIMITS = {"subtitle": 30, "promotionalText": 170, "description": 4000}


def check_limits() -> None:
    """Fail before touching the API, not halfway through it."""
    problems = []
    for locale, copy in LISTING.items():
        for field, limit in LIMITS.items():
            if len(copy.get(field, "")) > limit:
                problems.append(f"{locale}.{field}: {len(copy[field])} chars > {limit}")
        # Keywords are capped in *bytes*: accented characters cost two, CJK three.
        kw_bytes = len(copy.get("keywords", "").encode("utf-8"))
        if kw_bytes > 100:
            problems.append(f"{locale}.keywords: {kw_bytes} bytes > 100")
        # A space after a comma is indexed as part of the next keyword and wastes a byte.
        if re.search(r",\s", copy.get("keywords", "")):
            problems.append(f"{locale}.keywords: whitespace after a comma")
        for word in wasted_keywords(copy):
            problems.append(f"{locale}.keywords: '{word}' is already in the name or subtitle")
    if problems:
        raise SystemExit("copy exceeds App Store limits:\n  " + "\n  ".join(problems))


def wasted_keywords(copy: dict[str, str]) -> list[str]:
    """Keywords that buy nothing because the field is not the only one indexed.

    Apple searches name, subtitle and keywords as a single bag of words, so a term
    repeated from the name is 100 bytes' worth of budget spent on nothing. Latin
    scripts are compared on a five-character stem because Apple stems too — plural
    'sensores' and singular 'sensor' are one term to the index. CJK has no word
    boundaries, so there a substring test is the only one that means anything.
    """
    bag = f"{copy['name']} {copy['subtitle']}".lower()
    wasted = []
    for keyword in copy.get("keywords", "").split(","):
        word = keyword.lower().strip()
        if not word:
            continue
        is_cjk = max(ord(ch) for ch in word) > 0x2E80
        if (is_cjk and word in bag) or (not is_cjk and len(word) >= 5 and word[:5] in bag):
            wasted.append(keyword)
    return wasted


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


# The App Review contact. Not a demo account — there is nothing to log into — just the
# human Apple calls when a review question comes up. Empty means "not decided yet", and
# `sync_review_details` then says so instead of inventing one.
REVIEW_CONTACT = {
    "contactFirstName": "Peter",
    "contactLastName": "Bognar",
    "contactPhone": "+41798005684",
    "contactEmail": "peter@bognar.net",
    "notes": (
        "Everything runs on the device: no account, no server of ours, no login. "
        "Grant the permission prompts (camera, microphone, motion, location) and press "
        "record to see live sensor data.\n\n"
        "In-app purchase: Sensorstorm Pro, one-time non-consumable. Settings tab > "
        "Sensorstorm Pro, or any padlock. Recording and CSV/GPX/KML export stay free.\n\n"
        "The Apple Watch app records heart rate and wrist motion while a recording runs on "
        "the iPhone. It reads HealthKit and writes nothing back."
    ),
}

# Mainland China needs an ICP filing that a Chinese legal entity has to hold, so the app is
# not offered there. Everything else Apple sells in, including territories added later.
EXCLUDED_TERRITORIES = {"CHN"}

# Every answer in the App Store's age rating questionnaire, as a value rather than as
# clicks in a web form — a rating is part of the release and belongs in the diff.
#
# All of it is "none": a sensor logger has no content. Health is the one worth saying out
# loud: the watch reads heart rate as a *measurement*, and the app gives no health advice,
# no treatment information and no wellness guidance, which is what these two ask about.
AGE_RATING = {
    "alcoholTobaccoOrDrugUseOrReferences": "NONE",
    "contests": "NONE",
    "gambling": False,
    "gamblingSimulated": "NONE",
    "gunsOrOtherWeapons": "NONE",
    "horrorOrFearThemes": "NONE",
    "matureOrSuggestiveThemes": "NONE",
    "medicalOrTreatmentInformation": "NONE",
    "healthOrWellnessTopics": False,
    "profanityOrCrudeHumor": "NONE",
    "sexualContentGraphicAndNudity": "NONE",
    "sexualContentOrNudity": "NONE",
    "violenceCartoonOrFantasy": "NONE",
    "violenceRealistic": "NONE",
    "violenceRealisticProlongedGraphicOrSadistic": "NONE",
    "advertising": False,
    "ageAssurance": False,
    "lootBox": False,
    "messagingAndChat": False,
    "parentalControls": False,
    "socialMedia": False,
    "unrestrictedWebAccess": False,
    "userGeneratedContent": False,
    # Not a kids-category app: the band stays empty, which is what keeps it out of Kids.
    "kidsAgeBand": None,
}


def sync_age_rating(info_id: str, dry_run: bool) -> None:
    print("age rating")
    body = {"data": {"type": "ageRatingDeclarations", "id": info_id, "attributes": AGE_RATING}}
    write("PATCH", f"/v1/ageRatingDeclarations/{info_id}", body, "no objectionable content (4+)", dry_run)


def sync_availability(dry_run: bool) -> None:
    """Where the app may be downloaded.

    Created once and then left alone: this is the resource that decides in which stores the
    app exists at all, and re-posting it on every metadata run would make a narrowing in the
    web UI silently snap back on the next release."""
    print("territory availability")
    status, raw = request("GET", f"/v1/apps/{APP_ID}/appAvailabilityV2")
    if status < 400 and json.loads(raw).get("data"):
        print("  already configured — not touched")
        return

    # Every territory has to appear, the excluded ones as `available: false`. Sending only
    # the wanted ones is rejected: Apple reads the list as the complete answer, not as a
    # selection.
    territories = [t["id"] for t in get("/v1/territories?limit=200")["data"]]
    body = {
        "data": {
            "type": "appAvailabilities",
            "attributes": {"availableInNewTerritories": True},
            "relationships": {
                "app": {"data": {"type": "apps", "id": APP_ID}},
                "territoryAvailabilities": {"data": [
                    {"type": "territoryAvailabilities", "id": f"${{t{i}}}"}
                    for i, _ in enumerate(territories)]},
            },
        },
        "included": [
            {"type": "territoryAvailabilities", "id": f"${{t{i}}}",
             "attributes": {"available": code not in EXCLUDED_TERRITORIES},
             "relationships": {"territory": {"data": {"type": "territories", "id": code}}}}
            for i, code in enumerate(territories)
        ],
    }
    available = len(territories) - len(EXCLUDED_TERRITORIES & set(territories))
    write("POST", "/v2/appAvailabilities", body,
          f"{available} territories, without {', '.join(sorted(EXCLUDED_TERRITORIES))}", dry_run)


def sync_review_details(version_id: str, dry_run: bool) -> None:
    print("app review contact")
    if not REVIEW_CONTACT["contactPhone"] or not REVIEW_CONTACT["contactEmail"]:
        print("  skipped — fill REVIEW_CONTACT in this file (phone and e-mail are required)")
        return

    attrs = {k: v for k, v in REVIEW_CONTACT.items()}
    attrs["demoAccountRequired"] = False
    status, raw = request("GET", f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail")
    existing = json.loads(raw).get("data") if status < 400 else None
    if existing:
        body = {"data": {"type": "appStoreReviewDetails", "id": existing["id"], "attributes": attrs}}
        write("PATCH", f"/v1/appStoreReviewDetails/{existing['id']}", body, "updated", dry_run)
        return
    body = {"data": {"type": "appStoreReviewDetails", "attributes": attrs,
                     "relationships": {"appStoreVersion": {
                         "data": {"type": "appStoreVersions", "id": version_id}}}}}
    write("POST", "/v1/appStoreReviewDetails", body, "created", dry_run)


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
        sync_age_rating(info_id, args.dry_run)
        sync_availability(args.dry_run)
        sync_review_details(version_id, args.dry_run)
        if args.attach_build:
            attach_build(version_id, args.attach_build, args.dry_run)

    if not args.dry_run:
        report(version_id, info_id)


if __name__ == "__main__":
    main()
