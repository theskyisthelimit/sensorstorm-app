#!/usr/bin/env python3
"""Build the sensorstorm.ch site into `dist/`.

Same arrangement as the Xcode project: the generator is checked in, the output is
not. Editing a generated `dist/index.html` by hand would be lost on the next run,
and the SEO boilerplate — canonical, hreflang pairs, Open Graph, JSON-LD — is
exactly the kind of thing that rots when it is copied into ten files by hand.

    python3 web/build.py            # -> web/dist/
    python3 -m http.server -d web/dist 8000

Cloudflare Pages: build command `python3 build.py`, root `web`, output `dist`.

Two of these pages are not optional decoration. Apple refuses the submission
without a privacy policy URL and a support URL, and `Tools/asc_metadata.py`
takes both as flags.
"""
import html
import pathlib
import re
import shutil
import sys

# --- Things only the owner can fill in ---------------------------------------------
# Everything here is placeholder text. The site builds and is fully checkable
# without it, but the imprint is a legal requirement in DE/AT and the support
# address is what App Store Review writes to. Grep for TODO before going live.

OWNER = {
    "legal_name": "TODO Name oder Firma",
    "street": "TODO Strasse und Nummer",
    "city": "TODO PLZ und Ort",
    "country_de": "Schweiz",
    "country_en": "Switzerland",
    "email": "TODO@sensorstorm.ch",
    "uid": "",           # optional: CHE-xxx.xxx.xxx
}

DOMAIN = "https://sensorstorm.ch"
APP_ID = "6795648479"
APP_STORE_URL = f"https://apps.apple.com/app/id{APP_ID}"
GITHUB_URL = "https://github.com/theskyisthelimit/sensorstorm-app"
UPDATED = "2026-09-06"

ACCENT = "#4ac7f0"   # Theme.accent from the app, so the two look like one product

# --- Page graph ---------------------------------------------------------------------
# Each entry pairs the German page with its English counterpart. The pairing is what
# makes hreflang correct: a one-sided alternate is worse than none, because it tells
# a crawler a translation exists at a URL that does not answer.

PAIRS = [
    ("index.html", "en/index.html"),
    ("beobachtungen.html", "en/observations.html"),
    ("datenschutz.html", "en/privacy.html"),
    ("support.html", "en/support.html"),
    ("impressum.html", "en/legal.html"),
]
ALTERNATE = {de: en for de, en in PAIRS} | {en: de for de, en in PAIRS}

NAV = {
    "de": [("index.html", "Übersicht"), ("beobachtungen.html", "Beobachtungen"),
           ("support.html", "Support"), ("datenschutz.html", "Datenschutz"),
           ("impressum.html", "Impressum")],
    "en": [("en/index.html", "Overview"), ("en/observations.html", "Observations"),
           ("en/support.html", "Support"), ("en/privacy.html", "Privacy"),
           ("en/legal.html", "Legal notice")],
}

STRINGS = {
    "de": {
        "skip": "Zum Inhalt",
        "store": "Im App Store laden",
        "switch": "English",
        "footer": f"Sensorstorm ist ein Schweizer Einzelprojekt. Quellcode auf "
                  f'<a href="{GITHUB_URL}">GitHub</a>.',
        "updated": "Stand",
    },
    "en": {
        "skip": "Skip to content",
        "store": "Get it on the App Store",
        "switch": "Deutsch",
        "footer": f"Sensorstorm is a one-person project from Switzerland. Source on "
                  f'<a href="{GITHUB_URL}">GitHub</a>.',
        "updated": "Last updated",
    },
}


def depth_prefix(path: str) -> str:
    """`en/observations.html` has to reach `index.html` as `../index.html`."""
    return "../" * path.count("/")


STYLE = """
:root {
  --bg: #0b0d0f;
  --panel: #14181b;
  --border: #262d31;
  --text: #e9eef1;
  --muted: #97a3aa;
  --accent: ACCENT;
  --max: 46rem;
}
* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; }
body {
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font: 16px/1.65 -apple-system, BlinkMacSystemFont, "Segoe UI", Inter, Roboto,
        Helvetica, Arial, sans-serif;
  padding: 0 1.25rem 4rem;
}
.skip { position: absolute; left: -9999px; }
.skip:focus { left: 1rem; top: 1rem; position: fixed; background: var(--accent);
              color: #000; padding: .6rem 1rem; border-radius: 8px; z-index: 10; }
header, main, footer { max-width: var(--max); margin: 0 auto; }
header { display: flex; flex-wrap: wrap; gap: .75rem 1.25rem; align-items: baseline;
         padding: 1.75rem 0 1.25rem; border-bottom: 1px solid var(--border); }
.brand { font-weight: 700; font-size: 1.05rem; letter-spacing: -.01em;
         color: var(--text); text-decoration: none; }
nav { display: flex; flex-wrap: wrap; gap: .25rem 1rem; margin-left: auto;
      font-size: .875rem; }
nav a { color: var(--muted); text-decoration: none; }
nav a:hover, nav a:focus { color: var(--text); }
nav a[aria-current="page"] { color: var(--accent); }
main { padding-top: 2.25rem; }
h1 { font-size: clamp(1.7rem, 5vw, 2.4rem); line-height: 1.18; letter-spacing: -.02em;
     margin: 0 0 .75rem; }
h2 { font-size: 1.3rem; letter-spacing: -.01em; margin: 2.5rem 0 .6rem; }
h3 { font-size: 1.02rem; margin: 1.75rem 0 .4rem; }
p, li { color: #d3dbe0; }
.lede { font-size: 1.12rem; color: var(--text); }
a { color: var(--accent); }
ul { padding-left: 1.15rem; }
li { margin: .3rem 0; }
code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
       font-size: .9em; background: var(--panel); border: 1px solid var(--border);
       border-radius: 5px; padding: .1em .35em; }
.cta { display: inline-block; background: var(--accent); color: #000;
       font-weight: 600; text-decoration: none; padding: .7rem 1.15rem;
       border-radius: 10px; margin: 1.25rem 0 .5rem; }
.card { background: var(--panel); border: 1px solid var(--border);
        border-radius: 14px; padding: 1.1rem 1.25rem; margin: 1rem 0; }
.card h3 { margin-top: 0; }
.muted { color: var(--muted); font-size: .9rem; }
.table-wrap { overflow-x: auto; margin: 1rem 0; }
table { border-collapse: collapse; width: 100%; font-size: .93rem; }
th, td { text-align: left; padding: .5rem .7rem; border-bottom: 1px solid var(--border);
         vertical-align: top; }
th { color: var(--muted); font-weight: 600; }
footer { margin-top: 3.5rem; padding-top: 1.25rem; border-top: 1px solid var(--border);
         color: var(--muted); font-size: .875rem; }
footer a { color: var(--muted); }
:focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; }
@media (prefers-reduced-motion: no-preference) { html { scroll-behavior: smooth; } }
""".replace("ACCENT", ACCENT)


