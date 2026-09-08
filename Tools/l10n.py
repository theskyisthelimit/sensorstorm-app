#!/usr/bin/env python3
"""Das Lokalisierungssystem: eine Registry, Adapter je Oberfläche, eine Pipeline.

    Tools/l10n.py doctor                         # Matrix Sprache × Oberfläche
    Tools/l10n.py verify [--lang es]             # deterministische Sperren
    Tools/l10n.py add-language es                # Registry-Eintrag → überall vorhanden
    Tools/l10n.py sync                           # neue/geänderte Texte in alle Sprachen
    Tools/l10n.py translate --lang ja            # nur eine Sprache, alle Oberflächen
    Tools/l10n.py pack --lang ja [--chunk 400]   # ein Übersetzungspaket je Sprache
    Tools/l10n.py import --lang ja --dir l10n/packs/ja   # ausgefüllt zurücklesen
    Tools/l10n.py export --lang ja --out ja.jsonl / import --lang ja --file ja.jsonl
    Tools/l10n.py store-copy --locale ja         # das App-Store-Listing in vier Stufen (ASO), Bericht store-ja.md
    Tools/l10n.py report --lang ja               # der letzte Prüfbericht
    Tools/l10n.py context --key "Beobachtung"    # wo ein Text in der App steht
    Tools/l10n.py pseudo                         # Startargumente für Pseudo-Lokalisierung und Pseudo-RTL
    Tools/l10n.py rename-term --from Fund --to Beobachtung   # Key und Swift-Literal zusammen

Eine Sprache ist ein Eintrag in l10n/languages.json plus `add-language`. Alles
andere leitet sich ab: Katalog der App (Localizable + InfoPlist), Katalog der
Uhr (Watch/Localizable.xcstrings), Store-Texte (Tools/store/<locale>.json:
Listing, Release Notes, IAP-Texte) und project.yml.

Übersetzt wird ausschliesslich maschinell, aber geprüft: (1) Übersetzen,
(2) unabhängiges Lektorat, (3) Rückübersetzung mit Urteil; dazu deterministische
Sperren (verify), die ein fehlerhaftes Ergebnis nie in eine Datei lassen.
Das Übersetzungsgedächtnis unter l10n/memory sorgt dafür, dass kein Text
zweimal übersetzt wird — ein neuer Text nach einer Funktion ist ein Lauf
von Sekunden, nicht die ganze App.

Engines: `--engine claude` (Standard, braucht ANTHROPIC_API_KEY, Modell
claude-opus-5) oder `--engine mock` (offline, für Tests und Trockenläufe).
"""
from __future__ import annotations

import argparse
import ast
import datetime as _dt
import hashlib
import json
import os
import re
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(os.environ.get("SENSORSTORM_ROOT") or Path(__file__).resolve().parent.parent)
REGISTRY = "l10n/languages.json"
GLOSSARY = "l10n/glossary.json"
MEMORY_DIR = "l10n/memory"
PACK_DIR = "l10n/packs"
REPORT_DIR = "l10n/reports"
CATALOG = "Resources/Localizable.xcstrings"
INFOPLIST = "Resources/InfoPlist.xcstrings"
WATCH = "Watch/Localizable.xcstrings"
STORE = "Tools/store"
PROJECT = "project.yml"
SWIFT_DIRS = ("App", "Watch")

MODEL = "claude-opus-5"
BATCH_SIZE = 40
UI_LENGTH_FACTOR = 1.4
UI_LENGTH_SLACK = 8
HELP_THRESHOLD = 120  # Zeichen: darüber ist ein Text Fliesstext, kein UI-Element

STORE_LIMITS = {"name": 30, "subtitle": 30, "promotionalText": 170, "description": 4000, "whatsNew": 4000}
STORE_BYTE_LIMITS = {"keywords": 100}

# Sichtbare Bildschirme, damit die Maschine weiss, wo ein Text steht.
SCREENS = {
    "RootView.swift": "Hauptansichten und Tab-Leiste: Aufnehmen, Messaufnahmen, Routen, Einstellungen",
    "RecordView.swift": "Aufnehmen: Sensoren scharf schalten, Start und Stopp, laufende Aufnahme",
    "SensorArmingList.swift": "Sensoren auswählen",
    "SettingsView.swift": "Einstellungen: Abtastrate, Video, Kamerapose, Live-Übertragung, Pro",
    "LibraryView.swift": "Messaufnahmen (Liste aller Aufnahmen)",
    "RecordingLibrary.swift": "Ablage der Aufnahmen: Anlegen, Umbenennen, Löschen",
    "RecordingDetailView.swift": "Eine Aufnahme im Detail: Ströme, Video, Export",
    "RecordingPlayback.swift": "Wiedergabe einer Aufnahme",
    "SensorChartCard.swift": "Diagramm eines Sensorstroms",
    "ArchiveExportView.swift": "Gesamtexport: alles auf dem Gerät als ein Zip",
    "PhotoSetExportView.swift": "Bilder für Fotogrammetrie",
    "SurveyListView.swift": "Routen (Liste)",
    "SurveyDetailView.swift": "Eine Route im Detail: Beobachtungen, Karte, Export",
    "FindingCaptureView.swift": "Beobachtung erfassen: Fotos, Position, Bewertung",
    "FindingDetailView.swift": "Eine Beobachtung im Detail",
    "AreaEditorView.swift": "Bereich markieren: Kreis oder Polygon",
    "PinEditorView.swift": "Nadel von Hand setzen",
    "SurveyComponents.swift": "Routen: gemeinsame Bausteine und Formulare",
    "SurveyModel.swift": "Routen: Datenmodell, Meldungen und Fehler",
    "SurveyCamera.swift": "Kamera in der Beobachtung",
    "SurveyLocation.swift": "Standort in der Beobachtung: Fix, Mittelung, Abweichung",
    "PaywallView.swift": "Bezahlschranke (Sensorstorm Pro)",
    "ProEntitlement.swift": "Kauf und Wiederherstellung: Meldungen und Fehler",
    "ProLock.swift": "Hinweise auf Pro an gesperrten Funktionen",
    "LiveStreamer.swift": "Live-Übertragung an einen Server",
    "MQTTTransport.swift": "MQTT-Broker: Verbindungsfehler",
    "SensorHub.swift": "Sensoren: Namen der Ströme, Meldungen",
    "VideoRecorder.swift": "Videoaufnahme: Fehler und Grenzen",
    "AudioSource.swift": "Ton: Pegel und Lautstärke",
    "Formatting.swift": "Zahlen, Einheiten und Zeitangaben",
    "Theme.swift": "Beschriftungen der Oberfläche",
    "ScreenshotFixtures.swift": "Beispieldaten für Screenshots",
    "WatchRootView.swift": "Apple Watch: Hauptansicht",
    "WatchRecorder.swift": "Apple Watch: Aufnahme und Herzfrequenz",
}

# ---------------------------------------------------------------------------
# Registry und Glossar


def path(*parts: str) -> Path:
    return ROOT.joinpath(*parts)


def load_json(rel: str):
    with open(path(rel), encoding="utf-8") as handle:
        return json.load(handle)


def registry() -> dict:
    return load_json(REGISTRY)


def languages() -> dict[str, dict]:
    return {entry["code"]: entry for entry in registry()["languages"]}


def source_language() -> str:
    return registry().get("sourceLanguage", "de")


def reference_language() -> str:
    return registry().get("referenceLanguage", "en")


def language(code: str) -> dict:
    entries = languages()
    if code not in entries:
        known = ", ".join(sorted(entries))
        raise SystemExit(f"„{code}“ steht nicht in {REGISTRY}. Bekannt: {known}. "
                         f"Eine neue Sprache ist zuerst ein Eintrag dort (code, name, appleLocale, ascLocales, "
                         f"siteLocale, direction, script, quotes, register, pluralCategories, status).")
    return entries[code]


def glossary() -> dict:
    return load_json(GLOSSARY)


# ---------------------------------------------------------------------------
# Platzhalter

PLACEHOLDER = re.compile(
    r"%(?:\d+\$)?#@[A-Za-z0-9_]+@"
    r"|%(?:\d+\$)?[-+#0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j|L)?[@dDiuUxXoOfeEgGcCsSpaAF]"
    r"|%%"
)
# Der App-Name in App-Shortcut-Sätzen: `${applicationName}`, kein Platzhalter
# im Sinne von `%@`, aber genauso unantastbar.
APP_TOKEN = re.compile(r"\$\{[A-Za-z][A-Za-z0-9_]*\}")
_SPEC = re.compile(r"%(\d+\$)?[-+#0]*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfeEgGcCsSpaAF])")
_SUBST = re.compile(r"%(\d+\$)?#@([A-Za-z0-9_]+)@")


def placeholders(text: str) -> list[str]:
    return PLACEHOLDER.findall(text or "")


def placeholder_signature(text: str) -> list[str]:
    """Typen der Platzhalter ohne Position und Flags, sortiert: `%1$@ · %2$lld`
    und `%lld %@` haben dieselbe Signatur, `%@ %@` und `%@` nicht."""
    signature = []
    for token in placeholders(text):
        if token == "%%":
            signature.append("%%")
            continue
        subst = _SUBST.match(token)
        if subst:
            signature.append("#@" + subst.group(2))
            continue
        spec = _SPEC.match(token)
        if spec:
            signature.append((spec.group(2) or "") + spec.group(3))
    return sorted(signature)


def positional_indices(text: str) -> list[int]:
    return sorted(int(m.group(1)[:-1]) for m in (_SPEC.match(t) for t in placeholders(text)) if m and m.group(1))


# ---------------------------------------------------------------------------
# Zeilen


@dataclass
class Row:
    surface: str
    id: str
    source: str
    reference: str
    context: str = ""
    kind: str = "ui"  # ui | help | plural | store
    max_chars: int | None = None
    max_bytes: int | None = None
    current: str | None = None
    extra: dict = field(default_factory=dict)

    @property
    def hash(self) -> str:
        raw = "\x1f".join([self.surface, self.id, self.source, self.context, json.dumps(self.extra.get("categories", []))])
        return hashlib.sha1(raw.encode("utf-8")).hexdigest()

    def to_json(self) -> dict:
        return {
            "surface": self.surface, "id": self.id, "source": self.source, "reference": self.reference,
            "context": self.context, "kind": self.kind, "maxChars": self.max_chars, "maxBytes": self.max_bytes,
            "extra": self.extra,
        }


# ---------------------------------------------------------------------------
# Kontext: wo steht ein Text in der App

_context_cache: dict[str, list[str]] | None = None


def swift_literal(key: str) -> str:
    return key.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


# Ein Katalog-Key schreibt `%@`, das Swift-Literal schreibt `\(ausdruck)`. Damit
# der Vergleich beide Seiten sieht, wird jede der zwei Formen auf dieselbe Marke
# gebracht. Ohne das meldete `reword` „nichts von Hand" und liess fünf Literale
# mit dem alten Satz stehen — der nächste Build hätte den alten Key neu
# angelegt und den neuen verwaist zurückgelassen (2026-09-08).
_INTERPOLATION = "\x00"
_PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:@|lld|ld|lu|d|u|s|(?:\.\d+)?f)")


def normalize_interpolation(text: str) -> str:
    """`\\(…)` in einem Swift-Literal auf die Platzhaltermarke bringen.

    Geklammert gezählt, nicht mit einem regulären Ausdruck: die Ausdrücke sind
    verschachtelt (`\\(Format.fixes(model.location.fixCount(inLast: 1)))`), und
    ein nicht-gieriges `\\(.*?\\)` bricht mitten drin ab.
    """
    out: list[str] = []
    index = 0
    while index < len(text):
        if text.startswith("\\(", index):
            depth, cursor = 1, index + 2
            while cursor < len(text) and depth:
                if text[cursor] == "(":
                    depth += 1
                elif text[cursor] == ")":
                    depth -= 1
                cursor += 1
            out.append(_INTERPOLATION)
            index = cursor
        else:
            out.append(text[index])
            index += 1
    return "".join(out)


def normalize_placeholders(text: str) -> str:
    """`%@`, `%lld` und Freunde auf dieselbe Marke bringen."""
    return _PLACEHOLDER.sub(_INTERPOLATION, text)


def context_index() -> dict[str, list[str]]:
    """Katalog-Key → Swift-Dateien, in denen der Text als Literal steht. Ein
    Durchlauf über alle Dateien; 1460 Keys × 90 Dateien sind Sekunden."""
    global _context_cache
    if _context_cache is not None:
        return _context_cache
    files: dict[str, str] = {}
    for directory in SWIFT_DIRS:
        base = path(directory)
        if not base.is_dir():
            continue
        for swift in base.rglob("*.swift"):
            try:
                files[swift.name] = swift.read_text(encoding="utf-8")
            except OSError:
                continue
    index: dict[str, list[str]] = {}
    catalog_path = path(CATALOG)
    if catalog_path.exists():
        with open(catalog_path, encoding="utf-8") as handle:
            keys = list(json.load(handle)["strings"].keys())
        for key in keys:
            if not key.strip():
                continue
            needle = '"' + swift_literal(key) + '"'
            index[key] = sorted(name for name, text in files.items() if needle in text)
    _context_cache = index
    return index


def describe_context(files: list[str]) -> str:
    return "; ".join(SCREENS.get(name, name.removesuffix(".swift")) for name in files[:3])


# ---------------------------------------------------------------------------
# Adapter: String Catalog


def _plural_units(loc: dict):
    """Jede `stringUnit` unter den Plural-Varianten einer Lokalisierung.

    Ein Plural hat oben keine `stringUnit`, sondern je Kategorie eine. Wer nur
    oben schaut, hält jeden frisch übersetzten Plural für gelesen: `doctor`
    zählte ihn nie unter `?N`, und `approve` fasste ihn nie an.
    """
    for substitution in (loc.get("substitutions") or {}).values():
        for variation in ((substitution.get("variations") or {}).get("plural") or {}).values():
            if "stringUnit" in variation:
                yield variation["stringUnit"]
    for variation in ((loc.get("variations") or {}).get("plural") or {}).values():
        if "stringUnit" in variation:
            yield variation["stringUnit"]


def _state(loc: dict | None) -> str | None:
    if not loc:
        return None
    unit = loc.get("stringUnit")
    if unit:
        return unit.get("state")
    units = list(_plural_units(loc))
    if not units:
        return "translated"
    return "needs_review" if any(u.get("state") == "needs_review" for u in units) else "translated"


