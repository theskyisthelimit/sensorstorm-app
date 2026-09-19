#!/usr/bin/env python3
"""Was im Swift-Code gegen Rechts-nach-links spricht — deterministisch, ohne Xcode.

    Tools/rtl_audit.py            # Befund; Exit 1 bei Blockern

SwiftUI spiegelt Stapel, `leading`/`trailing` und Systemsymbole mit
`forward`/`backward` von selbst. Was es nicht spiegelt, findet dieses Werkzeug:

Blocker
  * Symbole mit fester Richtung: `chevron.right`, `arrow.left` … — in RTL
    zeigen sie in die falsche Richtung; `chevron.forward`/`arrow.backward`
    drehen mit. Symmetrische (`arrow.left.arrow.right`) sind erlaubt.
  * Absolute Kanten und Ausrichtung: `.padding(.left)`, `Edge.Set.right`,
    `alignment: .left`, `NSTextAlignment.right` — `leading`/`trailing`/
    `.natural` sind die logischen Formen.
  * PDF-Text ohne Absatzstil in den drei Generatoren: ohne
    `baseWritingDirection = .natural` stünde ein arabischer Absatz linksbündig.

Hinweise (kein Exit 1)
  * `.offset(x:)` — nur spiegeln, wenn eine Richtung gemeint ist (Pfeile,
    Routen); Schmuckversatz in Illustrationen darf bleiben.
  * `lineLimit(1)` — CJK, Thai und Devanagari brauchen Zeilenhöhe; eine Zeile
    kann ein Wort abschneiden, das im Deutschen zwei Zeilen brauchte.

Der Rest ist Sehen: Pseudo-RTL im Simulator (`Tools/l10n.py pseudo`, über
`HS_LAUNCH_ARGS` in der Screenshot-Pipeline) vor dem ersten arabischen Text.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [ROOT / "App", ROOT / "Widget"]
PDF_GENERATORS = ("DamagePDFGenerator.swift", "BoxLabelPDFGenerator.swift", "WorkspaceExportGenerator.swift")

SYMMETRIC = {"arrow.left.arrow.right", "arrow.right.arrow.left", "arrow.left.and.right", "arrow.right.and.line.vertical.and.arrow.left"}
DIRECTIONAL_SYMBOL = re.compile(r'"((?:chevron|arrow|arrowshape|arrowtriangle)\.(?:right|left)(?:\.[a-z.]+)?)"')
ABSOLUTE = [
    (re.compile(r"\.padding\(\.(?:left|right)\b"), "absolute Kante: .padding(.left/.right) → .leading/.trailing"),
    (re.compile(r"Edge\.Set\.(?:left|right)\b"), "absolute Kante: Edge.Set.left/right → .leading/.trailing"),
    (re.compile(r"alignment:\s*\.(?:left|right)\b"), "absolute Ausrichtung: alignment: .left/.right → .leading/.trailing"),
    (re.compile(r"NSTextAlignment\.(?:left|right)\b|\.alignment\s*=\s*\.(?:left|right)\b|textAlignment\s*=\s*\.(?:left|right)\b"),
     "absolute Textausrichtung → .natural"),
]
PDF_TEXT = re.compile(r"(?:withAttributes|attributes):\s*\[\s*\.font")
OFFSET = re.compile(r"\.offset\(x:")
LINE_LIMIT = re.compile(r"\.lineLimit\(1\)")


def swift_files() -> list[Path]:
    return sorted(p for root in SOURCES if root.is_dir() for p in root.rglob("*.swift"))


def audit() -> tuple[list[str], list[str]]:
    blockers: list[str] = []
    hints: list[str] = []
    offsets = 0
    limits = 0
    for file in swift_files():
        rel = file.relative_to(ROOT)
        for number, line in enumerate(file.read_text(encoding="utf-8").splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("//"):
                continue
            for match in DIRECTIONAL_SYMBOL.finditer(line):
                if match.group(1) not in SYMMETRIC:
                    blockers.append(f"{rel}:{number}: Symbol „{match.group(1)}“ → forward/backward")
            for pattern, text in ABSOLUTE:
                if pattern.search(line):
                    blockers.append(f"{rel}:{number}: {text}")
            if file.name in PDF_GENERATORS and PDF_TEXT.search(line):
                blockers.append(f"{rel}:{number}: PDF-Text ohne Absatzstil → PDFTextStyle.attributes")
            if OFFSET.search(line):
                offsets += 1
            if LINE_LIMIT.search(line):
                limits += 1
    if offsets:
        hints.append(f"{offsets}× .offset(x:) — spiegeln nur, wo eine Richtung gemeint ist")
    if limits:
        hints.append(f"{limits}× .lineLimit(1) — CJK, Thai und Devanagari brauchen Zeilenhöhe; im Pseudo-RTL/CJK-Lauf ansehen")
    return blockers, hints


def main() -> int:
    blockers, hints = audit()
    for blocker in blockers:
        print("✗", blocker)
    for hint in hints:
        print("ℹ", hint)
    print(("✓ keine Blocker" if not blockers else f"{len(blockers)} Blocker") + f", {len(hints)} Hinweis(e)")
    return 1 if blockers else 0


if __name__ == "__main__":
    sys.exit(main())