def json_ld(lang: str) -> str:
    name = "Sensorstorm: Sensor Logger"
    desc = {
        "de": "iOS-App, die alle iPhone-Sensoren gleichzeitig auf einer gemeinsamen Uhr "
              "aufzeichnet und Strassenschäden mit ausgewiesener Lagegenauigkeit dokumentiert.",
        "en": "iOS app that records every iPhone sensor at once on one shared clock and "
              "documents road damage with stated positional accuracy.",
    }[lang]
    offer = {
        "de": "Gratis mit optionalem einmaligem In-App-Kauf (Sensorstorm Pro).",
        "en": "Free, with an optional one-time in-app purchase (Sensorstorm Pro).",
    }[lang]
    # No aggregateRating: there are no ratings yet, and inventing structured data is
    # the one SEO mistake that gets a manual penalty rather than a shrug.
    return f"""{{
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  "name": "{name}",
  "operatingSystem": "iOS 18.0 or later",
  "applicationCategory": "UtilitiesApplication",
  "url": "{DOMAIN}/",
  "installUrl": "{APP_STORE_URL}",
  "inLanguage": ["de", "en"],
  "description": "{desc}",
  "offers": {{
    "@type": "Offer",
    "price": "0",
    "priceCurrency": "CHF",
    "description": "{offer}"
  }}
}}"""


def render(path: str, lang: str, title: str, description: str, body: str) -> str:
    up = depth_prefix(path)
    canonical = f"{DOMAIN}/{path}"
    other = ALTERNATE[path]
    other_lang = "en" if lang == "de" else "de"
    s = STRINGS[lang]

    current = ' aria-current="page"'
    nav_items = []
    for href, label in NAV[lang]:
        # Links are written from the site root, so a page one level down needs the prefix.
        target = href if "/" not in path else up + href
        mark = current if href == path else ""
        nav_items.append(f'      <a href="{target}"{mark}>{html.escape(label)}</a>')
    nav = "\n".join(nav_items)

    return f"""<!doctype html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<meta name="description" content="{html.escape(description)}">
<link rel="canonical" href="{canonical}">
<link rel="alternate" hreflang="{lang}" href="{canonical}">
<link rel="alternate" hreflang="{other_lang}" href="{DOMAIN}/{other}">
<link rel="alternate" hreflang="x-default" href="{DOMAIN}/{ALTERNATE[path] if lang == "en" else path}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Sensorstorm">
<meta property="og:locale" content="{"de_CH" if lang == "de" else "en_GB"}">
<meta property="og:title" content="{html.escape(title)}">
<meta property="og:description" content="{html.escape(description)}">
<meta property="og:url" content="{canonical}">
<meta property="og:image" content="{DOMAIN}/og-image.png">
<meta name="twitter:card" content="summary">
<!-- Turns every iOS Safari visit into an install prompt. One line, and the highest
     conversion per byte on the whole site. -->
<meta name="apple-itunes-app" content="app-id={APP_ID}">
<link rel="icon" href="{up}favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="{up}style.css">
<script type="application/ld+json">{json_ld(lang)}</script>
</head>
<body>
<a class="skip" href="#main">{s["skip"]}</a>
<header>
  <a class="brand" href="{up}{"index.html" if lang == "de" else "en/index.html"}">Sensorstorm</a>
    <nav aria-label="{'Hauptnavigation' if lang == 'de' else 'Main'}">
{nav}
      <a href="{DOMAIN}/{other}">{s["switch"]}</a>
    </nav>
</header>
<main id="main">
{body}
</main>
<footer>
  <p>{s["footer"]}</p>
  <p>{s["updated"]}: {UPDATED}</p>
</footer>
</body>
</html>
"""


# --- Copy ------------------------------------------------------------------------------

def _addr(lang: str) -> str:
    country = OWNER["country_de"] if lang == "de" else OWNER["country_en"]
    uid = f"<br>{html.escape(OWNER['uid'])}" if OWNER["uid"] else ""
    return (f"{html.escape(OWNER['legal_name'])}<br>{html.escape(OWNER['street'])}<br>"
            f"{html.escape(OWNER['city'])}<br>{country}{uid}")


PAGES: dict[str, dict] = {}

