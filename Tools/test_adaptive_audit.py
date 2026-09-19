#!/usr/bin/env python3
"""Tests für Tools/adaptive_audit.py mit kleinen Repos in einem Temp-Ordner.

    python3 -m unittest Tools/test_adaptive_audit.py

Festgehalten wird: jede Blocker-Regel schlägt an, eine begründete Ausnahme
(`// adaptiv: …`) wird zum Hinweis, Kommentare, Watch, Widgets und Tests zählen nicht,
ein Symbol mit Titel in der Leiste ist in Ordnung, und `UIRequiresFullScreen` wird in
project.yml und Info.plist gefunden, aber nicht, wenn es auskommentiert ist.
"""
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import adaptive_audit  # noqa: E402


class AdaptiveAuditTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write(self, rel: str, text: str) -> None:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def test_clean_view_has_no_findings(self) -> None:
        self.write("App/Clean.swift", """
struct Clean: View {
    @Environment(\\.horizontalSizeClass) private var sizeClass
    var body: some View {
        NavigationStack {
            List { Text("A") }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { } label: { Label("Neu", systemImage: "plus") }
                    }
                }
        }
    }
}
""")
        blockers, hints = adaptive_audit.audit(self.root)
        self.assertEqual(blockers, [])
        self.assertEqual(hints, [])

    def test_each_blocker_rule(self) -> None:
        self.write("App/Bad.swift", """
let pad = UIDevice.current.userInterfaceIdiom == .pad
let turned = UIDevice.current.orientation.isLandscape
let width = UIScreen.main.bounds.width
let bar = UIToolbar()
let inner = view.bounds.width - view.safeAreaInsets.left * 2
""")
        blockers, _ = adaptive_audit.audit(self.root)
        self.assertEqual(len(blockers), 5, blockers)
        self.assertTrue(all(b.startswith("App/Bad.swift:") for b in blockers))

    def test_marker_turns_blocker_into_hint(self) -> None:
        self.write("App/Marked.swift", """
// adaptiv: Rechtsklick-Menü nur mit Zeiger, kein Layout
let pad = UIDevice.current.userInterfaceIdiom == .pad
let mac = UIDevice.current.userInterfaceIdiom == .mac // adaptiv: Tastaturkürzel
""")
        blockers, hints = adaptive_audit.audit(self.root)
        self.assertEqual(blockers, [])
        self.assertEqual(sum("begründet" in h for h in hints), 2)

    def test_comments_and_other_targets_are_ignored(self) -> None:
        self.write("App/Doc.swift", "/// Nie `UIScreen.main` verwenden.\n// userInterfaceIdiom\n")
        self.write("AppWatch/Face.swift", "let w = UIScreen.main.bounds.width\n")
        self.write("AppWidget/Entry.swift", "let pad = UIDevice.current.userInterfaceIdiom == .pad\n")
        self.write("AppTests/Test.swift", "let w = UIScreen.main.bounds.width\n")
        self.write("build/Gen.swift", "let w = UIScreen.main.bounds.width\n")
        self.write(".claude/worktrees/x/App/Copy.swift", "let w = UIScreen.main.bounds.width\n")
        blockers, hints = adaptive_audit.audit(self.root)
        self.assertEqual(blockers, [])
        self.assertEqual(hints, [])

    def test_toolbar_symbol_without_title_and_own_overflow(self) -> None:
        self.write("App/Bar.swift", """
struct Bar: View {
    var body: some View {
        Text("x")
            .toolbar {
                ToolbarItem {
                    Button { } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                ToolbarItem {
                    Menu { } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        Image(systemName: "star")
    }
}
""")
        blockers, hints = adaptive_audit.audit(self.root)
        self.assertEqual(blockers, [])
        self.assertEqual(sum("Symbol ohne Titel" in h for h in hints), 2, hints)
        self.assertEqual(sum("eigenes ⋯" in h for h in hints), 1, hints)

    def test_requires_full_screen_in_project_and_plist(self) -> None:
        self.write("project.yml", "        UIRequiresFullScreen: true\n        # UIRequiresFullScreen: true\n")
        self.write("App/Info.plist", "<dict>\n<key>UIRequiresFullScreen</key>\n<true/>\n</dict>\n")
        blockers, _ = adaptive_audit.audit(self.root)
        self.assertEqual(len(blockers), 2, blockers)

    def test_portrait_only_iphone_is_a_hint(self) -> None:
        self.write("project.yml", """        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
        UISupportedInterfaceOrientations~ipad:
          - UIInterfaceOrientationPortrait
          - UIInterfaceOrientationLandscapeLeft
""")
        blockers, hints = adaptive_audit.audit(self.root)
        self.assertEqual(blockers, [])
        self.assertEqual(len(hints), 1, hints)


if __name__ == "__main__":
    unittest.main()
