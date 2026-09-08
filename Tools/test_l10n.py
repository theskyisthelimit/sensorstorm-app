#!/usr/bin/env python3
"""Mechanik-Tests für Tools/l10n.py mit der Mock-Engine in einer Repo-Kopie.

    python3 -m unittest Tools/test_l10n.py

Was hier festgehalten wird: eine Sprache ist nach `add-language` überall
vorhanden (Katalog inkl. Plural-Schlüssel, InfoPlist, Uhren-Katalog, Store-
Dateien je ASC-Locale, project.yml), ein zweiter Lauf
übersetzt nichts mehr (Gedächtnis), die deterministischen Sperren lassen
kaputte Texte nicht in die Dateien, und das Store-Listing rührt nicht an, was
heute ein Ranking trägt (Name, Untertitel, bewährte Keywords).
"""
import argparse
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import l10n  # noqa: E402

REPO = HERE.parent


def planned_language() -> str:
    """Eine Sprache, in der noch nichts steht.

    Die Pipeline-Tests legen eine Sprache neu an und prüfen, dass danach überall
    etwas steht. Mit einer bereits übersetzten Sprache prüften sie nichts —
    darum wird die erste `planned` aus der Registry genommen, statt eine
    festzuschreiben, die morgen übersetzt ist.
    """
    catalog = json.loads((REPO / "Resources/Localizable.xcstrings").read_text(encoding="utf-8"))["strings"]

    def leer(code: str) -> bool:
        for key, entry in catalog.items():
            if not key.strip() or entry.get("extractionState") == "stale":
                continue
            if code in entry.get("localizations", {}):
                return False
        return True

    # „planned" allein reicht nicht: eine Sprache, die von Hand übersetzt und
    # noch nicht `activate`-t wurde, steht ebenfalls auf `planned`, ist aber
    # voll. Der Test braucht eine wirklich leere.
    for entry in json.loads((REPO / "l10n/languages.json").read_text(encoding="utf-8"))["languages"]:
        if entry.get("status") == "planned" and leer(entry["code"]):
            return entry["code"]
    raise unittest.SkipTest("keine unübersetzte Sprache mehr in der Registry")


class TempRepo:
    def __init__(self):
        self.dir = Path(tempfile.mkdtemp(prefix="sensorstorm-l10n-"))
        for rel in ("l10n/languages.json", "l10n/glossary.json", "Resources/Localizable.xcstrings",
                    "Resources/InfoPlist.xcstrings", "Watch/Localizable.xcstrings", "project.yml"):
            target = self.dir / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(REPO / rel, target)
        shutil.copytree(REPO / "Tools/store", self.dir / "Tools/store")
        if (REPO / "l10n/aso").is_dir():
            shutil.copytree(REPO / "l10n/aso", self.dir / "l10n/aso")
        (self.dir / "App").mkdir()
        (self.dir / "App" / "PaywallView.swift").write_text('Text("Pro freischalten")\n', encoding="utf-8")
        l10n.ROOT = self.dir
        l10n._context_cache = None

    def cleanup(self):
        shutil.rmtree(self.dir, ignore_errors=True)


class GermanStyleTests(unittest.TestCase):
    """Die Quellsprache ist die Vorlage für 33 weitere. Was hier steht, wird
    33-mal übersetzt — auch der Stil."""

    def test_no_em_dashes_in_the_source(self):
        # Rückmeldung 2026-09-07: „Viel zu viele Gedankenstriche, man sieht
        # sofort dass es AI geschrieben hat." Der Strich stand 146-mal im
        # Katalog, fast immer in derselben Figur: kurzer Satz, Strich, Pointe.
        # Ein deutscher Satz kommt mit Komma, Punkt und Doppelpunkt aus.
        catalog = json.loads((REPO / "Resources/Localizable.xcstrings").read_text(encoding="utf-8"))
        treffer = [k for k in catalog["strings"] if "—" in k or "–" in k]
        self.assertEqual(treffer, [], f"{len(treffer)} deutsche Texte tragen einen Gedankenstrich")

    def test_no_em_dashes_in_the_source_screenshot_captions(self):
        """Die Zeilen über den App-Store-Bildern sind die kürzesten Texte im
        Bestand und die meistgelesenen. Die Figur „kurzer Satz, Strich, Pointe"
        fällt dort am stärksten auf."""
        store = json.loads((REPO / "Tools/store/de-DE.json").read_text(encoding="utf-8"))
        treffer = [f"{key}.{field}"
                   for key, texts in (store.get("screenshots") or {}).items()
                   for field, value in texts.items()
                   if "—" in value or "–" in value]
        self.assertEqual(treffer, [], "Bildtexte mit Gedankenstrich")