class XCStringsAdapter:
    def __init__(self, rel: str, name: str, with_context: bool = True):
        self.rel = rel
        self.name = name
        self.with_context = with_context

    @property
    def path(self) -> Path:
        return path(self.rel)

    def exists(self) -> bool:
        return self.path.exists()

    def load(self) -> dict:
        with open(self.path, encoding="utf-8") as handle:
            return json.load(handle)

    def save(self, data: dict) -> None:
        text = json.dumps(data, ensure_ascii=False, indent=2, separators=(",", " : "), sort_keys=True)
        self.path.write_text(text + "\n", encoding="utf-8")

    @staticmethod
    def keys(data: dict):
        for key, entry in data["strings"].items():
            if not key.strip() or entry.get("extractionState") == "stale":
                continue
            yield key, entry

    @staticmethod
    def project_sources() -> dict[str, str]:
        """Die deutschen InfoPlist-Texte, die in `project.yml` stehen.

        Im Katalog gibt es für diese Schlüssel keine deutsche Zeile: der
        Schlüssel ist die Kennung, der Text steht in `project.yml`. Ohne diese
        Rückfrage nähme `rows()` den Schlüsselnamen als Quelltext, und dann
        prüft keine Marken- oder Platzhaltersperre je eine Berechtigungsfrage.
        Genau so stand „二维码“ statt „QR“ im chinesischen Kameradialog.
        """
        text = path("project.yml").read_text(encoding="utf-8")
        found: dict[str, str] = {}
        lines = text.split("\n")
        for index, line in enumerate(lines):
            stripped = line.strip()
            if not (stripped.startswith("NS") and "UsageDescription" in stripped and ":" in stripped):
                continue
            key, _, value = stripped.partition(":")
            value = value.strip().strip('"')
            if value in (">-", ">", "|-", "|"):
                # Gefaltetes Blockskalar: der Text steht eingerückt darunter, und
                # YAML zieht die Zeilen mit einem Leerzeichen zusammen. Ohne das
                # stünde hier „>-“ als Quelltext, und keine Marken- oder
                # Platzhaltersperre sähe je eine Berechtigungsfrage.
                indent = len(line) - len(line.lstrip())
                parts = []
                for follow in lines[index + 1:]:
                    if not follow.strip():
                        break
                    if len(follow) - len(follow.lstrip()) <= indent:
                        break
                    parts.append(follow.strip())
                value = " ".join(parts)
            # Beide Targets führen `NSMotionUsageDescription`, mit verschiedenem
            # Text. Der Katalog gehört zur App, und deren Block steht zuerst:
            # `setdefault`, sonst überschreibt die Uhr den Text des iPhones.
            found.setdefault(key.strip(), value)
        return found

    @staticmethod
    def value(entry: dict, lang: str, default: str) -> str:
        loc = entry.get("localizations", {}).get(lang)
        if loc and "stringUnit" in loc:
            return loc["stringUnit"].get("value", default)
        return default

    def rows(self, lang: str, only_missing: bool = True) -> list[Row]:
        data = self.load()
        src, ref = source_language(), reference_language()
        index = context_index() if (self.with_context and self.rel == CATALOG) else {}
        rows: list[Row] = []
        for key, entry in self.keys(data):
            localizations = entry.get("localizations", {})
            if lang == src:
                continue
            target = localizations.get(lang)
            if only_missing and target is not None:
                continue
            source = self.value(entry, src, key)
            if source == key and self.rel == INFOPLIST:
                source = self.project_sources().get(key, key)
            ref_loc = localizations.get(ref)
            context = describe_context(index.get(key, [])) if index else ""
            if entry.get("comment"):
                context = (context + " — " if context else "") + entry["comment"]
            if ref_loc and ("substitutions" in ref_loc or "variations" in ref_loc):
                rows.append(Row(
                    surface=self.name, id=key, source=source,
                    reference=json.dumps(self.plural_structure(ref_loc), ensure_ascii=False),
                    context=context, kind="plural",
                    current=json.dumps(self.plural_structure(target), ensure_ascii=False) if target else None,
                    extra={"categories": language(lang)["pluralCategories"]},
                ))
                continue
            reference = self.value(entry, ref, "") if ref_loc else ""
            kind = "help" if len(source) > HELP_THRESHOLD else "ui"
            max_chars = None
            if kind == "ui":
                basis = max(len(source), len(reference))
                max_chars = int(basis * UI_LENGTH_FACTOR) + UI_LENGTH_SLACK
            rows.append(Row(
                surface=self.name, id=key, source=source, reference=reference, context=context, kind=kind,
                max_chars=max_chars, current=self.value(entry, lang, "") if target else None,
            ))
        return rows

    @staticmethod
    def plural_structure(loc: dict) -> dict:
        """`{"value": "...", "substitutions": {"arg1": {"one": "...", "other": "..."}}}`
        oder `{"variations": {"one": "...", "other": "..."}}` — die Form, die die
        Maschine zurückgeben muss."""
        result: dict = {}
        if "stringUnit" in loc:
            result["value"] = loc["stringUnit"].get("value", "")
        if "substitutions" in loc:
            result["substitutions"] = {
                name: {cat: unit["stringUnit"]["value"]
                       for cat, unit in sub.get("variations", {}).get("plural", {}).items()}
                for name, sub in loc["substitutions"].items()
            }
        if "variations" in loc and "plural" in loc["variations"]:
            result["variations"] = {cat: unit["stringUnit"]["value"] for cat, unit in loc["variations"]["plural"].items()}
        return result

    def apply(self, lang: str, results: dict[str, str], state: str = "needs_review") -> int:
        data = self.load()
        ref = reference_language()
        written = 0
        for key, text in results.items():
            entry = data["strings"].get(key)
            if entry is None:
                continue
            localizations = entry.setdefault("localizations", {})
            ref_loc = localizations.get(ref, {})
            if "substitutions" in ref_loc or "variations" in ref_loc:
                localizations[lang] = self.plural_localization(json.loads(text), ref_loc, state)
            else:
                localizations[lang] = {"stringUnit": {"state": state, "value": text}}
            written += 1
        self.save(data)
        return written

    @staticmethod
    def plural_localization(structure: dict, ref_loc: dict, state: str) -> dict:
        loc: dict = {}
        if "value" in structure:
            loc["stringUnit"] = {"state": state, "value": structure["value"]}
        if "substitutions" in structure:
            loc["substitutions"] = {}
            for name, categories in structure["substitutions"].items():
                ref_sub = ref_loc.get("substitutions", {}).get(name, {})
                loc["substitutions"][name] = {
                    "argNum": ref_sub.get("argNum", 1),
                    "formatSpecifier": ref_sub.get("formatSpecifier", "lld"),
                    "variations": {"plural": {cat: {"stringUnit": {"state": state, "value": value}}
                                              for cat, value in categories.items()}},
                }
        if "variations" in structure:
            loc["variations"] = {"plural": {cat: {"stringUnit": {"state": state, "value": value}}
                                            for cat, value in structure["variations"].items()}}
        return loc

    def coverage(self, lang: str) -> dict:
        data = self.load()
        total = done = review = 0
        for key, entry in self.keys(data):
            total += 1
            loc = entry.get("localizations", {}).get(lang)
            if loc is not None:
                done += 1
                if _state(loc) == "needs_review":
                    review += 1
        if lang == source_language():
            done = total
        return {"total": total, "done": done, "review": review}


# ---------------------------------------------------------------------------
# Store: Tools/store/<locale>.json — Listing, „Neu in dieser Version“, IAP-Texte
#
# Eine Datei je ASC-Locale, und sie trägt alles, was Apple in dieser Sprache
# zeigt: Name, Untertitel, Werbetext, Keywords, Beschreibung, „Neu in dieser
# Version“ (mit Versionsnummer) und die Texte der In-App-Käufe. `asc_metadata.py`
# und `asc_commerce.py` lesen daraus; nichts davon steht mehr in Python-Dicts.
#
# Zwei Wege in die Datei: **`sync`/`add-language`** übersetzen, was Übersetzung
# ist (Release Notes, IAP-Texte) — dieselbe Pipeline wie der Katalog. **`store-copy`**
# schreibt das Listing (Name, Untertitel, Werbetext, Keywords, Beschreibung) in
# vier Stufen, weil ein Store-Text kein übersetzter Text ist, sondern einer, der
# gefunden werden muss.

LISTING_FIELDS = ("name", "subtitle", "promotionalText", "keywords", "description")
STORE_FIELD_ORDER = ("name", "subtitle", "promotionalText", "keywords", "description", "whatsNew", "iap", "screenshots")
IAP_NAME_LIMIT = 30

# Die zwei Zeilen über einem App-Store-Screenshot. Keine Grenze von Apple,
# sondern eine des Bildes: darüber verkleinert `Tools/ScreenshotFrame.swift` die
# Überschrift unter den Grad, der in der Suchergebnisliste eines Telefons noch
# zu lesen ist. Hier zu scheitern kostet eine Minute, dort kostet es 1900 Bilder.
SCREENSHOT_LIMITS = {"headline": 46, "subline": 44}
SCREENSHOT_FIELDS = ("headline", "subline")

# Das Budget gilt in lateinischer Schrift. Ein CJK-Zeichen ist etwa doppelt so
# breit und sagt dafür mehr: 46 Zeichen Japanisch liefen über den Rand, 23 sind
# eine geräumige Überschrift. Die Zahl kommt aus dem `script` der Registry, eine
# neue Sprache bringt sie also mit.
SCREENSHOT_SCRIPT_FACTOR = {"Jpan": 0.5, "Kore": 0.5, "Hans": 0.5, "Hant": 0.5}


def screenshot_limit(field: str, script: str) -> int:
    return max(int(round(SCREENSHOT_LIMITS[field] * SCREENSHOT_SCRIPT_FACTOR.get(script, 1.0))), 12)
IAP_DESCRIPTION_LIMIT = 45
SOURCE_STORE_LOCALE = "de-DE"
KEYWORD_BUDGET = 100
# Ein Keyword, das heute trägt, weicht nur einem mit gemessen höherem Wert.
# Apple-Search-Ads-Beliebtheit reicht von 5 bis 100 — darüber ist unantastbar.
INCUMBENT_SCORE = 101
SEED_SCORE = 0.5
LATIN_LIKE_SCRIPTS = {"Latn", "Cyrl", "Grek"}

# Wie dicht eine Schrift gegenüber dem Deutschen schreibt. Ein japanischer Satz
# braucht rund 45 % der Zeichen, ein koreanischer rund 60 % — ohne diese Zahlen
# meldete die Längenprüfung jede CJK-Beschreibung als „auffällig kurz“, und eine
# Warnung, die immer steht, ist keine mehr.
SCRIPT_DENSITY = {"Jpan": 0.45, "Hans": 0.4, "Hant": 0.4, "Kore": 0.6, "Thai": 0.7}
# Pflicht in jeder Beschreibung, solange es ein Abo gibt (Guideline 3.1.2):
BRAND = "Sensorstorm"
# Sensorstorm Pro ist ein einmaliger Kauf, kein Auto-Renewable. Apple verlangt
# den EULA-Link und die Laufzeitangabe nur beim Abo, also steht hier nichts
# Pflichtiges; der Datenschutzlink hängt am appInfo, nicht an der Beschreibung.
# Beides bleibt trotzdem geprüft, aber als Warnung.
REQUIRED_DESCRIPTION_URLS: tuple[str, ...] = ()
PRIVACY_URL_PATTERN = re.compile(r"https://sensorstorm\.bognar\.net/(?:datenschutz\.html|[a-z]{2}(?:-[A-Za-z]+)?/privacy\.html)")
IAP_TITLE = "Sensorstorm Pro"
PRICE_PATTERN = re.compile(
    r"(?i)(?<![A-Za-z])(CHF|EUR|USD|GBP|JPY|CAD|AUD|BRL|MXN|INR|KRW|CNY|RUB|PLN|TRY|Fr\.)\s?\d"
    r"|[€$£¥₹₩₽]\s?\d|\d\s?[€$£¥₹₩₽]|\d+[.,]\d{2}\s?(?:CHF|EUR|USD|Fr\.)"
)
PLATFORM_PATTERN = re.compile(r"(?i)\bAndroid\b|Google Play|Play Store|\bWindows\b")

# Hinweise je ASC-Locale, wo eine Sprache mehrere Storefronts bedient. Die
# Maschine schreibt für die Storefront, nicht für „die Sprache“.
ASC_LOCALE_NOTES = {
    "de-DE": "German for Germany, Austria and Switzerland (Swiss terms allowed as keywords where they carry search volume)",
    "en-US": "American English",
    "en-GB": "British English spelling and vocabulary (colour, organise, flat, removals)",
    "en-AU": "Australian English (removalist, unit)",
    "en-CA": "Canadian English",
    "fr-FR": "French (France)",
    "fr-CA": "Canadian French (courriel, magasiner where natural)",
    "es-ES": "European Spanish (piso, mudanza)",
    "es-MX": "Mexican Spanish with neutral Latin American vocabulary (departamento, mudanza)",
    "pt-BR": "Brazilian Portuguese (mudança, apartamento)",
    "pt-PT": "European Portuguese",
    "zh-Hans": "Simplified Chinese (Singapore, Malaysia; mainland China is not a storefront of this app)",
    "zh-Hant": "Traditional Chinese (Taiwan, Hong Kong)",
    "no": "Norwegian Bokmål",
}


def locale_language(locale: str) -> dict:
    """Die Registry-Sprache zu einer ASC-Locale (`es-MX` → es)."""
    for entry in languages().values():
        if locale in entry.get("ascLocales", []):
            return entry
    known = ", ".join(sorted(l for e in languages().values() for l in e.get("ascLocales", [])))
    raise SystemExit(f"„{locale}“ ist keine Store-Locale in {REGISTRY}. Bekannt: {known}")


def all_store_locales() -> list[str]:
    """Alle ASC-Locales der Registry, Referenz zuerst — in dieser Reihenfolge
    läuft `store-copy --all`, damit die anderen die englische Fassung sehen."""
    ordered: list[str] = []
    for entry in languages().values():
        for locale in entry.get("ascLocales", []):
            if locale not in ordered:
                ordered.append(locale)
    # Die Position **vor** dem Sortieren merken: `ordered.index(l)` im
    # Sortierschlüssel liest in der Liste, die gerade umgestellt wird, und
    # findet dann Einträge nicht mehr (ValueError bei `--all`).
    position = {locale: index for index, locale in enumerate(ordered)}
    ordered.sort(key=lambda l: (0 if l == SOURCE_STORE_LOCALE else 1 if l.startswith("en") else 2, position[l]))
    return ordered


def _words(text: str) -> set[str]:
    return {w for w in re.findall(r"[^\W\d_]+", (text or "").lower()) if len(w) >= 2}


def _term_in_title(term: str, name: str, subtitle: str, script: str) -> bool:
    low = term.lower()
    if script in LATIN_LIKE_SCRIPTS:
        return low in (_words(name) | _words(subtitle)) - {BRAND.lower()}
    # CJK, Thai, Devanagari: keine Wortgrenzen — ein Teilstring zählt.
    return low in (name or "").lower() or low in (subtitle or "").lower()


def _plural_pair(a: str, b: str) -> bool:
    return a != b and (a == b + "s" or a == b + "es" or b == a + "s" or b == a + "es")


