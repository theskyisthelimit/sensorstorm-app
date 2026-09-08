#!/usr/bin/env python3
"""Create and maintain the in-app purchase `ch.sensorstorm.app.pro` in App Store Connect.

The sibling of `asc_metadata.py`, for the other half of the listing: the product that
sells. Same contract — idempotent, GET-then-PATCH-or-POST, and the repo is the source of
truth. The display texts come from `Tools/store/<locale>.json` (`iap.products`), the same
files the listing is pushed from, so a new language is one file and not one more place to
remember.

  export ASC_KEY_ID=... ASC_ISSUER_ID=...
  Tools/asc_iap.py --report          # what exists and what is still missing
  Tools/asc_iap.py --dry-run
  Tools/asc_iap.py                   # create/update everything except the screenshot
  Tools/asc_iap.py --screenshot screenshots-review/de/iphone_67/06-paywall.png
  Tools/asc_iap.py --capture-screenshot   # shoot the paywall in a simulator, then upload it

What this does *not* do, on purpose:

  * submit. A non-consumable is reviewed together with the app version, and pressing
    that button stays a human decision.
  * make it sellable. Nothing sells until the Paid Applications agreement is signed and
    the tax and banking forms are complete — see RELEASE.md. That is a form in the web
    UI with no API behind it.
"""
import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc import request, _SSL_CTX  # noqa: E402
import urllib.request  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP_ID = "6795648479"
PRODUCT_ID = "ch.sensorstorm.app.pro"

# The name only App Store Connect and we ever see. Kept identical to the display name so
# the two never drift into "which one is this again" in a list of products.
REFERENCE_NAME = "Sensorstorm Pro"

# Base territory for the price. Switzerland, because that is where the product is from and
# where the number was decided; App Store Connect derives every other storefront from it.
BASE_TERRITORY = "CHE"
BASE_PRICE = "19.00"

# Read by App Review, so English, and short. It answers the three things they check on a
# non-consumable: where it is, that it restores, and that nothing already paid for is
# taken away.
REVIEW_NOTE = (
    "Sensorstorm Pro is a one-time non-consumable unlock. No subscription, no account, "
    "no server of ours — StoreKit 2 checks the entitlement against the Apple Account.\n\n"
    "Where to find it: Settings tab > Sensorstorm Pro, or tap any padlock, for example "
    "Observations > a walk > Export > GeoJSON.\n\n"
    "Restore: \"Restore purchases\" on the same sheet (StoreKit AppStore.sync).\n\n"
    "It unlocks the professional formats and the two ceilings: 400 Hz motion sampling, 4K "
    "video, ARKit camera pose, raw and Blender and photogrammetry exports, combined "
    "CSV/JSON/SQLite, live streaming, more than one walk, and GeoJSON/GPX/KML for a walk. "
    "Recording itself and the CSV, GPX and KML exports stay free with or without the "
    "purchase — the app never locks anyone out of their own measurements."
)

STORE_DIR = ROOT / "Tools/store"

# App Store Connect's limits for an in-app purchase, and they are not the listing's.
NAME_LIMIT = 30
DESCRIPTION_LIMIT = 45

# Where `--capture-screenshot` puts the shot, matching `asc_capture_screenshots.REVIEW_DIR`.
PAYWALL_SHOT = ROOT / "screenshots-review/de/iphone_67/06-paywall.png"


def api(method: str, path: str, body=None, allow: tuple[int, ...] = ()) -> dict:
    status, raw = request(method, path, body)
    if status >= 400 and status not in allow:
        raise SystemExit(f"{method} {path} failed {status}: {raw}")
    return json.loads(raw) if raw else {}