PAGES["index.html"] = dict(lang="de",
    title="Sensorstorm — Sensoren messen, Strassenschäden erfassen",
    description="Video, GPS, Beschleunigung und Neigung gleichzeitig auf einer Uhr "
                "aufzeichnen. Dazu Routen mit ausgewiesener Lagegenauigkeit. "
                "iOS-App aus der Schweiz.",
    body=f"""
<h1>Dein iPhone als Messgerät.</h1>
<p class="lede">Sensorstorm zeichnet die Sensoren deines iPhones gleichzeitig auf — Video,
GPS, Beschleunigung und Neigung auf einer gemeinsamen Zeitbasis — und dokumentiert, was du
vor Ort vorfindest, mit einer Lagegenauigkeit, die es nicht versteckt.</p>
<a class="cta" href="{APP_STORE_URL}">Im App Store laden</a>
<p class="muted">Gratis. Sensorstorm Pro ist ein einmaliger In-App-Kauf, kein Abo.</p>

<h2>Warum eine gemeinsame Uhr</h2>
<p>Jeder Messwert wird mit <code>mach_absolute_time</code>-Sekunden gestempelt. Das ist
dieselbe Zeitbasis, die <code>CMLogItem.timestamp</code> benutzt und die die
Capture-Session als <code>synchronizationClock</code> führt. Darum liegen ein Videobild
und der Beschleunigungswert dazu ohne Umrechnung, ohne Kalibrierung und ohne Drift
aufeinander.</p>
<p>Deshalb schreibt die App das Video mit <code>AVAssetWriter</code> statt mit
<code>AVCaptureMovieFileOutput</code>: der Movie-File-Output sagt einem <em>dass</em> er
gestartet ist, nicht <em>wann</em>.</p>
<p>Die Bildstabilisierung bleibt aus. Sie entkoppelt das Bild von der IMU und würde jede
Auswertung, die beides verbindet, still verfälschen.</p>

<h2>Was aufgezeichnet wird</h2>
<ul>
<li>Beschleunigung, roh und sensorfusioniert, dazu Gravitation</li>
<li>Drehrate und Magnetfeld, je roh und kalibriert</li>
<li>Orientierung als Roll/Pitch/Yaw und als Quaternion</li>
<li>Kompass, an Nordrichtung ausgerichtet</li>
<li>Barometer: Luftdruck und relative Höhe</li>
<li>GPS: Position, Höhe, Geschwindigkeit, Kurs — jeweils mit Genauigkeit</li>
<li>Lautstärke in dBFS, Video mit Ton in 720p, 1080p oder 4K</li>
<li>Schrittzähler, Aktivität, Batterie, Helligkeit, Netzwerk</li>
<li>Bluetooth-Umgebung, AirPods-Kopfbewegung</li>
<li>Apple Watch: Herzfrequenz und Handgelenkbewegung</li>
</ul>
<p>Abtastrate wählbar von 10 bis 400 Hz. Auf Wunsch geht jede Messung während der
Aufnahme zusätzlich als JSON an eine Adresse deiner Wahl — eigenes Dashboard, Node-RED,
Home Assistant.</p>

<h2>Fotogrammetrie: Bilder mit bekanntem Ort</h2>
<p>Diese App baut kein 3D-Modell, und aus einem Video kann das auch sonst niemand. Was
eine Aufnahme beitragen kann, ist der Teil, den Fotogrammetrie-Software sonst raten
muss.</p>
<p>Im ARKit-Modus wird zu jedem Bild Position, Blickrichtung und Brennweite
aufgezeichnet. Der Export wählt daraus scharfe, räumlich verteilte Einzelbilder — eines,
sobald sich die Kamera weit genug bewegt hat, und innerhalb jedes Abschnitts das
schärfste. Brennweite, Ort und Blickrichtung stehen im EXIF, daneben liegen eine
Kameratabelle und ein COLMAP-Modell. <strong>RealityScan</strong>,
<strong>Metashape</strong> und <strong>Meshroom</strong> lesen das ein; das Modell
rechnen sie, nicht diese App.</p>

<h2>Der GPS-Track als GPX</h2>
<p>Jede Aufnahme mit GPS lässt sich direkt als <code>.gpx</code> oder <code>.kml</code>
teilen — ohne Pro und ohne Umweg über ein Fremdwerkzeug. Die Höhe darin ist orthometrisch,
also die über Meer, nicht die ellipsoidische: in der Schweiz sind das rund 50 Meter
Unterschied.</p>

<h2>Beobachtungen: Schäden festhalten</h2>
<p>Eine <strong>Route</strong> ist ein Weg, eine <strong>Beobachtung</strong> eine
Stelle darauf. Ein Schlagloch ist nicht ein Bild — es ist eine Übersicht, eine
Nahaufnahme, eines mit dem Zollstock daneben und dreissig Sekunden Video darum herum. All
das ist <em>ein</em> Punkt auf der Karte, nicht vier.</p>
<p><a href="beobachtungen.html">Wie die Position zustande kommt und warum das zählt →</a></p>

<h2>Export, der sich weiterverwenden lässt</h2>
<div class="table-wrap">
<table>
<tr><th>Format</th><th>wofür</th></tr>
<tr><td>CSV</td><td>eine Datei pro Sensor, Zeit seit Aufnahmebeginn und Unix-Zeit nebeneinander</td></tr>
<tr><td>GeoJSON</td><td>QGIS, Leaflet, Mapbox — Punkte <em>und</em> Bereiche als Polygone</td></tr>
<tr><td>GPX / KML</td><td>Wegpunkte zum Wiederfinden; Google Earth, nach Bewertung eingefärbt</td></tr>
<tr><td>3D-Szene</td><td><code>frames.csv</code>, <code>scene.json</code>, Video und GPS-Track für das Blender-Add-on</td></tr>
<tr><td>Sensor Logger / Gyroflow</td><td>das Dateilayout, das die jeweiligen Werkzeuge unverändert lesen</td></tr>
<tr><td>Gesamtexport</td><td>alles als ein Zip mit <code>manifest.json</code>: jede Datei mit SHA-256</td></tr>
</table>
</div>

<h2>Bilder an ihren Ort legen</h2>
<p>Im ARKit-Modus wird zu jedem Bild Position, Blickrichtung und Brennweite aufgezeichnet
— visuell-inertial, zentimetergenau, driftfrei. Der Export als 3D-Szene liefert daraus ein
Bündel, das ein Blender-Add-on zu einer animierten Kamera macht, samt Terrain von swisstopo
swissALTI3D.</p>
<p>Zwei Dinge, die dabei nicht funktionieren können und es auch nicht sollen:
Kameraprojektion kennt keine Verdeckung, und die Höhe über Grund ist nicht gemessen,
sondern eine eingestandene Annahme. Beides steht in der Szenendatei, statt geraten zu
werden.</p>

<h2>Gratis und Pro</h2>
<div class="card">
<h3>Gratis</h3>
<p>Alle Sensoren aufzeichnen, Wiedergabe mit synchronen Diagrammen, eine Route,
CSV-Export.</p>
</div>
<div class="card">
<h3>Sensorstorm Pro — einmalig, kein Abo</h3>
<p>400 Hz, 4K, Kamerapose für 3D, Rohdaten, Blender-Szene, Sensor Logger, Gyroflow,
beliebig viele Routen, GeoJSON/GPX/KML und der Gesamtexport.</p>
</div>
<p><strong>Der CSV-Export bleibt auch ohne Pro offen.</strong> Ein Messwerkzeug, das
jemanden von den eigenen Messungen aussperren kann, ist keins. Verkauft werden die
Profi-Formate, nicht der Zugang zu den eigenen Daten.</p>

<h2>Keine Wolke</h2>
<p>Alles bleibt auf dem Gerät. Kein Konto, kein Tracking, keine Analyse im Hintergrund.
Aufnahmen verlassen das iPhone nur, wenn du sie exportierst. Auch der Kauf braucht kein
Konto bei uns — er hängt an deinem Apple-Account.</p>
<p><a href="datenschutz.html">Die vollständige Datenschutzerklärung →</a></p>
""")

