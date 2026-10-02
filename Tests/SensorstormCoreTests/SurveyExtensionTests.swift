import Foundation
import Testing
@testable import SensorstormCore

private func location(_ latitude: Double = 46.9480, _ longitude: Double = 7.4474) -> FindingLocation {
    FindingLocation(latitude: latitude, longitude: longitude, altitude: 540, horizontalAccuracy: 4)
}

private func finding(_ label: String = "Schlagloch", severity: Int = 5, status: FindingStatus = .open,
                     at date: Date = Date(timeIntervalSince1970: 1_700_000_000),
                     origin: UUID? = nil) -> GroundFinding {
    GroundFinding(capturedAt: date, location: location(), severity: severity, label: label,
                  status: status, originID: origin)
}

@Suite("Route: Weg, Messwerte, Attribute")
struct SurveyTrackTests {

    @Test("Der Weg nimmt nur Punkte auf, die etwas hinzufügen")
    func trackRules() {
        var survey = Survey(name: "Weg")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func point(_ offsetNorth: Double, at seconds: Double, accuracy: Double = 5) -> TrackPoint {
            // One degree of latitude is ~111.2 km.
            TrackPoint(time: start.addingTimeInterval(seconds), latitude: 46.9480 + offsetNorth / 111_200,
                       longitude: 7.4474, horizontalAccuracy: accuracy)
        }
        #expect(survey.appendTrackPoint(point(0, at: 0)))
        // 1 m and 3 s later: nothing new.
        #expect(!survey.appendTrackPoint(point(1, at: 3)))
        // 6 m on: a step.
        #expect(survey.appendTrackPoint(point(6, at: 6)))
        // Standing still for half a minute is worth one point, so a stop shows.
        #expect(survey.appendTrackPoint(point(6.5, at: 40)))
        // A poor fix, or none, is not a position.
        #expect(!survey.appendTrackPoint(point(50, at: 50, accuracy: 120)))
        #expect(!survey.appendTrackPoint(point(50, at: 51, accuracy: -1)))
        // Time going backwards is a glitch.
        #expect(!survey.appendTrackPoint(point(80, at: 10)))
        #expect(survey.track.count == 3)
        #expect(abs(survey.trackLength - 6.5) < 0.2)
        #expect(survey.trackDuration == 40)
        #expect(survey.bounds != nil)
    }

