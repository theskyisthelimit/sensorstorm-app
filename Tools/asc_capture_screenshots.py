#!/usr/bin/env python3
"""Capture App Store screenshots across languages x screens x device sizes,
and optionally upload them straight to App Store Connect.

Same shape as the `aarestation-app` tool of the same name, driving Homeshift's
own launch hooks (`HS_FIXTURE` / `HS_TAB` / `HS_SCREEN`, see
`App/ScreenshotFixtures.swift`) plus simulator language launch args. One build is
installed on every target simulator — `TARGETED_DEVICE_FAMILY "1,2"` makes a
single .app run on iPhone and iPad.

`HS_FIXTURE=1` replaces the contents with the sample move on every launch, so
every language and every device shows the same boxes, counts and progress.

Languages are NOT hardcoded: they are read from the String Catalog
(`Resources/Localizable.xcstrings`) every run. Add a language there and it is
captured (and uploaded) next time, no script change needed.

Usage:
  Tools/asc_capture_screenshots.py                        # every language x device x screen
  Tools/asc_capture_screenshots.py --langs de             # just German
  Tools/asc_capture_screenshots.py --devices iphone_61    # just one device
  Tools/asc_capture_screenshots.py --screens overview,boxes
  Tools/asc_capture_screenshots.py --skip-build           # reuse the last build
  Tools/asc_capture_screenshots.py --settle 2            # give slower machines an extra beat
  Tools/asc_capture_screenshots.py --upload               # capture and upload in one pass
                                                          # (needs ASC_KEY_ID/ASC_ISSUER_ID,
                                                          # see Tools/asc.py)

`--upload` does not wait for the capture to finish. An App Store screenshot set is
one language on one device, so each set is handed to the upload pool the moment its
last screen is shot, while the simulators carry on with the next language. The
App Store Connect credentials are checked before the first screenshot, so a bad key
fails in seconds rather than after a full run. `--upload-only` still uploads whatever
is already in `screenshots/`.

Output: screenshots/<lang>/<device_key>/<NN>-<screen_key>.png

--- Extending ---
New screen:      add a case to `ScreenshotFixture.Screen` (or a tab), then an
                 entry in SCREENS below.
New device:      add an entry to DEVICES. The simulator must already exist
                 (`xcrun simctl create "<name>" "<device type>" "<runtime>"`).
New language:    add the translations to the String Catalog — nothing to touch
                 here. Add an APPLE_LOCALE_OVERRIDES entry only if the generic
                 "<lang>_<LANG>" guess is wrong for that language.
"""
import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

ROOT = pathlib.Path(__file__).resolve().parent.parent
BUNDLE_ID = "ch.homeshift.app"
APP_ID = "6790398450"  # ch.homeshift.app on App Store Connect
BUILD_SIMULATOR = "iPhone 17 Pro"  # any sim works for building; the app installs everywhere
DERIVED_DATA = ROOT / ".derived-data/homeshift"
APP_PATH = DERIVED_DATA / "Build/Products/Debug-iphonesimulator/Homeshift.app"
OUT_DIR = ROOT / "screenshots"
SOURCE_CATALOG = ROOT / "Resources/Localizable.xcstrings"

# key: (order, kind, value)
#   kind "tab"    -> HS_TAB=<value>    (a RootTab case)
#   kind "screen" -> HS_SCREEN=<value> (a ScreenshotFixture.Screen raw value)
SCREENS: dict[str, tuple[int, str, str]] = {
    "overview": (1, "tab", "overview"),
    "boxes":    (2, "tab", "boxes"),
    "items":    (3, "tab", "items"),
    "tasks":    (4, "tab", "tasks"),
    "storage":  (5, "screen", "storage"),
    "damages":  (6, "screen", "damages"),
    "export":   (7, "screen", "export"),
    "tour":     (8, "screen", "tour"),
    "help":     (9, "screen", "help"),
    "settings": (10, "tab", "settings"),
}

