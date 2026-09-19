#!/usr/bin/env python3
"""Deutsche Texte finden, die der Compiler nie als Text sieht.

    Tools/l10n_literals.py            # Bericht, Rückgabe 1 bei einem Fund
    Tools/l10n_literals.py --list     # auch die bekannten Stellen zeigen

`Tools/l10n_extract.py` vergleicht den Katalog mit dem, was der Compiler als
lokalisierbar erkannt hat. Die gefährlichste Lücke liegt davor: ein deutscher
Text, den der Compiler gar nicht erst als lokalisierbar einstuft. Der bleibt
in jeder Sprache deutsch, und keine Prüfung schlägt an — weder `doctor`, der
nur zählt, was im Katalog steht, noch `verify`, das nur Vorhandenes prüft,
noch `extract`, dem er nie gemeldet wird.

Drei Wege hinein, alle drei am selben Tag gefunden:

    Text(bedingung ? "\\(zahl) Messwerte" : String(localized: "Bereit"))

Der Ternär nimmt den Typ des zweiten Zweigs an, `String`, und `Text(String)`
übersetzt nicht. „Messwerte“ stand damit auf dem Hauptbildschirm in 26
Sprachen auf Deutsch.

    infoRow("Audio", "\\(rate) Hz · \\(kanäle) Kanäle")

Der zweite Parameter ist `String`, nicht `LocalizedStringKey`. Die
Beschriftung wurde übersetzt, der Wert daneben nie.

    var label: String { switch self { case .wifi: "WLAN" … } }

Ein Literal in einer `String`-Eigenschaft ist eine Zeichenkette wie jede
andere. „Mobil“ und „Kabel“ standen überall auf Deutsch.

Erkannt wird über die Sprache, nicht über die Form: ein Literal mit einem
Umlaut oder einem deutschen Wort, das nicht als Schlüssel im Katalog steht,
ist entweder ein Fund oder gehört in `ALLOWED`. Beides ist eine Entscheidung,
die jemand einmal trifft — und die danach steht.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Resources/Localizable.xcstrings"
TREES = ("App", "Watch", "Sources")

PLACEHOLDER = re.compile(r"%(?:@|lld|\d*\.?\d*[fdi])")
GERMAN = re.compile(
    r"[äöüÄÖÜß]"
    r"|\b(?:der|die|das|und|oder|nicht|kein|keine|keinen|von|vom|mit|für|auf|beim|"
    r"eine|einen|einem|einer|dieses|diese|dieser|wird|werden|wurde|sind|"
    r"Messwerte|Kanäle|Bereit|Aufnahme|Aufnahmen|Punkte|Punkten|Radius|Sekunden|"
    r"Minuten|Stunden|Bilder|Fehler|Datei|Dateien|Ordner|Zeit|Wert|Werte|Grösse|"
    r"Höhe|Länge|Breite|Mobil|Kabel|Anderes|Position|Positionen)\b")

# Was hier steht, ist geprüft und soll deutsch bleiben — mit dem Grund daneben,
# damit der nächste Durchgang nicht dieselbe Frage noch einmal beantworten muss.
ALLOWED: dict[str, str] = {
    "App/UI/Playback/SensorChartCard.swift:Breiteste Ströme · 320 pt":
        "Name einer #Preview, nie ausgeliefert",
    "Sources/SensorstormCore/Export/SurveyExporter.swift:Nadel von Hand gesetzt":
        "Spaltenwert im Export: maschinenlesbar und über Sprachen hinweg stabil",
    "Sources/SensorstormCore/Export/SurveyExporter.swift:Nadel von Hand gesetzt, %.0f m vom GPS-Fix":
        "Spaltenwert im Export: maschinenlesbar und über Sprachen hinweg stabil",
}

# Die README im Fotogrammetrie-Bündel ist ein deutsches Dokument, kein UI-Text.
ALLOWED_FILES = {"Sources/SensorstormCore/Export/PhotoSetReadme.swift"}


def literals(line: str) -> list[str]:
    """Die Zeichenketten einer Zeile, mit `\\(…)` als einem Zeichen.

    Eine Regex reicht hier nicht: `\\(Int(a.b()))` klammert zwei Ebenen tief, und
    `\\(wert, specifier: "%.1f")` bringt Anführungszeichen mit, die eine Regex für
    das Ende des Literals hält. Beides hat Falschmeldungen erzeugt, und ein
    Prüfer, der ständig falsch meldet, wird abgeschaltet statt befolgt.
    """
    out: list[str] = []
    i, n = 0, len(line)
    while i < n:
        if line[i] != '"':
            i += 1
            continue
        i += 1
        buf: list[str] = []
        while i < n:
            c = line[i]
            if c == "\\" and i + 1 < n:
                if line[i + 1] == "(":
                    depth, j = 0, i + 1
                    while j < n:
                        if line[j] == "(":
                            depth += 1
                        elif line[j] == ")":
                            depth -= 1
                            if depth == 0:
                                break
                        elif line[j] == '"':
                            j += 1
                            while j < n and line[j] != '"':
                                j += 2 if line[j] == "\\" else 1
                        j += 1
                    buf.append("%@")
                    i = j + 1
                    continue
                buf.append(line[i:i + 2])
                i += 2
                continue
            if c == '"':
                i += 1
                break
            buf.append(c)
            i += 1
        out.append("".join(buf))
    return out


def shape(text: str) -> str:
    """Das Literal so, wie es als Schlüssel im Katalog stünde."""
    return PLACEHOLDER.sub("%@", text.replace("%%", "%"))


def catalog_keys() -> set[str]:
    strings = json.loads(CATALOG.read_text(encoding="utf-8"))["strings"]
    keys = set(strings)
    # Derselbe Text kann als %@ oder als %lld im Katalog stehen, je nachdem, was
    # interpoliert wird. Für den Abgleich zählt der Text, nicht der Platzhalter.
    keys |= {shape(k) for k in keys}
    return keys


def scan() -> list[tuple[str, int, str]]:
    keys = catalog_keys()
    hits: list[tuple[str, int, str]] = []
    for tree in TREES:
        for path in sorted((ROOT / tree).rglob("*.swift")):
            rel = str(path.relative_to(ROOT))
            if rel in ALLOWED_FILES:
                continue
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                stripped = line.lstrip()
                if stripped.startswith(("//", "///", "*")):
                    continue
                for text in literals(line):
                    if not GERMAN.search(text):
                        continue
                    if text in keys or shape(text) in keys:
                        continue
                    if f"{rel}:{text}" in ALLOWED:
                        continue
                    hits.append((rel, number, text))
    return hits


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--list", action="store_true",
                        help="auch die bekannten Stellen aus ALLOWED zeigen")
    args = parser.parse_args(argv)

    if args.list:
        for where, why in sorted(ALLOWED.items()):
            print(f"  ✓ {where}  — {why}")
        for name in sorted(ALLOWED_FILES):
            print(f"  ✓ {name}  — ganze Datei")
        print()

    hits = scan()
    for rel, number, text in hits:
        print(f"✗ {rel}:{number}  {text[:90]!r}")
    if hits:
        print(f"\n{len(hits)} deutsche Zeichenkette(n) ohne Schlüssel im Katalog. "
              f"Entweder lokalisierbar machen (`Text`, `LocalizedStringKey`, "
              f"`String(localized:)`) oder mit Grund in ALLOWED eintragen.")
        return 1
    print("✓ keine unlokalisierten deutschen Texte")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