class CheckTextTests(unittest.TestCase):
    def setUp(self):
        self.repo = TempRepo()
        self.entry = l10n.language("es")
        self.gloss = l10n.glossary()

    def tearDown(self):
        self.repo.cleanup()

    def check(self, source, text, reference="", kind="ui", max_chars=None):
        row = l10n.Row("catalog", source, source, reference, "", kind, max_chars=max_chars)
        return l10n.errors(l10n.check_text(row, text, self.entry, self.gloss))

    def warns(self, source, text, reference="", kind="ui", max_chars=None):
        row = l10n.Row("catalog", source, source, reference, "", kind, max_chars=max_chars)
        return l10n.warnings(l10n.check_text(row, text, self.entry, self.gloss))

    def test_placeholders_must_match(self):
        self.assertEqual(self.check("%lld Kisten", "%lld cajas"), [])
        self.assertEqual(self.check("%@ · %lld", "%2$lld · %1$@"), [])
        self.assertTrue(any("Platzhalter" in p for p in self.check("%lld Kisten", "cajas")))
        self.assertTrue(any("Platzhalter" in p for p in self.check("%@ Kiste", "%d caja")))
        self.assertTrue(any("Positionen" in p for p in self.check("%@ %@", "%1$@ %3$@")))

    def test_siri_phrases_keep_the_app_name_token(self):
        # Ein Kurzbefehlsatz ohne `${applicationName}` wird von Apple abgelehnt.
        # Eine Sprache, deren Übersetzung den Token wegübersetzt, verlöre ihre
        # Sprachbefehle — still, denn die App baut trotzdem.
        self.assertEqual(
            self.check("Was steht in ${applicationName} an", "Qué hay pendiente en ${applicationName}"),
            [],
        )
        self.assertTrue(
            any("applicationName" in p for p in self.check("Was steht in ${applicationName} an", "Qué hay pendiente"))
        )

    def test_lone_percent_is_rejected_unless_the_source_has_one(self):
        self.assertTrue(any("%" in p for p in self.check("100 %% geschafft", "100 % hecho")))
        self.assertEqual(self.check("100 %% geschafft", "100 %% hecho"), [])
        self.assertEqual(self.check("Bei 100 % drucken", "Imprimir al 100 %"), [], "ein nacktes % in der Quelle bleibt erlaubt")

    def test_untranslated_is_a_warning_but_names_and_units_pass(self):
        self.assertTrue(any("unübersetzt" in p for p in self.warns("Kiste packen", "Kiste packen")))
        self.assertEqual(self.check("Kiste packen", "Kiste packen"), [], "eine Warnung, keine Sperre")
        self.assertEqual(self.warns("Garage", "Garage"), [])
        self.assertEqual(self.warns("OK", "OK"), [])
        self.assertEqual(self.warns("%lld min", "%lld min"), [])
        self.assertEqual(self.warns("%lld h %lld min", "%lld h %lld min"), [])

    def test_brand_names_must_survive_soft_ones_only_warn(self):
        self.assertTrue(any("Sensorstorm" in p for p in self.check("Sensorstorm Pro freischalten", "Desbloquear la versión de pago")))
        self.assertEqual(self.check("Sensorstorm Pro freischalten", "Desbloquear Sensorstorm Pro"), [])
        self.assertEqual(self.check("Mit Apple anmelden", "Iniciar sesión"), [])
        self.assertTrue(any("Apple" in p for p in self.warns("Mit Apple anmelden", "Iniciar sesión")))

    def test_local_short_forms_count_as_kept(self):
        # „Wi-Fi“ ist eine weiche Marke: sie darf landesüblich heissen. Ohne
        # diese Ausnahme stünde in jeder betroffenen Sprache dieselbe Warnung
        # und verdeckte die echten.
        self.assertEqual(self.warns("Über Wi-Fi senden", "Enviar por wifi"), [])
        self.assertTrue(any("Wi-Fi" in p for p in self.warns("Über Wi-Fi senden", "Enviar por red")))

    def test_length_budget_warns_for_ui_only(self):
        self.assertTrue(any("Budget" in p for p in self.warns("Kiste", "una caja muy pero que muy larga", "Box", max_chars=12)))
        self.assertEqual(self.check("Kiste", "una caja muy pero que muy larga", "Box", max_chars=12), [])
        self.assertEqual(self.warns("Kiste " * 30, "caja " * 60, kind="help"), [])

    def test_html_control_and_newlines(self):
        self.assertTrue(self.check("Zeile", "<b>línea</b>"))
        self.assertTrue(self.check("Zeile\nzwei", "línea dos"))
        self.assertEqual(self.check("Zeile\nzwei", "línea\ndos"), [])

    def test_plural_structure(self):
        row = l10n.Row("catalog", "%lld Kisten", "%lld Kisten",
                       json.dumps({"value": "%#@arg1@", "substitutions": {"arg1": {"one": "%arg box", "other": "%arg boxes"}}}),
                       kind="plural", extra={"categories": ["one", "many", "other"]})
        self.entry = dict(self.entry, pluralCategories=["one", "many", "other"])
        good = json.dumps({"value": "%#@arg1@", "substitutions": {"arg1": {"one": "%arg caja", "many": "%arg cajas", "other": "%arg cajas"}}})
        self.assertEqual(l10n.errors(l10n.check_text(row, good, self.entry, self.gloss)), [])
        missing = json.dumps({"value": "%#@arg1@", "substitutions": {"arg1": {"one": "%arg caja", "other": "%arg cajas"}}})
        self.assertTrue(l10n.errors(l10n.check_text(row, missing, self.entry, self.gloss)))
        self.assertTrue(l10n.errors(l10n.check_text(row, "kein json", self.entry, self.gloss)))


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.repo = TempRepo()

    def tearDown(self):
        self.repo.cleanup()

    def test_a_pack_round_trips_through_the_locks(self):
        """Eine Datei raus, ausgefüllt zurück — der Weg für jede fremde KI.

        Geprüft wird beides: dass das Paket alles trägt, was zum Übersetzen
        nötig ist, und dass der Rückweg durch dieselben Sperren geht wie die
        eingebaute Pipeline. Ein Paket, das kaputte Platzhalter durchliesse,
        wäre schlimmer als keines.
        """
        # `--all`, nicht nur das Offene: der Test soll dieselbe Datei bekommen,
        # egal wie weit die Sprache im echten Bestand schon ist.
        rc = l10n.main(["pack", "--lang", "es", "--surface", "infoplist", "--all", "--out", str(self.repo.dir / "packs")])
        self.assertEqual(rc, 0)
        pack_file = self.repo.dir / "packs" / "es.json"
        payload = json.loads(pack_file.read_text(encoding="utf-8"))
        self.assertEqual(payload["$schema"], l10n.PACK_SCHEMA)
        self.assertEqual(payload["language"]["code"], "es")
        self.assertTrue(payload["rules"], "die Regeln stehen im Paket, nicht im Kopf")
        self.assertTrue(payload["units"])
        for unit in payload["units"]:
            self.assertEqual(unit["target"], "", "das Paket kommt leer heraus")
            self.assertTrue(unit["source"])

        # Ausgefüllt zurück: ein guter Text, ein kaputter, ein leerer.
        # Mit Marke: seit der Quelltext aus `project.yml` kommt, greift die
        # Marken-Sperre auch auf den Systemdialogen.
        # Die Marken der Quelle müssen im Ziel stehen, sonst greift die Sperre
        # zu Recht: der Text kommt aus `project.yml` und nennt die App.
        marken = [b for b in l10n.glossary()["doNotTranslate"] if b in payload["units"][0]["source"]]
        gut = " ".join(marken + ["texto de prueba"])
        payload["units"][0]["target"] = gut
        if len(payload["units"]) > 1:
            payload["units"][1]["target"] = "%@ zu viel"   # Platzhalter, den die Quelle nicht hat
        pack_file.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")

        rc = l10n.main(["import", "--lang", "es", "--dir", str(self.repo.dir / "packs")])
        info = l10n.XCStringsAdapter(l10n.INFOPLIST, "infoplist", with_context=False)
        data = info.load()
        good, bad = payload["units"][0]["id"], payload["units"][1]["id"]
        self.assertEqual(info.value(data["strings"][good], "es", ""), gut)
        self.assertNotEqual(info.value(data["strings"][bad], "es", ""), "%@ zu viel",
                            "ein erfundener Platzhalter kommt nicht durch")
        self.assertEqual(rc, 1, "eine abgelehnte Zeile ist ein Fehlschlag, kein Achselzucken")

    def test_a_pack_splits_into_parts_and_comes_back_from_a_folder(self):
        lang = planned_language()
        rc = l10n.main(["pack", "--lang", lang, "--chunk", "50", "--out", str(self.repo.dir / "packs")])
        self.assertEqual(rc, 0)
        parts = sorted((self.repo.dir / "packs").glob(f"{lang}-*.json"))
        self.assertGreater(len(parts), 1, "grosse Sprachen kommen in Teilen")
        seen = set()
        for index, part in enumerate(parts, start=1):
            payload = json.loads(part.read_text(encoding="utf-8"))
            self.assertEqual(payload["part"], {"index": index, "of": len(parts), "units": len(payload["units"])})
            self.assertLessEqual(len(payload["units"]), 50)
            for unit in payload["units"]:
                self.assertNotIn(unit["id"], seen, "kein Text steht in zwei Teilen")
                seen.add(unit["id"])

    def test_activate_is_the_bookkeeping_without_the_pipeline(self):
        # Wer die Pakete von Hand übersetzt, braucht trotzdem `project.yml` und
        # den Status — sonst baut Xcode die Sprache nicht mit und `doctor` zählt
        # sie ewig als geplant. Scharf geschaltet wird erst, wenn nichts fehlt:
        # eine Sprache in `CFBundleLocalizations` mit Lücken heisst, iOS bietet
        # sie an und zeigt dann Deutsch.
        lang = planned_language()
        self.assertEqual(l10n.main(["activate", lang]), 1, "leer wird nicht scharfgeschaltet")
        project = (self.repo.dir / "project.yml").read_text(encoding="utf-8")
        self.assertEqual(project.count(f"          - {lang}"), 0)

        l10n.main(["sync", "--lang", lang, "--surface", "catalog", "--surface", "infoplist",
                   "--engine", "mock"])
        self.assertEqual(l10n.main(["activate", lang]), 0)
        project = (self.repo.dir / "project.yml").read_text(encoding="utf-8")
        self.assertEqual(project.count(f"          - {lang}"), 2, "beide Targets")
        registry = json.loads((self.repo.dir / "l10n/languages.json").read_text(encoding="utf-8"))
        status = {e["code"]: e["status"] for e in registry["languages"]}
        self.assertEqual(status[lang], "machine")
        self.assertEqual(l10n.main(["activate", lang]), 0, "ein zweiter Lauf ändert nichts")

    def test_add_language_fills_every_surface(self):
        lang = planned_language()
        prefix = f"[{lang}] "
        rc = l10n.main(["add-language", lang, "--engine", "mock"])
        self.assertEqual(rc, 0)
        catalog = l10n.XCStringsAdapter(l10n.CATALOG, "catalog")
        cov = catalog.coverage(lang)
        self.assertEqual(cov["done"], cov["total"])
        self.assertEqual(cov["review"], cov["total"], "maschinelle Texte stehen auf needs_review")
        data = catalog.load()
        plural = data["strings"]["%lld Kisten · %lld Gegenstände"]["localizations"][lang]
        # Die Kategorien kommen aus der Registry, nicht aus dem Test: Japanisch
        # führt nur „other“, Polnisch fünf. Ein festes Paar prüfte nur, dass
        # gerade eine westeuropäische Sprache die erste geplante ist.
        categories = set(l10n.language(lang)["pluralCategories"])
        self.assertEqual(set(plural["substitutions"]["arg1"]["variations"]["plural"]), categories)
        self.assertIn("%#@arg1@", plural["stringUnit"]["value"])
        info = l10n.XCStringsAdapter(l10n.INFOPLIST, "infoplist", with_context=False).coverage(lang)
        self.assertEqual(info["done"], info["total"])
        watch = l10n.XCStringsAdapter(l10n.WATCH, "watch").coverage(lang)
        self.assertEqual(watch["done"], watch["total"])
        project = (self.repo.dir / "project.yml").read_text(encoding="utf-8")
        self.assertEqual(project.count(f"          - {lang}"), 2)
        self.assertEqual(json.load(open(self.repo.dir / "l10n/languages.json", encoding="utf-8"))["languages"] and next(e for e in json.load(open(self.repo.dir / "l10n/languages.json", encoding="utf-8"))["languages"] if e["code"] == lang)["status"], "machine")
        self.assertTrue((self.repo.dir / f"l10n/memory/{lang}.jsonl").exists())
        self.assertTrue((self.repo.dir / f"l10n/reports/{lang}.md").exists())
        # Store: je ASC-Locale eine vollständige Datei — Listing aus store-copy,
        # Release Notes und IAP-Texte aus der Übersetzung.
        store = l10n.StoreAdapter()
        for locale in l10n.language(lang)["ascLocales"]:
            data = store.read(locale)
            self.assertTrue(store.is_complete(data), locale)
            self.assertLessEqual(len(data["keywords"].encode("utf-8")), 100)
            self.assertNotIn(", ", data["keywords"])
            self.assertEqual(data["whatsNew"]["version"], store.source()["whatsNew"]["version"])
            self.assertTrue(data["whatsNew"]["text"].startswith(prefix))
            self.assertEqual(set(data["iap"]["products"]), set(store.product_ids()))
            self.assertTrue(data["iap"]["products"]["ch.sensorstorm.app.pro"]["name"].startswith(prefix))
            self.assertTrue((self.repo.dir / "l10n/aso" / f"{locale}.json").exists())
            self.assertTrue((self.repo.dir / "l10n/reports" / f"store-{locale}.md").exists())
        self.assertEqual(store.coverage(lang), {"done": len(l10n.language(lang)["ascLocales"]), "total": len(l10n.language(lang)["ascLocales"]), "source": l10n.STORE})
        self.assertEqual(l10n.main(["verify", "--lang", lang]), 0)
        self.assertEqual(l10n.main(["doctor"]), 0)

    def test_second_run_uses_memory_only(self):
        l10n.main(["add-language", "es", "--engine", "mock"])
        rows = l10n.collect_rows("es", None)
        self.assertEqual(rows, [], "nach add-language ist nichts mehr offen")
        # Ein neuer Quelltext taucht auf: nur er wird übersetzt.
        catalog = l10n.XCStringsAdapter(l10n.CATALOG, "catalog")
        data = catalog.load()
        data["strings"]["Neuer Text für den Test"] = {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "New text"}}}}
        catalog.save(data)
        report = l10n.translate_language("es", "mock", None, True, 3, log=lambda *a: None)
        self.assertEqual(report.rows, 1)
        self.assertEqual(report.translated, 1)
        self.assertEqual(report.from_memory, 0)
        # Und beim Wiederholen kommt derselbe Text aus dem Gedächtnis.
        data = catalog.load()
        del data["strings"]["Neuer Text für den Test"]["localizations"]["es"]
        catalog.save(data)
        report = l10n.translate_language("es", "mock", None, True, 3, log=lambda *a: None)
        self.assertEqual(report.from_memory, 1)
        self.assertEqual(report.translated, 0)

    def test_catalog_formatting_matches_xcode(self):
        catalog = l10n.XCStringsAdapter(l10n.CATALOG, "catalog")
        before = (self.repo.dir / l10n.CATALOG).read_text(encoding="utf-8")
        catalog.save(catalog.load())
        after = (self.repo.dir / l10n.CATALOG).read_text(encoding="utf-8")
        self.assertEqual(before, after, "Speichern ohne Änderung darf keinen Diff erzeugen")

    def test_import_rejects_broken_rows(self):
        lang = planned_language()
        rows = l10n.collect_rows(lang, ["catalog"])
        target = next(r for r in rows if r.kind == "ui" and "%lld" in r.source)
        jsonl = self.repo.dir / "broken.jsonl"
        jsonl.write_text(json.dumps({"id": target.id, "text": "ohne Platzhalter"}) + "\n", encoding="utf-8")
        rc = l10n.main(["import", "--lang", lang, "--file", str(jsonl)])
        self.assertEqual(rc, 1)
        self.assertIsNone(l10n.XCStringsAdapter(l10n.CATALOG, "catalog").load()["strings"][target.id]["localizations"].get(lang))

    def test_context_index_finds_screens(self):
        self.assertIn("Bezahlschranke", l10n.describe_context(l10n.context_index().get("Freischalten", [])))

    def test_rename_term_moves_keys_translations_and_swift_literals(self):
        catalog = l10n.XCStringsAdapter(l10n.CATALOG, "catalog")
        data = catalog.load()
        data["strings"]["Zügelwagen buchen"] = {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "Book the van"}}}}
        data["strings"]["Zügelwagen: %@"] = {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "Van: %@"}}}}
        catalog.save(data)
        swift = self.repo.dir / "App" / "RootView.swift"
        swift.write_text('Text("Zügelwagen buchen")\nString(localized: "Zügelwagen: %@")\n', encoding="utf-8")
        renames = l10n.rename_term("Zügelwagen", "Umzugswagen")
        self.assertIn(("Zügelwagen buchen", "Umzugswagen buchen"), renames)
        data = catalog.load()["strings"]
        self.assertNotIn("Zügelwagen buchen", data)
        self.assertEqual(data["Umzugswagen buchen"]["localizations"]["en"]["stringUnit"]["value"], "Book the van")
        text = swift.read_text(encoding="utf-8")
        self.assertIn('Text("Umzugswagen buchen")', text)
        self.assertIn('String(localized: "Umzugswagen: %@")', text)
        self.assertNotIn("Zügelwagen", text)
        self.assertEqual(l10n.term_leftovers("Zügelwagen"), [])

    def test_store_copy_is_idempotent_and_protects_what_carries(self):
        # fr-FR hat ein Listing: ohne geänderte Quelle passiert nichts …
        before = l10n.StoreAdapter().read("fr-FR")
        report = l10n.store_copy_locale("fr-FR", "mock", log=lambda *a: None)
        self.assertTrue(report.skipped)
        self.assertEqual(l10n.StoreAdapter().read("fr-FR"), before)
        # … und erzwungen bleiben Name, Untertitel und die heutigen Keywords stehen:
        # unbewertete Maschinenvorschläge verdrängen nichts, was heute trägt.
        report = l10n.store_copy_locale("fr-FR", "mock", force=True, log=lambda *a: None)
        after = l10n.StoreAdapter().read("fr-FR")
        self.assertFalse(report.blocked)
        self.assertEqual(after["name"], before["name"])
        self.assertEqual(after["subtitle"], before["subtitle"])
        self.assertEqual(after["keywords"], before["keywords"])
        self.assertEqual(after["iap"], before["iap"], "die IAP-Texte gehören der Übersetzung, nicht dem Listing")
        aso = l10n.read_aso("fr-FR")
        self.assertTrue(any(c["source"] == "machine" for c in aso["candidates"]), "Kandidaten werden gesammelt")
        self.assertEqual(aso["chosen"], before["keywords"])
        # Ein gemessener Wert entscheidet: der neue Begriff steht dann vor dem alten.
        aso["popularity"] = {"inventaire": 10, "cartons": 90}
        aso["candidates"].append({"term": "cartons", "source": "machine"})
        l10n.write_aso("fr-FR", aso)
        order = [term for term, _, _ in l10n.rank_terms(aso, l10n.split_keywords(before["keywords"]))]
        # Unbewertete Bestandsbegriffe bleiben unantastbar (vor allem Gemessenen),
        # ein gemessener Bestand (10) weicht dem gemessenen Neuling (90).
        self.assertLess(order.index("emballage"), order.index("cartons"))
        self.assertLess(order.index("cartons"), order.index("inventaire"))

    def test_source_locale_keeps_its_text_and_only_packs_keywords(self):
        before = l10n.StoreAdapter().read("de-DE")
        report = l10n.store_copy_locale("de-DE", "mock", force=True, log=lambda *a: None)
        after = l10n.StoreAdapter().read("de-DE")
        self.assertFalse(report.blocked)
        self.assertEqual(after["description"], before["description"])
        self.assertEqual(after["keywords"], before["keywords"])

    def test_pack_keywords_rules(self):
        ranked = [("Umzug", 101, "incumbent"), ("Kisten", 80, "machine"), ("Kiste", 70, "machine"),
                  ("Packliste", 60, "machine"), ("Homeshift", 50, "machine"), ("KistenRadar", 40, "machine"),
                  ("Etikett", 0, "machine"), ("Inventar", 0, "machine")]
        packed, skipped = l10n.pack_keywords(ranked, "Homeshift: Umzugsplaner", "Kisten packen & Inventar", "Latn",
                                             ["KistenRadar"], admit_unvalued=False, budget=100)
        self.assertEqual(packed, "Umzug,Kiste,Packliste")
        reasons = dict(skipped)
        self.assertIn("Kisten", reasons)          # steht im Untertitel
        self.assertIn("Homeshift", reasons)       # Marke
        self.assertIn("KistenRadar", reasons)     # Konkurrenz
        self.assertIn("Etikett", reasons)         # ohne Wert, Bestand vorhanden
        packed, _ = l10n.pack_keywords(ranked, "Homeshift: Umzugsplaner", "Kisten packen & Inventar", "Latn",
                                       ["KistenRadar"], admit_unvalued=True, budget=100)
        self.assertEqual(packed, "Umzug,Kiste,Packliste,Etikett")
        packed, _ = l10n.pack_keywords([("Karton", 5, "machine"), ("Kartons", 5, "machine")], "Homeshift", "", "Latn", [], True)
        self.assertEqual(packed, "Karton", "kein Plural neben dem Singular")
        packed, skipped = l10n.pack_keywords([("Umzugscheckliste", 5, "machine"), ("QR", 5, "machine")], "Homeshift", "", "Latn", [], True, budget=10)
        self.assertEqual(packed, "QR")

    def test_store_verify_rules(self):
        adapter = l10n.StoreAdapter()
        good = adapter.read("en-US")
        self.assertEqual(l10n.errors(adapter.verify_locale("en-US", good)), [])

        def errors_for(**changes):
            data = json.loads(json.dumps(good))
            for key, value in changes.items():
                if key == "whatsNewVersion":
                    data["whatsNew"]["version"] = value
                else:
                    data[key] = value
            return l10n.errors(adapter.verify_locale("en-US", data))

        self.assertTrue(any("Preis" in e for e in errors_for(description=good["description"] + "\nOnly $4.99 a month")))
        self.assertTrue(any("Preis" in e for e in errors_for(promotionalText="Now CHF 5")))
        self.assertTrue(any("Plattform" in e for e in errors_for(description=good["description"] + "\nAlso on Android")))
        self.assertTrue(any("Pflichtlink" in e for e in errors_for(description="Homeshift Cloud only")))
        self.assertTrue(any("Komma" in e for e in errors_for(keywords="packing, list")))
        self.assertTrue(any("doppelt" in e for e in errors_for(keywords="packing,list,Packing")))
        self.assertTrue(any("Plural" in e for e in errors_for(keywords="box,boxes,label")))
        self.assertTrue(any("Untertitel" in e for e in errors_for(keywords="inventory,label")))
        self.assertTrue(any("Homeshift" in e for e in errors_for(name="Moving Planner")))
        self.assertTrue(any("doppelt in Name" in e for e in errors_for(subtitle="Moving boxes and more")))
        self.assertTrue(any("Neu in dieser Version" in e for e in errors_for(whatsNewVersion="0.9")))
        self.assertTrue(any("Zeichen" in e for e in errors_for(subtitle="x" * 31)))
        self.assertTrue(any("Bytes" in e for e in errors_for(keywords="ü" * 51)))
        iap = json.loads(json.dumps(good["iap"]))
        del iap["products"]["ch.homeshift.planning"]
        self.assertTrue(any("ch.homeshift.planning" in e for e in errors_for(iap=iap)))

    def test_brand_lock_accepts_a_declined_name_only_where_the_language_declines(self):
        # Polnisch beugt lateinische Eigennamen: „na iPhonie" ist der Lokativ
        # von iPhone, und die Zeichenfolge „iPhone" steht darin nicht mehr.
        # Ohne diese Ausnahme müsste Polnisch falsch schreiben, um die Sperre
        # zu bestehen. Weggeübersetzt werden darf der Name deswegen nicht.
        beugt = {"code": "pl", "inflectsBrands": True}
        beugt_nicht = {"code": "de"}
        self.assertTrue(l10n._brand_present("iPhone", "na tym iPhonie", beugt))
        self.assertTrue(l10n._brand_present("iPad", "w iPadzie", beugt))
        self.assertTrue(l10n._brand_present("iPhone", "na tym iPhone\u2019a", beugt))
        self.assertFalse(l10n._brand_present("iPhone", "na tym telefonie", beugt))
        self.assertFalse(l10n._brand_present("iPhone", "na tym iPhonie", beugt_nicht))
        # Kurze Marken und solche mit Leerzeichen bleiben auf der strengen Regel:
        # dort wäre ein Stamm nicht mehr von einem beliebigen Wort zu unterscheiden.
        self.assertFalse(l10n._brand_present("QR", "kod kreskowy", beugt))
        self.assertFalse(l10n._brand_present("App Store", "w sklepie", beugt))

    def test_infoplist_source_comes_from_project_yml_so_the_locks_bite(self):
        # Für die Berechtigungstexte gibt es im Katalog keine deutsche Zeile:
        # der Schlüssel ist die Kennung, der Text steht in `project.yml`. Nahm
        # `rows()` den Schlüsselnamen als Quelle, prüfte keine Marken- und keine
        # Platzhaltersperre je einen Systemdialog, und im chinesischen
        # Kameradialog stand „二维码" statt „QR".
        adapter = l10n.adapters()["infoplist"]
        sources = adapter.project_sources()
        self.assertIn("QR", sources["NSCameraUsageDescription"])
        rows = {r.id: r for r in adapter.rows("zh-Hans", only_missing=False)}
        camera = rows["NSCameraUsageDescription"]
        self.assertNotEqual(camera.source, "NSCameraUsageDescription", "der Schlüssel ist kein Quelltext")
        self.assertIn("QR", camera.source)
        entry = l10n.language("zh-Hans")
        gloss = l10n.glossary()
        levels = [lvl for lvl, _ in l10n.check_text(camera, "Homeshift 可以扫描二维码。", entry, gloss)]
        self.assertIn("error", levels, "eine weggeübersetzte harte Marke ist ein Verstoss")

    def test_project_adapter_adds_once(self):
        # Eine Sprache, die noch nicht in `project.yml` steht — sonst prüfte der
        # Test nur, dass ein zweiter Lauf nichts tut, und das ist die Hälfte.
        lang = planned_language()
        adapter = l10n.ProjectAdapter()
        self.assertEqual(adapter.add(lang), 2, "beide Targets")
        self.assertEqual(adapter.add(lang), 0, "ein zweiter Lauf ändert nichts")
        self.assertEqual(adapter.coverage(lang), {"declared": 2, "blocks": 2})
        self.assertEqual(adapter.verify(), [])


if __name__ == "__main__":
    unittest.main()