# key: (simulator name, screenshotDisplayType)
# Apple's display-type names keep the old diagonal naming: the 6.9" iPhone still
# uploads as APP_IPHONE_67, and the 13" iPad as APP_IPAD_PRO_3GEN_129.
DEVICES: dict[str, tuple[str, str]] = {
    "iphone_67": ("iPhone 17 Pro Max", "APP_IPHONE_67"),
    "iphone_65": ("iPhone 14 Plus", "APP_IPHONE_65"),
    "iphone_61": ("iPhone 17 Pro", "APP_IPHONE_61"),
    "ipad_129":  ("iPad Pro 13-inch (M5)", "APP_IPAD_PRO_3GEN_129"),
    "ipad_11":   ("iPad Pro 11-inch (M5)", "APP_IPAD_PRO_3GEN_11"),
}

# Only where the generic "<lang>_<LANG>" guess picks the wrong region for the
# simulator's AppleLocale. Homeshift is a Swiss product, so the German, French
# and Italian shots use the Swiss regional formats.
APPLE_LOCALE_OVERRIDES: dict[str, str] = {
    "de": "de_CH", "fr": "fr_CH", "it": "it_CH", "en": "en_GB",
}


def discover_languages() -> list[str]:
    """Every language the app ships, from the String Catalog — the single source
    of truth for which languages get captured.

    `sourceLanguage` (German) is added explicitly: source strings live in the
    catalog *keys*, so German has no `localizations` entry of its own and would
    otherwise be missing from the App Store's primary locale."""
    with open(SOURCE_CATALOG) as f:
        data = json.load(f)
    locales: set[str] = {data.get("sourceLanguage", "de")}
    for value in data["strings"].values():
        locales |= set(value.get("localizations", {}).keys())
    return sorted(locales)


def apple_locale_for(lang: str) -> str:
    return APPLE_LOCALE_OVERRIDES.get(lang, f"{lang}_{lang.upper()}")


_print_lock = threading.Lock()


def log(prefix: str, msg: str) -> None:
    with _print_lock:
        print(f"[{prefix}] {msg}", flush=True)


def sh(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw)


def _runtime_sort_key(runtime_id: str) -> tuple[int, ...]:
    """`com.apple.CoreSimulator.SimRuntime.iOS-26-5` -> (26, 5), for picking the
    newest runtime numerically (a string sort puts iOS-9 above iOS-26)."""
    tail = runtime_id.rsplit(".", 1)[-1]
    parts = [p for p in tail.split("-")[1:] if p.isdigit()]
    return tuple(int(p) for p in parts) or (0,)


def udid_for(device_name: str) -> str:
    """Newest-runtime simulator with this name.

    The same device name usually exists on every installed runtime (e.g. an
    "iPhone 17 Pro" on both iOS 26.5 and 27.0). Taking whichever one `simctl`
    happened to list first mixes OS versions across a capture run — different
    status bar metrics and system fonts in one App Store set — and can pick a
    runtime older than the SDK the app was just built against."""
    out = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "-j"],
        check=True, capture_output=True, text=True,
    ).stdout
    devices = json.loads(out)["devices"]
    candidates = [
        (_runtime_sort_key(runtime_id), d["udid"])
        for runtime_id, runtime_devices in devices.items()
        for d in runtime_devices
        if d["name"] == device_name
    ]
    if not candidates:
        raise SystemExit(
            f"Simulator '{device_name}' not found. Create it first:\n"
            f"  xcrun simctl create \"{device_name}\" \"<device type>\" \"<runtime>\""
        )
    return max(candidates)[1]


def boot(udid: str) -> None:
    result = subprocess.run(["xcrun", "simctl", "boot", udid], capture_output=True, text=True)
    if result.returncode != 0 and "Booted" not in result.stderr:
        raise SystemExit(f"boot failed: {result.stderr}")
    subprocess.run(["xcrun", "simctl", "bootstatus", udid], capture_output=True, text=True)


def fix_status_bar(udid: str) -> None:
    """Clean, locale-independent status bar. SpringBoard renders it, not the app,
    so -AppleLanguages/-AppleLocale never reach it — without this an iPad shows
    the host system's date next to the clock regardless of the app's language."""
    sh([
        "xcrun", "simctl", "status_bar", udid, "override",
        "--time", "9:41",
        "--dataNetwork", "wifi",
        "--wifiMode", "active",
        "--wifiBars", "3",
        "--batteryState", "charged",
        "--batteryLevel", "100",
    ])


