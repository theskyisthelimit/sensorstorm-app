import Foundation
import SQLite3
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
        func point(_ offsetNorth: Double, at seconds: Double, accuracy: Double = 5) -> WalkPoint {
            // One degree of latitude is ~111.2 km.
            WalkPoint(time: start.addingTimeInterval(seconds), latitude: 46.9480 + offsetNorth / 111_200,
                       longitude: 7.4474, horizontalAccuracy: accuracy)
        }
        // `#expect` cannot hold a call that mutates a local, so the calls come first.
        let first = survey.appendTrackPoint(point(0, at: 0))
        // 1 m and 3 s later: nothing new.
        let tooClose = survey.appendTrackPoint(point(1, at: 3))
        // 6 m on: a step.
        let step = survey.appendTrackPoint(point(6, at: 6))
        // Standing still for half a minute is worth one point, so a stop shows.
        let stop = survey.appendTrackPoint(point(6.5, at: 40))
        // A poor fix, or none, is not a position.
        let poor = survey.appendTrackPoint(point(50, at: 50, accuracy: 120))
        let none = survey.appendTrackPoint(point(50, at: 51, accuracy: -1))
        // Time going backwards is a glitch.
        let backwards = survey.appendTrackPoint(point(80, at: 10))
        #expect(first && !tooClose && step && stop && !poor && !none && !backwards)
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
            survey.track.append(WalkPoint(time: survey.startedAt.addingTimeInterval(Double(index) * 10),
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
        local.track = [WalkPoint(time: Date(timeIntervalSince1970: 10), latitude: 46.9, longitude: 7.4, horizontalAccuracy: 3)]
        remote.track = local.track + [WalkPoint(time: Date(timeIntervalSince1970: 20), latitude: 46.9001, longitude: 7.4, horizontalAccuracy: 3)]

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

@Suite("Kacheln, GeoPackage, Zip")
struct MapAndPackageTests {

    @Test("Kachelnummern stimmen mit dem Web-Mercator-Schema überein")
    func tileNumbers() {
        #expect(TileMath.tile(latitude: 46.948, longitude: 7.4474, zoom: 10) == MapTile(z: 10, x: 533, y: 360))
        #expect(TileMath.tile(latitude: 46.948, longitude: 7.4474, zoom: 16) == MapTile(z: 16, x: 34123, y: 23064))
        #expect(TileMath.tile(latitude: 0, longitude: 0, zoom: 1) == MapTile(z: 1, x: 1, y: 1))
        // Beyond the poles and the date line the numbers stay on the map.
        #expect(TileMath.tile(latitude: 89, longitude: -181, zoom: 2) == MapTile(z: 2, x: 0, y: 0))
        #expect(TileMath.swisstopoURL(layer: "ch.swisstopo.pixelkarte-farbe", tile: MapTile(z: 16, x: 34123, y: 23064))?
            .absoluteString == "https://wmts.geo.admin.ch/1.0.0/ch.swisstopo.pixelkarte-farbe/default/current/3857/16/34123/23064.jpeg")
    }

    @Test("Der Plan nimmt die tiefsten Stufen weg, bis es unter der Grenze liegt")
    func plan() throws {
        let bounds = try #require(GeoBounds(coordinates: [
            Coordinate2D(latitude: 46.94, longitude: 7.43), Coordinate2D(latitude: 46.96, longitude: 7.46)]))
        let small = TileMath.plan(bounds: bounds, zooms: 12...14, limit: 10_000)
        #expect(small.deepest == 14 && small.tiles.contains { $0.z == 12 } && small.tiles.contains { $0.z == 14 })
        #expect(small.tiles.count == Set(small.tiles).count)
        let capped = TileMath.plan(bounds: bounds, zooms: 12...18, limit: 400)
        #expect(capped.deepest < 18 && capped.tiles.count <= 400 && !capped.tiles.isEmpty)
        // A box inside one tile is that one tile.
        let tiny = try #require(GeoBounds(coordinates: [Coordinate2D(latitude: 46.9480, longitude: 7.4474)]))
        #expect(TileMath.tiles(in: tiny, zoom: 10).count == 1)
    }

    @Test("Das GeoPackage hat die Pflichttabellen, drei Ebenen und lesbare Geometrie")
    func geoPackage() throws {
        var survey = Survey(name: "Paket")
        var item = GroundFinding(location: FindingLocation(latitude: 46.9480, longitude: 7.4474, altitude: 540,
                                                           horizontalAccuracy: 4),
                                 severity: 6, label: "Schlagloch, \"gross\"")
        item.area = .circle(center: Coordinate2D(latitude: 46.9480, longitude: 7.4474), radius: 1)
        item.attributes = ["surface": "asphalt"]
        survey.findings = [item]
        survey.track = [
            WalkPoint(time: Date(timeIntervalSince1970: 0), latitude: 46.9480, longitude: 7.4474, horizontalAccuracy: 3),
            WalkPoint(time: Date(timeIntervalSince1970: 60), latitude: 46.9490, longitude: 7.4480, horizontalAccuracy: 3),
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).gpkg")
        defer { try? FileManager.default.removeItem(at: url) }
        try GeoPackageExporter().write(survey, to: url)

        var db: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func scalar(_ sql: String) -> String {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return "" }
            return String(cString: text)
        }
        #expect(scalar("PRAGMA application_id") == "1196444487")
        #expect(scalar("PRAGMA user_version") == "10300")
        #expect(scalar("SELECT group_concat(table_name) FROM (SELECT table_name FROM gpkg_contents ORDER BY table_name)") == "areas,findings,track")
        #expect(scalar("SELECT group_concat(geometry_type_name) FROM (SELECT geometry_type_name FROM gpkg_geometry_columns ORDER BY table_name)") == "POLYGON,POINT,LINESTRING")
        #expect(scalar("SELECT COUNT(*) FROM gpkg_spatial_ref_sys WHERE srs_id IN (-1, 0, 4326)") == "3")
        #expect(scalar("SELECT label FROM findings") == "Schlagloch, \"gross\"")
        #expect(scalar("SELECT attributes FROM findings") == "{\"surface\":\"asphalt\"}")
        // "GP", version 0, flags 1 (little-endian, no envelope), SRS 4326 = 0x000010E6.
        #expect(scalar("SELECT hex(substr(geom, 1, 8)) FROM findings") == "47500001E6100000")
        // The point's blob: header (8 bytes) + byte order + type 1 + two doubles.
        #expect(scalar("SELECT length(geom) FROM findings") == "29")
        #expect(scalar("SELECT length(geom) FROM track") == "49")
        // Polygon: header + order + type + one ring + points (a closed 48-gon is 49 points).
        #expect(scalar("SELECT length(geom) FROM areas") == "805")
        #expect(abs((Double(scalar("SELECT length_m FROM track")) ?? 0) - survey.trackLength) < 0.01)
    }

    @Test("Ohne Weg und ohne Bereich gibt es nur die Ebene der Befunde")
    func geoPackageMinimal() throws {
        var survey = Survey(name: "Klein")
        survey.findings = [GroundFinding(location: FindingLocation(latitude: 46.9, longitude: 7.4, horizontalAccuracy: 3))]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).gpkg")
        defer { try? FileManager.default.removeItem(at: url) }
        try GeoPackageExporter().write(survey, to: url)
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM gpkg_contents", -1, &statement, nil)
        sqlite3_step(statement)
        #expect(sqlite3_column_int(statement, 0) == 1)
        sqlite3_finalize(statement)
    }
}

