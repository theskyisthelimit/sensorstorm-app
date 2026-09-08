#!/usr/bin/env python3
"""Ein Übersetzungspaket der Reihe nach ausfüllen.

    python3 Tools/l10n_fill.py l10n/packs/es/es-001.json < targets.json

`targets.json` ist eine Liste von Zeichenketten — **in der Reihenfolge der
`units`**, eine je Eintrag. Das Skript weigert sich, wenn die Anzahl nicht
stimmt: eine verschobene Liste wäre schlimmer als eine leere, weil jeder Text
dann am falschen Ort stünde und die Sperren das nur teilweise fangen.

Warum diese Form: wer ein ganzes Paket in einem Stück übersetzt, schreibt die
Texte ohnehin der Reihe nach. Die Kennungen noch einmal mitzuschicken wäre die
doppelte Menge Text für dieselbe Information.

Ein leerer Eintrag ("") bleibt leer und wird beim Import übersprungen.
"""
import json
import sys
from pathlib import Path


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__)
        return 2
    pack_path = Path(argv[0])
    pack = json.loads(pack_path.read_text(encoding="utf-8"))
    units = pack["units"]
    targets = json.load(sys.stdin)

    if not isinstance(targets, list):
        raise SystemExit("Erwartet wird eine JSON-Liste von Zeichenketten.")
    if len(targets) != len(units):
        raise SystemExit(
            f"{pack_path.name}: {len(targets)} Übersetzungen für {len(units)} Texte — "
            "die Liste ist verschoben, es wird nichts geschrieben."
        )

    filled = 0
    for unit, target in zip(units, targets):
        if not isinstance(target, str):
            raise SystemExit(f"Eintrag zu „{unit['id'][:40]}…“ ist kein Text.")
        unit["target"] = target
        if target.strip():
            filled += 1

    pack_path.write_text(json.dumps(pack, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"{pack_path.name}: {filled}/{len(units)} ausgefüllt")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
