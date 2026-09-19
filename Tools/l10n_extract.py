#!/usr/bin/env python3
"""Deutsche Texte aus dem Build in den String Catalog holen.

    Tools/l10n_extract.py                 # Bericht: was fehlt im Katalog
    Tools/l10n_extract.py --write         # fehlende Schlüssel anlegen
    Tools/l10n_extract.py --write --prune # zusätzlich verwaiste Schlüssel entfernen

Warum nicht `xcstringstool sync`: das Werkzeug leert den Katalog, statt ihn zu
ergänzen — mit denselben `.stringsdata` kommen null Schlüssel heraus. Hier wird
dieselbe Quelle selbst gelesen: `SWIFT_EMIT_LOC_STRINGS: YES` legt je Swift-Datei
eine `.stringsdata` an; darin steht jeder lokalisierbare Text mit Datei und Zeile.
Das ist die einzige Stelle, an der die Wahrheit steht — `xcodebuild` von der
Kommandozeile schreibt sie nie in den Katalog zurück, nur Xcode selbst tut das.

Voraussetzung: ein Build in `DERIVED_DATA` (Standard: der von `xcodebuild` ohne
`-derivedDataPath`). Ohne frischen Build fehlen genau die Texte, die neu sind.
"""
from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(os.environ.get("SENSORSTORM_ROOT") or Path(__file__).resolve().parent.parent)
# Zwei Kataloge, weil es zwei Bundles gibt: was in `Sources/SensorstormCore`
# steht, wird über `bundle: .module` aus dem Katalog der Bibliothek geholt —
# landete es im Katalog der App, fände es dort niemand und die Übersetzung
# bliebe wirkungslos.
# Ein Katalog, weil es hier ein Bundle gibt: `SensorstormCore` wird in die App
# hineingebaut und nicht als eigene Ressource ausgeliefert, seine Texte liegen
# also im Katalog der App. Bekommt das Paket eigene Ressourcen, kommt hier ein
# zweiter Eintrag dazu — die Vorlage des Baukastens zeigt, wie.
CATALOGS = {
    "app": (ROOT / "Resources/Localizable.xcstrings", lambda source: True),
}
DERIVED = Path(os.environ.get("DERIVED_DATA") or
               Path.home() / "Library/Developer/Xcode/DerivedData")
# Nur Ziele der App, nicht die Abhängigkeiten aus dem Paket-Cache: WhisperKit und
# Freunde bringen eigene Texte mit, die niemand von uns übersetzt.
TARGETS = ("Sensorstorm.build", "SensorstormCore.build",
           "SensorstormWatch.build", "SensorstormWatchWidgets.build")


# `Sources/SensorstormCore` wird in die App hineingebaut und liefert keine eigene
# Ressource aus: sein `String(localized:)` löst zur Laufzeit gegen den Katalog der
# App auf. Die `.stringsdata` des App-Ziels enthält seine Texte aber nicht, und
# `--prune` hielt sie deshalb für verwaist und entfernte zwölf Fehlermeldungen in
# 26 Sprachen. Sie werden hier direkt aus dem Quelltext gelesen.
LOCALIZED_CALL = re.compile(r'String\(\s*localized:\s*"((?:[^"\\]|\\.)*)"')
PLACEHOLDER_IN_KEY = re.compile(r"%(?:@|lld|\d*\.?\d*[fdi])")
INTERPOLATION = re.compile(r"\\\((?:[^()]|\([^()]*\))*\)")


def _shape(text: str) -> str:
    """Der Text ohne seine Platzhalter — %@ und `\\(wert)` sollen sich treffen."""
    return PLACEHOLDER_IN_KEY.sub("\x00", INTERPOLATION.sub("\x00", text))


def package_shapes() -> set[str]:
    shapes = set()
    for path in (ROOT / "Sources").rglob("*.swift"):
        for match in LOCALIZED_CALL.finditer(path.read_text(encoding="utf-8")):
            shapes.add(_shape(match.group(1)))
    return shapes


def build_dirs() -> list[Path]:
    """Beide Layouts: das der Xcode-Ablage und das von `-derivedDataPath`.

    Ohne `-derivedDataPath` legt Xcode je Projekt einen Ordner `Sensorstorm-<hash>`
    an; mit der Option fällt dieser Zwischenschritt weg und `Build/` liegt direkt
    im angegebenen Verzeichnis. Die CI benutzt die zweite Form, ein Lauf von Hand
    meist die erste — und ein Abgleich, der nur eine davon findet, meldet
    „kein Build“ genau dort, wo er gebraucht wird.
    """
    roots = sorted(DERIVED.glob("Sensorstorm-*/Build/Intermediates.noindex"))
    direct = DERIVED / "Build/Intermediates.noindex"
    if direct.is_dir():
        roots.append(direct)
    if not roots:
        raise SystemExit(f"Kein Build unter {DERIVED} — erst `xcodebuild … build` laufen lassen.")
    return roots