@Suite("Arbeitsprofile")
struct WorkProfileTests {

    @Test("Jedes Profil nennt Sensoren, eine Rate aus der Liste und einen vorhandenen Katalog")
    func profilesAreConsistent() {
        let rates: Set<Double> = [10, 25, 50, 100, 200, 400]
        for profile in WorkProfile.allCases {
            #expect(!profile.sensors.isEmpty, "\(profile)")
            #expect(rates.contains(profile.motionRateHz), "\(profile)")
            if let id = profile.catalogID {
                #expect(FindingCatalog.builtIn.contains { $0.id == id }, "\(profile)")
            }
            // A stream the person cannot arm by hand must not be armed by a profile.
            #expect(profile.sensors.isDisjoint(with: SensorID.engineControlled), "\(profile)")
        }
        #expect(WorkProfile.network.recordsNetworkQuality && !WorkProfile.roads.recordsNetworkQuality)
        #expect(WorkProfile.roads.sensors.contains(.verticalAcceleration) && WorkProfile.construction.sensors.contains(.loudnessA))
        #expect(Set(WorkProfile.allCases.map(\.rawValue)).count == WorkProfile.allCases.count)
    }
}

@Suite("Meldung an andere Systeme")
struct RemoteReportTests {

    private func sample() -> (GroundFinding, Survey) {
        var finding = GroundFinding(capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                    location: FindingLocation(latitude: 46.948, longitude: 7.4474, horizontalAccuracy: 3.5),
                                    severity: 7, label: "Schlagloch & Riss", note: "Vor Nr. 12; tief")
        finding.address = PostalAddress(street: "Bahnhofstrasse", houseNumber: "12", postcode: "3011", locality: "Bern", egid: 99, source: "swisstopo")
        finding.attributes = ["surface": "asphalt"]
        finding.measurements = [CaseMeasurement(kind: .depth, value: 5)]
        return (finding, Survey(name: "Quartier", findings: [finding]))
    }