PAGES["en/index.html"] = dict(lang="en",
    title="Sensorstorm — sensor logging and road defect surveys",
    description="Record video, GPS, acceleration and tilt at once on one shared clock. "
                "Plus road surveys with stated positional accuracy. An iOS app from "
                "Switzerland.",
    body=f"""
<h1>Every sensor on one clock.<br>And the road with it.</h1>
<p class="lede">Sensorstorm records your iPhone's sensors at the same time — video, GPS,
acceleration and tilt on one shared time base — and documents damage on the road with a
positional accuracy it does not hide.</p>
<a class="cta" href="{APP_STORE_URL}">Get it on the App Store</a>
<p class="muted">Free. Sensorstorm Pro is a one-time in-app purchase, not a subscription.</p>

<h2>Why one clock</h2>
<p>Every sample is stamped with <code>mach_absolute_time</code> seconds. That is the same
time base <code>CMLogItem.timestamp</code> uses and the one the capture session runs as its
<code>synchronizationClock</code>. So a video frame and the acceleration value that belongs
to it line up with no conversion, no calibration and no drift.</p>
<p>That is why the app writes video with <code>AVAssetWriter</code> rather than
<code>AVCaptureMovieFileOutput</code>: the movie file output tells you <em>that</em> it
started, not <em>when</em>.</p>
<p>Video stabilisation stays off. It decouples the image from the IMU and would quietly
invalidate any analysis that correlates the two.</p>

<h2>What gets recorded</h2>
<ul>
<li>Acceleration, raw and sensor-fused, plus the gravity vector</li>
<li>Rotation rate and magnetic field, each raw and calibrated</li>
<li>Orientation as roll/pitch/yaw and as a quaternion</li>
<li>Compass, referenced to true north</li>
<li>Barometer: pressure and relative altitude</li>
<li>GPS: position, altitude, speed, course — each with its accuracy</li>
<li>Loudness in dBFS, video with audio in 720p, 1080p or 4K</li>
<li>Pedometer, activity, battery, brightness, network</li>
<li>Bluetooth surroundings, AirPods head motion</li>
<li>Apple Watch: heart rate and wrist motion</li>
</ul>
<p>Sample rate selectable from 10 to 400 Hz. If you want it, every reading also goes to
an address of your choosing as JSON while the recording runs — your own dashboard,
Node-RED, Home Assistant.</p>

<h2>Photogrammetry: images that know where they were taken</h2>
<p>This app does not build a 3D model, and neither does anything else that starts from a
video. What a recording can contribute is the part photogrammetry software otherwise has
to guess.</p>
<p>In ARKit mode the position, viewing direction and focal length are recorded for every
frame. The export picks sharp, well-spaced stills from those — one as soon as the camera
has moved far enough, and the sharpest within each stretch. Focal length, place and
viewing direction go into the EXIF, with a camera table and a COLMAP model alongside.
<strong>RealityScan</strong>, <strong>Metashape</strong> and <strong>Meshroom</strong>
read that; they compute the model, this app does not.</p>

<h2>The GPS track as GPX</h2>
<p>Any recording with GPS shares directly as <code>.gpx</code> or <code>.kml</code> — no
Pro, and no detour through a third-party converter. The elevation in it is orthometric,
height above sea level rather than above the ellipsoid: in Switzerland that is a
difference of about 50 metres.</p>

<h2>Observations: recording damage</h2>
<p>A <strong>route</strong> is a path; an <strong>observation</strong> is a spot on it. An
pothole is not one image — it is an overview, a close-up, one with a ruler next to it and
thirty seconds of video around it. All of that is <em>one</em> point on the map, not four.</p>
<p><a href="observations.html">How the position is arrived at, and why that matters →</a></p>

<h2>An export you can actually use</h2>
<div class="table-wrap">
<table>
<tr><th>Format</th><th>what for</th></tr>
<tr><td>CSV</td><td>one file per sensor, time since start and Unix time side by side</td></tr>
<tr><td>GeoJSON</td><td>QGIS, Leaflet, Mapbox — points <em>and</em> areas as polygons</td></tr>
<tr><td>GPX / KML</td><td>waypoints to find the spot again; Google Earth, coloured by severity</td></tr>
<tr><td>3D scene</td><td><code>frames.csv</code>, <code>scene.json</code>, video and GPS track for the Blender add-on</td></tr>
<tr><td>Sensor Logger / Gyroflow</td><td>the file layout each of those tools reads unmodified</td></tr>
<tr><td>Full archive</td><td>everything as one zip with a <code>manifest.json</code>: every file with its SHA-256</td></tr>
</table>
</div>

<h2>Putting images where they were taken</h2>
<p>In ARKit mode the position, viewing direction and focal length are recorded for every
frame — visual-inertial, centimetre-accurate, drift-free. The 3D scene export turns that
into a bundle, and a Blender add-on turns the bundle into an animated camera, with terrain
from swisstopo swissALTI3D.</p>
<p>Two things that cannot work here and are not meant to: camera projection knows nothing
about occlusion, and height above ground is not measured but an admitted assumption. Both
are written into the scene file rather than guessed at.</p>

<h2>Free and Pro</h2>
<div class="card">
<h3>Free</h3>
<p>Record every sensor, play it back with synchronised charts, one route, CSV export.</p>
</div>
<div class="card">
<h3>Sensorstorm Pro — one-time, no subscription</h3>
<p>400 Hz, 4K, camera pose for 3D, raw data, Blender scene, Sensor Logger, Gyroflow, any
number of routes, GeoJSON/GPX/KML and the full archive export.</p>
</div>
<p><strong>CSV export stays open without Pro.</strong> A measurement tool that can lock
someone out of their own measurements is not one. What is sold is the professional formats,
never access to your own data.</p>

<h2>No cloud</h2>
<p>Everything stays on the device. No account, no tracking, no background analytics.
Recordings leave your iPhone only when you export them. The purchase needs no account with
us either — it is tied to your Apple Account.</p>
<p><a href="privacy.html">The full privacy policy →</a></p>
""")

PAGES["beobachtungen.html"] = dict(lang="de",
    title="Strassenschäden erfassen — Lagegenauigkeit | Sensorstorm",
    description="Schlaglöcher und Risse mit dem iPhone dokumentieren: Fotos, Clips, "
                "Bewertung 1–10, Bereich — und bei jeder Beobachtung, woher die Koordinate "
                "stammt.",
    body="""
<h1>Strassenschäden erfassen, ohne die Genauigkeit zu verschweigen</h1>
<p class="lede">Eine Route ist ein Weg, eine Beobachtung eine Stelle darauf. Zu einer Beobachtung
gehören beliebig viele Fotos und Clips, ihre Position mitsamt der Abweichung, eine
Bewertung von 1 bis 10 und — wenn die Stelle grösser ist als ein Punkt — der markierte
Bereich.</p>

<h2>Wie genau ist die Position — und woher kommt sie</h2>
<p>Die Frage, die eine Schadensmeldung brauchbar oder wertlos macht. GPS auf einer Strasse
ist ein Kreis, kein Punkt: zwischen Häusern sind ±10 m ein guter Tag. Deshalb steht bei
jeder Beobachtung, woher ihre Koordinate stammt.</p>
<div class="table-wrap">
<table>
<tr><th>Quelle</th><th>was sie bedeutet</th><th>Fehlerangabe</th></tr>
<tr><td>Einzelner Fix</td><td>ein GPS-Fix, aufgenommen beim ersten Foto</td>
    <td>der Radius, den das Gerät für sich beansprucht</td></tr>
<tr><td>Gemittelt</td><td>Mittel aus den Fixes von zehn Sekunden Stillstehen</td>
    <td>die <em>gemessene</em> Streuung der Fixes um ihren Mittelwert</td></tr>
<tr><td>Nadel</td><td>von Hand auf dem Luftbild gesetzt</td>
    <td>keine — dafür bleibt der GPS-Fix samt Versatz gespeichert</td></tr>
</table>
</div>

<h3>Mitteln heisst nicht Mittelwert</h3>
<p>Zehn Sekunden ruhig stehen, und die Fixes werden mit 1/Genauigkeit² gewichtet gemittelt.
Die ersten Fixes nach dem Aufwachen des Empfängers sind die schlechtesten; sie gleich stark
zählen zu lassen wie einen guten hiesse, den Grund fürs Mitteln wegzuwerfen.</p>
<p>Ausgegeben wird nicht die behauptete Genauigkeit, sondern die <strong>gemessene
Streuung</strong> der Fixes um ihren Mittelwert — die ehrlichere der beiden Zahlen, und
meist die grössere.</p>

<h3>Die Nadel ist die genaueste Quelle, obwohl sie keine Fehlerangabe hat</h3>
<p>Wer vor dem Riss steht, sieht auf dem Luftbild, um welche Fuge es geht; das Gerät sieht
das nie. Darum liegt die Karte im Nadel-Editor auf Satellitenbild, das Fadenkreuz steht
fest und die Karte wandert darunter — so verdeckt kein Finger das Ziel.</p>
<p>Und <strong>beide Positionen werden gespeichert</strong>: eine korrigierte Koordinate,
die die Messung wegwirft, wäre weniger wert als jede der beiden für sich, weil hinterher
niemand mehr sagen könnte, ob die Nadel steht, wo der Empfänger sagte, oder wo jemand
entschied.</p>

<h2>Der Unsicherheitskreis wird gezeichnet</h2>
<p>Massstäblich, auf der Karte. Eine Nadel in einem 30-Meter-Kreis ist eine andere Aussage
als eine in einem 3-Meter-Kreis — und ohne den Kreis sehen die beiden gleich aus.</p>

<h2>Der Bereich</h2>
<p>Zwei Formen, weil es im Feld zwei Situationen gibt. Vor der Stelle stehend ist ein Radius
ein Regler und drei Sekunden Arbeit; wenn die Form zählt, tippt man die Ecken auf der Karte
an oder läuft den Rand ab und setzt an jeder Ecke einen Punkt an der eigenen Position.</p>
<p>Die Fläche wird im lokalen metrischen System gerechnet, nicht in Grad — die
Schuhbandformel direkt auf Längen- und Breitengraden läge in der Schweiz um ein Drittel
daneben.</p>

<h2>Weiterverwenden</h2>
<div class="table-wrap">
<table>
<tr><th>Format</th><th>wofür</th></tr>
<tr><td>GeoJSON</td><td>QGIS, Leaflet, Mapbox — Punkte und Bereiche als Polygone</td></tr>
<tr><td>CSV</td><td>Tabelle oder Datenbank, WGS84 und LV95 (EPSG:2056) nebeneinander</td></tr>
<tr><td>GPX</td><td>Wegpunkte, um dieselbe Stelle wiederzufinden</td></tr>
<tr><td>KML</td><td>Google Earth, nach Bewertung eingefärbt</td></tr>
<tr><td>Bündel</td><td>alle vier plus jedes Foto und jeden Clip, gezippt</td></tr>
</table>
</div>
<p>Quelle, Genauigkeit, Streuung, gemessener Fix und Versatz stehen in jedem Format, das
Felder dafür hat. Ein Kreis wird überall dort zum Ring, wo ein Polygon erwartet wird. GPX
bekommt keine Bereiche: das Format kennt keine Flächen, und ein geschlossener Track wäre
ein Weg, den nie jemand gegangen ist.</p>

<h2>Für wen</h2>
<p>Tiefbauämter und Werkhöfe, die den Zustand einer Strasse festhalten müssen.
Ingenieurbüros bei der Zustandserfassung. Versicherungen und Gutachter bei der
Beweissicherung. Und alle, denen eine Meldung ohne Fehlerangabe schon einmal um die Ohren
geflogen ist.</p>
<p class="muted">Die erste Route ist gratis — mit allen Beobachtungen, Fotos, Clips und dem
CSV-Export. Mehrere Routen nebeneinander und die Formate GeoJSON, GPX und KML gehören
zu Sensorstorm Pro, einem einmaligen In-App-Kauf.</p>
""")