    @Test("Eine Route aus alter Zeit lädt ohne Weg, Messwerte und Attribute")
    func legacyJSON() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Alt","startedAt":"2026-05-01T08:00:00Z","notes":"","findings":[
         {"id":"\(UUID().uuidString)","capturedAt":"2026-05-01T08:05:00Z","location":{"latitude":46.9,"longitude":7.4,
          "horizontalAccuracy":3,"verticalAccuracy":-1},"severity":4}]}
        """
        let survey = try JSONDecoder.surveyDecoder.decode(Survey.self, from: Data(json.utf8))
        #expect(survey.track.isEmpty && survey.endedAt == nil && survey.catalogID == nil && survey.isOpen)
        let item = try #require(survey.findings.first)
        #expect(item.attributes.isEmpty && item.measurements.isEmpty && item.originID == nil)
    }

    @Test("Neigung in Grad und Prozent, Volumen aus Fläche mal Tiefe")
    func measurements() {
        #expect(abs(CaseMeasurement.percent(fromDegrees: 45) - 100) < 1e-9)
        #expect(abs(CaseMeasurement.degrees(fromPercent: 100) - 45) < 1e-9)
        var item = finding()
        #expect(item.volumeCubicMetres == nil)
        item.area = .circle(center: location().coordinate, radius: 0.5)
        #expect(item.volumeCubicMetres == nil)
        item.measurements = [
            CaseMeasurement(kind: .depth, value: 4, measuredAt: Date(timeIntervalSince1970: 10)),
            CaseMeasurement(kind: .depth, value: 6, measuredAt: Date(timeIntervalSince1970: 20)),
        ]
        // The newer depth counts: π · 0.25 m² · 0.06 m.
        #expect(abs((item.volumeCubicMetres ?? 0) - Double.pi * 0.25 * 0.06) < 1e-9)
        #expect(item.measurement(.slope) == nil)
    }

    @Test("Weg und Attribute stehen in GeoJSON, GPX, KML und CSV")
    func exportsCarryTheTrack() throws {
        var survey = Survey(name: "Mit Weg", startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        for index in 0..<3 {
            survey.track.append(TrackPoint(time: survey.startedAt.addingTimeInterval(Double(index) * 10),
                                           latitude: 46.9480 + Double(index) * 0.0001, longitude: 7.4474,
                                           horizontalAccuracy: 4))
        }
        var item = finding()
        item.attributes = ["surface": "asphalt", "_entry": "pothole"]
        item.measurements = [CaseMeasurement(kind: .slope, value: 3.5)]
        survey.findings = [item]

        let geoJSON = SurveyExporter.geoJSON(survey)
        #expect(geoJSON.contains("\"LineString\"") && geoJSON.contains("\"lengthMetres\""))
        #expect(geoJSON.contains("\"surface\"") && geoJSON.contains("\"slope\""))
        #expect(SurveyExporter.gpx(survey).contains("<trkseg>"))
        #expect(SurveyExporter.kml(survey).contains("<LineString>"))

        let lines = SurveyExporter.csv(survey).split(separator: "\n").map(String.init)
        #expect(lines[0].hasSuffix("attributes,slopeDegrees,depthCentimetres,volumeCubicMetres,origin"))
        #expect(lines[1].contains("_entry=pothole;surface=asphalt") || lines[1].contains("\"_entry=pothole;surface=asphalt\""))
        // Every row has as many fields as the header: the new columns did not shift anything.
        func fields(_ line: String) -> Int {
            var count = 1, quoted = false
            for character in line {
                if character == "\"" { quoted.toggle() }
                if character == ",", !quoted { count += 1 }
            }
            return count
        }
        #expect(fields(lines[1]) == fields(lines[0]))

        // A route without a walked path writes none of it.
        survey.track = []
        #expect(!SurveyExporter.gpx(survey).contains("<trk>"))
        #expect(!SurveyExporter.geoJSON(survey).contains("LineString"))
    }
}

@Suite("Kataloge")
struct CatalogTests {

    @Test("Ein Text darf eine Zeichenkette oder nach Sprachen geordnet sein")
    func localizedText() throws {
        let decoder = JSONDecoder()
        let plain = try decoder.decode(LocalizedText.self, from: Data("\"Schlagloch\"".utf8))
        #expect(plain.resolve("de-CH") == "Schlagloch" && plain.resolve("fr") == "Schlagloch")
        let multi = try decoder.decode(LocalizedText.self, from: Data("{\"de\":\"Riss\",\"en\":\"Crack\"}".utf8))
        #expect(multi.resolve("en-GB") == "Crack" && multi.resolve("de") == "Riss")
        // A language without a translation gets English, not German.
        #expect(multi.resolve("ja") == "Crack")
    }

    @Test("Die mitgelieferten Kataloge sind gültig und haben stabile Schlüssel")
    func builtIn() throws {
        #expect(FindingCatalog.builtIn.count == 4)
        for catalog in FindingCatalog.builtIn {
            try catalog.validate()
            let round = try FindingCatalog.decode(try catalog.encoded())
            #expect(round == catalog)
        }
        let pothole = try #require(FindingCatalog.road.entry("pothole"))
        #expect(pothole.defaultSeverity == 7 && pothole.label.resolve("en") == "Pothole")
    }

    @Test("Ein Katalog mit Fehlern wird ganz abgelehnt")
    func validation() {
        func decode(_ json: String) -> FindingCatalog.CatalogError? {
            do { _ = try FindingCatalog.decode(Data(json.utf8)); return nil }
            catch let error as FindingCatalog.CatalogError { return error }
            catch { return .notReadable }
        }
        #expect(decode("{\"id\":\"x\",\"name\":\"X\",\"entries\":[]}") == .empty)
        #expect(decode("nonsense") == .notReadable)
        #expect(decode("{\"id\":\"x\",\"name\":\"X\",\"entries\":[{\"key\":\"a\",\"label\":\"A\"},{\"key\":\"a\",\"label\":\"B\"}]}")
                == .duplicateKey("a"))
        #expect(decode("{\"id\":\"x\",\"name\":\"X\",\"entries\":[{\"key\":\"a\",\"label\":\"A\",\"defaultSeverity\":11}]}")
                == .severityOutOfRange("a"))
        #expect(decode("{\"id\":\"x\",\"name\":\"X\",\"entries\":[{\"key\":\"a\",\"label\":\"A\",\"attributes\":[{\"key\":\"c\",\"title\":\"C\",\"kind\":\"choice\"}]}]}")
                == .choiceWithoutOptions("a.c"))
        #expect(decode("{\"id\":\"x\",\"name\":\"X\",\"entries\":[{\"key\":\"a\",\"label\":\"A\"}]}") == nil)
    }

    @Test("Antworten werden mit den Wörtern der Sprache beschrieben")
    func describing() {
        let lines = FindingCatalog.road.describe(["surface": "asphalt", "position": "edge"],
                                                 entryKey: "pothole", language: "de")
        #expect(lines.map(\.title) == ["Belag", "Lage"])
        #expect(lines.map(\.value) == ["Asphalt", "Rand"])
        let crack = FindingCatalog.road.describe(["width": "4"], entryKey: "crack", language: "en")
        #expect(crack.first?.value == "4 mm")
        #expect(FindingCatalog.road.describe(["a": "b"], entryKey: nil, language: "de").isEmpty)
    }
}

@Suite("Wiederholung und Zusammenführen")
struct SurveyHistoryTests {

    @Test("Eine Wiederholung übernimmt die offenen Fälle ohne Fotos")
    func repeating() {
        var old = Survey(name: "Frühling")
        old.findings = [finding("A", severity: 6), finding("B", status: .resolved), finding("C", status: .scheduled)]
        old.findings[0].media = [CaseMedia(kind: .photo, fileName: "a.jpg")]
        old.findings[0].note = "alt"
        let next = FindingHistory.repeating(old, name: "Herbst")
        #expect(next.repeatsSurveyID == old.id && next.findings.count == 2)
        #expect(next.findings.allSatisfy { $0.status == .open && $0.media.isEmpty && $0.note.isEmpty })
        #expect(next.findings.map(\.label).sorted() == ["A", "C"])
        #expect(next.findings.first { $0.label == "A" }?.originID == old.findings[0].id)
        #expect(FindingHistory.repeating(old, name: "Alles", includeResolved: true).findings.count == 3)
    }

    @Test("Der Verlauf eines Falls über drei Begehungen")
    func chain() {
        var first = Survey(name: "1", startedAt: Date(timeIntervalSince1970: 100))
        first.findings = [finding("A", severity: 4, at: Date(timeIntervalSince1970: 100))]
        let second = FindingHistory.repeating(first, name: "2", now: Date(timeIntervalSince1970: 200))
        var third = FindingHistory.repeating(second, name: "3", now: Date(timeIntervalSince1970: 300))
        third.findings[0].severity = 8
        let entries = FindingHistory.chain(for: third.findings[0], in: [third, first, second])
        #expect(entries.map(\.surveyName) == ["1", "2", "3"])
        #expect(entries.map(\.severity) == [4, 4, 8])
        // The chain is found from any of its members.
        #expect(FindingHistory.chain(for: first.findings[0], in: [first, second, third]).count == 3)
    }

    @Test("Vergleich: neu, erledigt, schlimmer, besser, gleich, noch nicht geprüft")
    func comparison() {
        var old = Survey(name: "alt")
        old.findings = (0..<5).map { finding("F\($0)", severity: 5, at: Date(timeIntervalSince1970: 1_000 + Double($0))) }
        var new = FindingHistory.repeating(old, name: "neu")
        // F0 resolved, F1 worse, F2 better, F3 unchanged, F4 not visited again.
        new.findings.removeAll { $0.label == "F4" }
        new.findings[0].setStatus(.resolved)
        new.findings[1].severity = 8
        new.findings[2].severity = 3
        new.findings.append(finding("Neu", severity: 6))
        let comparison = FindingHistory.compare(older: old, newer: new)
        #expect(comparison == FindingHistory.Comparison(new: 1, resolved: 1, worse: 1, better: 1,
                                                        unchanged: 1, notYetChecked: 1))
    }

    @Test("Zusammenführen: der Neuere gewinnt, Medien und Weg vereinigen sich")
    func merge() {
        let shared = finding("Geteilt", severity: 4, at: Date(timeIntervalSince1970: 1_000))
        var local = Survey(name: "Meine")
        var remote = local
        var mine = shared
        mine.media = [CaseMedia(kind: .photo, fileName: "mine.jpg")]
        local.findings = [mine]
        var theirs = shared
        theirs.severity = 9
        theirs.setStatus(.resolved, at: Date(timeIntervalSince1970: 5_000))
        theirs.media = [CaseMedia(kind: .photo, fileName: "theirs.jpg")]
        remote.findings = [theirs, finding("Nur dort", at: Date(timeIntervalSince1970: 2_000))]
        local.track = [TrackPoint(time: Date(timeIntervalSince1970: 10), latitude: 46.9, longitude: 7.4, horizontalAccuracy: 3)]
        remote.track = local.track + [TrackPoint(time: Date(timeIntervalSince1970: 20), latitude: 46.9001, longitude: 7.4, horizontalAccuracy: 3)]

        let result = SurveyMerge.merge(local: local, remote: remote)
        #expect(result.report == SurveyMerge.Report(added: 1, updated: 1, kept: 0, trackPointsAdded: 1))
        let merged = result.survey.findings.first { $0.id == shared.id }
        #expect(merged?.severity == 9 && merged?.status == .resolved)
        #expect(Set(merged?.media.map(\.fileName) ?? []) == ["mine.jpg", "theirs.jpg"])
        #expect(result.survey.findings.count == 2 && result.survey.track.count == 2)

        // Merging the result again changes nothing.
        let again = SurveyMerge.merge(local: result.survey, remote: remote)
        #expect(!again.report.changedAnything && again.report.kept == 2)
    }

    @Test("Mehrere Routen zu einer")
    func combine() {
        var a = Survey(name: "A", startedAt: Date(timeIntervalSince1970: 500))
        var b = Survey(name: "B", startedAt: Date(timeIntervalSince1970: 100))
        a.findings = [finding("A1", at: Date(timeIntervalSince1970: 600))]
        b.findings = [finding("B1", at: Date(timeIntervalSince1970: 200))]
        a.endedAt = Date(timeIntervalSince1970: 900)
        let combined = SurveyMerge.combine([a, b], name: "Alle")
        #expect(combined.startedAt == b.startedAt && combined.endedAt == a.endedAt)
        #expect(combined.findings.map(\.label) == ["B1", "A1"])
    }
}

private extension JSONDecoder {
    static var surveyDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
