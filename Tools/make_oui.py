#!/usr/bin/env python3
"""Baut Resources/oui.bin, die Herstellerliste für Hardware-Adressen.

    Tools/make_oui.py oui.csv mam.csv oui36.csv      # direkt aus den CSV-Dateien der IEEE
    Tools/make_oui.py --normalise Resources/oui.bin  # die vorhandene Datei bereinigen

Die IEEE bietet drei Register als CSV an (https://standards-oui.ieee.org/): MA-L mit 24 Bit
(sechs Hexziffern), MA-M mit 28 Bit (sieben) und MA-S mit 36 Bit (neun). Die Spalten heissen
`Registry,Assignment,Organization Name,Organization Address`.

Ergebnis: je Zeile `SCHLÜSSEL<TAB>Name`, nach Bytes sortiert, ohne „Private" und ohne doppelte
Schlüssel, mit rohem Deflate (Fenster -15) komprimiert, wie `NSData.decompressed(using: .zlib)`
es liest. Die Suche in der App ist eine Binärsuche über diese Zeilen; sie verlangt genau diese
Sortierung.
"""
import csv
import html
import sys
import zlib
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "Resources" / "oui.bin"


def clean(name: str) -> str:
    name = html.unescape(name).replace("\t", " ").replace("\n", " ").replace("\r", " ")
    return " ".join(name.split())


def from_csv(paths):
    entries = {}
    for path in paths:
        with open(path, newline="", encoding="utf-8") as handle:
            for row in csv.DictReader(handle):
                key = row["Assignment"].strip().upper()
                name = clean(row["Organization Name"])
                if len(key) in (6, 7, 9) and name and name != "Private":
                    entries[key] = name
    return entries


def from_bin(path):
    text = zlib.decompress(Path(path).read_bytes(), -15).decode("utf-8")
    entries = {}
    for line in text.split("\n"):
        if "\t" not in line:
            continue
        key, name = line.split("\t", 1)
        name = clean(name)
        if len(key) in (6, 7, 9) and name and name != "Private":
            entries[key] = name
    return entries


def main():
    args = sys.argv[1:]
    if args[:1] == ["--normalise"]:
        entries = from_bin(args[1] if len(args) > 1 else OUT)
    elif args:
        entries = from_csv(args)
    else:
        sys.exit(__doc__)
    text = "".join(f"{key}\t{entries[key]}\n" for key in sorted(entries, key=lambda k: k.encode()))
    packer = zlib.compressobj(9, zlib.DEFLATED, -15)
    OUT.write_bytes(packer.compress(text.encode("utf-8")) + packer.flush())
    print(f"{len(entries)} Einträge, {OUT.stat().st_size} Byte")


if __name__ == "__main__":
    main()