PAGES["en/observations.html"] = dict(lang="en",
    title="Road defect surveys with honest accuracy | Sensorstorm",
    description="Document potholes and cracks with an iPhone: photos, clips, severity "
                "1–10, area — and for every observation, where the coordinate came from.",
    body="""
<h1>Road defect surveys that do not hide their accuracy</h1>
<p class="lede">A route is a path; an observation is a spot on it. An observation carries any
number of photos and clips, its position together with its uncertainty, a severity from 1 to
10, and — when the spot is bigger than a point — the marked area.</p>

<h2>How accurate is the position, and where did it come from</h2>
<p>The question that makes a defect report usable or worthless. GPS on a street is a circle,
not a point: between buildings, ±10 m is a good day. So every observation states where its
coordinate came from.</p>
<div class="table-wrap">
<table>
<tr><th>Source</th><th>what it means</th><th>error figure</th></tr>
<tr><td>Single fix</td><td>one GPS fix, taken with the first photo</td>
    <td>the radius the device claims for itself</td></tr>
<tr><td>Averaged</td><td>the mean of ten seconds of fixes taken standing still</td>
    <td>the <em>measured</em> spread of the fixes about their mean</td></tr>
<tr><td>Pin</td><td>placed by hand on the aerial image</td>
    <td>none — but the GPS fix and the offset from it are kept</td></tr>
</table>
</div>

<h3>Averaging is not a mean</h3>
<p>Stand still for ten seconds, and the fixes are averaged weighted by 1/accuracy². The
first fixes after the receiver wakes up are the worst ones; letting them count as much as a
good one would throw away the reason for averaging.</p>
<p>What is reported is not the claimed accuracy but the <strong>measured spread</strong> of
the fixes about their mean — the more honest of the two numbers, and usually the larger.</p>

<h3>The pin is the most accurate source, although it carries no error figure</h3>
<p>Someone standing in front of the crack can see on the aerial image which joint is meant;
the device never can. So the map in the pin editor sits on satellite imagery, the crosshair
stays fixed and the map moves underneath it — that way no finger covers the target.</p>
<p>And <strong>both positions are stored</strong>: a corrected coordinate that discards the
measurement would be worth less than either of the two on its own, because afterwards nobody
could say whether the pin sits where the receiver said, or where somebody decided.</p>

<h2>The uncertainty circle is drawn</h2>
<p>To scale, on the map. A pin inside a 30-metre circle is a different statement from one
inside a 3-metre circle — and without the circle the two look identical.</p>

<h2>The area</h2>
<p>Two shapes, because the field offers two situations. Standing in front of the spot, a
radius is one slider and three seconds of work; when the shape matters, you tap the corners
on the map or walk the edge and drop a point at each corner at your own position.</p>
<p>The area is computed in a local metric frame, not in degrees — the shoelace formula
applied directly to latitude and longitude would be off by a third in Switzerland.</p>

<h2>Getting it out again</h2>
<div class="table-wrap">
<table>
<tr><th>Format</th><th>what for</th></tr>
<tr><td>GeoJSON</td><td>QGIS, Leaflet, Mapbox — points and areas as polygons</td></tr>
<tr><td>CSV</td><td>spreadsheet or database, WGS84 and Swiss LV95 (EPSG:2056) side by side</td></tr>
<tr><td>GPX</td><td>waypoints, to find the same spot again</td></tr>
<tr><td>KML</td><td>Google Earth, coloured by severity</td></tr>
<tr><td>Bundle</td><td>all four plus every photo and clip, zipped</td></tr>
</table>
</div>
<p>Source, accuracy, spread, measured fix and offset appear in every format that has fields
for them. A circle becomes a ring wherever a polygon is expected. GPX gets no areas: the
format has no concept of a surface, and a closed track would be a path nobody ever walked.</p>

<h2>Who it is for</h2>
<p>Road authorities and maintenance depots that have to record the condition of a street.
Engineering firms doing condition surveys. Insurers and assessors preserving evidence. And
anyone who has had a report thrown back at them for having no error figure.</p>
<p class="muted">The first route is free — with all its observations, photos, clips and CSV export.
Running several routes side by side, and the GeoJSON, GPX and KML formats, belong to
Sensorstorm Pro, a one-time in-app purchase.</p>
""")