def grant_permissions(udid: str) -> None:
    """Pre-grant camera and photos so no OS permission sheet can appear over a
    shot. Homeshift asks for both the moment a capture or scan screen opens."""
    for service in ("camera", "photos"):
        subprocess.run(
            ["xcrun", "simctl", "privacy", udid, "grant", service, BUNDLE_ID],
            capture_output=True, text=True,
        )


def build(destination_name: str) -> pathlib.Path:
    print(f"==> building ({destination_name}) ...")
    sh(["xcodegen", "generate"], cwd=ROOT)
    sh([
        "xcodebuild", "-quiet",
        "-project", "Homeshift.xcodeproj",
        "-scheme", "Homeshift",
        "-destination", f"platform=iOS Simulator,name={destination_name}",
        "-derivedDataPath", str(DERIVED_DATA),
        "CODE_SIGNING_ALLOWED=NO",
        "build",
    ], cwd=ROOT)
    if not APP_PATH.exists():
        raise SystemExit(f"build succeeded but {APP_PATH} not found")
    return APP_PATH


def ready_marker(udid: str) -> pathlib.Path:
    """Path to the readiness file the app writes once the target screen is up
    (`ScreenshotFixture.markReady`)."""
    out = sh(["xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data"]).stdout.strip()
    return pathlib.Path(out) / "Documents/screenshot-ready"


