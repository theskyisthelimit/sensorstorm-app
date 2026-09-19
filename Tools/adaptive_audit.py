#!/usr/bin/env python3
"""Was im Code gegen jede Grösse spricht: iPad-Fenster, iPhone Mirroring, iPhone Duo.

    Tools/adaptive_audit.py                      # dieses Repo; Exit 1 bei Blockern
    Tools/adaptive_audit.py --root ../andere-app # ein anderes Repo, auch direkt aus dem Skill
    Tools/adaptive_audit.py --summary            # nur die Zahlen

Quellen: HIG „Layout › Size classes“ und „Designing for iPhone Duo“, Apple-Artikel
„Preparing your app for iPhone Duo“ (September 2026). Regeln, Posen, Testmatrix und
Ablauf für bestehende Apps: Skill ios-developer, references/adaptive-layout.md.

Blocker
  * `userInterfaceIdiom`: sagt nichts über den Platz. Das iPhone Duo ist offen ein
    `.phone` mit regulär × regulär. Layout nach Size Class, Grösse vom Container.
  * Ausrichtung als Weiche (`UIDevice.current.orientation`, `interfaceOrientation`,
    `statusBarOrientation`): das Innendisplay beachtet keine Ausrichtungssperre.
  * `UIScreen.main`: auf Geräten mit zwei Displays veraltet. Grösse vom Container,
    der Bildschirm über `windowScene.screen`.
  * `UIRequiresFullScreen` in project.yml oder einer Info.plist: schaltet das
    stufenlose Grössenändern ab.
  * Eigene Leisten (`UIToolbar(`, `UINavigationBar(`, `UITabBar(`): nur Leisten der
    Navigations-Container wandern auf dem iPhone Duo an die Seite.
  * Symmetrische Safe-Area-Rechnung (`safeAreaInsets.left * 2`): Safe Areas sind
    asymmetrisch, seitliche Leisten stehen nur auf einer Seite.

Hinweise (kein Exit 1)
  * Symbol ohne Titel in `.toolbar { … }`: `Label("…", systemImage:)`. Ohne Symbol
    steht ein Eintrag nie seitlich, ohne Titel fehlt er im Überlaufmenü.
  * Eigenes ⋯ (`ellipsis`) in einer Leiste: das System-Überlaufmenü nehmen
    (`ToolbarOverflowMenu`, iOS 27).
  * `requestGeometryUpdate`: eine Drehanfrage. Das Innendisplay dreht nicht, es
    braucht einen Weg ohne Drehen.
  * `.safeAreaInset(edge: .top/.bottom)`: oft eine selbstgebaute Leiste, die nicht an
    die Seite wandert.
  * Feste Breiten ab 300 pt, `isLandscape`-Weichen, iPhone nur hochkant.

Begründete Ausnahme: `// adaptiv: <Grund>` auf derselben Zeile oder direkt darüber.
Sie zählt als Hinweis, nicht als Blocker. Ohne Grund gibt es keine Ausnahme.

Nicht geprüft werden watchOS, Widgets, Tests, Build-Ordner, versteckte Ordner (Worktrees)
und fremder Code. Der Rest ist Sehen: Device Hub mit allen Posen (Xcode 27.1).
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_ROOT = HERE.parent

SKIP_DIRS = {
    "build", "DerivedData", "SourcePackages",
    "Pods", "Carthage", "checkouts", "node_modules", "site", "web", "server", "supabase",
    "docs", "screenshots", "l10n", "Vendor", "Tools",
}
# Ziele ohne iPhone-/iPad-Oberfläche: Watch, Widgets (Grössen gibt das System vor), Tests.
SKIP_PARTS = ("Watch", "Widget", "Tests", "Complication")

MARKER = re.compile(r"//\s*adaptiv:\s*\S")

BLOCKERS = [
    (re.compile(r"\buserInterfaceIdiom\b"),
     "Geräte-Idiom als Weiche → Size Class bzw. Containergrösse"),
    (re.compile(r"UIDevice\.current\.orientation\b|\binterfaceOrientation\b|\bstatusBarOrientation\b"),
     "Ausrichtung als Weiche → Size Class; das Innendisplay des iPhone Duo dreht nicht"),
    (re.compile(r"\bUIScreen\.main\b"),
     "UIScreen.main → Grösse vom Container, Bildschirm über windowScene.screen"),
    (re.compile(r"\b(?:UIToolbar|UINavigationBar|UITabBar)\("),
     "eigene Leiste → Leisten des Navigations-Containers (.toolbar, navigationItem)"),
    (re.compile(r"safeAreaInsets\.(?:left|right|leading|trailing)\s*\*\s*2|2\s*\*\s*[\w.]*safeAreaInsets\.(?:left|right|leading|trailing)"),
     "symmetrische Safe-Area-Rechnung → jede Kante einzeln (bounds.inset(by:))"),
]

HINTS = [
    (re.compile(r"\brequestGeometryUpdate\b"),
     "Drehanfrage → Weg ohne Drehen fürs Innendisplay des iPhone Duo"),
    (re.compile(r"\.safeAreaInset\(\s*edge:\s*\.(?:top|bottom)"),
     "eigene Leiste über safeAreaInset? → .toolbar, damit sie an die Seite wandern kann"),
    (re.compile(r"\bisLandscape\b"),
     "Querformat-Weiche → Size Class oder Seitenverhältnis des Containers"),
]

FIXED_WIDTH = re.compile(r"\.frame\(\s*width:\s*(\d{3,})")
TOOLBAR_OPEN = re.compile(r"\.toolbar\s*\{")
TOOLBAR_SYMBOL = re.compile(r"Image\(systemName:")
LABELLED = re.compile(r"\bLabel\b|icon:")
ELLIPSIS = re.compile(r'"ellipsis(?:\.circle)?(?:\.fill)?"')
REQUIRES_FULL_SCREEN = re.compile(r"UIRequiresFullScreen[^\n]*?(?:true|YES|<true/>)|<key>UIRequiresFullScreen</key>\s*<true/>")


def skipped(path: Path, root: Path) -> bool:
    parts = path.relative_to(root).parts[:-1]
    return any(part in SKIP_DIRS or part.startswith(".") or part.endswith((".xcodeproj", ".xcworkspace", ".app"))
               or any(s in part for s in SKIP_PARTS) for part in parts)


def swift_files(root: Path) -> list[Path]:
    return sorted(p for p in root.rglob("*.swift") if not skipped(p, root))


def is_comment(line: str) -> bool:
    stripped = line.strip()
    return stripped.startswith(("//", "/*", "*"))


def exempt(lines: list[str], index: int) -> bool:
    if MARKER.search(lines[index]):
        return True
    return index > 0 and is_comment(lines[index - 1]) and bool(MARKER.search(lines[index - 1]))


def toolbar_lines(lines: list[str]) -> set[int]:
    """Zeilen innerhalb von `.toolbar { … }` (Klammern gezählt, Zeichenketten grob übersprungen)."""
    inside: set[int] = set()
    index = 0
    while index < len(lines):
        match = TOOLBAR_OPEN.search(lines[index])
        if not match or is_comment(lines[index]):
            index += 1
            continue
        depth = 0
        start_col = match.end() - 1
        line_no = index
        done = False
        while line_no < len(lines) and not done:
            text = re.sub(r'"(?:\\.|[^"\\])*"', '""', lines[line_no])
            begin = start_col if line_no == index else 0
            for char in text[begin:]:
                if char == "{":
                    depth += 1
                elif char == "}":
                    depth -= 1
                    if depth == 0:
                        done = True
                        break
            inside.add(line_no)
            line_no += 1
        index = line_no
    return inside


def audit_swift(root: Path) -> tuple[list[str], list[str]]:
    blockers: list[str] = []
    hints: list[str] = []
    fixed = 0
    for file in swift_files(root):
        rel = file.relative_to(root)
        lines = file.read_text(encoding="utf-8", errors="replace").splitlines()
        in_toolbar = toolbar_lines(lines)
        for index, line in enumerate(lines):
            if is_comment(line):
                continue
            where = f"{rel}:{index + 1}"
            for pattern, text in BLOCKERS:
                if pattern.search(line):
                    if exempt(lines, index):
                        hints.append(f"{where}: begründet: {text}")
                    else:
                        blockers.append(f"{where}: {text}")
            for pattern, text in HINTS:
                if pattern.search(line) and not exempt(lines, index):
                    hints.append(f"{where}: {text}")
            width = FIXED_WIDTH.search(line)
            if width and int(width.group(1)) >= 300 and not exempt(lines, index):
                fixed += 1
            if index in in_toolbar and not exempt(lines, index):
                previous = lines[index - 1] if index else ""
                if TOOLBAR_SYMBOL.search(line) and not LABELLED.search(line) and not LABELLED.search(previous):
                    hints.append(f"{where}: Symbol ohne Titel in der Leiste → Label(\"…\", systemImage:)")
                if ELLIPSIS.search(line):
                    hints.append(f"{where}: eigenes ⋯ in der Leiste → System-Überlaufmenü (ToolbarOverflowMenu)")
    if fixed:
        hints.append(f"{fixed}× feste Breite ab 300 pt → relativ zum Container (containerRelativeFrame, maxWidth)")
    return blockers, hints


def audit_config(root: Path) -> tuple[list[str], list[str]]:
    blockers: list[str] = []
    hints: list[str] = []
    project = root / "project.yml"
    candidates = [project] if project.exists() else []
    candidates += [p for p in root.rglob("Info.plist") if not skipped(p, root)]
    for path in candidates:
        raw = path.read_text(encoding="utf-8", errors="replace")
        text = "\n".join(line for line in raw.splitlines() if not line.strip().startswith("#"))
        rel = path.relative_to(root)
        if REQUIRES_FULL_SCREEN.search(text):
            blockers.append(f"{rel}: UIRequiresFullScreen → entfernen, die App muss jede Grösse können")
        phone = re.search(r"UISupportedInterfaceOrientations:\s*\n((?:\s+- \S+\n)+)", text)
        if phone and path.name == "project.yml":
            entries = re.findall(r"- (\S+)", phone.group(1))
            if entries and all("Portrait" in e for e in entries):
                hints.append(f"{rel}: iPhone nur hochkant (erlaubt) → Layout muss trotzdem quer und regulär × regulär funktionieren")
    return blockers, hints


def audit(root: Path = DEFAULT_ROOT) -> tuple[list[str], list[str]]:
    root = root.resolve()
    b1, h1 = audit_swift(root)
    b2, h2 = audit_config(root)
    return b2 + b1, h2 + h1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="Repo, Standard: das dieses Werkzeugs")
    parser.add_argument("--summary", action="store_true", help="nur Zahlen")
    args = parser.parse_args()
    blockers, hints = audit(args.root)
    if not args.summary:
        for blocker in blockers:
            print("✗", blocker)
        for hint in hints:
            print("ℹ", hint)
    print(("✓ keine Blocker" if not blockers else f"{len(blockers)} Blocker") + f", {len(hints)} Hinweis(e)")
    return 1 if blockers else 0


if __name__ == "__main__":
    sys.exit(main())