_PRIVACY_DE = f"""
<h1>Datenschutzerklärung</h1>
<p class="lede">Sensorstorm erhebt keine personenbezogenen Daten. Es gibt keinen Server, kein
Konto und keine Analyse. Diese Erklärung beschreibt trotzdem im Einzelnen, was auf dem Gerät
passiert — weil „wir sammeln nichts" ohne Begründung nichts wert ist.</p>

<h2>Verantwortlich</h2>
<p>{_addr("de")}<br>E-Mail: <a href="mailto:{html.escape(OWNER["email"])}">{html.escape(OWNER["email"])}</a></p>

<h2>Welche Daten die App erhebt</h2>
<p><strong>Keine.</strong> Sensorstorm überträgt keine Nutzungsdaten, keine Kennungen und
keine Messdaten an uns oder an Dritte. Es gibt kein Analyse-SDK, kein Absturzberichts-SDK,
kein Werbenetzwerk und keine Tracking-Technologie in der App. Die
<code>PrivacyInfo.xcprivacy</code> der App weist dementsprechend keine erhobenen Datentypen
und kein Tracking aus.</p>

<h2>Was auf dem Gerät bleibt</h2>
<p>Aufnahmen, Routen, Fotos, Clips und Einstellungen liegen ausschliesslich im
Datenbereich der App auf deinem iPhone. Sie verlassen das Gerät nur, wenn du sie selbst
exportierst und teilst — über die Dateien-App, AirDrop, Mail oder ein anderes Ziel deiner
Wahl. Wohin sie dann gehen, bestimmst du; ab diesem Punkt gilt die Datenschutzerklärung des
Ziels.</p>

<h2>Berechtigungen und wofür sie gebraucht werden</h2>
<div class="table-wrap">
<table>
<tr><th>Berechtigung</th><th>wofür</th></tr>
<tr><td>Bewegung &amp; Fitness</td><td>Beschleunigung, Drehrate, Orientierung, Magnetfeld
    und Schritte aufzeichnen</td></tr>
<tr><td>Standort</td><td>Position, Höhe, Geschwindigkeit und Kurs aufzeichnen, die
    Orientierung an Nordrichtung ausrichten und festhalten, wo eine Beobachtung erfasst wurde.
    „Immer" nur, damit die Aufzeichnung weiterläuft, wenn der Bildschirm während einer
    Messung gesperrt wird.</td></tr>
<tr><td>Kamera</td><td>Video synchron zu den Sensordaten aufnehmen und den Boden für einen
    Beobachtung fotografieren</td></tr>
<tr><td>Mikrofon</td><td>Lautstärke messen und den Ton von Aufnahmen und Clips
    aufzeichnen</td></tr>
</table>
</div>
<p>Jede Berechtigung lässt sich in den iOS-Einstellungen jederzeit widerrufen. Die App
funktioniert dann eingeschränkt weiter — ohne Standort etwa bleibt für eine Beobachtung nur die
von Hand gesetzte Nadel.</p>

<h2>Wo doch etwas das Gerät verlässt</h2>
<p>Zwei Stellen, an denen „nichts verlässt das Gerät" eine Fussnote braucht:</p>
<ul>
<li><strong>Karten.</strong> Die Kartenansichten nutzen Apple MapKit. Zum Laden der Kacheln
kontaktiert iOS Apple-Server; dabei wird der dargestellte Kartenausschnitt übermittelt. Das
geschieht innerhalb des Betriebssystems, nach Apples
<a href="https://www.apple.com/legal/privacy/">Datenschutzrichtlinie</a>. Wir erhalten davon
nichts.</li>
<li><strong>Der Kauf.</strong> Sensorstorm Pro wird über Apples In-App-Kauf abgewickelt.
Zahlung und Berechtigung liegen vollständig bei Apple und hängen an deinem Apple-Account.
Wir erhalten weder deinen Namen noch deine Zahlungsdaten noch eine Kennung, mit der sich ein
Kauf einer Person zuordnen liesse — die App fragt das Betriebssystem lediglich, ob dieses
Gerät die Freischaltung besitzt.</li>
</ul>
<p>Die Werkzeuge zum Laden von Terraindaten (swisstopo swissALTI3D) laufen auf dem Rechner,
nicht in der App, und sind nicht Teil des Produkts im App Store.</p>

<h2>Kinder</h2>
<p>Die App richtet sich nicht an Kinder und erhebt wissentlich keine Daten von ihnen — sie
erhebt von niemandem Daten.</p>

<h2>Deine Rechte</h2>
<p>Nach DSGVO und revDSG hast du Recht auf Auskunft, Berichtigung, Löschung, Einschränkung
und Datenübertragbarkeit. Da wir über dich keine Daten halten, können wir keine herausgeben
oder löschen — deine Daten liegen auf deinem Gerät und werden mit der App entfernt.
Schreib uns trotzdem, wenn du eine Frage dazu hast:
<a href="mailto:{html.escape(OWNER["email"])}">{html.escape(OWNER["email"])}</a>.</p>
<p>Für Käufe wende dich an Apple; Rückerstattungen laufen über
<a href="https://reportaproblem.apple.com">reportaproblem.apple.com</a>.</p>

<h2>Änderungen</h2>
<p>Ändert sich etwas Wesentliches, steht es hier, mit neuem Datum. Stand dieser Fassung:
{UPDATED}.</p>
"""

_PRIVACY_EN = f"""
<h1>Privacy policy</h1>
<p class="lede">Sensorstorm collects no personal data. There is no server, no account and no
analytics. This policy nevertheless spells out what happens on the device — because "we
collect nothing" is worth nothing without the detail behind it.</p>

<h2>Controller</h2>
<p>{_addr("en")}<br>Email: <a href="mailto:{html.escape(OWNER["email"])}">{html.escape(OWNER["email"])}</a></p>

<h2>What the app collects</h2>
<p><strong>Nothing.</strong> Sensorstorm transmits no usage data, no identifiers and no
measurements to us or to any third party. There is no analytics SDK, no crash-reporting SDK,
no ad network and no tracking technology in the app. The app's
<code>PrivacyInfo.xcprivacy</code> accordingly declares no collected data types and no
tracking.</p>

<h2>What stays on the device</h2>
<p>Recordings, routes, photos, clips and settings live solely in the app's own storage on
your iPhone. They leave the device only when you export and share them yourself — via the
Files app, AirDrop, Mail or any other destination you choose. Where they go from there is
your decision, and from that point the receiving service's policy applies.</p>

<h2>Permissions, and what they are for</h2>
<div class="table-wrap">
<table>
<tr><th>Permission</th><th>what for</th></tr>
<tr><td>Motion &amp; Fitness</td><td>recording acceleration, rotation rate, orientation,
    magnetic field and steps</td></tr>
<tr><td>Location</td><td>recording position, altitude, speed and course, referencing
    orientation to true north, and recording where an observation was captured. "Always" only so
    recording continues when the screen locks during a measurement.</td></tr>
<tr><td>Camera</td><td>recording video in sync with the sensor data, and photographing the
    ground for an observation</td></tr>
<tr><td>Microphone</td><td>measuring loudness and recording the audio of measurements and
    clips</td></tr>
</table>
</div>
<p>Every permission can be revoked at any time in iOS Settings. The app keeps working with
less — without location, for instance, an observation can still be placed with the hand-set pin.</p>

<h2>Where something does leave the device</h2>
<p>Two places where "nothing leaves the device" needs a footnote:</p>
<ul>
<li><strong>Maps.</strong> The map views use Apple MapKit. To load tiles, iOS contacts
Apple's servers, which involves sending the region being displayed. That happens inside the
operating system under Apple's
<a href="https://www.apple.com/legal/privacy/">privacy policy</a>. We receive none of it.</li>
<li><strong>The purchase.</strong> Sensorstorm Pro is handled by Apple's in-app purchase.
Payment and entitlement rest entirely with Apple and are tied to your Apple Account. We
receive neither your name, nor your payment details, nor any identifier that would let a
purchase be traced to a person — the app merely asks the operating system whether this
device holds the unlock.</li>
</ul>
<p>The tools that fetch terrain data (swisstopo swissALTI3D) run on a desktop computer, not
in the app, and are not part of the App Store product.</p>

<h2>Children</h2>
<p>The app is not directed at children and knowingly collects no data from them — it
collects data from nobody.</p>

<h2>Your rights</h2>
<p>Under the GDPR and the Swiss FADP you have the right to access, rectification, erasure,
restriction and data portability. Since we hold no data about you, there is nothing for us to
release or erase — your data sits on your device and is removed with the app. Write to us
anyway if you have a question:
<a href="mailto:{html.escape(OWNER["email"])}">{html.escape(OWNER["email"])}</a>.</p>
<p>For purchases, contact Apple; refunds go through
<a href="https://reportaproblem.apple.com">reportaproblem.apple.com</a>.</p>

<h2>Changes</h2>
<p>If anything material changes it will appear here with a new date. This version:
{UPDATED}.</p>
"""