def localized_copy() -> dict[str, dict[str, str]]:
    """locale -> {name, description}, from the store files. A locale whose product texts
    are still empty is skipped rather than pushed as a blank."""
    out: dict[str, dict[str, str]] = {}
    problems: list[str] = []
    for path in sorted(STORE_DIR.glob("*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        product = ((data.get("iap") or {}).get("products") or {}).get(PRODUCT_ID) or {}
        name, description = product.get("name", ""), product.get("description", "")
        if not name or not description:
            continue
        if len(name) > NAME_LIMIT:
            problems.append(f"{path.stem}: name {len(name)} > {NAME_LIMIT}")
        if len(description) > DESCRIPTION_LIMIT:
            problems.append(f"{path.stem}: description {len(description)} > {DESCRIPTION_LIMIT}")
        out[path.stem] = {"name": name, "description": description}
    if problems:
        raise SystemExit("in-app purchase copy exceeds App Store limits:\n  " + "\n  ".join(problems))
    if not out:
        raise SystemExit(f"no product texts for {PRODUCT_ID} in {STORE_DIR}")
    return out


def find_purchase() -> dict | None:
    data = api("GET", f"/v1/apps/{APP_ID}/inAppPurchasesV2?filter[productId]={PRODUCT_ID}&limit=10")
    for entry in data.get("data", []):
        if entry["attributes"].get("productId") == PRODUCT_ID:
            return entry
    return None


def ensure_purchase(dry_run: bool) -> dict | None:
    existing = find_purchase()
    if existing is None:
        print(f"create {PRODUCT_ID} (NON_CONSUMABLE, family sharable, all territories)")
        if dry_run:
            return None
        body = {"data": {
            "type": "inAppPurchases",
            "attributes": {
                "name": REFERENCE_NAME,
                "productId": PRODUCT_ID,
                "inAppPurchaseType": "NON_CONSUMABLE",
                "reviewNote": REVIEW_NOTE,
                # On, and it costs nothing: a household that shares one Apple Account
                # subscription tier shares this too, and the alternative is a support mail
                # about a purchase that "did not arrive" on the second phone.
                "familySharable": True,
            },
            "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}},
        }}
        created = api("POST", "/v2/inAppPurchases", body)
        return created["data"]

    attrs = existing["attributes"]
    changes = {}
    if attrs.get("name") != REFERENCE_NAME:
        changes["name"] = REFERENCE_NAME
    if attrs.get("reviewNote") != REVIEW_NOTE:
        changes["reviewNote"] = REVIEW_NOTE
    if not attrs.get("familySharable"):
        changes["familySharable"] = True
    if not changes:
        print(f"{PRODUCT_ID}: unchanged ({attrs.get('state')})")
        return existing
    print(f"update {PRODUCT_ID}: {', '.join(sorted(changes))}")
    if dry_run:
        return existing
    api("PATCH", f"/v2/inAppPurchases/{existing['id']}",
        {"data": {"type": "inAppPurchases", "id": existing["id"], "attributes": changes}})
    return existing


def ensure_localizations(iap_id: str, dry_run: bool) -> None:
    copy = localized_copy()
    data = api("GET", f"/v2/inAppPurchases/{iap_id}/inAppPurchaseLocalizations?limit=200")
    existing = {entry["attributes"]["locale"]: entry for entry in data.get("data", [])}

    for locale, texts in sorted(copy.items()):
        current = existing.get(locale)
        if current is None:
            print(f"  + {locale}: {texts['description']}")
            if dry_run:
                continue
            api("POST", "/v1/inAppPurchaseLocalizations", {"data": {
                "type": "inAppPurchaseLocalizations",
                "attributes": {"locale": locale, **texts},
                "relationships": {"inAppPurchaseV2": {
                    "data": {"type": "inAppPurchases", "id": iap_id}}},
            }})
            continue
        attrs = current["attributes"]
        changes = {k: v for k, v in texts.items() if attrs.get(k) != v}
        if not changes:
            continue
        print(f"  ~ {locale}: {', '.join(sorted(changes))}")
        if dry_run:
            continue
        api("PATCH", f"/v1/inAppPurchaseLocalizations/{current['id']}", {"data": {
            "type": "inAppPurchaseLocalizations", "id": current["id"], "attributes": changes}})

    stale = sorted(set(existing) - set(copy))
    if stale:
        print(f"  (left alone, no copy in {STORE_DIR.name}/: {', '.join(stale)})")


# Mainland China needs an ICP filing held by a Chinese legal entity, so the app is not
# offered there and neither is the purchase.
EXCLUDED_TERRITORIES = {"CHN"}


def ensure_availability(iap_id: str, dry_run: bool) -> None:
    """Where the purchase may be sold.

    Its own resource, not an attribute: App Store Connect models availability as a list of
    territories plus a standing answer for the ones Apple adds later. Without it the
    product stays in MISSING_METADATA no matter how complete the texts are."""
    current = api("GET", f"/v2/inAppPurchases/{iap_id}/inAppPurchaseAvailability", allow=(404,))
    if current.get("data"):
        print("availability: already set — not touched")
        return

    territories = [t["id"] for t in api("GET", "/v1/territories?limit=200").get("data", [])
                   if t["id"] not in EXCLUDED_TERRITORIES]
    print(f"availability: {len(territories)} territories, new ones included automatically"
          f" (without {', '.join(sorted(EXCLUDED_TERRITORIES))})")
    if dry_run:
        return
    api("POST", "/v1/inAppPurchaseAvailabilities", {"data": {
        "type": "inAppPurchaseAvailabilities",
        "attributes": {"availableInNewTerritories": True},
        "relationships": {
            "inAppPurchase": {"data": {"type": "inAppPurchases", "id": iap_id}},
            "availableTerritories": {
                "data": [{"type": "territories", "id": t} for t in territories]},
        },
    }})


def price_point_id(iap_id: str) -> str:
    """The price point for CHF 19 in Switzerland.

    Apple prices in points, not in numbers: a schedule refers to one of the app's own
    price points, and which ones exist depends on the territory. Looked up every run
    rather than pinned, because a pinned id is a silent wrong price the day Apple
    reshuffles the tiers."""
    path = (f"/v2/inAppPurchases/{iap_id}/pricePoints"
            f"?filter[territory]={BASE_TERRITORY}&limit=200")
    while path:
        data = api("GET", path)
        for point in data.get("data", []):
            # Numeric comparison: Apple writes CHF 19 as "19.0", and a string test against
            # "19.00" walks past the right tier into the fallback error.
            if float(point["attributes"].get("customerPrice", "nan")) == float(BASE_PRICE):
                return point["id"]
        path = data.get("links", {}).get("next", "")
    raise SystemExit(
        f"no {BASE_TERRITORY} price point at {BASE_PRICE} — Apple's tiers may have moved; "
        "list them with Tools/asc.py and pick the closest.")


def ensure_price(iap_id: str, dry_run: bool) -> None:
    current = api("GET", f"/v2/inAppPurchases/{iap_id}/iapPriceSchedule"
                         "?include=manualPrices&limit[manualPrices]=50", allow=(404,))
    for price in current.get("included", []):
        if price.get("type") != "inAppPurchasePrices":
            continue
        # An existing schedule is left alone: re-posting it would re-date the price, and a
        # price change is a decision, not a side effect of running a script.
        print(f"price: schedule already set (base {BASE_TERRITORY}) — not touched")
        return

    print(f"price: {BASE_TERRITORY} {BASE_PRICE}, every other storefront derived from it")
    if dry_run:
        return
    point_id = price_point_id(iap_id)
    api("POST", "/v1/inAppPurchasePriceSchedules", {
        "data": {
            "type": "inAppPurchasePriceSchedules",
            "relationships": {
                "inAppPurchase": {"data": {"type": "inAppPurchases", "id": iap_id}},
                "baseTerritory": {"data": {"type": "territories", "id": BASE_TERRITORY}},
                "manualPrices": {"data": [{"type": "inAppPurchasePrices", "id": "${price}"}]},
            },
        },
        "included": [{
            "type": "inAppPurchasePrices",
            "id": "${price}",
            # No startDate: in effect from now, which for an unreleased product means
            # from the day it goes on sale.
            "attributes": {"startDate": None, "endDate": None},
            "relationships": {"inAppPurchasePricePoint": {
                "data": {"type": "inAppPurchasePricePoints", "id": point_id}}},
        }],
    })


def capture_paywall() -> pathlib.Path:
    """Shoot the paywall in a simulator, in German, on the 6.9" iPhone.

    One shot, one device: App Review looks at the purchase, not at a device matrix."""
    print("==> capturing the paywall in the simulator ...")
    subprocess.run([
        sys.executable, str(ROOT / "Tools/asc_capture_screenshots.py"),
        "--screens", "paywall", "--langs", "de", "--devices", "iphone_67", "--keep-local",
    ], cwd=ROOT, check=True)
    if not PAYWALL_SHOT.exists():
        raise SystemExit(f"capture ran but {PAYWALL_SHOT} is not there")
    return PAYWALL_SHOT


def ensure_screenshot(iap_id: str, image: pathlib.Path, dry_run: bool) -> None:
    """Replace the review screenshot with this file. Same reserve/PUT/commit dance as the
    product page shots, one resource type over."""
    current = api("GET", f"/v2/inAppPurchases/{iap_id}/appStoreReviewScreenshot", allow=(404,))
    existing = current.get("data")

    print(f"review screenshot: {image.relative_to(ROOT)} ({image.stat().st_size} bytes)")
    if dry_run:
        return
    if existing:
        api("DELETE", f"/v1/inAppPurchaseAppStoreReviewScreenshots/{existing['id']}")

    data = image.read_bytes()
    reserved = api("POST", "/v1/inAppPurchaseAppStoreReviewScreenshots", {"data": {
        "type": "inAppPurchaseAppStoreReviewScreenshots",
        "attributes": {"fileName": image.name, "fileSize": len(data)},
        "relationships": {"inAppPurchaseV2": {"data": {"type": "inAppPurchases", "id": iap_id}}},
    }})["data"]

    for op in reserved["attributes"]["uploadOperations"]:
        chunk = data[op["offset"]:op["offset"] + op["length"]]
        req = urllib.request.Request(op["url"], data=chunk, method=op["method"])
        for header in op.get("requestHeaders", []):
            req.add_header(header["name"], header["value"])
        with urllib.request.urlopen(req, context=_SSL_CTX) as response:
            if response.status >= 400:
                raise SystemExit(f"screenshot PUT failed {response.status}")

    api("PATCH", f"/v1/inAppPurchaseAppStoreReviewScreenshots/{reserved['id']}", {"data": {
        "type": "inAppPurchaseAppStoreReviewScreenshots", "id": reserved["id"],
        "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()},
    }})


def report() -> int:
    """What exists, and what still blocks submission. Exit code 1 while anything is open,
    so it can gate a release script."""
    purchase = find_purchase()
    if purchase is None:
        print(f"✗ {PRODUCT_ID} does not exist yet — run this script without --report")
        return 1

    iap_id = purchase["id"]
    attrs = purchase["attributes"]
    print(f"{PRODUCT_ID} · {iap_id} · {attrs.get('state')}")
    print(f"  type            {attrs.get('inAppPurchaseType')}")
    print(f"  family sharable {attrs.get('familySharable')}")

    gaps: list[str] = []
    have = api("GET", f"/v2/inAppPurchases/{iap_id}/inAppPurchaseLocalizations?limit=200").get("data", [])
    locales = sorted(entry["attributes"]["locale"] for entry in have)
    print(f"  localizations   {len(locales)}: {', '.join(locales) or '—'}")
    for locale in sorted(set(localized_copy()) - set(locales)):
        gaps.append(f"localization missing: {locale}")

    schedule = api("GET", f"/v2/inAppPurchases/{iap_id}/iapPriceSchedule"
                          "?include=manualPrices&limit[manualPrices]=50", allow=(404,))
    prices = [x for x in schedule.get("included", []) if x.get("type") == "inAppPurchasePrices"]
    print(f"  price schedule  {'set' if prices else 'MISSING'}")
    if not prices:
        gaps.append("price schedule missing")

    availability = api("GET", f"/v2/inAppPurchases/{iap_id}/inAppPurchaseAvailability",
                       allow=(404,)).get("data")
    print(f"  availability    {'set' if availability else 'MISSING'}")
    if not availability:
        gaps.append("territory availability missing")

    shot = api("GET", f"/v2/inAppPurchases/{iap_id}/appStoreReviewScreenshot", allow=(404,)).get("data")
    state = (shot or {}).get("attributes", {}).get("assetDeliveryState", {}).get("state")
    print(f"  review shot     {state or 'MISSING'}")
    if not shot:
        gaps.append("App Review screenshot missing")

    if attrs.get("state") not in ("READY_TO_SUBMIT", "WAITING_FOR_REVIEW", "IN_REVIEW", "APPROVED"):
        gaps.append(f"state is {attrs.get('state')}")

    print()
    if not gaps:
        print("nothing missing — the purchase goes up with the version")
        return 0
    print("--- remaining gaps ---")
    for gap in gaps:
        print(f"  ✗ {gap}")
    return 1


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="print the writes without sending them")
    parser.add_argument("--report", action="store_true", help="only list what exists and what is missing")
    parser.add_argument("--screenshot", type=pathlib.Path, help="PNG to upload as the App Review screenshot")
    parser.add_argument("--capture-screenshot", action="store_true",
                        help="shoot the paywall in a simulator first, then upload that")
    args = parser.parse_args()

    if args.report:
        raise SystemExit(report())

    purchase = ensure_purchase(args.dry_run)
    if purchase is None:          # --dry-run before the product exists
        print("(dry run: nothing else can be resolved before the product exists)")
        return
    iap_id = purchase["id"]

    print("localizations:")
    ensure_localizations(iap_id, args.dry_run)
    ensure_availability(iap_id, args.dry_run)
    ensure_price(iap_id, args.dry_run)

    image = args.screenshot
    if args.capture_screenshot and not args.dry_run:
        image = capture_paywall()
    if image:
        ensure_screenshot(iap_id, image, args.dry_run)

    print()
    if args.dry_run:
        print("dry run — nothing was sent")
        return
    raise SystemExit(report())


if __name__ == "__main__":
    main()