class StoreAdapter:
    name = "store"

    def exists(self) -> bool:
        return self.file(SOURCE_STORE_LOCALE).exists()

    def file(self, locale: str) -> Path:
        return path(STORE, f"{locale}.json")

    def read(self, locale: str) -> dict | None:
        if not self.file(locale).exists():
            return None
        with open(self.file(locale), encoding="utf-8") as handle:
            return json.load(handle)

    def write(self, locale: str, data: dict) -> None:
        ordered = {k: data[k] for k in STORE_FIELD_ORDER if k in data}
        ordered.update({k: v for k, v in data.items() if k not in ordered})
        self.file(locale).parent.mkdir(parents=True, exist_ok=True)
        self.file(locale).write_text(json.dumps(ordered, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    def source(self) -> dict:
        return self.read(SOURCE_STORE_LOCALE) or {}

    def reference_locale(self) -> str | None:
        for candidate in ("en-US", "en-GB", "en"):
            if self.file(candidate).exists():
                return candidate
        return None

    def product_ids(self) -> list[str]:
        return list(((self.source().get("iap") or {}).get("products") or {}).keys())

    # -- Übersetzung: Release Notes und IAP-Texte ---------------------------

    def rows(self, lang: str, only_missing: bool = True) -> list[Row]:
        if not self.exists() or lang == source_language():
            return []
        src = self.source()
        ref_locale = self.reference_locale()
        ref = (self.read(ref_locale) if ref_locale else None) or {}
        rows: list[Row] = []
        for locale in language(lang)["ascLocales"]:
            current = self.read(locale) or {}
            note = ASC_LOCALE_NOTES.get(locale, "")
            suffix = f" — {note}" if note else ""
            src_wn = src.get("whatsNew") or {}
            if src_wn.get("text"):
                cur_wn = current.get("whatsNew") or {}
                ref_wn = ref.get("whatsNew") or {}
                same_version = cur_wn.get("version") == src_wn.get("version")
                reference = ref_wn.get("text", "") if ref_wn.get("version") == src_wn.get("version") and locale != ref_locale else ""
                if not (only_missing and same_version and cur_wn.get("text")):
                    rows.append(Row(
                        self.name, f"{locale}/whatsNew", src_wn["text"], reference,
                        f"App Store „Neu in dieser Version“ {src_wn.get('version')} für {locale}{suffix}; Absätze und Aufzählung erhalten",
                        "store", max_chars=STORE_LIMITS["whatsNew"],
                        current=cur_wn.get("text") if same_version else None, extra={"version": src_wn.get("version")},
                    ))
            src_iap = src.get("iap") or {}
            cur_iap = current.get("iap") or {}
            ref_iap = ref.get("iap") or {}
            if src_iap.get("group") and not (only_missing and cur_iap.get("group")):
                rows.append(Row(
                    self.name, f"{locale}/iap/group", src_iap["group"], ref_iap.get("group", "") if locale != ref_locale else "",
                    f"Name der Abo-Gruppe im App Store für {locale}{suffix}; harte Grenze {IAP_NAME_LIMIT} Zeichen",
                    "store", max_chars=IAP_NAME_LIMIT, current=cur_iap.get("group"),
                ))
            for product_id, texts in (src_iap.get("products") or {}).items():
                cur_product = (cur_iap.get("products") or {}).get(product_id) or {}
                ref_product = (ref_iap.get("products") or {}).get(product_id) or {}
                for field_name, limit in (("name", IAP_NAME_LIMIT), ("description", IAP_DESCRIPTION_LIMIT)):
                    if not texts.get(field_name):
                        continue
                    if only_missing and cur_product.get(field_name):
                        continue
                    rows.append(Row(
                        self.name, f"{locale}/iap/{product_id}/{field_name}", texts[field_name],
                        ref_product.get(field_name, "") if locale != ref_locale else "",
                        f"In-App-Kauf {product_id}, Anzeige-{field_name} im App Store {locale}{suffix}; harte Grenze {limit} Zeichen, "
                        f"Apple indexiert den Namen für die Suche",
                        "store", max_chars=limit, current=cur_product.get(field_name),
                    ))
            src_shots = src.get("screenshots") or {}
            cur_shots = current.get("screenshots") or {}
            ref_shots = ref.get("screenshots") or {}
            for shot_key, texts in src_shots.items():
                cur_shot = cur_shots.get(shot_key) or {}
                ref_shot = ref_shots.get(shot_key) or {}
                for field_name in SCREENSHOT_FIELDS:
                    if not texts.get(field_name):
                        continue
                    if only_missing and cur_shot.get(field_name):
                        continue
                    role = ("Überschrift über dem Bild, fett und gross"
                            if field_name == "headline" else
                            "zweite Zeile unter der Überschrift, in der Akzentfarbe")
                    limit = screenshot_limit(field_name, language(lang).get("script", "Latn"))
                    rows.append(Row(
                        self.name, f"{locale}/screenshots/{shot_key}/{field_name}", texts[field_name],
                        ref_shot.get(field_name, "") if locale != ref_locale else "",
                        f"App-Store-Screenshot „{shot_key}“ für {locale}{suffix}; {role}. "
                        f"Das steht über einem Bild und wird gross gesetzt: ein Gedanke, kein Satzgefüge, "
                        f"kein Punkt am Ende nötig. Länger als {limit} Zeichen "
                        f"wird die Schrift zu klein",
                        "store", max_chars=limit, current=cur_shot.get(field_name),
                    ))
        return rows

    def apply(self, lang: str, results: dict[str, str]) -> int:
        written = 0
        src_version = (self.source().get("whatsNew") or {}).get("version")
        for locale in language(lang)["ascLocales"]:
            data = self.read(locale) or {}
            changed = False
            for row_id, value in results.items():
                if not row_id.startswith(locale + "/"):
                    continue
                parts = row_id.split("/")[1:]
                if parts == ["whatsNew"]:
                    data["whatsNew"] = {"version": src_version, "text": value}
                elif parts == ["iap", "group"]:
                    data.setdefault("iap", {})["group"] = value
                elif len(parts) == 3 and parts[0] == "iap":
                    data.setdefault("iap", {}).setdefault("products", {}).setdefault(parts[1], {})[parts[2]] = value
                elif len(parts) == 3 and parts[0] == "screenshots":
                    data.setdefault("screenshots", {}).setdefault(parts[1], {})[parts[2]] = value
                else:
                    continue
                changed = True
            if changed:
                self.write(locale, data)
                written += 1
        return written

    # -- Stand ----------------------------------------------------------------

    def is_listing_complete(self, data: dict | None) -> bool:
        return bool(data) and all(data.get(f) for f in LISTING_FIELDS)

    def is_complete(self, data: dict | None) -> bool:
        if not self.is_listing_complete(data):
            return False
        src = self.source()
        src_wn = src.get("whatsNew") or {}
        wn = data.get("whatsNew") or {}
        if src_wn.get("text") and not (wn.get("version") == src_wn.get("version") and wn.get("text")):
            return False
        src_iap = src.get("iap") or {}
        iap = data.get("iap") or {}
        if src_iap.get("group") and not iap.get("group"):
            return False
        for product_id in (src_iap.get("products") or {}):
            product = (iap.get("products") or {}).get(product_id) or {}
            if not (product.get("name") and product.get("description")):
                return False
        # Ohne die Zeilen über den Bildern kann `Tools/screenshot_frames.py` für
        # diese Locale nichts rahmen. Eine Sprache, die im Bericht fertig heisst
        # und dann den Bildlauf abbricht, ist die Sorte Zahl, die niemand mehr
        # glaubt.
        shots = data.get("screenshots") or {}
        for shot_key, texts in (src.get("screenshots") or {}).items():
            for field_name in SCREENSHOT_FIELDS:
                if texts.get(field_name) and not (shots.get(shot_key) or {}).get(field_name):
                    return False
        return True

    def coverage(self, lang: str) -> dict:
        locales = language(lang)["ascLocales"]
        if not self.exists():
            return {"done": 0, "total": len(locales), "source": STORE}
        done = sum(1 for locale in locales if self.is_complete(self.read(locale)))
        return {"done": done, "total": len(locales), "source": STORE}

    # -- Sperren --------------------------------------------------------------

    def verify(self, lang: str) -> list[Problem]:
        problems: list[Problem] = []
        if not self.exists():
            return problems
        for locale in language(lang)["ascLocales"]:
            data = self.read(locale)
            if data is not None:
                problems += self.verify_locale(locale, data)
        return problems

    def verify_locale(self, locale: str, data: dict) -> list[Problem]:
        """Die deterministischen Store-Regeln — ohne Modell, ohne Ausnahme."""
        tag = f"store/{locale}"
        problems: list[Problem] = []
        try:
            script = locale_language(locale).get("script", "Latn")
        except SystemExit:
            script = "Latn"
        aso = read_aso(locale) or {}
        competitors = [c.lower() for c in aso.get("competitors", [])]
        src = self.source()
        name = data.get("name") or ""
        subtitle = data.get("subtitle") or ""
        keywords = data.get("keywords") or ""
        promo = data.get("promotionalText") or ""
        description = data.get("description") or ""
        whats_new = data.get("whatsNew") or {}

        def err(text: str) -> None:
            problems.append(("error", f"{tag}: {text}"))

        def warn(text: str) -> None:
            problems.append(("warn", f"{tag}: {text}"))

        for field_name, limit in STORE_LIMITS.items():
            value = whats_new.get("text", "") if field_name == "whatsNew" else (data.get(field_name) or "")
            if len(value) > limit:
                err(f"{field_name} hat {len(value)} Zeichen, erlaubt {limit}")
        for field_name, limit in STORE_BYTE_LIMITS.items():
            size = len((data.get(field_name) or "").encode("utf-8"))
            if size > limit:
                err(f"{field_name} hat {size} Bytes, erlaubt {limit}")
        for field_name in ("name", "subtitle", "keywords"):
            if "\n" in (data.get(field_name) or ""):
                err(f"{field_name} enthält einen Zeilenumbruch")
        for field_name in ("name", "subtitle", "promotionalText", "description"):
            value = data.get(field_name) or ""
            if re.search(r"</?[a-zA-Z][^>]*>", value):
                err(f"{field_name} enthält HTML")
            if re.search(r"[\x00-\x08\x0b\x0c\x0e-\x1f]", value):
                err(f"{field_name} enthält Steuerzeichen")

        # Name und Untertitel: die Marke vorn, kein Wort doppelt.
        if name and not name.startswith(BRAND):
            err(f"Name beginnt nicht mit „{BRAND}“ — die Marke steht vorn, der Suchbegriff dahinter")
        if BRAND.lower() in subtitle.lower():
            err(f"Untertitel wiederholt „{BRAND}“ — verschenkte Zeichen, der Name ist ohnehin indexiert")
        if script in LATIN_LIKE_SCRIPTS:
            overlap = (_words(name) - {BRAND.lower()}) & _words(subtitle)
            if overlap:
                err(f"Wort doppelt in Name und Untertitel: {', '.join(sorted(overlap))} (Apple indexiert beide zusammen)")

        # Keywords: Bytes, Kommas, Dubletten, Plurale, Marken.
        if keywords:
            terms = [t.strip() for t in keywords.split(",")]
            lowers = [t.lower() for t in terms]
            if ", " in keywords:
                err("keywords: kein Leerzeichen nach dem Komma (kostet Bytes)")
            if any(not t for t in terms):
                err("keywords: leerer Eintrag (doppeltes Komma oder Komma am Rand)")
            duplicates = sorted({t for t in lowers if t and lowers.count(t) > 1})
            if duplicates:
                err(f"keywords doppelt: {', '.join(duplicates)}")
            if BRAND.lower() in lowers:
                err(f"„{BRAND}“ als Keyword — der Name ist ohnehin indexiert")
            in_title = [t for t in terms if t and _term_in_title(t, name, subtitle, script)]
            if in_title:
                err(f"Keyword steht schon im Namen oder Untertitel: {', '.join(in_title)}")
            if script in LATIN_LIKE_SCRIPTS:
                pairs = sorted({f"{a}/{b}" for a in lowers for b in lowers if a < b and _plural_pair(a, b)})
                if pairs:
                    err(f"Singular und Plural nebeneinander: {', '.join(pairs)} (Apple findet beide über eines)")
            brands = [t for t in terms if t.lower() in competitors]
            if brands:
                err(f"Konkurrenzmarke als Keyword: {', '.join(brands)}")
            multi = [t for t in terms if " " in t]
            if multi:
                warn(f"Mehrwort-Keyword (Apple kombiniert Einzelwörter selbst): {', '.join(multi)}")
            size = len(keywords.encode("utf-8"))
            if size < 90:
                warn(f"keywords nutzen nur {size} von {KEYWORD_BUDGET} Bytes")

        # Beschreibung und Werbetext: kein Preis, keine fremde Plattform, keine Konkurrenz, die Pflichtlinks.
        for field_name, value in (("description", description), ("promotionalText", promo), ("whatsNew", whats_new.get("text", ""))):
            if not value:
                continue
            hit = PRICE_PATTERN.search(value)
            if hit:
                err(f"{field_name}: Preis „{hit.group(0).strip()}“ — Preise sind je Storefront anders und stehen unter „In-App-Käufe“")
            hit = PLATFORM_PATTERN.search(value)
            if hit:
                err(f"{field_name}: nennt eine fremde Plattform („{hit.group(0)}“)")
            for competitor in competitors:
                if competitor in value.lower():
                    err(f"{field_name}: nennt eine Konkurrenzmarke („{competitor}“)")
        if description:
            for url in REQUIRED_DESCRIPTION_URLS:
                if url not in description:
                    err(f"description: Pflichtlink fehlt: {url}")
            if not PRIVACY_URL_PATTERN.search(description):
                warn("description: kein Datenschutz-Link (https://sensorstorm.bognar.net/datenschutz.html "
                     "oder https://sensorstorm.bognar.net/<sprache>/privacy.html); Pflicht ist nur das Feld am appInfo")
            if IAP_TITLE not in description:
                warn(f"description: nennt den Kauf „{IAP_TITLE}“ nicht beim Namen")
            src_description = src.get("description") or ""
            erwartet = 0.5 * SCRIPT_DENSITY.get(script, 1.0) * len(src_description)
            if locale != SOURCE_STORE_LOCALE and src_description and len(description) < erwartet:
                warn(f"description auffällig kurz: {len(description)} Zeichen gegenüber {len(src_description)} "
                     f"in der Quelle (erwartet mindestens {int(erwartet)})")
        if self.is_listing_complete(data) and not promo:
            warn("kein Werbetext (promotionalText)")

        # „Neu in dieser Version“ muss zur Quelle passen, sonst geht eine alte Fassung hoch.
        src_wn = src.get("whatsNew") or {}
        if src_wn.get("text") and locale != SOURCE_STORE_LOCALE and whats_new.get("version") != src_wn.get("version"):
            err(f"„Neu in dieser Version“ steht auf {whats_new.get('version') or '–'}, die Quelle auf {src_wn.get('version')} — Tools/l10n.py sync")

        # IAP-Texte: vollständig und innerhalb der Grenzen.
        src_iap = src.get("iap") or {}
        iap = data.get("iap") or {}
        if src_iap:
            # Der Gruppenname gehört zum Abo. Sensorstorm Pro ist ein einmaliger
            # Kauf, also verlangt die Quelle keine Gruppe, und dann fehlt sie hier
            # auch nicht: geprüft wird nur, was die Quelle führt.
            group = iap.get("group") or ""
            if src_iap.get("group") and not group:
                err("IAP: Name der Abo-Gruppe fehlt")
            elif len(group) > IAP_NAME_LIMIT:
                err(f"IAP: Gruppenname hat {len(group)} Zeichen, erlaubt {IAP_NAME_LIMIT}")
            for product_id in (src_iap.get("products") or {}):
                product = (iap.get("products") or {}).get(product_id) or {}
                if not (product.get("name") and product.get("description")):
                    err(f"IAP {product_id}: Text fehlt — Tools/l10n.py sync")
                    continue
                if len(product["name"]) > IAP_NAME_LIMIT:
                    err(f"IAP {product_id}: Name hat {len(product['name'])} Zeichen, erlaubt {IAP_NAME_LIMIT}")
                if len(product["description"]) > IAP_DESCRIPTION_LIMIT:
                    err(f"IAP {product_id}: Beschreibung hat {len(product['description'])} Zeichen, erlaubt {IAP_DESCRIPTION_LIMIT}")
                if "\n" in product["name"] or "\n" in product["description"]:
                    err(f"IAP {product_id}: Zeilenumbruch")

        # Die Zeilen über den App-Store-Bildern.
        src_shots = src.get("screenshots") or {}
        shots = data.get("screenshots") or {}
        for shot_key, texts in src_shots.items():
            shot = shots.get(shot_key) or {}
            for field_name in SCREENSHOT_FIELDS:
                if not texts.get(field_name):
                    continue
                value = shot.get(field_name) or ""
                if not value:
                    # Warnung, kein Fehler: die harte Sperre steht dort, wo der
                    # Text gebraucht wird. `Tools/screenshot_frames.py` malt
                    # nichts, solange eine Locale ohne Überschrift dasteht, und
                    # nennt sie beim Namen. Ein Fehler auch hier färbte das
                    # ganze Listing rot und verdeckte die Befunde, die man
                    # sonst nirgends sieht.
                    warn(f"Screenshot {shot_key}: {field_name} fehlt — Tools/l10n.py sync")
                    continue
                limit = screenshot_limit(field_name, script)
                if len(value) > limit:
                    err(f"Screenshot {shot_key}: {field_name} hat {len(value)} Zeichen, "
                        f"erlaubt {limit}")
                # Ein Umbruch im Text ist kein Umbruch im Bild: der Satz bricht dort,
                # wo die Breite es verlangt, und ein \n mitten drin gibt eine Zeile,
                # die zu früh aufhört.
                if "\n" in value:
                    err(f"Screenshot {shot_key}: {field_name} enthält einen Zeilenumbruch")
        for shot_key in shots:
            if shot_key not in src_shots:
                warn(f"Screenshot {shot_key}: gibt es in der Quelle nicht mehr")
        return problems


# ---------------------------------------------------------------------------
# ASO: das Listing je Locale in vier Stufen
#
# 1. Keyword-Kandidaten: die Maschine schlägt Suchbegriffe je Storefront vor;
#    dazu Saat-Begriffe aus der Marktkenntnis (`l10n/aso/seeds.json`) und die
#    heutigen Keywords. **Gewertet wird nach Apple-Search-Ads-Beliebtheit**, von
#    Hand in `l10n/aso/<locale>.json` unter `popularity` eingetragen — der Wert
#    entscheidet, nicht das Modell. Ein Keyword, das heute trägt, weicht nur
#    einem mit gemessen höherem Wert.
# 2. Texten: Name-Zusatz, Untertitel, Werbetext, Beschreibung — mit den stärksten
#    Begriffen in Name und Untertitel; das Keyword-Feld packt danach ein
#    Algorithmus (Bytes, keine Dublette zu Name/Untertitel, kein Plural daneben).
# 3. Unabhängiges Lektorat als App-Store-Texterin der Sprache.
# 4. Compliance gegen die Review-Richtlinien; ein Befund geht zurück zu Stufe 2,
#    nach drei Runden Sperre. Danach die deterministischen Sperren (`verify`)
#    und ein Diff-Bericht `l10n/reports/store-<locale>.md`.

ASO_DIR = "l10n/aso"
ASO_SEEDS = "l10n/aso/seeds.json"

ASO_RULES = (
    "App Store copy rules (Apple indexes name, subtitle and the keyword field together, so a word counts once):\n"
    "1. name: starts with \"Sensorstorm\", then a colon and a 1–3-word descriptor carrying the strongest search term; max 30 characters.\n"
    "2. subtitle: max 30 characters; the benefit with the next strongest terms; no word repeated from the name, never \"Sensorstorm\".\n"
    "3. promotionalText: max 170 characters; one concrete scene of use; no price, no superlatives, no \"best\", \"#1\" or \"the only\".\n"
    "4. description: up to 4000 characters; keep the structure of the source (sections in capitals, bullets, the purchase block "
    "naming \"Sensorstorm Pro\" as a one-time purchase without subscription or renewal); the first sentence says what the app is "
    "(search engines index it); no prices or currencies, no other platforms (Android, Google Play, Windows), no competitor names, "
    "no superlatives or claims that cannot be verified, no mention of the languages the app ships in.\n"
    "5. Use the ranked search terms: the top ones in name and subtitle, in their natural inflected form; do not list terms — write.\n"
    "6. Register and quotation marks of the language; native, natural phrasing for this storefront; nothing that reads like a "
    "machine translation; keep \"Sensorstorm\", \"Sensorstorm Pro\", \"iPhone\", \"iPad\", \"Apple Watch\", \"CSV\", \"GeoJSON\", "
    "\"GPX\", \"KML\", \"Blender\", \"Sensor Logger\", \"Gyroflow\", \"COLMAP\", \"QGIS\", \"ARKit\", \"MQTT\" as they are.\n"
)


def aso_path(locale: str) -> Path:
    return path(ASO_DIR, f"{locale}.json")


def read_aso(locale: str) -> dict | None:
    target = aso_path(locale)
    if not target.exists():
        return None
    with open(target, encoding="utf-8") as handle:
        return json.load(handle)


def write_aso(locale: str, data: dict) -> None:
    aso_path(locale).parent.mkdir(parents=True, exist_ok=True)
    aso_path(locale).write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def aso_seeds() -> dict:
    target = path(ASO_SEEDS)
    if not target.exists():
        return {}
    with open(target, encoding="utf-8") as handle:
        return {k: v for k, v in json.load(handle).items() if not k.startswith("$")}


def new_aso(locale: str, entry: dict) -> dict:
    seeds = aso_seeds().get(locale) or aso_seeds().get(entry["code"]) or {}
    return {
        "locale": locale,
        "language": entry["code"],
        "competitors": list(seeds.get("competitors", [])),
        "seedTerms": list(seeds.get("seedTerms", [])),
        "popularity": {},
        "candidates": [],
    }


def listing_hash(src: dict, ref: dict | None) -> str:
    parts = [src.get(f) or "" for f in LISTING_FIELDS]
    if ref:
        parts += [ref.get(f) or "" for f in LISTING_FIELDS]
    return hashlib.sha1("\x1f".join(parts).encode("utf-8")).hexdigest()


def split_keywords(keywords: str | None) -> list[str]:
    return [t.strip() for t in (keywords or "").split(",") if t.strip()]


def rank_terms(aso: dict, incumbents: list[str]) -> list[tuple[str, float, str]]:
    """(Begriff, Wert, Herkunft), absteigend nach Wert. Herkunft: incumbent
    (steht heute im Feld), seed (Marktkenntnis), machine (Stufe 1)."""
    popularity = {str(k).lower(): float(v) for k, v in (aso.get("popularity") or {}).items() if v is not None}
    order: list[tuple[str, str]] = []
    seen: set[str] = set()

    def add(term: str, source: str) -> None:
        key = term.strip()
        if key and key.lower() not in seen:
            seen.add(key.lower())
            order.append((key, source))

    for term in incumbents:
        add(term, "incumbent")
    for term in aso.get("seedTerms", []):
        add(term, "seed")
    for item in aso.get("candidates", []):
        add(item["term"] if isinstance(item, dict) else str(item), "machine")
    ranked = []
    for position, (term, source) in enumerate(order):
        value = popularity.get(term.lower())
        if value is not None:
            score = value
        elif source == "incumbent":
            score = INCUMBENT_SCORE
        elif source == "seed":
            score = SEED_SCORE
        else:
            score = 0.0
        ranked.append((term, score, source, position))
    ranked.sort(key=lambda item: (-item[1], item[3]))
    return [(term, score, source) for term, score, source, _ in ranked]


def pack_keywords(ranked: list[tuple[str, float, str]], name: str, subtitle: str, script: str,
                  competitors: list[str], admit_unvalued: bool, budget: int = KEYWORD_BUDGET) -> tuple[str, list[tuple[str, str]]]:
    """Füllt das Keyword-Feld aus der Rangliste: Bytes, keine Dublette zu Name
    und Untertitel, kein Plural neben dem Singular, keine Marke. Steht heute
    etwas im Feld, kommen unbewertete Maschinenvorschläge nicht hinein — ein
    Storefront-Ranking, das trägt, wird nicht aus Übermut angefasst."""
    chosen: list[str] = []
    lowers: set[str] = set()
    skipped: list[tuple[str, str]] = []
    competitor_set = {c.lower() for c in competitors}
    for term, score, source in ranked:
        low = term.lower()
        if low == BRAND.lower() or low in lowers:
            skipped.append((term, "Marke oder doppelt"))
            continue
        if source == "machine" and score <= 0 and not admit_unvalued:
            skipped.append((term, "ohne Beliebtheitswert — erst in l10n/aso eintragen"))
            continue
        if _term_in_title(low, name, subtitle, script):
            skipped.append((term, "steht im Namen oder Untertitel"))
            continue
        if low in competitor_set:
            skipped.append((term, "Konkurrenzmarke"))
            continue
        if script in LATIN_LIKE_SCRIPTS and any(_plural_pair(low, other) for other in lowers):
            skipped.append((term, "Plural/Singular schon drin"))
            continue
        candidate = ",".join(chosen + [term])
        if len(candidate.encode("utf-8")) > budget:
            skipped.append((term, f"kein Platz ({budget} Bytes)"))
            continue
        chosen.append(term)
        lowers.add(low)
    return ",".join(chosen), skipped


@dataclass
class StoreRunReport:
    locale: str
    engine: str
    started: str
    before: dict = field(default_factory=dict)
    after: dict = field(default_factory=dict)
    skipped: bool = False
    candidates: int = 0
    ranked: list[tuple[str, float, str]] = field(default_factory=list)
    skipped_terms: list[tuple[str, str]] = field(default_factory=list)
    review_changes: list[str] = field(default_factory=list)
    rounds: list[tuple[int, list[str]]] = field(default_factory=list)
    blocked: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def markdown(self) -> str:
        out = [f"## Lauf {self.started} · Engine {self.engine}", ""]
        if self.skipped:
            out += ["- Quelle unverändert, nichts geschrieben.", ""]
            return "\n".join(out)
        out.append(f"- Kandidaten in der Rangliste: {self.candidates}; Lektorat hat geändert: {len(self.review_changes)}; "
                   f"Runden mit Befund: {len(self.rounds)}")
        if self.blocked:
            out += ["", "### Gesperrt — nichts geschrieben"] + [f"- {b}" for b in self.blocked]
        else:
            out += ["", "### Felder (vorher → nachher)"]
            for field_name in LISTING_FIELDS:
                old = (self.before.get(field_name) or "").replace("\n", "⏎")
                new = (self.after.get(field_name) or "").replace("\n", "⏎")
                if old == new:
                    out.append(f"- `{field_name}`: unverändert ({len(new)} Zeichen)")
                elif field_name == "description":
                    out.append(f"- `{field_name}`: {len(old)} → {len(new)} Zeichen; Anfang: „{new[:120]}“")
                else:
                    out.append(f"- `{field_name}`: „{old}“ → „{new}“")
        if self.ranked:
            out += ["", "### Rangliste (Begriff · Wert · Herkunft)"]
            out += [f"- {term} · {score:g} · {source}" for term, score, source in self.ranked[:40]]
        if self.skipped_terms:
            out += ["", "### Nicht ins Keyword-Feld"] + [f"- {term}: {reason}" for term, reason in self.skipped_terms[:40]]
        if self.review_changes:
            out += ["", "### Lektorat"] + [f"- {change}" for change in self.review_changes]
        if self.rounds:
            out += ["", "### Befunde je Runde"]
            for number, findings in self.rounds:
                out += [f"- Runde {number}:"] + [f"  - {f}" for f in findings]
        if self.warnings:
            out += ["", "### Warnungen"] + [f"- {w}" for w in self.warnings]
        out.append("")
        return "\n".join(out)


def write_store_report(report: StoreRunReport) -> Path:
    path(REPORT_DIR).mkdir(parents=True, exist_ok=True)
    target = path(REPORT_DIR, f"store-{report.locale}.md")
    header = f"# Store-Bericht {report.locale}\n\n" if not target.exists() else ""
    with open(target, "a", encoding="utf-8") as handle:
        handle.write(header + report.markdown() + "\n")
    return target


def store_copy_locale(locale: str, engine_name: str, max_rounds: int = 3, force: bool = False,
                      allow_rename: bool = False, log=print) -> StoreRunReport:
    adapter = StoreAdapter()
    if not adapter.exists():
        raise SystemExit(f"{STORE}/{SOURCE_STORE_LOCALE}.json fehlt — ohne Quelle kein Store-Text.")
    entry = locale_language(locale)
    src = adapter.source()
    ref_locale = adapter.reference_locale()
    is_source = locale == SOURCE_STORE_LOCALE
    is_reference = locale == ref_locale
    ref = src if (is_source or is_reference) else ((adapter.read(ref_locale) if ref_locale else None) or {})
    current = adapter.read(locale) or {}
    aso = read_aso(locale) or new_aso(locale, entry)
    digest = listing_hash(src, None if (is_source or is_reference) else ref)
    started = _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="minutes")
    report = StoreRunReport(locale, engine_name, started, before=dict(current))
    if not force and aso.get("sourceHash") == digest and adapter.is_listing_complete(current):
        report.skipped = True
        log(f"{locale}: Quelle unverändert — nichts zu tun (--force erzwingt)")
        return report
    engine = make_engine(engine_name)
    report.engine = engine.name
    incumbents = split_keywords(current.get("keywords"))

    # Stufe 1: Kandidaten sammeln — nur ergänzen, nie streichen.
    known = {str(item["term"] if isinstance(item, dict) else item).lower() for item in aso.get("candidates", [])}
    known |= {t.lower() for t in incumbents} | {t.lower() for t in aso.get("seedTerms", [])}
    today = _dt.date.today().isoformat()
    for term in engine.aso_candidates(entry, locale, src, ref, aso):
        term = term.strip().strip(",")
        if term and term.lower() not in known and "," not in term:
            aso.setdefault("candidates", []).append({"term": term, "source": "machine", "added": today})
            known.add(term.lower())
    ranked = rank_terms(aso, incumbents)
    report.candidates = len(ranked)
    report.ranked = ranked

    # Stufe 2–4, höchstens max_rounds Runden.
    keep_title = bool(current.get("name")) and not allow_rename
    findings: list[str] = []
    draft: dict = {}
    problems: list[Problem] = []
    for round_number in range(1, max_rounds + 1):
        if is_source:
            draft = {f: src.get(f, "") for f in ("name", "subtitle", "promotionalText", "description")}
        else:
            draft = engine.store_copy(entry, locale, src, ref, ranked, current, keep_title, findings)
            if keep_title:
                draft["name"], draft["subtitle"] = current["name"], current.get("subtitle", "")
            reviewed = engine.store_review(entry, locale, draft, src, ref)
            report.review_changes += [c for c in reviewed.pop("changes", []) if c]
            for field_name in ("name", "subtitle", "promotionalText", "description"):
                if reviewed.get(field_name):
                    draft[field_name] = reviewed[field_name]
            if keep_title:
                draft["name"], draft["subtitle"] = current["name"], current.get("subtitle", "")
        draft["keywords"], report.skipped_terms = pack_keywords(
            ranked, draft["name"], draft["subtitle"], entry.get("script", "Latn"), aso.get("competitors", []),
            admit_unvalued=not incumbents,
        )
        compliance = {"ok": True, "findings": []} if is_source else engine.store_compliance(entry, locale, draft)
        problems = adapter.verify_locale(locale, {**current, **draft})
        hard = errors(problems)
        if compliance["ok"] and not hard:
            break
        findings = list(compliance["findings"]) + hard
        report.rounds.append((round_number, findings))
        if is_source:
            break  # die Quelle schreibt kein Modell um — der Befund geht an den Menschen
    else:
        report.blocked = findings or ["Compliance nach allen Runden nicht bestätigt"]
    if is_source and errors(problems):
        report.blocked = errors(problems)
    if report.blocked:
        target = write_store_report(report)
        log(f"{locale}: gesperrt — {target.relative_to(ROOT)}")
        return report

    data = {**current, **draft}
    adapter.write(locale, data)
    aso["sourceHash"] = digest
    aso["chosen"] = draft["keywords"]
    aso["updated"] = today
    write_aso(locale, aso)
    report.after = data
    report.warnings = warnings(problems)
    target = write_store_report(report)
    log(f"{locale}: geschrieben — Keywords {len(draft['keywords'].encode('utf-8'))} Bytes, "
        f"Lektorat {len(report.review_changes)}, Runden {len(report.rounds)}, Warnungen {len(report.warnings)} — {target.relative_to(ROOT)}")
    return report


def store_accept_source(locale: str, log=print) -> bool:
    """Den neuen Quellstand übernehmen, ohne das Listing anzufassen.

    `store-copy` merkt sich den Hash der deutschen Quelle und läuft wieder,
    sobald sie sich bewegt. Das ist richtig, wenn sich der Inhalt ändert, und
    zu viel, wenn nur die Zeichensetzung aufgeräumt wurde: das Listing dieser
    Sprache stimmt weiter, und ein erzwungener Lauf würde ein Ranking anfassen,
    das heute trägt.

    Wer das ruft, sagt damit: die Quelle hat sich geändert, die Übersetzung
    bleibt gültig. Wo das nicht stimmt, gehört `store-copy --force` hin.
    """
    adapter = StoreAdapter()
    entry = locale_language(locale)
    src = adapter.source()
    ref_locale = adapter.reference_locale()
    is_source = locale == SOURCE_STORE_LOCALE
    is_reference = locale == ref_locale
    ref = src if (is_source or is_reference) else ((adapter.read(ref_locale) if ref_locale else None) or {})
    digest = listing_hash(src, None if (is_source or is_reference) else ref)
    aso = read_aso(locale) or new_aso(locale, entry)
    if aso.get("sourceHash") == digest:
        log(f"{locale}: Quelle war schon übernommen")
        return False
    aso["sourceHash"] = digest
    write_aso(locale, aso)
    log(f"{locale}: neuer Quellstand übernommen, Listing unverändert")
    return True


def store_copy_locales(locales: list[str], engine_name: str, max_rounds: int, force: bool, allow_rename: bool, log=print) -> int:
    failures = 0
    for locale in locales:
        report = store_copy_locale(locale, engine_name, max_rounds=max_rounds, force=force, allow_rename=allow_rename, log=log)
        failures += 1 if report.blocked else 0
    return failures


class ProjectAdapter:
    """`CFBundleLocalizations` in project.yml — für beide Targets."""
    name = "project"
    KEY = "CFBundleLocalizations:"

    def exists(self) -> bool:
        return path(PROJECT).exists()

    def blocks(self, text: str) -> list[tuple[int, int, str, list[str]]]:
        """(Startzeile, Endzeile exklusiv, Einrückung der Einträge, Codes) je Block."""
        lines = text.split("\n")
        result = []
        for i, line in enumerate(lines):
            if line.strip() == self.KEY:
                codes, indent, j = [], None, i + 1
                while j < len(lines):
                    match = re.match(r"^(\s*)-\s+(\S+)\s*$", lines[j])
                    if not match:
                        break
                    indent = match.group(1)
                    codes.append(match.group(2))
                    j += 1
                result.append((i, j, indent or "          ", codes))
        return result

    def coverage(self, lang: str) -> dict:
        if not self.exists():
            return {"declared": 0, "blocks": 0}
        blocks = self.blocks(path(PROJECT).read_text(encoding="utf-8"))
        return {"declared": sum(1 for b in blocks if lang in b[3]), "blocks": len(blocks)}

    def add(self, lang: str) -> int:
        text = path(PROJECT).read_text(encoding="utf-8")
        lines = text.split("\n")
        added = 0
        for start, end, indent, codes in reversed(self.blocks(text)):
            if lang in codes:
                continue
            lines.insert(end, f"{indent}- {lang}")
            added += 1
        if added:
            path(PROJECT).write_text("\n".join(lines), encoding="utf-8")
        return added

    def verify(self) -> list[str]:
        if not self.exists():
            return []
        blocks = self.blocks(path(PROJECT).read_text(encoding="utf-8"))
        problems = []
        known = set(languages())
        for _, _, _, codes in blocks:
            for code in codes:
                if code not in known:
                    problems.append(f"project.yml: CFBundleLocalizations nennt „{code}“, die Registry kennt es nicht")
        if len(blocks) >= 2 and any(set(b[3]) != set(blocks[0][3]) for b in blocks[1:]):
            problems.append("project.yml: die CFBundleLocalizations der Targets stimmen nicht überein")
        return problems


# ---------------------------------------------------------------------------
# Übersetzungsgedächtnis


class Memory:
    def __init__(self, lang: str):
        self.lang = lang
        self.file = path(MEMORY_DIR, f"{lang}.jsonl")
        self.entries: dict[str, dict] = {}
        if self.file.exists():
            for line in self.file.read_text(encoding="utf-8").splitlines():
                if line.strip():
                    entry = json.loads(line)
                    self.entries[entry["h"]] = entry

    def get(self, row: Row) -> str | None:
        entry = self.entries.get(row.hash)
        return entry["tgt"] if entry and entry.get("stage", 0) >= 3 else None

    def put(self, row: Row, text: str, stage: int, model: str) -> None:
        self.entries[row.hash] = {
            "h": row.hash, "surface": row.surface, "id": row.id, "src": row.source, "tgt": text,
            "stage": stage, "model": model, "at": _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds"),
        }

    def save(self) -> None:
        self.file.parent.mkdir(parents=True, exist_ok=True)
        with open(self.file, "w", encoding="utf-8") as handle:
            for entry in self.entries.values():
                handle.write(json.dumps(entry, ensure_ascii=False) + "\n")

    def settled_terms(self, terms: list[dict]) -> dict[str, str]:
        """Glossarbegriffe, die für diese Sprache schon eine Übersetzung im
        Gedächtnis haben — sie gelten ab dann verbindlich."""
        by_source = {e["src"]: e["tgt"] for e in self.entries.values() if e.get("stage", 0) >= 3}
        return {t["de"]: by_source[t["de"]] for t in terms if t["de"] in by_source}


# ---------------------------------------------------------------------------
# Deterministische Prüfung eines Textes
#
# Zwei Stufen: ein `error` sperrt den Import (Platzhalter, Plural-Struktur,
# Marken, HTML, Steuerzeichen, Zeilenumbrüche, Bytes im Store), eine `warn`
# steht im Bericht (Längenbudget, gleich wie die Quelle, weiche Marken).

Problem = tuple[str, str]  # ("error" | "warn", Text)


def errors(problems: list[Problem]) -> list[str]:
    return [text for level, text in problems if level == "error"]


def warnings(problems: list[Problem]) -> list[str]:
    return [text for level, text in problems if level == "warn"]


def check_text(row: Row, text: str, entry: dict, gloss: dict) -> list[Problem]:
    if row.kind == "plural":
        try:
            structure = json.loads(text)
        except json.JSONDecodeError:
            return [("error", "Plural: keine gültige JSON-Struktur")]
        reference = json.loads(row.reference)
        if set(structure) != set(reference):
            return [("error", f"Plural: Struktur {sorted(structure)} statt {sorted(reference)}")]
        problems: list[Problem] = []
        categories = set(entry["pluralCategories"])
        if "value" in structure:
            problems += _check_plain(row, structure["value"], reference["value"], entry, gloss, "Hauptsatz")
        for name, cats in structure.get("substitutions", {}).items():
            if set(cats) != categories:
                problems.append(("error", f"Plural: {name} hat Kategorien {sorted(cats)}, erwartet {sorted(categories)}"))
            for cat, value in cats.items():
                if "%arg" not in value:
                    problems.append(("error", f"Plural: {name}/{cat} ohne %arg"))
        if "variations" in structure and set(structure["variations"]) != categories:
            problems.append(("error", f"Plural: Kategorien {sorted(structure['variations'])}, erwartet {sorted(categories)}"))
        return problems
    return _check_plain(row, text, row.reference or row.source, entry, gloss, "")


def _brand_present(brand: str, text: str, entry: dict) -> bool:
    """Steht der Markenname im Zieltext, notfalls dekliniert?

    Die Sperre sucht sonst die Zeichenfolge. Das reicht für Sprachen, die
    lateinische Eigennamen unverändert lassen, und ist falsch für die, die sie
    beugen: „na iPhonie“ ist der polnische Lokativ von iPhone, und
    „iPhone“ steht darin nicht mehr als Zeichenfolge. Ohne diese Ausnahme
    müsste Polnisch falsch schreiben, um die Sperre zu bestehen — und eine
    Sperre, die korrektes Deutsch, Polnisch oder Tschechisch ablehnt, wird
    umgangen statt befolgt.

    Geprüft wird deshalb der **Stamm**: der Markenname ohne seinen Endvokal,
    gefolgt von höchstens drei Buchstaben. Eine Übersetzung, die den Namen
    wirklich übersetzt („二维码“ statt „QR“), enthält den Stamm nicht und wird
    weiter abgelehnt. Kurze Marken (QR, PDF, CSV) und solche mit Leerzeichen
    (App Store) bleiben auf der strengen Regel.
    """
    if brand in text:
        return True
    if not entry.get("inflectsBrands") or " " in brand or len(brand) < 5:
        return False
    stamm = brand[:-1] if brand[-1:].lower() in "aeiouy" else brand
    if len(stamm) < 4:
        return False
    return re.search(re.escape(stamm) + r"[\u2019\']?[^\W\d_]{0,3}(?![A-Za-z])", text) is not None


def _strip_placeholders(text: str) -> str:
    return PLACEHOLDER.sub("", text or "")


def _check_plain(row: Row, text: str, reference: str, entry: dict, gloss: dict, label: str) -> list[Problem]:
    prefix = f"{label}: " if label else ""
    problems: list[Problem] = []
    source = row.source if not label else reference  # im Plural-Hauptsatz ist die Referenz der Massstab
    if not text or not text.strip():
        return [("error", prefix + "leer")] if source.strip() else []
    if placeholder_signature(text) != placeholder_signature(source):
        problems.append(("error", f"{prefix}Platzhalter {placeholders(text)} statt {placeholders(source)}"))
    positions = positional_indices(text)
    if positions and positions != list(range(1, len(positions) + 1)):
        problems.append(("error", f"{prefix}Positionen {positions} sind lückenhaft"))
    if _strip_placeholders(text).count("%") > _strip_placeholders(source).count("%"):
        problems.append(("error", f"{prefix}einzelnes % ohne Platzhalter (muss %% sein)"))
    if re.search(r"[\x00-\x08\x0b\x0c\x0e-\x1f]", text):
        problems.append(("error", f"{prefix}Steuerzeichen"))
    if re.search(r"</?[a-zA-Z][^>]*>", text):
        problems.append(("error", f"{prefix}HTML"))
    # Siri-Sätze tragen den App-Namen als Token (`${applicationName}`). Apple
    # lehnt einen Satz ohne ihn ab — er wäre nicht mehr unterscheidbar von
    # fremden Kurzbefehlen —, und eine Übersetzung, die ihn wegübersetzt,
    # nimmt der Sprache still ihre Sprachbefehle.
    for token in APP_TOKEN.findall(source):
        if token not in text:
            problems.append(("error", f"{prefix}„{token}“ fehlt"))
    if text.count("\n") != source.count("\n"):
        problems.append(("error", f"{prefix}Zeilenumbrüche {text.count(chr(10))} statt {source.count(chr(10))}"))
    for brand in gloss.get("doNotTranslate", []):
        if re.search(r"(?<![A-Za-z])" + re.escape(brand) + r"(?![A-Za-z])", source) and not _brand_present(brand, text, entry):
            problems.append(("error", f"{prefix}„{brand}“ fehlt"))
    if row.max_bytes and len(text.encode("utf-8")) > row.max_bytes:
        problems.append(("error", f"{prefix}{len(text.encode('utf-8'))} Bytes, Grenze {row.max_bytes}"))
    if row.kind == "store" and row.max_chars and len(text) > row.max_chars:
        problems.append(("error", f"{prefix}{len(text)} Zeichen, Grenze {row.max_chars}"))
    # Warnungen
    if "  " in text and "  " not in source:
        problems.append(("warn", f"{prefix}doppeltes Leerzeichen"))
    if text != text.strip() and source == source.strip():
        problems.append(("warn", f"{prefix}Leerzeichen am Rand"))
    for brand in gloss.get("keepIfPossible", []):
        if not re.search(r"(?<![A-Za-z])" + re.escape(brand) + r"(?![A-Za-z])", source):
            continue
        # Die landesübliche Kurzform zählt als übernommen: „AR“ heisst auf
        # Portugiesisch, Spanisch, Französisch und Italienisch „RA“, und eine
        # Warnung je Sprache und Vorkommen verdeckt nur die echten.
        local = gloss.get("localNames", {}).get(brand, {}).get(entry["code"])
        if not _brand_present(brand, text, entry) and not (local and local in text):
            problems.append(("warn", f"{prefix}„{brand}“ nicht übernommen"))
    for regel in entry.get("avoid", []):
        # Anrede und Regionalismen: die Registry sagt je Sprache, was nicht
        # vorkommen darf. Ohne das driftet eine Sprache still auseinander —
        # Französisch siezte in 100 Texten und duzte in 18.
        if re.search(regel["pattern"], text, re.IGNORECASE if regel.get("ignoreCase") else 0):
            problems.append(("warn", f"{prefix}{regel['reason']}"))
    if row.max_chars and row.kind == "ui" and len(text) > row.max_chars:
        problems.append(("warn", f"{prefix}{len(text)} Zeichen, Budget {row.max_chars}"))
    if entry["code"] != source_language() and text.strip() == row.source.strip():
        allowed = set(gloss.get("identicalAllowed", [])) | set(gloss.get("doNotTranslate", [])) | set(gloss.get("keepIfPossible", []))
        bare = _strip_placeholders(row.source)
        words = [w for w in re.findall(r"[A-Za-zÀ-ÿ]+", bare) if len(w) >= 3]
        if row.source.strip() not in allowed and len(words) >= 2:
            problems.append(("warn", f"{prefix}unübersetzt (gleich wie die Quelle)"))
    return problems


# ---------------------------------------------------------------------------
# Engines


class MockEngine:
    """Offline: Präfix je Sprache, Platzhalter bleiben. Für Tests und
    Trockenläufe — sagt nichts über Qualität, alles über die Mechanik."""
    name = "mock"

    def translate(self, entry: dict, rows: list[Row], guidance: str) -> dict[str, str]:
        out: dict[str, str] = {}
        for row in rows:
            if row.kind == "plural":
                reference = json.loads(row.reference)
                structure: dict = {}
                if "value" in reference:
                    structure["value"] = f"[{entry['code']}] " + reference["value"]
                if "substitutions" in reference:
                    structure["substitutions"] = {
                        name: {cat: f"[{entry['code']}] " + cats.get("other", next(iter(cats.values())))
                               for cat in entry["pluralCategories"]}
                        for name, cats in reference["substitutions"].items()
                    }
                if "variations" in reference:
                    structure["variations"] = {cat: f"[{entry['code']}] " + reference["variations"].get("other", "")
                                               for cat in entry["pluralCategories"]}
                out[row.id] = json.dumps(structure, ensure_ascii=False)
            else:
                draft = f"[{entry['code']}] {row.source}"
                # Store-Felder haben harte Grenzen; die Mechanik-Engine hält sie ein.
                if row.kind == "store" and row.max_chars and len(draft) > row.max_chars:
                    draft = draft[:row.max_chars]
                out[row.id] = draft
        return out

    def review(self, entry: dict, rows: list[Row], drafts: dict[str, str], guidance: str) -> dict[str, dict]:
        return {row.id: {"text": drafts[row.id], "changed": False, "reason": ""} for row in rows if row.id in drafts}

    def backcheck(self, entry: dict, rows: list[Row], drafts: dict[str, str]) -> dict[str, dict]:
        return {row.id: {"back": row.reference or row.source, "verdict": "same", "reason": ""} for row in rows if row.id in drafts}

    # -- Store (ASO) — Mechanik ohne Modell ---------------------------------------

    def aso_candidates(self, entry: dict, locale: str, src: dict, ref: dict, aso: dict) -> list[str]:
        return split_keywords(ref.get("keywords")) + split_keywords(src.get("keywords"))

    def store_copy(self, entry: dict, locale: str, src: dict, ref: dict, ranked: list, current: dict,
                   keep_title: bool, findings: list[str]) -> dict:
        code = entry["code"]
        return {
            "name": ref.get("name", ""),
            "subtitle": ref.get("subtitle", ""),
            "promotionalText": (f"[{code}] " + (ref.get("promotionalText") or ""))[:STORE_LIMITS["promotionalText"]],
            "description": f"[{code}] " + (ref.get("description") or ""),
        }

    def store_review(self, entry: dict, locale: str, draft: dict, src: dict, ref: dict) -> dict:
        return {**draft, "changes": []}

    def store_compliance(self, entry: dict, locale: str, draft: dict) -> dict:
        return {"ok": True, "findings": []}

class ClaudeEngine:
    """Drei Aufrufe je Paket: übersetzen, lektorieren, rückübersetzen und
    urteilen. Strukturierte JSON-Ausgabe, Glossar und Sprachregeln als
    gecachter System-Prompt. Modell claude-opus-5 — Qualität vor Preis."""
    name = MODEL

    def __init__(self, model: str = MODEL):
        try:
            import anthropic  # noqa: WPS433
            from pydantic import BaseModel  # noqa: WPS433
        except ImportError as error:
            raise SystemExit("pip install anthropic — die Pipeline braucht das Python-SDK") from error
        self.anthropic = anthropic
        self.client = anthropic.Anthropic()
        self.model = model

        class TranslationItem(BaseModel):
            id: str
            text: str

        class TranslationBatch(BaseModel):
            items: list[TranslationItem]

        class ReviewItem(BaseModel):
            id: str
            text: str
            changed: bool
            reason: str

        class ReviewBatch(BaseModel):
            items: list[ReviewItem]

        class BackcheckItem(BaseModel):
            id: str
            back: str
            verdict: str
            reason: str

        class BackcheckBatch(BaseModel):
            items: list[BackcheckItem]

        self.TranslationBatch, self.ReviewBatch, self.BackcheckBatch = TranslationBatch, ReviewBatch, BackcheckBatch

        class AsoCandidates(BaseModel):
            items: list[str]

        class StoreCopy(BaseModel):
            name: str
            subtitle: str
            promotionalText: str
            description: str

        class StoreReview(BaseModel):
            name: str
            subtitle: str
            promotionalText: str
            description: str
            changes: list[str]

        class StoreCompliance(BaseModel):
            ok: bool
            findings: list[str]

        self.AsoCandidates, self.StoreCopy, self.StoreReview, self.StoreCompliance = AsoCandidates, StoreCopy, StoreReview, StoreCompliance

    def _call(self, system: str, user: str, output_format):
        for attempt in range(4):
            try:
                response = self.client.messages.parse(
                    model=self.model,
                    max_tokens=16000,
                    system=[{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
                    messages=[{"role": "user", "content": user}],
                    output_format=output_format,
                )
                return response.parsed_output
            except (self.anthropic.RateLimitError, self.anthropic.APIConnectionError, self.anthropic.InternalServerError):
                time.sleep(2 ** attempt * 5)
        raise SystemExit("Die API antwortete viermal nicht — später erneut versuchen, das Gedächtnis hält den Stand.")

    @staticmethod
    def _rows_block(rows: list[Row], drafts: dict[str, str] | None = None) -> str:
        lines = []
        for row in rows:
            item = {"id": row.id, "source_de": row.source, "reference_en": row.reference, "context": row.context,
                    "kind": row.kind, "placeholders": placeholders(row.source)}
            if row.max_chars:
                item["max_chars"] = row.max_chars
            if row.max_bytes:
                item["max_bytes"] = row.max_bytes
            if row.kind == "plural":
                item["plural_categories"] = row.extra.get("categories")
                item["expected_shape"] = "JSON string with the same keys as reference_en, plural categories replaced by the target language's categories; keep %arg"
            if drafts is not None:
                item["draft"] = drafts.get(row.id, "")
            lines.append(json.dumps(item, ensure_ascii=False))
        return "\n".join(lines)

    def translate(self, entry: dict, rows: list[Row], guidance: str) -> dict[str, str]:
        system = (
            f"You are the localization engineer for Sensorstorm, an iOS app that records every phone sensor on one clock "
            f"(acceleration, rotation rate, orientation, magnetic field, GPS, barometer, audio level, pedometer, video, "
            f"Apple Watch heart rate) and documents field observations along a route (photos, position with its accuracy, "
            f"a severity from 1 to 10, a marked area), with export to CSV, JSON, SQLite, GeoJSON, GPX, KML, Blender and "
            f"photogrammetry. Translate UI strings into {entry['englishName']} ({entry['code']}).\n"
            f"Rules: (1) Keep every placeholder exactly (%@, %lld, %1$@, %#@arg@, %%) — same count and types; you may reorder "
            f"with positional indices when grammar needs it. (2) Register: {entry['register']}. Quotation marks: "
            f"{entry['quotes'][0]}…{entry['quotes'][1]}. (3) UI strings must fit max_chars; prefer short, natural phrasing "
            f"native speakers expect in iOS apps in this language; never explain. (4) Help texts (kind=help) are prose: "
            f"translate faithfully, keep paragraph breaks. (5) Brand, format and product names stay: Sensorstorm, Sensorstorm Pro, "
            f"App Store, Apple Watch, ARKit, Blender, Sensor Logger, Gyroflow, COLMAP, QGIS, MQTT, CSV, JSON, SQLite, GeoJSON, "
            f"GPX, KML, EXIF, GPS, IMU, Hz. (6) Use the glossary consistently. (7) Output only the JSON structure requested.\n\n"
            f"{guidance}"
        )
        user = ("Translate each item. Return items with the same ids. For kind=plural, `text` is a JSON string of the "
                "structure described in expected_shape.\n\n" + self._rows_block(rows))
        parsed = self._call(system, user, self.TranslationBatch)
        return {item.id: item.text for item in parsed.items}

    def review(self, entry: dict, rows: list[Row], drafts: dict[str, str], guidance: str) -> dict[str, dict]:
        system = (
            f"You are an independent native-speaking editor ({entry['englishName']}, {entry['code']}) who reviews iOS app "
            f"localizations before release. You see the German source, the English reference and a draft. Correct anything "
            f"unnatural, wrong in meaning, inconsistent with the glossary, wrong in register ({entry['register']}), wrongly "
            f"punctuated (quotes {entry['quotes'][0]}…{entry['quotes'][1]}), or over the length budget. Keep placeholders "
            f"exactly. If the draft is good, return it unchanged with changed=false. Every change needs a one-line reason.\n\n"
            f"{guidance}"
        )
        user = "Review each draft.\n\n" + self._rows_block(rows, drafts)
        parsed = self._call(system, user, self.ReviewBatch)
        return {item.id: {"text": item.text, "changed": item.changed, "reason": item.reason} for item in parsed.items}

    def backcheck(self, entry: dict, rows: list[Row], drafts: dict[str, str]) -> dict[str, dict]:
        system = (
            f"You are a meaning checker. For each item, translate the draft ({entry['englishName']}) back into English "
            f"literally, then compare with reference_en (or source_de). verdict: 'same' (same meaning, tone may differ), "
            f"'different' (meaning shifted, information lost or added), 'dangerous' (negation inverted, number or amount "
            f"changed, action or actor swapped, a warning turned into a confirmation). Give a short reason."
        )
        user = "Check each draft.\n\n" + self._rows_block(rows, drafts)
        parsed = self._call(system, user, self.BackcheckBatch)
        return {item.id: {"back": item.back, "verdict": item.verdict, "reason": item.reason} for item in parsed.items}

    # -- Store (ASO): vier Stufen, jede ein eigener Aufruf --------------------------

    @staticmethod
    def _store_context(entry: dict, locale: str, src: dict, ref: dict) -> str:
        note = ASC_LOCALE_NOTES.get(locale, "")
        listing = {f: src.get(f, "") for f in LISTING_FIELDS}
        reference = {f: ref.get(f, "") for f in LISTING_FIELDS}
        return (
            f"Storefront locale: {locale} ({entry['englishName']}, {entry['code']}){' — ' + note if note else ''}. "
            f"Register: {entry['register']}. Quotation marks: {entry['quotes'][0]}…{entry['quotes'][1]}.\n\n"
            f"German source listing (authoritative for facts):\n{json.dumps(listing, ensure_ascii=False, indent=1)}\n\n"
            f"English reference listing:\n{json.dumps(reference, ensure_ascii=False, indent=1)}"
        )

    def aso_candidates(self, entry: dict, locale: str, src: dict, ref: dict, aso: dict) -> list[str]:
        system = (
            "You are an App Store Optimization specialist for the storefront named below. Propose the search terms people in "
            "this market type into the App Store when they look for an app that logs phone sensors and documents damage in "
            "the field: data logger, accelerometer, gyroscope, GPS track, vibration, road survey, pothole, inspection, "
            "photogrammetry, CSV export. Single words in the target language (compounds where the language "
            "compounds), lowercase unless a proper noun, no brand names, no plural of a term you already listed, nothing that "
            "'Sensorstorm' already covers, no generic words (app, free, new). 25 to 40 terms, ordered by your estimate of search "
            "volume in this storefront, strongest first. Output only the JSON requested."
        )
        existing = [str(item["term"] if isinstance(item, dict) else item) for item in aso.get("candidates", [])]
        user = (
            self._store_context(entry, locale, src, ref)
            + "\n\nAlready known candidates (do not repeat): " + (", ".join(existing) or "–")
            + "\nSeed terms from market research: " + (", ".join(aso.get("seedTerms", [])) or "–")
            + "\nCompetitor names, never to be proposed: " + (", ".join(aso.get("competitors", [])) or "–")
        )
        parsed = self._call(system, user, self.AsoCandidates)
        return [str(item) for item in parsed.items]

    def store_copy(self, entry: dict, locale: str, src: dict, ref: dict, ranked: list, current: dict,
                   keep_title: bool, findings: list[str]) -> dict:
        system = (
            "You write App Store listings for Sensorstorm, an iOS app that records every phone sensor on one shared clock and "
            "documents field observations along a route, with export to CSV, JSON, SQLite, GeoJSON, GPX, KML, Blender and "
            "photogrammetry; Sensorstorm Pro unlocks the rest as a one-time purchase. You write for the storefront "
            "named below as a native copywriter would: the text must read as if it had been written in that language for that "
            "market, never like a translation. Facts come from the German source only — nothing is promised that the source does "
            "not promise.\n\n" + ASO_RULES
        )
        user = self._store_context(entry, locale, src, ref)
        user += "\n\nRanked search terms for this storefront (term · popularity · origin), strongest first:\n" + "\n".join(
            f"- {term} · {score:g} · {source}" for term, score, source in ranked[:30])
        if keep_title:
            user += (f"\n\nKeep name and subtitle exactly as they are — they carry a ranking today:\nname: {current.get('name', '')}"
                     f"\nsubtitle: {current.get('subtitle', '')}")
        if current.get("description"):
            user += "\n\nCurrent description in this storefront (improve, do not discard what works):\n" + current["description"]
        if findings:
            user += "\n\nThe previous draft was rejected. Fix these findings:\n" + "\n".join(f"- {f}" for f in findings)
        user += "\n\nWrite name, subtitle, promotionalText and description. Return only the JSON."
        parsed = self._call(system, user, self.StoreCopy)
        return {"name": parsed.name, "subtitle": parsed.subtitle, "promotionalText": parsed.promotionalText,
                "description": parsed.description}

    def store_review(self, entry: dict, locale: str, draft: dict, src: dict, ref: dict) -> dict:
        system = (
            f"You are an independent App Store copywriter and native speaker for the storefront {locale} ({entry['englishName']}). "
            "You review a listing draft against the German source and the English reference: natural wording a local would "
            "write, search intent (would someone looking for a moving app understand and trust this at a glance?), register, "
            "punctuation, the length limits (name 30, subtitle 30, promotionalText 170, description 4000 characters), and "
            "fidelity — nothing promised that the source does not promise, nothing left out that the source states. Correct "
            "what needs correcting, keep what is good, keep both legal links and the subscription block intact, and list every "
            "change with a one-line reason. Output only the JSON requested.\n\n" + ASO_RULES
        )
        user = self._store_context(entry, locale, src, ref) + "\n\nDraft to review:\n" + json.dumps(draft, ensure_ascii=False, indent=1)
        parsed = self._call(system, user, self.StoreReview)
        return {"name": parsed.name, "subtitle": parsed.subtitle, "promotionalText": parsed.promotionalText,
                "description": parsed.description, "changes": [str(c) for c in parsed.changes]}

    def store_compliance(self, entry: dict, locale: str, draft: dict) -> dict:
        system = (
            "You are the compliance check for App Store metadata against the App Store Review Guidelines (2.3 Accurate "
            "Metadata, 3.1.1 In-App Purchase, 5.1.1 Privacy). Fail the draft if it promises a feature that a sensor-logging and "
            "field-survey app with video, GPS, photogrammetry and CSV/JSON/GeoJSON export does not plausibly have; "
            "uses superlatives or unverifiable claims (best, #1, most popular, guaranteed, everyone); mentions prices or "
            "currencies; names other platforms or competitors; misdescribes the purchase (Sensorstorm Pro is a one-time "
            "non-consumable purchase, never a subscription and never auto-renewing); "
            "contains keyword stuffing, placeholder text, a claim about the languages the app ships in, or text in another "
            "language than the storefront's. Otherwise pass. Findings are short, actionable sentences. Output only the JSON."
        )
        user = f"Storefront {locale} ({entry['englishName']}).\n\nDraft:\n" + json.dumps(draft, ensure_ascii=False, indent=1)
        parsed = self._call(system, user, self.StoreCompliance)
        return {"ok": bool(parsed.ok), "findings": [str(f) for f in parsed.findings]}

def make_engine(name: str):
    return MockEngine() if name == "mock" else ClaudeEngine()


def guidance_block(entry: dict, memory: Memory) -> str:
    gloss = glossary()
    lines = ["Glossary (German source → English reference; note):"]
    settled = memory.settled_terms(gloss["terms"])
    for term in gloss["terms"]:
        fixed = term.get(entry["code"]) or settled.get(term["de"])
        line = f"- {term['de']} → {term['en']}"
        if fixed:
            line += f" → {entry['code']}: „{fixed}“ (fixed, use exactly)"
        line += f" — {term['note']}"
        lines.append(line)
    lines.append("Never translate: " + ", ".join(gloss.get("doNotTranslate", [])))
    if entry.get("notes"):
        lines.append("Notes: " + entry["notes"])
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Pipeline


@dataclass
class RunReport:
    lang: str
    engine: str
    started: str
    rows: int = 0
    from_memory: int = 0
    translated: int = 0
    review_changes: list[tuple[str, str]] = field(default_factory=list)
    dangerous: list[tuple[str, str]] = field(default_factory=list)
    different: list[tuple[str, str]] = field(default_factory=list)
    blocked: list[tuple[str, str]] = field(default_factory=list)
    warnings: list[tuple[str, str]] = field(default_factory=list)
    verify_problems: list[str] = field(default_factory=list)
    verify_warnings: list[str] = field(default_factory=list)

    def markdown(self) -> str:
        out = [f"## Lauf {self.started} · Engine {self.engine}", "",
               f"- Zeilen: {self.rows}, aus dem Gedächtnis: {self.from_memory}, neu übersetzt: {self.translated}",
               f"- Lektorat hat geändert: {len(self.review_changes)}",
               f"- Rückübersetzung: gefährlich {len(self.dangerous)}, abweichend {len(self.different)}",
               f"- Gesperrt (nach drei Runden nicht sauber): {len(self.blocked)}",
               f"- Warnungen (Länge, weiche Marken, gleich wie Quelle): {len(self.warnings)}", ""]
        if self.review_changes:
            out.append("### Lektorat")
            out += [f"- `{i}`: {r}" for i, r in self.review_changes[:200]]
            out.append("")
        if self.dangerous:
            out.append("### Als gefährlich gemeldet und neu übersetzt")
            out += [f"- `{i}`: {r}" for i, r in self.dangerous]
            out.append("")
        if self.blocked:
            out.append("### Gesperrt — von Hand ansehen")
            out += [f"- `{i}`: {r}" for i, r in self.blocked]
            out.append("")
        if self.warnings:
            out.append("### Warnungen")
            out += [f"- `{i}`: {r}" for i, r in self.warnings[:300]]
            out.append("")
        if self.verify_problems or self.verify_warnings:
            out.append("### verify")
            out += [f"- ✗ {p}" for p in self.verify_problems[:200]]
            out += [f"- ⚠ {p}" for p in self.verify_warnings[:200]]
            out.append("")
        return "\n".join(out)


def run_pipeline(entry: dict, rows: list[Row], engine, memory: Memory, max_rounds: int = 3, log=print) -> tuple[dict[str, str], RunReport]:
    gloss = glossary()
    report = RunReport(entry["code"], engine.name, _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="minutes"), rows=len(rows))
    results: dict[str, str] = {}
    pending: list[Row] = []
    for row in rows:
        hit = memory.get(row)
        if hit is not None and not errors(check_text(row, hit, entry, gloss)):
            results[row.id] = hit
            report.from_memory += 1
        else:
            pending.append(row)
    # Glossarbegriffe zuerst, damit sie im Gedächtnis stehen, bevor die Masse kommt.
    terms = {t["de"] for t in gloss["terms"]}
    pending.sort(key=lambda r: (0 if r.source in terms else 1, r.surface, r.id))
    guidance = guidance_block(entry, memory)
    by_id = {row.id: row for row in pending}
    for start in range(0, len(pending), BATCH_SIZE):
        batch = pending[start:start + BATCH_SIZE]
        log(f"  {entry['code']}: Paket {start // BATCH_SIZE + 1}/{(len(pending) + BATCH_SIZE - 1) // BATCH_SIZE} ({len(batch)} Texte)")
        drafts = engine.translate(entry, batch, guidance)
        remaining = list(batch)
        for round_number in range(1, max_rounds + 1):
            # deterministische Sperren
            bad = {}
            for row in remaining:
                text = drafts.get(row.id, "")
                problems = check_text(row, text, entry, gloss)
                if problems:
                    bad[row.id] = [t for _, t in problems]
            if bad:
                fix_rows = [by_id[i] for i in bad]
                hint = guidance + "\n\nPrevious attempt was rejected. Problems:\n" + "\n".join(
                    f"- {i}: {'; '.join(p)}" for i, p in bad.items())
                drafts.update(engine.translate(entry, fix_rows, hint))
            # Lektorat
            reviewed = engine.review(entry, remaining, drafts, guidance)
            for row in remaining:
                item = reviewed.get(row.id)
                if item and item["changed"] and not errors(check_text(row, item["text"], entry, gloss)):
                    report.review_changes.append((row.id, item["reason"]))
                    drafts[row.id] = item["text"]
            # Rückübersetzung
            verdicts = engine.backcheck(entry, remaining, drafts)
            redo: list[Row] = []
            for row in remaining:
                verdict = verdicts.get(row.id, {"verdict": "same", "reason": ""})
                if verdict["verdict"] == "dangerous":
                    report.dangerous.append((row.id, verdict["reason"]))
                    redo.append(row)
                elif verdict["verdict"] == "different":
                    report.different.append((row.id, verdict["reason"]))
                    redo.append(row)
            if not redo:
                remaining = []
                break
            if round_number < max_rounds:
                hint = guidance + "\n\nA meaning check flagged the previous draft. Findings:\n" + "\n".join(
                    f"- {row.id}: {verdicts[row.id]['reason']}" for row in redo)
                drafts.update(engine.translate(entry, redo, hint))
            remaining = redo
        for row in batch:
            text = drafts.get(row.id, "")
            problems = check_text(row, text, entry, gloss)
            hard = errors(problems)
            if row in remaining or hard:
                report.blocked.append((row.id, "; ".join(hard) or "Bedeutung nach drei Runden nicht bestätigt"))
                continue
            for warning in warnings(problems):
                report.warnings.append((row.id, warning))
            results[row.id] = text
            report.translated += 1
            memory.put(row, text, stage=3, model=engine.name)
        memory.save()
        guidance = guidance_block(entry, memory)
    return results, report


def write_report(report: RunReport) -> Path:
    path(REPORT_DIR).mkdir(parents=True, exist_ok=True)
    target = path(REPORT_DIR, f"{report.lang}.md")
    header = f"# Prüfbericht {report.lang}\n\n" if not target.exists() else ""
    with open(target, "a", encoding="utf-8") as handle:
        handle.write(header + report.markdown() + "\n")
    return target


# ---------------------------------------------------------------------------
# Oberflächen zusammen


def adapters() -> dict:
    return {
        "catalog": XCStringsAdapter(CATALOG, "catalog"),
        "infoplist": XCStringsAdapter(INFOPLIST, "infoplist", with_context=False),
        "watch": XCStringsAdapter(WATCH, "watch"),
        "store": StoreAdapter(),
    }


def collect_rows(lang: str, surfaces: list[str] | None, only_missing: bool = True) -> list[Row]:
    rows: list[Row] = []
    for name, adapter in adapters().items():
        if surfaces and name not in surfaces:
            continue
        if not adapter.exists():
            continue
        rows += adapter.rows(lang, only_missing=only_missing)
    return rows


def apply_results(lang: str, results: dict[str, str], rows: list[Row]) -> dict[str, int]:
    by_surface: dict[str, dict[str, str]] = {}
    for row in rows:
        if row.id in results:
            by_surface.setdefault(row.surface, {})[row.id] = results[row.id]
    written = {}
    for name, adapter in adapters().items():
        if name in by_surface:
            written[name] = adapter.apply(lang, by_surface[name])
    return written


def verify_language(lang: str, surfaces: list[str] | None = None) -> tuple[list[str], list[str]]:
    """(Fehler, Warnungen) für eine Sprache über Katalog, InfoPlist und Store."""
    entry = language(lang)
    gloss = glossary()
    hard: list[str] = []
    soft: list[str] = []
    for name in ("catalog", "infoplist", "watch"):
        if surfaces and name not in surfaces:
            continue
        adapter = adapters()[name]
        if not adapter.exists():
            continue
        for row in adapter.rows(lang, only_missing=False):
            if row.current is None:
                continue
            for level, problem in check_text(row, row.current, entry, gloss):
                (hard if level == "error" else soft).append(f"{name} „{row.id[:60]}“: {problem}")
    for name in ("store",):
        if surfaces and name not in surfaces:
            continue
        for level, problem in adapters()[name].verify(lang):
            (hard if level == "error" else soft).append(problem)
    return hard, soft


def translate_language(lang: str, engine_name: str, surfaces: list[str] | None, apply: bool, max_rounds: int, log=print) -> RunReport:
    entry = language(lang)
    if entry["status"] == "source":
        raise SystemExit(f"{lang} ist die Quellsprache.")
    rows = collect_rows(lang, surfaces)
    memory = Memory(lang)
    engine = make_engine(engine_name)
    log(f"{lang}: {len(rows)} Texte offen" + (f" ({', '.join(surfaces)})" if surfaces else ""))
    results, report = run_pipeline(entry, rows, engine, memory, max_rounds=max_rounds, log=log)
    if apply and results:
        written = apply_results(lang, results, rows)
        log(f"{lang}: geschrieben " + ", ".join(f"{k}={v}" for k, v in written.items()))
    report.verify_problems, report.verify_warnings = verify_language(lang, surfaces)
    target = write_report(report)
    log(f"{lang}: Bericht {target.relative_to(ROOT)} — übersetzt {report.translated}, Gedächtnis {report.from_memory}, "
        f"gesperrt {len(report.blocked)}, Warnungen {len(report.warnings)}, verify ✗{len(report.verify_problems)} ⚠{len(report.verify_warnings)}")
    return report


# ---------------------------------------------------------------------------
# Befehle


def cmd_doctor(args) -> int:
    entries = languages()
    ad = adapters()
    project = ProjectAdapter()
    header = f"{'Sprache':9} {'Status':9} {'Katalog':13} {'Info':6} {'Uhr':7} {'Store':7} {'project.yml':11} {'Apple':11}"
    print(header)
    print("-" * len(header))
    gaps = 0
    empty = {"done": 0, "total": 0, "review": 0}
    for code, entry in entries.items():
        cat = ad["catalog"].coverage(code) if ad["catalog"].exists() else empty
        info = ad["infoplist"].coverage(code) if ad["infoplist"].exists() else empty
        watch = ad["watch"].coverage(code) if ad["watch"].exists() else empty
        store = ad["store"].coverage(code)
        proj = project.coverage(code)
        cat_text = f"{cat['done']}/{cat['total']}" + (f" ?{cat['review']}" if cat["review"] else "")
        info_text = f"{info['done']}/{info['total']}"
        watch_text = f"{watch['done']}/{watch['total']}"
        store_text = f"{store['done']}/{store['total']}"
        proj_text = f"{proj['declared']}/{proj['blocks']}"
        complete = (cat["done"] == cat["total"] and info["done"] == info["total"]
                    and watch["done"] == watch["total"]
                    and proj["declared"] == proj["blocks"]
                    and (store["done"] == store["total"] or not ad["store"].exists()))
        if not complete and entry["status"] != "source":
            gaps += 1
        mark = "" if complete else "  ← unvollständig"
        print(f"{code:9} {entry['status']:9} {cat_text:13} {info_text:6} {watch_text:7} {store_text:7} {proj_text:11} {entry['appleLocale']:11}{mark}")
    print()
    print(f"{len(entries)} Sprachen in der Registry, {sum(len(e['ascLocales']) for e in entries.values())} Store-Locales; "
          f"{gaps} Sprache(n) unvollständig.")
    for problem in project.verify():
        print("✗", problem)
        gaps += 1
    return 1 if (args.strict and gaps) else 0


def cmd_verify(args) -> int:
    codes = [args.lang] if args.lang else [c for c, e in languages().items() if e["status"] != "source"]
    surfaces = args.surface or None
    total = 0
    soft_total = 0
    for code in codes:
        hard, soft = verify_language(code, surfaces)
        total += len(hard)
        soft_total += len(soft)
        for problem in hard:
            print(f"✗ {code}: {problem}")
        if args.warnings:
            for problem in soft:
                print(f"⚠ {code}: {problem}")
    for problem in ProjectAdapter().verify():
        print("✗", problem)
        total += 1
    print(("✓ keine Verstösse" if total == 0 else f"{total} Verstoss/Verstösse") + f", {soft_total} Warnung(en)"
          + ("" if args.warnings or not soft_total else " (--warnings zeigt sie)"))
    return 1 if total else 0


# ---------------------------------------------------------------------------
# Übersetzungspakete: eine Datei je Sprache, die sich selbst erklärt
#
# Der Weg für alles, was nicht durch die eingebaute Pipeline läuft: `pack`
# schreibt eine Datei mit allem, was zum Übersetzen nötig ist — Quelltext,
# englische Referenz, Kontext, Längenbudget, Platzhalter, Glossar und die
# Regeln, an denen `verify` sonst scheitert. Irgendein Modell füllt die
# `target`-Felder, `import` liest die Datei zurück und lässt sie durch dieselben
# Sperren wie jede andere Übersetzung.
#
# **Warum eine Datei und nicht ein Aufruf je Text:** eine neue Sprache soll ein
# Auftrag sein, kein Projekt. Und wer 2500 Zeilen in einem Stück übersetzt, hält
# die Begriffe konsistent — genau das, was 2500 Einzelaufrufe nicht können.


PACK_SCHEMA = "sensorstorm-l10n-pack/1"


def pack_instructions(entry: dict, gloss: dict) -> list[str]:
    """Die Regeln, an denen `verify` sonst scheitert — im Paket, nicht im Kopf."""
    quotes = entry.get("quotes") or ["\u201e", "\u201c"]
    rules = [
        "Fülle in jedem Eintrag nur „target“. „id“ und „source“ bleiben unverändert.",
        "Übersetze aus „source“ (Deutsch). „reference“ ist die englische Fassung als "
        "zweite Lesart — bei Widerspruch gilt Deutsch.",
        "Platzhalter (%@, %lld, %1$@ …) kommen in derselben Anzahl und mit denselben Typen "
        "vor; ihre Reihenfolge darfst du ändern, dann aber mit Positionsangabe (%1$@, %2$lld).",
        "${applicationName} ist der App-Name und bleibt wörtlich stehen — ein Siri-Satz ohne "
        "ihn wird von Apple abgelehnt.",
        "Gleich viele Zeilenumbrüche wie in „source“. Kein HTML, keine Steuerzeichen.",
        "„maxChars“ ist das Budget für die Oberfläche, „maxBytes“ eine harte Grenze des "
        "App Store. Wo beides fehlt, gibt es keine Grenze.",
        f"Anführungszeichen dieser Sprache: {quotes[0]} … {quotes[-1]}",
        f"Anrede und Register: {entry.get('register') or 'wie im Deutschen'}",
        "Die App spricht kurz, konkret und ohne Werbeton. Ein Knopf ist ein Knopf, kein Satz.",
    ]
    if entry.get("direction") == "rtl":
        rules.append(
            "Diese Sprache läuft von rechts nach links. Platzhalter und lateinische Kürzel "
            "bleiben trotzdem in Leserichtung des Textes stehen; setze keine Steuerzeichen ein."
        )
    if gloss.get("doNotTranslate"):
        rules.append("Unübersetzt bleiben: " + ", ".join(gloss["doNotTranslate"]))
    if gloss.get("keepIfPossible"):
        soft = []
        for brand in gloss["keepIfPossible"]:
            local = gloss.get("localNames", {}).get(brand, {}).get(entry["code"])
            soft.append(f"{brand} (hier: {local})" if local else brand)
        rules.append("Möglichst behalten (nur ändern, wo die Plattform es anders nennt): "
                     + ", ".join(soft))
    return rules


def pack_units(rows: list[Row]) -> list[dict]:
    """Ein Text, eine Einheit — auch wenn er auf zwei Oberflächen steht.

    „Aufnahme starten" und „Stopp" stehen im Katalog des iPhones und in dem der
    Uhr. Zweimal im Paket hiesse: zweimal übersetzt, und nichts garantiert, dass
    beide Male dasselbe herauskommt. `import` verteilt eine Antwort ohnehin auf
    jede Zeile mit dieser Kennung.
    """
    units = []
    seen: set[str] = set()
    for row in rows:
        if row.id in seen:
            continue
        seen.add(row.id)
        unit = {
            "id": row.id,
            "surface": row.surface,
            "kind": row.kind,
            "source": row.source,
            "reference": row.reference,
            "target": "",
        }
        if row.context:
            unit["context"] = row.context
        if row.surface == "infoplist" and row.reference:
            # InfoPlist: der Schlüssel **ist** die Kennung, der deutsche Text steht
            # in `project.yml`. Hier ist die englische Fassung die Vorlage — das
            # gehört ins Paket, sonst übersetzt jemand den Schlüsselnamen.
            unit["note"] = "Der Schlüssel ist kein Text: übersetze die englische Referenz."
        marks = placeholders(row.source)
        if marks:
            unit["placeholders"] = marks
        if row.max_chars:
            unit["maxChars"] = row.max_chars
        if row.max_bytes:
            unit["maxBytes"] = row.max_bytes
        if row.extra.get("categories"):
            unit["pluralCategories"] = row.extra["categories"]
        units.append(unit)
    return units


def write_packs(lang: str, rows: list[Row], chunk: int, out_dir: Path) -> list[Path]:
    entry = language(lang)
    gloss = glossary()
    units = pack_units(rows)
    size = chunk if chunk > 0 else max(1, len(units))
    parts = [units[i:i + size] for i in range(0, len(units), size)] or [[]]
    out_dir.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []
    for index, part in enumerate(parts, start=1):
        payload = {
            "$schema": PACK_SCHEMA,
            "task": f"Übersetze Sensorstorm ins {entry['name']} ({lang}).",
            "language": {
                "code": lang,
                "name": entry["name"],
                "appleLocale": entry.get("appleLocale"),
                "direction": entry.get("direction", "ltr"),
                "script": entry.get("script"),
                "quotes": entry.get("quotes"),
                "register": entry.get("register"),
                "pluralCategories": entry.get("pluralCategories"),
            },
            "rules": pack_instructions(entry, gloss),
            "glossary": {k: v for k, v in gloss.items() if not k.startswith("$")},
            "returnTo": f"Tools/l10n.py import --lang {lang} --file <diese Datei>",
            "part": {"index": index, "of": len(parts), "units": len(part)},
            "units": part,
        }
        name = f"{lang}.json" if len(parts) == 1 else f"{lang}-{index:03d}.json"
        target = out_dir / name
        target.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        written.append(target)
    return written


def read_pack(file: Path) -> list[tuple[str, str]]:
    """Ein Paket **oder** eine JSONL-Datei zurücklesen — beides wird akzeptiert,
    weil beide denselben Weg durch die Sperren nehmen."""
    text = file.read_text(encoding="utf-8")
    # Erst als Ganzes lesen: ein Paket ist ein JSON-Objekt, eine JSONL-Datei ist
    # es nie. Am Dateianfang zu raten ging schief, sobald Regeln und Glossar vor
    # den Texten standen und die Datei in einer Zeile geschrieben war.
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        payload = None
    if isinstance(payload, dict) and "units" in payload:
        return [(u["id"], u.get("target", "")) for u in payload["units"]]
    pairs = []
    for line in text.splitlines():
        if not line.strip():
            continue
        item = json.loads(line)
        pairs.append((item["id"], item.get("text", item.get("target", ""))))
    return pairs


def cmd_pack(args) -> int:
    rows = collect_rows(args.lang, args.surface or None, only_missing=not args.all)
    if not rows:
        print(f"{args.lang}: nichts offen — `doctor` zeigt den Stand.")
        return 0
    out_dir = Path(args.out) if args.out else path(PACK_DIR, args.lang)
    written = write_packs(args.lang, rows, args.chunk, out_dir)
    total = sum(len(json.loads(p.read_text(encoding='utf-8'))["units"]) for p in written)
    print(f"{args.lang}: {total} Texte in {len(written)} Datei(en) → {out_dir}")
    for p in written:
        print(f"  {p}")
    print(f"Zurück mit: python3 Tools/l10n.py import --lang {args.lang} --dir {out_dir}")
    return 0


def cmd_export(args) -> int:
    rows = collect_rows(args.lang, args.surface or None, only_missing=not args.all)
    out = Path(args.out) if args.out else None
    lines = [json.dumps(r.to_json(), ensure_ascii=False) for r in rows]
    if out:
        out.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
        print(f"{len(rows)} Zeilen → {out}")
    else:
        print("\n".join(lines))
    return 0


def cmd_import(args) -> int:
    entry = language(args.lang)
    gloss = glossary()
    # Eine Kennung kann mehrere Zeilen haben (derselbe Text im Katalog des
    # iPhones und in dem der Uhr). Geprüft wird gegen die erste, geschrieben
    # wird in alle — sonst bliebe die Uhr still unübersetzt.
    all_rows = collect_rows(args.lang, None, only_missing=False)
    rows: dict[str, Row] = {}
    for row in all_rows:
        rows.setdefault(row.id, row)
    results: dict[str, str] = {}
    rejected = 0
    empty = 0

    files: list[Path] = []
    if args.dir:
        files = sorted(Path(args.dir).glob("*.json")) + sorted(Path(args.dir).glob("*.jsonl"))
        if not files:
            raise SystemExit(f"Keine Pakete in {args.dir}")
    elif args.file:
        files = [Path(args.file)]
    else:
        raise SystemExit("--file <datei> oder --dir <ordner> angeben")

    for file in files:
        for key, text in read_pack(file):
            row = rows.get(key)
            if row is None:
                print(f"✗ unbekannt: {key}")
                rejected += 1
                continue
            if not text.strip():
                # Ein leeres Feld ist keine Übersetzung, aber auch kein Fehler:
                # ein Paket darf in Teilen zurückkommen.
                empty += 1
                continue
            problems = check_text(row, text, entry, gloss)
            if errors(problems):
                print(f"✗ {key}: {'; '.join(errors(problems))}")
                rejected += 1
                continue
            for warning in warnings(problems):
                print(f"⚠ {key}: {warning}")
            results[key] = text

    written = apply_results(args.lang, results, all_rows)
    summary = f"übernommen {len(results)}, abgelehnt {rejected}"
    if empty:
        summary += f", leer gelassen {empty}"
    print(summary + ", geschrieben " + ", ".join(f"{k}={v}" for k, v in written.items()))
    return 1 if rejected else 0


def cmd_translate(args) -> int:
    report = translate_language(args.lang, args.engine, args.surface or None, not args.no_apply, args.max_rounds)
    return 1 if (report.blocked or report.verify_problems) else 0


def cmd_sync(args) -> int:
    codes = args.langs.split(",") if args.langs else [c for c, e in languages().items() if e["status"] != "source"]
    failures = 0
    for code in codes:
        rows = collect_rows(code, args.surface or None)
        if not rows:
            print(f"{code}: nichts offen")
            continue
        report = translate_language(code, args.engine, args.surface or None, True, args.max_rounds)
        failures += 1 if (report.blocked or report.verify_problems) else 0
    # Das Listing folgt der Quelle: geändert heisst neu geschrieben, sonst nichts.
    if (not args.surface or "store" in args.surface) and StoreAdapter().exists():
        locales = [l for c in codes for l in language(c)["ascLocales"]]
        failures += store_copy_locales(locales, args.engine, args.max_rounds, False, False)
    return 1 if failures else 0


def cmd_activate(args) -> int:
    """Die Buchhaltung einer Sprache, ohne die Pipeline.

    `add-language` erledigt drei Dinge: `project.yml`, die Übersetzung und den
    Status in der Registry. Wer die Pakete von Hand übersetzt (`pack` →
    `import`), braucht nur das erste und das dritte — und braucht es trotzdem,
    sonst baut Xcode die Sprache nicht mit und `doctor` zählt sie ewig als
    geplant.
    """
    entry = language(args.code)
    # Erst nachzählen, dann scharfschalten: eine Sprache mit Lücken in
    # `CFBundleLocalizations` heisst, iOS bietet sie an und zeigt dann Deutsch.
    surfaces = args.surface or ["catalog", "infoplist"]
    gaps = []
    for name in surfaces:
        adapter = adapters()[name]
        if not adapter.exists() or not hasattr(adapter, "coverage"):
            continue
        cov = adapter.coverage(entry["code"])
        if cov.get("total") and cov["done"] < cov["total"]:
            gaps.append(f"{name} {cov['done']}/{cov['total']}")
    if gaps:
        print(f"{entry['code']}: noch unvollständig — " + ", ".join(gaps))
        return 1
    added = ProjectAdapter().add(entry["code"]) if ProjectAdapter().exists() else 0
    print(f"project.yml: {added} Block/Blöcke ergänzt")
    errors, warnings = verify_language(entry["code"], surfaces)
    for text in errors:
        print("✗ " + text)
    print(f"verify: {len(errors)} Fehler, {len(warnings)} Warnungen")
    if errors:
        print(f"{entry['code']}: Status bleibt „{entry['status']}“, bis die Fehler weg sind.")
        return 1
    if entry["status"] == "planned":
        data = registry()
        for item in data["languages"]:
            if item["code"] == entry["code"]:
                item["status"] = "machine"
        path(REGISTRY).write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"Registry: {entry['code']} status → machine")
    else:
        print(f"Registry: {entry['code']} steht schon auf „{entry['status']}“")
    return 0


def cmd_approve(args) -> int:
    """Setzt gelesene Übersetzungen von „needs_review" auf „translated".

    `import` und `sync` schreiben jede Zeile als `needs_review` — richtig, denn
    frisch übersetzt heisst ungelesen. Wer eine Sprache danach durchgeht, hat
    aber keine Stelle, an der er das festhält, und `doctor` zeigt bis in alle
    Ewigkeit `?1571`. Das ist keine Warnung mehr, das ist Rauschen.

    Die Freigabe hängt darum an `verify`: erst wenn die Sperren derselben
    Sprache ohne Verstoss durchlaufen, wird umgeschrieben. Der Zustand heisst
    dann „durch die Sperren gegangen", und das stimmt.
    """
    entry = language(args.code)
    surfaces = args.surface or ["catalog", "infoplist"]
    errors, warnings = verify_language(entry["code"], surfaces)
    for text in errors:
        print("✗ " + text)
    if errors:
        print(f"{entry['code']}: {len(errors)} Verstoss/Verstösse — nichts freigegeben.")
        return 1
    total = 0
    for name in surfaces:
        adapter = adapters().get(name)
        if not isinstance(adapter, XCStringsAdapter) or not adapter.exists():
            continue
        data = adapter.load()
        count = 0
        for _key, item in adapter.keys(data):
            loc = item.get("localizations", {}).get(entry["code"])
            if not loc:
                continue
            if "stringUnit" in loc:
                if loc["stringUnit"].get("state") == "needs_review":
                    loc["stringUnit"]["state"] = "translated"
                    count += 1
                continue
            # Ein Plural trägt seinen Zustand je Kategorie, nicht oben.
            offen = [u for u in _plural_units(loc) if u.get("state") == "needs_review"]
            for unit in offen:
                unit["state"] = "translated"
            if offen:
                count += 1
        if count:
            adapter.save(data)
        print(f"{name}: {count} freigegeben")
        total += count
    print(f"{entry['code']}: {total} Text(e) freigegeben, {len(warnings)} Warnung(en) bleiben.")
    return 0


def cmd_add_language(args) -> int:
    entry = language(args.code)
    print(f"Sprache {entry['code']} ({entry['englishName']}), Store-Locales {', '.join(entry['ascLocales']) or '–'}")
    added = ProjectAdapter().add(entry["code"]) if ProjectAdapter().exists() else 0
    print(f"project.yml: {added} Block/Blöcke ergänzt")
    report = translate_language(entry["code"], args.engine, None, True, args.max_rounds)
    store_failures = 0
    if StoreAdapter().exists():
        store_failures = store_copy_locales(entry["ascLocales"], args.engine, args.max_rounds, False, False)
    if entry["status"] == "planned":
        data = registry()
        for item in data["languages"]:
            if item["code"] == entry["code"]:
                item["status"] = "machine"
        path(REGISTRY).write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print("Registry: status → machine")
    cmd_doctor(argparse.Namespace(strict=False))
    return 1 if (report.blocked or report.verify_problems or store_failures) else 0


def cmd_store_copy(args) -> int:
    if args.accept_source:
        # Nur Locales mit Listing: für eine Sprache ohne Text gäbe es nichts
        # zu übernehmen, und ein leerer ASO-Eintrag wäre nur Rauschen im Repo.
        adapter = StoreAdapter()
        locales = ([l for l in all_store_locales() if adapter.read(l)] if args.all else args.locale)
        for locale in locales:
            store_accept_source(locale)
        return 0
    if args.all:
        locales = [l for l in all_store_locales() if locale_language(l)["status"] != "planned"]
    else:
        locales = args.locale
    failures = store_copy_locales(locales, args.engine, args.max_rounds, args.force, args.allow_rename)
    return 1 if failures else 0


def cmd_report(args) -> int:
    target = path(REPORT_DIR, f"{args.lang}.md")
    if not target.exists():
        print("kein Bericht")
        return 1
    print(target.read_text(encoding="utf-8"))
    return 0


def cmd_context(args) -> int:
    files = context_index().get(args.key)
    if files is None:
        print("Key nicht im Katalog")
        return 1
    print(describe_context(files) or "in keiner Swift-Datei als Literal gefunden (String(localized:) mit Variable?)")
    for name in files:
        print("-", name)
    return 0


def rename_term(source_term: str, target_term: str, dry_run: bool = False) -> list[tuple[str, str]]:
    """Ersetzt einen Begriff in allen Katalog-Keys, die ihn enthalten — und in
    den Swift-Literalen, die diese Keys verwenden. Die Übersetzungen wandern
    mit: „Zügeltermin" → „Umzugstermin" ändert das deutsche Wort, nicht die
    Bedeutung, und „Moving date" bleibt richtig.

    Warum ein Befehl und nicht Hand: der Key **ist** das deutsche Literal im
    Code. Wer nur den Katalog ändert, bekommt beim nächsten Build einen neuen,
    unübersetzten Key und einen verwaisten alten."""
    adapter = XCStringsAdapter(CATALOG, "catalog", with_context=False)
    data = adapter.load()
    strings = data["strings"]
    renames: list[tuple[str, str]] = []
    for key in list(strings):
        if source_term in key:
            new_key = key.replace(source_term, target_term)
            if new_key == key:
                continue
            renames.append((key, new_key))
    if dry_run:
        return renames
    for key, new_key in renames:
        entry = strings.pop(key)
        if new_key in strings:
            # Der neue Key existiert schon (z. B. von Hand angelegt): seine
            # Übersetzungen gelten, die alten füllen nur Lücken.
            existing = strings[new_key]
            merged = dict(entry)
            merged["localizations"] = {**entry.get("localizations", {}), **existing.get("localizations", {})}
            strings[new_key] = merged
        else:
            strings[new_key] = entry
        # Die deutsche Lokalisierung (positionale Umschreibungen) trägt das Wort auch.
        loc = strings[new_key].get("localizations", {}).get(source_language())
        if loc and "stringUnit" in loc:
            loc["stringUnit"]["value"] = loc["stringUnit"]["value"].replace(source_term, target_term)
    adapter.save(data)
    # Swift-Literale.
    for directory in SWIFT_DIRS:
        base = path(directory)
        if not base.is_dir():
            continue
        for swift in base.rglob("*.swift"):
            text = swift.read_text(encoding="utf-8")
            changed = text
            for key, new_key in renames:
                changed = changed.replace('"' + swift_literal(key) + '"', '"' + swift_literal(new_key) + '"')
            if changed != text:
                swift.write_text(changed, encoding="utf-8")
    global _context_cache
    _context_cache = None
    return renames


def term_leftovers(term: str) -> list[str]:
    """Swift-Zeilen, die den Begriff noch tragen — Literale mit Interpolation
    (`\\(x)` statt `%@`) oder mit Zeilenfortsetzung, die kein Katalog-Key
    eins zu eins ist. Die stehen im Bericht und werden von Hand angepasst."""
    found = []
    for directory in SWIFT_DIRS:
        base = path(directory)
        if not base.is_dir():
            continue
        for swift in sorted(base.rglob("*.swift")):
            for number, line in enumerate(swift.read_text(encoding="utf-8").splitlines(), 1):
                if term in line:
                    found.append(f"{swift.relative_to(ROOT)}:{number}")
    return found


def reword(mapping: dict[str, str], dry_run: bool = False) -> tuple[list[tuple[str, str]], list[str]]:
    """Deutsche Texte umschreiben, ohne die Übersetzungen zu verlieren.

    `rename-term` tauscht ein Wort in vielen Keys; hier steht je Key ein ganzer
    neuer Satz. Der Anlass ist derselbe: der Key **ist** das deutsche Literal im
    Code, also muss der Katalog mit den Swift-Dateien in einem Schritt wandern,
    sonst hat der nächste Build einen neuen, unübersetzten Key und einen
    verwaisten alten.

    Die Übersetzungen wandern mit. Das ist richtig, solange sich nur der
    deutsche Stil ändert und nicht die Aussage — wer die Aussage ändert, setzt
    die Zielsprachen hinterher selbst nach.

    Zurück kommen die tatsächlich umbenannten Paare und die Stellen, die von
    Hand nachzuziehen sind: ein Literal mit Interpolation oder über mehrere
    Zeilen findet die Textersetzung nicht.
    """
    adapter = XCStringsAdapter(CATALOG, "catalog", with_context=False)
    data = adapter.load()
    strings = data["strings"]
    missing = [old for old in mapping if old not in strings]
    if missing:
        raise SystemExit("Diese Texte stehen nicht im Katalog:\n  " + "\n  ".join(repr(m[:70]) for m in missing))
    done: list[tuple[str, str]] = []
    for old, new in mapping.items():
        if old == new:
            continue
        done.append((old, new))
    if dry_run:
        return done, []

    for old, new in done:
        entry = strings.pop(old)
        if new in strings:
            existing = strings[new]
            merged = dict(entry)
            merged["localizations"] = {**entry.get("localizations", {}), **existing.get("localizations", {})}
            strings[new] = merged
        else:
            strings[new] = entry
    adapter.save(data)

    for directory in SWIFT_DIRS:
        base = path(directory)
        if not base.is_dir():
            continue
        for swift in base.rglob("*.swift"):
            text = swift.read_text(encoding="utf-8")
            changed = text
            for old, new_text in done:
                changed = changed.replace('"' + swift_literal(old) + '"', '"' + swift_literal(new_text) + '"')
            if changed != text:
                swift.write_text(changed, encoding="utf-8")

    # Ein Literal kann als `"""`-Block über mehrere Zeilen stehen, mit `\` am
    # Zeilenende. Die Textersetzung oben findet das nicht — und `context_index`
    # sieht es auch nicht, meldete also nichts. Darum wird hier **entfaltet**
    # gesucht: was Swift zu einem Satz zusammenzieht, muss verglichen werden
    # wie Swift es zusammenzieht. Ohne das gab der Befehl grünes Licht, während
    # `HelpView.swift` noch die alten Sätze trug (2026-09-07).
    leftovers: list[str] = []
    for directory in SWIFT_DIRS:
        base = path(directory)
        if not base.is_dir():
            continue
        for swift in base.rglob("*.swift"):
            flach = re.sub(r"\\\n\s*", "", swift.read_text(encoding="utf-8"))
            # Ein Literal schreibt `\(ausdruck)`, wo der Key `%@` schreibt.
            # Beide Seiten kommen auf dieselbe Marke, sonst sieht die Suche
            # genau die Texte nicht, die sie sehen müsste.
            marke = normalize_interpolation(flach)
            for old, new_text in done:
                alt, neu = normalize_placeholders(old), normalize_placeholders(new_text)
                # Der neue Text darf den alten enthalten („Scan öffnet …“ →
                # „Ein Scan öffnet …“); gesucht wird, was nach Abzug des neuen
                # Literals übrig bleibt.
                if alt in marke.replace(neu, ""):
                    leftovers.append(f"{swift.relative_to(ROOT)}: „{old[:50]}…“")
    global _context_cache
    _context_cache = None
    return done, sorted(set(leftovers))


def cmd_reword(args) -> int:
    file = Path(args.file)
    mapping = json.loads((file if file.is_absolute() else path(args.file)).read_text(encoding="utf-8"))
    if not isinstance(mapping, dict):
        raise SystemExit("Erwartet wird ein JSON-Objekt: alter Text → neuer Text.")
    done, leftovers = reword(mapping, dry_run=args.dry_run)
    for old, new in done:
        print(("würde " if args.dry_run else "→ ") + f"„{old[:60]}“")
        print(("       " if args.dry_run else "  ") + f"„{new[:60]}“")
    print(f"{len(done)} Text(e)" + (" (Trockenlauf)" if args.dry_run else ""))
    for where in leftovers:
        print(f"⚠ von Hand: {where}")
    return 1 if leftovers else 0


def cmd_rename_term(args) -> int:
    renames = rename_term(args.source, args.target, dry_run=args.dry_run)
    for key, new_key in renames:
        print(f"{'würde' if args.dry_run else '→'} „{key[:70]}“ → „{new_key[:70]}“")
    print(f"{len(renames)} Key(s)" + (" (Trockenlauf)" if args.dry_run else ""))
    leftovers = term_leftovers(args.source)
    for where in leftovers:
        print(f"⚠ von Hand: {where} trägt „{args.source}“ noch (Interpolation oder Zeilenfortsetzung)")
    return 1 if leftovers and not args.dry_run else 0


def cmd_pseudo(args) -> int:
    print("Pseudo-Lokalisierung (doppelte Länge, Akzente) und Pseudo-RTL laufen als Startargumente im Simulator —")
    print("kein eigener Katalog, nichts zu übersetzen. In der Screenshot-Pipeline oder von Hand:")
    print()
    print("  xcrun simctl launch <udid> ch.sensorstorm.app -AppleLanguages '(en)' -NSDoubleLocalizedStrings YES -NSShowNonLocalizedStrings YES")
    print("  xcrun simctl launch <udid> ch.sensorstorm.app -AppleTextDirection YES -NSForceRightToLeftWritingDirection YES")
    print()
    print("Tools/asc_capture_screenshots.py --langs en --devices iphone_61 nimmt dieselben Argumente über HS_LAUNCH_ARGS entgegen (Welle 2).")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    doctor = sub.add_parser("doctor", help="Matrix Sprache × Oberfläche")
    doctor.add_argument("--strict", action="store_true", help="Exit 1, wenn etwas fehlt")
    doctor.set_defaults(func=cmd_doctor)

    verify = sub.add_parser("verify", help="deterministische Sperren prüfen")
    verify.add_argument("--lang")
    verify.add_argument("--surface", action="append", choices=["catalog", "infoplist", "watch", "store"])
    verify.add_argument("--warnings", action="store_true", help="auch Warnungen zeigen")
    verify.set_defaults(func=cmd_verify)

    export = sub.add_parser("export", help="offene Texte als JSONL")
    export.add_argument("--lang", required=True)
    export.add_argument("--surface", action="append", choices=["catalog", "infoplist", "watch", "store"])
    export.add_argument("--all", action="store_true", help="auch schon übersetzte Texte")
    export.add_argument("--out")
    export.set_defaults(func=cmd_export)

    pack = sub.add_parser("pack", help="Übersetzungspaket schreiben: eine Datei, die sich selbst erklärt")
    pack.add_argument("--lang", required=True)
    pack.add_argument("--surface", action="append", choices=["catalog", "infoplist", "watch", "store"])
    pack.add_argument("--all", action="store_true", help="auch schon Übersetztes, nicht nur Offenes")
    pack.add_argument("--chunk", type=int, default=0, help="in Teile à N Texte zerlegen (0 = eine Datei)")
    pack.add_argument("--out", help="Zielordner, sonst l10n/packs/<lang>")
    pack.set_defaults(func=cmd_pack)

    imp = sub.add_parser("import", help="Paket oder JSONL zurücklesen (nach verify)")
    imp.add_argument("--lang", required=True)
    imp.add_argument("--file", help="eine Datei: Paket (.json) oder JSONL")
    imp.add_argument("--dir", help="ein Ordner voller Pakete")
    imp.set_defaults(func=cmd_import)

    for name, func, help_text in (("translate", cmd_translate, "eine Sprache übersetzen"), ("sync", cmd_sync, "alle Sprachen nachziehen")):
        p = sub.add_parser(name, help=help_text)
        if name == "translate":
            p.add_argument("--lang", required=True)
            p.add_argument("--no-apply", action="store_true", help="nur Bericht, nichts schreiben")
        else:
            p.add_argument("--langs", help="Kommaliste, sonst alle")
        p.add_argument("--surface", action="append", choices=["catalog", "infoplist", "watch", "store"])
        p.add_argument("--engine", default="claude", choices=["claude", "mock"])
        p.add_argument("--max-rounds", type=int, default=3)
        p.set_defaults(func=func)

    activate = sub.add_parser(
        "activate",
        help="eine von Hand übersetzte Sprache scharfschalten (project.yml + Registry)",
    )
    activate.add_argument("code")
    activate.add_argument("--surface", action="append", help="nur diese Oberflächen prüfen")
    activate.set_defaults(func=cmd_activate)

    approve = sub.add_parser(
        "approve",
        help="gelesene Übersetzungen von „needs_review“ auf „translated“ setzen (nur wenn verify sauber ist)",
    )
    approve.add_argument("code")
    approve.add_argument("--surface", action="append", help="nur diese Oberflächen (Vorgabe: catalog, infoplist)")
    approve.set_defaults(func=cmd_approve)

    add = sub.add_parser("add-language", help="eine Sprache aus der Registry überall anlegen")
    add.add_argument("code")
    add.add_argument("--engine", default="claude", choices=["claude", "mock"])
    add.add_argument("--max-rounds", type=int, default=3)
    add.set_defaults(func=cmd_add_language)

    store = sub.add_parser("store-copy", help="das App-Store-Listing je Locale in vier Stufen (ASO)")
    which = store.add_mutually_exclusive_group(required=True)
    which.add_argument("--locale", action="append", help="ASC-Locale, z. B. ja oder es-MX (mehrfach möglich)")
    which.add_argument("--all", action="store_true", help="alle Store-Locales der Registry, Referenz zuerst")
    store.add_argument("--engine", default="claude", choices=["claude", "mock"])
    store.add_argument("--max-rounds", type=int, default=3)
    store.add_argument("--force", action="store_true", help="auch bei unveränderter Quelle neu schreiben")
    store.add_argument("--allow-rename", action="store_true", help="Name und Untertitel dürfen sich ändern (sonst nur bei leerem Bestand)")
    store.add_argument("--accept-source", action="store_true",
                       help="den neuen Quellstand übernehmen, ohne das Listing zu ändern "
                            "(die deutsche Quelle wurde nur sprachlich aufgeräumt)")
    store.set_defaults(func=cmd_store_copy)

    rep = sub.add_parser("report", help="den Prüfbericht einer Sprache zeigen")
    rep.add_argument("--lang", required=True)
    rep.set_defaults(func=cmd_report)

    ctx = sub.add_parser("context", help="wo ein Katalog-Text in der App steht")
    ctx.add_argument("--key", required=True)
    ctx.set_defaults(func=cmd_context)

    reword_p = sub.add_parser(
        "reword",
        help="deutsche Texte umschreiben (Katalog-Key + Swift-Literal), Übersetzungen wandern mit",
    )
    reword_p.add_argument("--file", required=True, help="JSON-Objekt: alter Text → neuer Text")
    reword_p.add_argument("--dry-run", action="store_true")
    reword_p.set_defaults(func=cmd_reword)

    rename = sub.add_parser("rename-term", help="einen Begriff in Katalog-Keys und Swift-Literalen ersetzen")
    rename.add_argument("--from", dest="source", required=True)
    rename.add_argument("--to", dest="target", required=True)
    rename.add_argument("--dry-run", action="store_true")
    rename.set_defaults(func=cmd_rename_term)

    pseudo = sub.add_parser("pseudo", help="Startargumente für Pseudo-Lokalisierung und Pseudo-RTL")
    pseudo.set_defaults(func=cmd_pseudo)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