PAGES["datenschutz.html"] = dict(lang="de", title="Datenschutzerklärung | Sensorstorm",
    description="Sensorstorm erhebt keine personenbezogenen Daten: kein Konto, kein "
                "Server, kein Tracking. Was auf dem Gerät bleibt und welche "
                "Berechtigungen wofür sind.",
    body=_PRIVACY_DE)
PAGES["en/privacy.html"] = dict(lang="en", title="Privacy policy | Sensorstorm",
    description="Sensorstorm collects no personal data: no account, no server, no "
                "tracking. What stays on the device, and which permissions are used for "
                "what.",
    body=_PRIVACY_EN)

PAGES["support.html"] = dict(lang="de", title="Support und FAQ | Sensorstorm",
    description="Hilfe zu Sensorstorm: Kauf wiederherstellen, Export nach QGIS und "
                "Blender, Genauigkeit der Position, Aufnahme bei gesperrtem "
                "Bildschirm.",
    body=f"""
<h1>Support</h1>
<p class="lede">Schreib an <a href="mailto:{html.escape(OWNER["email"])}">{html.escape(OWNER["email"])}</a>.
Es antwortet ein Mensch, meist innerhalb weniger Tage. Hilfreich sind: Gerät, iOS-Version
und die Versionsnummer aus <em>Einstellungen → Version</em>.</p>

<h2>Häufige Fragen</h2>

<h3>Ich habe Pro gekauft, es ist aber gesperrt</h3>
<p><em>Einstellungen → Käufe wiederherstellen</em>. Der Kauf hängt an dem Apple-Account, mit
dem er getätigt wurde — auf einem neuen Gerät muss derselbe Account angemeldet sein. Ein über
Familienfreigabe geteilter Kauf erscheint ebenfalls dort.</p>

<h3>Ist Pro ein Abo?</h3>
<p>Nein. Ein einmaliger Kauf, der nicht abläuft und sich nicht verlängert.</p>

<h3>Komme ich ohne Pro an meine Daten?</h3>
<p>Ja, immer. Der CSV-Export jeder Aufnahme und jeder Route ist nicht gesperrt und wird es
nicht werden — auch nicht nach einer Rückerstattung. Pro schaltet die Profi-Formate frei,
nicht den Zugang zu deinen eigenen Messungen.</p>

<h3>Wie bekomme ich eine Route nach QGIS?</h3>
<p>In der Route oben rechts auf <em>⋯ → GeoJSON</em>, dann teilen (Dateien, AirDrop,
Mail). Die Datei enthält Punkte und Bereiche als Polygone, mit Quelle, Genauigkeit,
Streuung, gemessenem Fix, Versatz und den Koordinaten in WGS84 und LV95.</p>

<h3>Wie kommt eine Aufnahme nach Blender?</h3>
<p>Die Aufnahme muss im ARKit-Modus entstanden sein (<em>Einstellungen → Kamerapose</em>,
mit eingeschalteter Kamera). Danach <em>⋯ → Als 3D-Szene exportieren</em>. Das Bündel liest
das Add-on aus dem <a href="{GITHUB_URL}">Repository</a> über
<em>File ▸ Import ▸ Sensorstorm Scene</em>.</p>

<h3>Warum ist meine Position um mehrere Meter daneben?</h3>
<p>Weil GPS das ist. Zwischen Häusern sind ±10 m ein guter Tag. Die App versteckt das nicht,
sondern zeichnet den Unsicherheitskreis massstäblich auf die Karte. Genauer wird es auf zwei
Wegen: zehn Sekunden stillstehen und mitteln lassen, oder die Nadel von Hand auf dem
Satellitenbild setzen. Beides bleibt neben dem ursprünglichen Fix gespeichert.</p>

<h3>Die Aufnahme stoppt, wenn der Bildschirm sperrt</h3>
<p>Sie sollte weiterlaufen. Prüfe in den iOS-Einstellungen, ob Sensorstorm den Standort
„Immer" verwenden darf — das ist der Hintergrundmodus, an dem die weiterlaufende
Aufzeichnung hängt.</p>

<h3>Was bedeutet die Bewertung von 1 bis 10?</h3>
<p>Sie ist bewusst nicht an eine Norm gebunden, sondern an das Urteil dessen, der davor
steht. Die Skala steht in jedem Export und im <code>manifest.json</code>, damit die
Gegenseite weiss, was sie liest.</p>

<h3>Läuft die App auf dem iPad?</h3>
<p>Ja. Manche Sensoren gibt es dort nicht (Barometer, Schrittzähler je nach Modell); die App
zeigt sie dann als nicht verfügbar an, statt Nullen aufzuzeichnen.</p>

<h2>Fehler melden</h2>
<p>Am liebsten als <a href="{GITHUB_URL}/issues">GitHub-Issue</a> — dort geht nichts
verloren. Per Mail geht es auch.</p>
""")