def stringsdata_files() -> list[Path]:
    found: list[Path] = []
    for root in build_dirs():
        for target in TARGETS:
            found += list(root.glob(f"**/{target}/**/*.stringsdata"))
    return sorted(set(found))


def read(path: Path) -> tuple[str, list[dict]]:
    """(Quelldatei, Einträge) — die `.stringsdata` sind Plists, aber nicht alle in
    einem Format, das `plistlib` liest; für den Rest übersetzt `plutil` nach JSON."""
    try:
        with open(path, "rb") as handle:
            data = plistlib.load(handle)
    except Exception:
        raw = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(path)],
                             capture_output=True)
        if raw.returncode != 0:
            return str(path), []
        data = json.loads(raw.stdout)
    entries = []
    for table, items in (data.get("tables") or {}).items():
        for item in items:
            key = item.get("key")
            if not key:
                continue
            entries.append({
                "key": key,
                "table": table,
                "comment": item.get("comment") or "",
                "line": (item.get("location") or {}).get("startingLine"),
            })
    return data.get("source", str(path)), entries


def collect() -> dict[str, dict]:
    """Schlüssel → {source, line, comment}. Der erste Fundort gewinnt."""
    keys: dict[str, dict] = {}
    for path in stringsdata_files():
        source, entries = read(path)
        # Alte Arbeitsbäume unter .claude/worktrees/ tragen dieselben Dateinamen
        # mit veraltetem Text: ihre Schlüssel gehören nicht in den Katalog.
        if "/.claude/" in str(source):
            continue
        # `GeneratedStringSymbols_Localizable.swift` in DerivedSources ist
        # Xcodes eigene Ausgabe **aus** dem Katalog: sie meldet dieselben
        # Schlüssel noch einmal, aber unter einem Pfad in DerivedData. Käme sie
        # zuerst, stünde als Fundort ein Build-Verzeichnis statt der Quelldatei
        # — und die Zuordnung zum richtigen Katalog wäre verloren.
        if "/DerivedSources/" in str(source):
            continue
        for entry in entries:
            if entry["table"] != "Localizable":
                continue
            keys.setdefault(entry["key"], {
                "source": str(Path(source).relative_to(ROOT)) if str(source).startswith(str(ROOT)) else source,
                "line": entry["line"],
                "comment": entry["comment"],
            })
    return keys


def catalog_for(source: str) -> str:
    """Welcher Katalog für eine Quelldatei zuständig ist — der erste, der passt."""
    for name, (_, matches) in CATALOGS.items():
        if matches(source):
            return name
    return "app"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--write", action="store_true", help="fehlende Schlüssel in den Katalog schreiben")
    parser.add_argument("--prune", action="store_true",
                        help="Schlüssel entfernen, die im Build nicht mehr vorkommen (nur mit --write)")
    args = parser.parse_args(argv)

    found = collect()
    if not found:
        raise SystemExit("Keine .stringsdata gefunden — ist der Build durchgelaufen?")

    exit_code = 0
    for name, (path_, _) in CATALOGS.items():
        catalog = json.loads(path_.read_text(encoding="utf-8"))
        existing = catalog.setdefault("strings", {})
        mine = {k: v for k, v in found.items() if catalog_for(v["source"]) == name}
        missing = {k: v for k, v in mine.items() if k not in existing}
        shapes = package_shapes()
        orphan = [k for k in existing
                  if k not in mine and k != "" and _shape(k) not in shapes]

        print(f"{path_.relative_to(ROOT)}: Build kennt {len(mine)}, Katalog {len(existing)} — "
              f"{len(missing)} fehlen, {len(orphan)} verwaist")
        for key, where in sorted(missing.items())[:100]:
            print(f"  + {where['source']}:{where['line']}  {key[:80]!r}")
        for key in sorted(orphan)[:50]:
            print(f"  - {key[:80]!r}")

        if not args.write:
            if missing:
                exit_code = 1
            continue

        for key, where in missing.items():
            entry: dict = {"extractionState": "manual"}
            if where["comment"]:
                entry["comment"] = where["comment"]
            existing[key] = entry
        removed = 0
        if args.prune:
            for key in orphan:
                del existing[key]
                removed += 1
        catalog["strings"] = dict(sorted(existing.items()))
        # Xcodes eigene Schreibweise: Leerzeichen vor dem Doppelpunkt. Ohne das
        # formatiert jeder Lauf den ganzen Katalog um und der Diff ist 1,5 MB
        # Rauschen statt der zwanzig Zeilen, die sich wirklich geändert haben.
        path_.write_text(
            json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : ")) + "\n",
            encoding="utf-8")
        print(f"  → {len(missing)} angelegt, {removed} entfernt, {len(catalog['strings'])} gesamt")

    if not args.write and exit_code:
        print("\nNichts geschrieben. Mit --write anlegen.")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