    @Test("Der Webhook trägt Schema, Ort, Zustand und auf Wunsch das Foto")
    func webhook() throws {
        let (finding, survey) = sample()
        let data = RemoteReport.webhookJSON(finding, in: survey, coverPhoto: Data([1, 2, 3]),
                                            now: Date(timeIntervalSince1970: 1_700_000_100))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schema"] as? String == RemoteReport.webhookSchema && object["event"] as? String == "finding")
        let body = try #require(object["finding"] as? [String: Any])
        #expect(body["severity"] as? Int == 7 && body["status"] as? String == "open")
        #expect(body["address"] as? String == "Bahnhofstrasse 12, 3011 Bern" && body["egid"] as? Int == 99)
        #expect((body["attributes"] as? [String: String])?["surface"] == "asphalt")
        #expect(abs((body["latitude"] as? Double ?? 0) - 46.948) < 1e-9)
        #expect((object["photo"] as? [String: Any])?["base64"] as? String == "AQID")
        let plain = RemoteReport.webhookJSON(finding, in: survey)
        #expect((try JSONSerialization.jsonObject(with: plain) as? [String: Any])?["photo"] == nil)
    }

    @Test("Open311: Felder nach GeoReport v2, Formularkodierung ohne Verwechslung der Trenner")
    func open311() throws {
        let (finding, _) = sample()
        let fields = RemoteReport.open311Fields(finding, serviceCode: "pothole", apiKey: "k", jurisdiction: "bern.ch")
        let dictionary = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value) })
        #expect(dictionary["service_code"] == "pothole" && dictionary["jurisdiction_id"] == "bern.ch")
        #expect(dictionary["lat"] == "46.9480000" && dictionary["long"] == "7.4474000")
        #expect(dictionary["description"] == "Schlagloch & Riss\nVor Nr. 12; tief")
        #expect(dictionary["address_string"] == "Bahnhofstrasse 12, 3011 Bern")
        let body = String(decoding: RemoteReport.formBody(fields), as: UTF8.self)
        #expect(body.contains("description=Schlagloch%20%26%20Riss%0AVor%20Nr.%2012%3B%20tief"))
        #expect(!body.contains(" ") && body.split(separator: "&").count == fields.count)

        var bare = GroundFinding(location: FindingLocation(latitude: 1, longitude: 2, horizontalAccuracy: 3), severity: 4)
        bare.label = ""
        #expect(RemoteReport.description(for: bare) == "(4/10)")
    }

    @Test("Die Antwort eines Open311-Servers: Kennung oder Token")
    func open311Response() {
        #expect(RemoteReport.parseOpen311Response(Data(#"[{"service_request_id":"638344"}]"#.utf8)) == "638344")
        #expect(RemoteReport.parseOpen311Response(Data(#"[{"service_request_id":638344}]"#.utf8)) == "638344")
        #expect(RemoteReport.parseOpen311Response(Data(#"[{"token":"abc","service_request_id":""}]"#.utf8)) == "abc")
        #expect(RemoteReport.parseOpen311Response(Data("nonsense".utf8)) == nil)
    }
}