PAGES["en/support.html"] = dict(lang="en", title="Support and FAQ | Sensorstorm",
    description="Help with Sensorstorm: restoring a purchase, exporting to QGIS and Blender, "
                "positional accuracy, recording with the screen locked. And how to reach us.",
    body=f"""
<h1>Support</h1>
<p class="lede">Write to <a href="mailto:{html.escape(OWNER["email"])}">{html.escape(OWNER["email"])}</a>.
A person answers, usually within a few days. Useful to include: device, iOS version and the
version number from <em>Settings → Version</em>.</p>

<h2>Common questions</h2>

<h3>I bought Pro but it is still locked</h3>
<p><em>Settings → Restore purchases</em>. The purchase is tied to the Apple Account it was
made with — on a new device the same account has to be signed in. A purchase shared through
Family Sharing shows up there too.</p>

<h3>Is Pro a subscription?</h3>
<p>No. A single purchase that does not expire and does not renew.</p>

<h3>Can I get at my data without Pro?</h3>
<p>Yes, always. CSV export of every recording and every route is not gated and will not be —
not even after a refund. Pro unlocks the professional formats, not access to your own
measurements.</p>

<h3>How do I get a route into QGIS?</h3>
<p>Inside the route, top right, <em>⋯ → GeoJSON</em>, then share it (Files, AirDrop, Mail).
The file carries points and areas as polygons, with source, accuracy, spread, the measured
fix, the offset, and coordinates in both WGS84 and Swiss LV95.</p>

<h3>How does a recording get into Blender?</h3>
<p>The recording has to have been made in ARKit mode (<em>Settings → Camera pose</em>, with
the camera on). Then <em>⋯ → Export as 3D scene</em>. The add-on in the
<a href="{GITHUB_URL}">repository</a> reads the bundle via
<em>File ▸ Import ▸ Sensorstorm Scene</em>.</p>

<h3>Why is my position several metres off?</h3>
<p>Because that is what GPS is. Between buildings, ±10 m is a good day. The app does not hide
it — it draws the uncertainty circle to scale on the map. Two ways to do better: stand still
for ten seconds and let it average, or place the pin by hand on the satellite image. Both are
stored alongside the original fix.</p>

<h3>Recording stops when the screen locks</h3>
<p>It should keep going. Check in iOS Settings whether Sensorstorm may use your location
"Always" — that is the background mode the continued recording depends on.</p>

<h3>What does the severity from 1 to 10 mean?</h3>
<p>It is deliberately not tied to a standard, but to the judgement of whoever is standing in
front of the damage. The scale is stated in every export and in the
<code>manifest.json</code>, so the other end knows what it is reading.</p>

<h3>Does it run on iPad?</h3>
<p>Yes. Some sensors are not present there (barometer, pedometer depending on the model); the
app then shows them as unavailable rather than recording zeros.</p>

<h2>Reporting a bug</h2>
<p>Ideally as a <a href="{GITHUB_URL}/issues">GitHub issue</a> — nothing gets lost there.
Email works too.</p>
""")

PAGES["impressum.html"] = dict(lang="de", title="Impressum | Sensorstorm",
    description="Impressum, Kontakt und Haftungshinweise zu Sensorstorm, der iOS-App für "
                "synchrone Sensoraufzeichnung und Strassenschäden.",
    body=f"""
<h1>Impressum</h1>
<h2>Verantwortlich für den Inhalt</h2>
<p>{_addr("de")}</p>
<p>E-Mail: <a href="mailto:{html.escape(OWNER["email"])}">{html.escape(OWNER["email"])}</a></p>
<h2>Haftung für Inhalte</h2>
<p>Die Inhalte dieser Seiten werden mit Sorgfalt erstellt. Für die Richtigkeit,
Vollständigkeit und Aktualität wird keine Gewähr übernommen.</p>
<h2>Haftung für Links</h2>
<p>Diese Seite enthält Links zu externen Websites Dritter, auf deren Inhalte kein Einfluss
besteht. Für diese Inhalte ist stets der jeweilige Anbieter verantwortlich.</p>
<h2>Urheberrecht</h2>
<p>Der Quellcode der App steht unter der Lizenz des
<a href="{GITHUB_URL}">Repositorys</a>. Texte und Bilder dieser Website bleiben beim
Betreiber.</p>
<h2>Apple</h2>
<p>Apple, iPhone, iPad, iOS, ARKit und App Store sind Marken von Apple Inc. Sensorstorm steht
in keiner Verbindung zu Apple Inc.</p>
""")

PAGES["en/legal.html"] = dict(lang="en", title="Legal notice | Sensorstorm",
    description="Legal notice, contact and liability information for Sensorstorm, the iOS "
                "app for synchronised sensor logging and road surveys.",
    body=f"""
<h1>Legal notice</h1>
<h2>Responsible for the content</h2>
<p>{_addr("en")}</p>
<p>Email: <a href="mailto:{html.escape(OWNER["email"])}">{html.escape(OWNER["email"])}</a></p>
<h2>Liability for content</h2>
<p>The content of these pages is prepared with care. No warranty is given as to its accuracy,
completeness or currency.</p>
<h2>Liability for links</h2>
<p>This site contains links to external websites over whose content we have no influence.
Responsibility for that content always rests with its respective provider.</p>
<h2>Copyright</h2>
<p>The app's source code is under the licence stated in the
<a href="{GITHUB_URL}">repository</a>. Text and images on this website remain with the
operator.</p>
<h2>Apple</h2>
<p>Apple, iPhone, iPad, iOS, ARKit and App Store are trademarks of Apple Inc. Sensorstorm is
not affiliated with Apple Inc.</p>
""")

FAVICON = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
<rect width="64" height="64" rx="14" fill="#0b0d0f"/>
<path d="M6 32h8l5-16 7 34 7-30 6 20 5-8h14" fill="none" stroke="{ACCENT}"
      stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
"""


def build(out: pathlib.Path) -> list[str]:
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    for path, page in PAGES.items():
        target = out / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(render(path, **page), encoding="utf-8")

    (out / "style.css").write_text(STYLE.strip() + "\n", encoding="utf-8")
    (out / "favicon.svg").write_text(FAVICON, encoding="utf-8")

    # The app icon doubles as the link-preview image. Square, so it renders as a
    # `summary` card rather than a banner — a purpose-drawn 1200x630 would look
    # better in a shared link, but a real icon beats a URL that 404s.
    icon = pathlib.Path(__file__).resolve().parent.parent / \
        "Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
    if icon.exists():
        shutil.copyfile(icon, out / "og-image.png")
    else:
        print(f"WARNING: {icon} missing, og:image will 404", file=sys.stderr)

    # Both old slugs were indexed and linked from every page's nav. A rename without a
    # redirect throws away the ranking the rest of this file exists to build.
    (out / "_redirects").write_text(
        "/faelle.html    /beobachtungen.html      301\n"
        "/en/cases.html  /en/observations.html    301\n", encoding="utf-8")

    (out / "robots.txt").write_text(
        f"User-agent: *\nAllow: /\n\nSitemap: {DOMAIN}/sitemap.xml\n", encoding="utf-8")

    urls = "\n".join(
        f"  <url><loc>{DOMAIN}/{p}</loc><lastmod>{UPDATED}</lastmod>"
        f"<changefreq>monthly</changefreq></url>"
        for p in PAGES)
    (out / "sitemap.xml").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        f"{urls}\n</urlset>\n", encoding="utf-8")

    return sorted(str(p.relative_to(out)) for p in out.rglob("*") if p.is_file())


def main() -> None:
    out = pathlib.Path(__file__).resolve().parent / "dist"
    files = build(out)
    for name in files:
        print(f"  {name}")
    todo = sum(1 for v in OWNER.values() if str(v).startswith("TODO"))
    print(f"\n{len(files)} files in {out}")
    if todo:
        print(f"WARNING: {todo} placeholder(s) left in OWNER — the imprint is a legal "
              f"requirement and the support address is where App Store Review writes.",
              file=sys.stderr)


if __name__ == "__main__":
    main()