def wait_until_ready(marker: pathlib.Path, timeout: float, settle: float, device_key: str, label: str) -> None:
    """Poll for the readiness marker instead of sleeping a fixed amount.

    A cold start plus seeding the sample move varies by an order of magnitude
    across devices and machine load; a blind sleep either captures the white
    launch screen or wastes minutes over a full run."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if marker.exists():
            # The marker is written from `onAppear`, which runs a beat before the
            # first frame is composited — hence the short settle.
            time.sleep(settle)
            return
        time.sleep(0.25)
    raise SystemExit(
        f"[{device_key}] {label}: app did not become ready within {timeout:.0f}s "
        f"(no {marker}). Raise --timeout, or check that the build has "
        f"App/ScreenshotFixtures.swift."
    )


def capture_one(udid: str, screen_key: str, lang_key: str, out_path: pathlib.Path,
                settle: float, timeout: float, device_key: str) -> None:
    _, kind, value = SCREENS[screen_key]

    # A real cold start: `simctl launch` on a running app does nothing, and the
    # environment below would be silently ignored.
    subprocess.run(["xcrun", "simctl", "terminate", udid, BUNDLE_ID], capture_output=True)

    marker = ready_marker(udid)
    marker.unlink(missing_ok=True)

    env = os.environ.copy()
    env["SIMCTL_CHILD_HS_FIXTURE"] = "1"
    # Note the SIMCTL_CHILD_ prefix: `simctl launch <udid> <bundle> KEY=VALUE`
    # passes KEY=VALUE as argv, not as an environment variable, and the app would
    # quietly show its default screen instead.
    if kind == "tab":
        env["SIMCTL_CHILD_HS_TAB"] = value
    else:
        env["SIMCTL_CHILD_HS_SCREEN"] = value

    sh([
        "xcrun", "simctl", "launch", udid, BUNDLE_ID,
        "-AppleLanguages", f"({lang_key})",
        "-AppleLocale", apple_locale_for(lang_key),
    ], env=env)

    wait_until_ready(marker, timeout, settle, device_key, f"{lang_key}/{screen_key}")

    out_path.parent.mkdir(parents=True, exist_ok=True)
    sh(["xcrun", "simctl", "io", udid, "screenshot", str(out_path)])


def run_device(device_key: str, langs: list[str], screens: list[str], app_path: pathlib.Path,
               settle: float, timeout: float, skip_install: bool, total: int, counter: list[int],
               on_language_done=None) -> None:
    device_name, _display_type = DEVICES[device_key]
    udid = udid_for(device_name)
    log(device_key, f"booting {device_name} ({udid})")
    boot(udid)
    fix_status_bar(udid)
    if not skip_install:
        sh(["xcrun", "simctl", "install", udid, str(app_path)])
    grant_permissions(udid)

    for lang_key in langs:
        for screen_key in screens:
            order, _, _ = SCREENS[screen_key]
            out_path = OUT_DIR / lang_key / device_key / f"{order:02d}-{screen_key}.png"
            capture_one(udid, screen_key, lang_key, out_path, settle, timeout, device_key)
            with _print_lock:
                counter[0] += 1
                n = counter[0]
            log(device_key, f"{out_path.relative_to(ROOT)}  [{n}/{total}]")
        # This language x device folder is complete — an App Store screenshot set is
        # exactly that, so it can go up now instead of waiting for the other 190 shots.
        if on_language_done is not None:
            on_language_done(lang_key, device_key)


# --- App Store Connect upload -----------------------------------------------
# Imported lazily (only when --upload is used) so pyjwt/certifi are not needed
# for a plain capture run.

def _asc():
    sys.path.insert(0, str(ROOT / "Tools"))
    import asc
    import asc_upload_screenshots as up
    return asc, up


def fetch_version_locale_ids(asc) -> dict[str, str]:
    """locale -> appStoreVersionLocalization id for the current
    PREPARE_FOR_SUBMISSION iOS version. Looked up fresh every run, so this keeps
    working across versions."""
    status, raw = asc.request(
        "GET",
        f"/v1/apps/{APP_ID}/appStoreVersions"
        "?filter[platform]=IOS&filter[appVersionState]=PREPARE_FOR_SUBMISSION"
        "&fields[appStoreVersions]=versionString",
    )
    if status >= 400:
        raise SystemExit(f"could not find a PREPARE_FOR_SUBMISSION iOS version: {raw}")
    versions = json.loads(raw)["data"]
    if not versions:
        raise SystemExit("no PREPARE_FOR_SUBMISSION iOS version found on App Store Connect")
    version_id = versions[0]["id"]

    status, raw = asc.request(
        "GET",
        f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations"
        "?fields[appStoreVersionLocalizations]=locale&limit=50",
    )
    if status >= 400:
        raise SystemExit(f"could not list localizations: {raw}")
    return {loc["attributes"]["locale"]: loc["id"] for loc in json.loads(raw)["data"]}


def replace_screenshot_set(asc, up, localization_id: str, display_type: str,
                           files: list[pathlib.Path], file_workers: int = 6) -> None:
    set_id = up.create_set(localization_id, display_type)

    # Deletes are order-independent -> parallelize.
    status, raw = asc.request("GET", f"/v1/appScreenshotSets/{set_id}/appScreenshots")
    if status >= 400:
        raise SystemExit(f"could not list existing screenshots in set {set_id}: {raw}")
    existing = json.loads(raw)["data"]
    if existing:
        def delete_one(shot):
            code, body = asc.request("DELETE", f"/v1/appScreenshots/{shot['id']}")
            # A swallowed failure here leaves the old shot in the set and the run
            # still reports success — the set then ends up mixed old/new.
            if code >= 400:
                raise SystemExit(f"deleting old screenshot {shot['id']} failed {code}: {body}")
        with ThreadPoolExecutor(max_workers=file_workers) as pool:
            list(pool.map(delete_one, existing))

    # Display order is fixed by the order these POSTs land, so `reserve` stays a
    # sequential loop. The slow parts — the S3 PUT and the commit PATCH — do not
    # affect ordering once the resource exists, so those run in parallel.
    reserved = [(fp, up.reserve(set_id, str(fp))) for fp in files]

    def upload_one(item):
        fp, shot = item
        with open(fp, "rb") as f:
            data = f.read()
        up.upload_bytes(shot["attributes"]["uploadOperations"], data)
        up.commit(shot["id"], hashlib.md5(data).hexdigest())

    with ThreadPoolExecutor(max_workers=file_workers) as pool:
        list(pool.map(upload_one, reserved))


def matching_locales(locale_ids: dict[str, str], lang_key: str) -> list[str]:
    """App Store locales that serve one catalog language — `de` covers `de-DE`,
    and a language the current version does not offer matches nothing."""
    return [loc for loc in locale_ids if loc.split("-")[0].lower() == lang_key.lower()]


UPLOAD_ATTEMPTS = 3


def with_retries(label: str, work):
    """Retry one screenshot set through App Store Connect's transient failures.

    A 200-shot run reliably draws at least one bare `500 UNEXPECTED_ERROR` out of
    Apple. Every helper in `asc_upload_screenshots` raises `SystemExit` on a non-2xx,
    so the retry has to sit around the whole set — which is safe, because
    `replace_screenshot_set` clears the set before refilling it."""
    for attempt in range(1, UPLOAD_ATTEMPTS + 1):
        try:
            return work()
        except SystemExit as error:
            if attempt == UPLOAD_ATTEMPTS:
                raise
            delay = 2 ** attempt
            first_line = str(error).splitlines()[0]
            log(label, f"{first_line} — retrying in {delay}s ({attempt}/{UPLOAD_ATTEMPTS - 1})")
            time.sleep(delay)


def upload_device_set(asc, up, locale_ids: dict[str, str], lang_key: str, device_key: str) -> str | None:
    """Push one `screenshots/<lang>/<device>/` folder to every App Store locale that
    serves it. Returns the language key when something went up, else `None`."""
    _name, display_type = DEVICES[device_key]
    files = sorted((OUT_DIR / lang_key / device_key).glob("*.png"))
    if not files:
        return None
    locales = matching_locales(locale_ids, lang_key)
    if not locales:
        log(lang_key, "no matching App Store locale on the current version, skipping upload")
        return None
    for asc_locale in locales:
        label = f"{asc_locale} / {display_type}"
        log(lang_key, f"uploading {len(files)} shots -> {label}")
        with_retries(
            lang_key,
            lambda locale=asc_locale: replace_screenshot_set(
                asc, up, locale_ids[locale], display_type, files
            ),
        )
        log(lang_key, f"done -> {label}")
    return lang_key


def drain_uploads(futures) -> tuple[set[str], list[str]]:
    """Wait for every upload, letting the ones that work finish.

    A set that fails must not take its siblings with it: the first raised
    `SystemExit` used to reach `main` and kill the interpreter while eight other
    sets were still mid-flight, so a single 500 left the listing half-updated."""
    uploaded: set[str] = set()
    failures: list[str] = []
    for future in as_completed(futures):
        try:
            lang_key = future.result()
        except SystemExit as error:
            failures.append(str(error).splitlines()[0])
            continue
        if lang_key:
            uploaded.add(lang_key)
    return uploaded, failures


def upload_all(langs: list[str], devices: list[str], parallel: int = 4) -> set[str]:
    """Upload whatever is already on disk (the `--upload-only` path).

    Returns the language keys that were actually uploaded, so the caller only
    deletes those — a blanket `rmtree` also destroyed shots for languages that
    were skipped for having no matching App Store locale."""
    asc, up = _asc()
    locale_ids = fetch_version_locale_ids(asc)
    print(f"==> ASC locales on the current version: {sorted(locale_ids)}")

    # `devices`, not every entry in DEVICES — otherwise `--upload-only --devices …`
    # silently re-uploads all five sizes, which is the slow path when one set has to
    # be retried after a transient failure.
    jobs = [(lang_key, device_key) for lang_key in langs for device_key in devices]
    print(f"==> uploading up to {len(jobs)} screenshot set(s), {parallel} in parallel")

    with ThreadPoolExecutor(max_workers=parallel) as pool:
        futures = [pool.submit(upload_device_set, asc, up, locale_ids, lang, device)
                   for lang, device in jobs]
        uploaded, failures = drain_uploads(futures)
    report_upload_failures(failures)
    return uploaded


def report_upload_failures(failures: list[str]) -> None:
    if not failures:
        return
    raise SystemExit(
        f"{len(failures)} screenshot set(s) failed after {UPLOAD_ATTEMPTS} attempts:\n  "
        + "\n  ".join(failures)
        + "\nEverything else went up. Re-run with --upload-only to retry the rest."
    )


def main() -> None:
    available_langs = discover_languages()
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--langs", default=",".join(available_langs), help="comma-separated language codes (default: every language in the String Catalog)")
    parser.add_argument("--devices", default=",".join(DEVICES), help="comma-separated device keys")
    parser.add_argument("--screens", default=",".join(SCREENS), help="comma-separated screen keys")
    parser.add_argument("--settle", type=float, default=1.2, help="seconds to wait after the app reports readiness, before screenshotting")
    parser.add_argument("--timeout", type=float, default=60.0, help="seconds to wait for the app to report readiness after launch")
    parser.add_argument("--skip-build", action="store_true", help="reuse the existing build in .derived-data")
    parser.add_argument("--skip-install", action="store_true", help="assume the app is already installed on every target device")
    parser.add_argument("--parallel", type=int, default=3, help="how many devices to run concurrently (independent simulators)")
    parser.add_argument("--upload", action="store_true", help="after capturing, push straight to App Store Connect (needs ASC_KEY_ID/ASC_ISSUER_ID)")
    parser.add_argument("--upload-only", action="store_true", help="skip capture, just upload whatever is in screenshots/")
    parser.add_argument("--upload-parallel", type=int, default=4, help="how many screenshot sets (lang x device x ASC locale) to upload concurrently")
    parser.add_argument("--keep-local", action="store_true", help="don't delete screenshots/ after a successful upload")
    args = parser.parse_args()

    langs = args.langs.split(",")
    devices = args.devices.split(",")
    screens = sorted(args.screens.split(","), key=lambda k: SCREENS[k][0])

    for key in langs:
        if key not in available_langs:
            raise SystemExit(f"unknown language '{key}', known (from {SOURCE_CATALOG.relative_to(ROOT)}): {available_langs}")
    for key in devices:
        if key not in DEVICES:
            raise SystemExit(f"unknown device '{key}', known: {list(DEVICES)}")
    for key in screens:
        if key not in SCREENS:
            raise SystemExit(f"unknown screen '{key}', known: {list(SCREENS)}")

    uploaded: set[str] = set()

    if not args.upload_only:
        if args.skip_build:
            if not APP_PATH.exists():
                raise SystemExit(f"--skip-build but {APP_PATH} does not exist yet")
            app_path = APP_PATH
        else:
            app_path = build(BUILD_SIMULATOR)
        print(f"using build: {app_path}")

        # Resolved before the first screenshot on purpose: a bad key or a version
        # that is not PREPARE_FOR_SUBMISSION should fail in two seconds, not after
        # a full capture run.
        upload_pool = None
        upload_futures = []
        on_language_done = None
        if args.upload:
            asc, up = _asc()
            locale_ids = fetch_version_locale_ids(asc)
            print(f"==> ASC locales on the current version: {sorted(locale_ids)}")
            upload_pool = ThreadPoolExecutor(max_workers=args.upload_parallel)

            def on_language_done(lang_key: str, device_key: str) -> None:
                # Called from a capture thread the moment a set is complete, so the
                # upload of one device overlaps the capture of the next.
                future = upload_pool.submit(upload_device_set, asc, up, locale_ids, lang_key, device_key)
                with _print_lock:
                    upload_futures.append(future)

        total = len(langs) * len(devices) * len(screens)
        counter = [0]
        print(f"==> capturing {total} screenshots across {len(devices)} device(s), {args.parallel} in parallel"
              + (", uploading each set as it completes" if args.upload else ""))

        with ThreadPoolExecutor(max_workers=args.parallel) as pool:
            futures = {
                pool.submit(run_device, device_key, langs, screens, app_path, args.settle, args.timeout, args.skip_install, total, counter, on_language_done): device_key
                for device_key in devices
            }
            for future in as_completed(futures):
                device_key = futures[future]
                future.result()  # re-raises on failure
                log(device_key, "device done")

        print(f"done: {counter[0]} screenshots in {OUT_DIR.relative_to(ROOT)}/")

        if upload_pool is not None:
            # Most sets are long done by now; this only drains whatever the last
            # device handed over.
            print(f"==> waiting for {len(upload_futures)} upload(s) to finish ...")
            uploaded, failures = drain_uploads(upload_futures)
            upload_pool.shutdown()
            print("done: uploaded")
            report_upload_failures(failures)

    elif args.upload_only:
        print("==> uploading to App Store Connect ...")
        uploaded = upload_all(langs, devices, parallel=args.upload_parallel)
        print("done: uploaded")

    if uploaded and not args.keep_local:
        import shutil
        for lang_key in uploaded:
            shutil.rmtree(OUT_DIR / lang_key, ignore_errors=True)
        skipped = sorted(set(langs) - uploaded)
        print(f"cleaned up {len(uploaded)} uploaded language(s) in {OUT_DIR.relative_to(ROOT)}/")
        if skipped:
            print(f"kept (not uploaded): {', '.join(skipped)}")


if __name__ == "__main__":
    main()
