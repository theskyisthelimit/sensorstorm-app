import Foundation
import Testing
@testable import SensorstormCore

@Suite("Begehungen und Befunde")
struct SurveyTests {

    // MARK: - Fixture

    /// Bern, roughly. Any anchor does — the point of using a real one is that the LV95
    /// conversion stays inside its validity range.
    static let anchor = Coordinate2D(latitude: 46.9480, longitude: 7.4474)

    private func makeStore() throws -> SurveyStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensorstorm-survey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return SurveyStore(root: root)
    }

    private func makeLocation(_ coordinate: Coordinate2D = SurveyTests.anchor,
                              accuracy: Double = 4) -> FindingLocation {
        FindingLocation(latitude: coordinate.latitude, longitude: coordinate.longitude,
                        altitude: 540, ellipsoidalAltitude: 590,
                        horizontalAccuracy: accuracy, verticalAccuracy: 6, heading: 182)
    }

    private func makeFinding(severity: Int = 7,
                             label: String = "Schlagloch",
                             area: FindingArea? = nil,
                             media: [CaseMedia] = [],
                             offset: TimeInterval = 0) -> GroundFinding {
        GroundFinding(capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + offset),
                      hostTime: 1_000 + offset,
                      location: makeLocation(),
                      severity: severity,
                      label: label,
                      note: "Rand ausgebrochen, 8 cm tief",
                      media: media,
                      area: area)
    }

    /// A point `metres` to the east of the anchor — the only way to write an expected
    /// distance down without doing the trigonometry twice.
    private func point(eastOf origin: Coordinate2D, metres: Double) -> Coordinate2D {
        let moved = Geodesy.geodetic(fromENU: ENU(east: metres, north: 0, up: 0),
                                     anchor: Geodetic(latitude: origin.latitude,
                                                      longitude: origin.longitude, height: 0))
        return Coordinate2D(latitude: moved.latitude, longitude: moved.longitude)
    }

    /// A square with the given edge length, built in the local metric frame so the expected
    /// area is known exactly rather than assumed.
    private func square(edge: Double, at centre: Coordinate2D = SurveyTests.anchor) -> [Coordinate2D] {
        let half = edge / 2
        let anchor = Geodetic(latitude: centre.latitude, longitude: centre.longitude, height: 0)
        return [ENU(east: -half, north: -half, up: 0),
                ENU(east: half, north: -half, up: 0),
                ENU(east: half, north: half, up: 0),
                ENU(east: -half, north: half, up: 0)]
            .map { Geodesy.geodetic(fromENU: $0, anchor: anchor) }
            .map { Coordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    // MARK: - Area

    @Test("Ein Kreis hat die Fläche πr²")
    func circleArea() {
        let area = FindingArea.circle(center: Self.anchor, radius: 4)
        #expect(area.isValid)
        #expect(abs(area.squareMetres - .pi * 16) < 0.001)
    }

    @Test("Ein 10-m-Quadrat misst 100 m², nicht das Cosinus-Vielfache davon")
    func polygonArea() {
        let area = FindingArea.polygon(square(edge: 10))
        #expect(area.isValid)
        // Degrees run through the shoelace formula unprojected would land ~33 % off here.
        #expect(abs(area.squareMetres - 100) < 0.5)
    }

    @Test("Die Umlaufrichtung ändert die Fläche nicht")
    func polygonWindingDoesNotMatter() {
        let clockwise = FindingArea.polygon(Array(square(edge: 10).reversed()))
        #expect(abs(clockwise.squareMetres - 100) < 0.5)
    }

    @Test("Der Ring eines Kreises liegt überall im Radius")
    func circleRing() {
        let radius = 12.0
        let area = FindingArea.circle(center: Self.anchor, radius: radius)
        let ring = area.ring(segments: 32)
        #expect(ring.count == 32)

        let anchor = Geodetic(latitude: Self.anchor.latitude,
                              longitude: Self.anchor.longitude, height: 0)
        for point in ring {
            let local = Geodesy.enu(of: Geodetic(latitude: point.latitude,
                                                 longitude: point.longitude, height: 0),
                                    from: anchor)
            let distance = (local.east * local.east + local.north * local.north).squareRoot()
            #expect(abs(distance - radius) < 0.01)
        }
    }

    @Test("Halbfertige Bereiche gelten nicht als Bereich")
    func invalidAreas() {
        #expect(!FindingArea.polygon([Self.anchor]).isValid)
        #expect(!FindingArea.polygon([Self.anchor, Self.anchor]).isValid)
        #expect(!FindingArea.circle(center: Self.anchor, radius: 0).isValid)
        #expect(FindingArea.polygon(square(edge: 3)).isValid)
        #expect(FindingArea.circle(center: Self.anchor, radius: 1).isValid)
        // Ein ungültiger Bereich hat auch keine Fläche.
        #expect(FindingArea.polygon([Self.anchor]).squareMetres == 0)
    }

    // MARK: - Model

    @Test("Die Bewertung bleibt zwischen 1 und 10")
    func severityIsClamped() throws {
        #expect(GroundFinding(location: makeLocation(), severity: 42).severity == 10)
        #expect(GroundFinding(location: makeLocation(), severity: -3).severity == 1)

        // Auch beim Lesen: eine Datei aus einer anderen Version darf sich öffnen lassen.
        let json = """
        {"id":"\(UUID().uuidString)","capturedAt":"2026-08-28T10:00:00Z","hostTime":12.5,
         "location":{"latitude":46.948,"longitude":7.4474,"horizontalAccuracy":5,
                     "verticalAccuracy":8},
         "severity":97}
        """
        let finding = try SurveyStore.decoder.decode(GroundFinding.self, from: Data(json.utf8))
        #expect(finding.severity == 10)
        #expect(finding.label.isEmpty)
        #expect(finding.area == nil)
    }

    @Test("Eine Position ohne Genauigkeit ist keine Position")
    func locationUsability() {
        #expect(makeLocation(accuracy: 4).isUsable)
        #expect(!makeLocation(accuracy: -1).isUsable)
        #expect(!FindingLocation(latitude: .nan, longitude: 7.4, horizontalAccuracy: 5).isUsable)
        // NaN kommt nie in eine JSON-Datei: fehlende Messwerte sind nil.
        #expect(FindingLocation(latitude: 46.9, longitude: 7.4, altitude: .nan).altitude == nil)
    }

    @Test("Eine Begehung fasst ihre Befunde zusammen")
    func surveySummary() {
        var survey = Survey(name: "Bahnhofstrasse")
        survey.upsert(makeFinding(severity: 3, offset: 20))
        survey.upsert(makeFinding(severity: 9, area: .circle(center: Self.anchor, radius: 2),
                                  offset: 0))

        #expect(survey.worstSeverity == 9)
        #expect(abs((survey.averageSeverity ?? 0) - 6) < 0.001)
        #expect(abs(survey.markedSquareMetres - .pi * 4) < 0.001)
        // In der Reihenfolge, in der sie gelaufen wurden.
        #expect(survey.findingsByTime.first?.severity == 9)
        #expect(survey.bounds != nil)
    }

    @Test("upsert ersetzt, remove entfernt")
    func surveyMutation() {
        var survey = Survey(name: "Test")
        var finding = makeFinding(severity: 4)
        survey.upsert(finding)
        finding.severity = 8
        survey.upsert(finding)

        #expect(survey.findings.count == 1)
        #expect(survey.finding(finding.id)?.severity == 8)
        #expect(survey.remove(finding.id) != nil)
        #expect(survey.findings.isEmpty)
    }

    // MARK: - Store

    @Test("Eine Begehung übersteht Speichern und Laden")
    func storeRoundTrip() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Feste Startzeit: ISO-8601 kennt keine Bruchteile von Sekunden, ein `Date()` käme
        // also gerundet zurück und der Vergleich unten wäre eine Wette auf den Zeitpunkt.
        var survey = Survey(name: "Bahnhofstrasse",
                            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                            notes: "Nach dem Gewitter")
        survey.upsert(makeFinding(area: .polygon(square(edge: 6))))
        try store.save(survey)

        let loaded = try store.load(id: survey.id)
        #expect(loaded == survey)
        #expect(store.allSurveys().count == 1)

        let finding = try #require(loaded.findings.first)
        #expect(finding.area?.kind == .polygon)
        #expect(abs((finding.area?.squareMetres ?? 0) - 36) < 0.5)
    }

    @Test("Mehrere Fotos und Clips gehören zu einem Fall und gehen mit ihm")
    func storeMedia() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        var survey = Survey(name: "Medien")
        var finding = makeFinding()

        let overview = try store.writePhoto(Data(repeating: 0xAB, count: 128), in: survey.id)
        let closeUp = try store.writePhoto(Data(repeating: 0xCD, count: 96), in: survey.id)

        let clipSource = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-\(UUID().uuidString).mov")
        try Data(repeating: 0x01, count: 64).write(to: clipSource)
        let clip = try store.importVideo(from: clipSource, duration: 12, in: survey.id)

        finding.add(overview)
        finding.add(closeUp)
        finding.add(clip)
        survey.upsert(finding)
        try store.save(survey)

        #expect(finding.photos.count == 2)
        #expect(finding.videos.count == 1)
        #expect(finding.coverPhoto == overview)
        #expect(finding.media.count == 3)
        // Jede Datei hat ihren eigenen Namen — zwei Fotos dürfen sich nicht überschreiben.
        #expect(Set(finding.media.map(\.fileName)).count == 3)
        #expect(store.url(for: overview, in: survey.id) != nil)
        #expect(store.url(for: clip, in: survey.id) != nil)
        #expect(clip.duration == 12)
        // Verschoben, nicht kopiert: die temporäre Datei ist weg.
        #expect(!FileManager.default.fileExists(atPath: clipSource.path))

        let loaded = try store.load(id: survey.id)
        #expect(loaded.finding(finding.id)?.media.count == 3)

        store.deleteMedia(of: finding, in: survey.id)
        #expect(store.url(for: overview, in: survey.id) == nil)
        #expect(store.url(for: closeUp, in: survey.id) == nil)
        #expect(store.url(for: clip, in: survey.id) == nil)
    }

    @Test("Eine gesetzte Nadel behält den gemessenen Fix und den Versatz dazu")
    func manualPinKeepsMeasurement() {
        var finding = makeFinding()
        let measured = finding.location
        let moved = point(eastOf: Self.anchor, metres: 12)

        finding.placePin(at: moved)

        #expect(finding.positionSource == .manual)
        #expect(finding.measuredLocation?.coordinate == measured.coordinate)
        #expect(abs((finding.manualOffsetMetres ?? 0) - 12) < 0.05)
        // Eine Nadel hat keine Fehlerangabe — eine zu behaupten wäre eine erfundene Messung.
        #expect(finding.uncertaintyRadius == nil)
        #expect(finding.location.horizontalAccuracy <= 0)
        // Trotzdem gültig: die Position ist bekannt, nur nicht gemessen.
        #expect(finding.location.coordinate.isValid)

        finding.resetPositionToMeasured()
        #expect(finding.positionSource == .gps)
        #expect(finding.measuredLocation == nil)
        #expect(finding.location.coordinate == measured.coordinate)
        #expect(finding.uncertaintyRadius == 4)
    }

    @Test("Der Unsicherheitsradius kommt bei gemittelten Positionen aus der Streuung")
    func uncertaintyRadiusPerSource() {
        var single = makeFinding()
        #expect(single.uncertaintyRadius == 4)

        single.positionSource = .averaged
        single.positionSpread = 1.4
        single.positionSampleCount = 11
        // Die gemessene Streuung schlägt die behauptete Genauigkeit.
        #expect(single.uncertaintyRadius == 1.4)
    }

    @Test("Abstände werden metrisch gerechnet, nicht in Grad")
    func coordinateDistance() {
        let east = point(eastOf: Self.anchor, metres: 25)
        #expect(abs(Self.anchor.distance(to: east) - 25) < 0.05)
        #expect(Self.anchor.distance(to: Self.anchor) == 0)
    }

    @Test("Ein Ordner ohne lesbares survey.json taucht nicht in der Liste auf")
    func storeIgnoresBrokenFolders() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        try store.save(Survey(name: "Gut"))
        let broken = try store.prepareDirectory(for: UUID())
        try Data("kaputt".utf8).write(to: broken.appendingPathComponent(SurveyStore.surveyFileName))

        #expect(store.allSurveys().count == 1)
    }

    // MARK: - Export

    @Test("GeoJSON enthält Punkt und Fläche, Länge vor Breite")
    func geoJSONShape() throws {
        var survey = Survey(name: "Export")
        survey.upsert(makeFinding(area: .circle(center: Self.anchor, radius: 3)))
        survey.upsert(makeFinding(severity: 2, label: "Riss", offset: 30))

        let text = SurveyExporter.geoJSON(survey)
        let object = try #require(try JSONSerialization.jsonObject(
            with: Data(text.utf8)) as? [String: Any])
        #expect(object["type"] as? String == "FeatureCollection")

        let features = try #require(object["features"] as? [[String: Any]])
        // Zwei Befunde, einer davon mit Bereich.
        #expect(features.count == 3)

        let point = try #require(features.first { feature in
            (feature["properties"] as? [String: Any])?["kind"] as? String == "case"
        })
        let geometry = try #require(point["geometry"] as? [String: Any])
        let coordinates = try #require(geometry["coordinates"] as? [Double])
        #expect(abs(coordinates[0] - Self.anchor.longitude) < 1e-9)
        #expect(abs(coordinates[1] - Self.anchor.latitude) < 1e-9)

        let properties = try #require(point["properties"] as? [String: Any])
        #expect(properties["severity"] as? Int != nil)
        #expect(properties["lv95East"] as? Double != nil)
        // Ohne die Genauigkeit ist die Koordinate nicht überprüfbar.
        #expect(properties["horizontalAccuracy"] as? Double == 4)
        #expect(properties["positionSource"] as? String == "gps")

        let area = try #require(features.first { feature in
            (feature["properties"] as? [String: Any])?["kind"] as? String == "area"
        })
        let ring = try #require((area["geometry"] as? [String: Any])?["coordinates"]
                                as? [[[Double]]])
        // Ein GeoJSON-Ring ist geschlossen.
        #expect(ring[0].count > 8)
        #expect(ring[0].first ?? [] == ring[0].last ?? [])
    }

    @Test("CSV hat eine Kopfzeile, eine Zeile pro Befund und maskierte Notizen")
    func csvShape() throws {
        var survey = Survey(name: "Export")
        var finding = makeFinding()
        finding.note = "Riss, quer zur Fahrbahn"
        survey.upsert(finding)

        let lines = SurveyExporter.csv(survey).split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("id,time,latitude,longitude"))
        #expect(lines[0].contains("positionSource,positionSpread,positionSampleCount"))
        #expect(lines[0].contains("manualOffset"))
        // Das Komma in der Notiz darf die Spalten nicht verschieben.
        #expect(lines[1].contains("\"Riss, quer zur Fahrbahn\""))
        #expect(lines[1].contains("Schlagloch"))
    }

    @Test("GPX und KML tragen die Koordinaten, KML zusätzlich die Fläche")
    func trackFormats() {
        var survey = Survey(name: "Export")
        survey.upsert(makeFinding(area: .polygon(square(edge: 5))))

        let gpx = SurveyExporter.gpx(survey)
        #expect(gpx.contains("<wpt lat=\"46.948\""))
        #expect(gpx.contains("7/10 Schlagloch"))

        let kml = SurveyExporter.kml(survey)
        #expect(kml.contains("<Polygon>"))
        #expect(kml.contains("#severity7"))
        // aabbggrr, und Rot wächst mit der Bewertung.
        #expect(SurveyExporter.kmlColour(forSeverity: 1) != SurveyExporter.kmlColour(forSeverity: 10))
        #expect(SurveyExporter.kmlColour(forSeverity: 10).count == 8)
    }

    @Test("Das Bündel enthält alle Formate und die Fotos")
    func bundleExport() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        var survey = Survey(name: "Bahnhofstrasse")
        var finding = makeFinding()
        finding.add(try store.writePhoto(Data(repeating: 0xCD, count: 256), in: survey.id))
        survey.upsert(finding)
        try store.save(survey)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("survey-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        let zip = try SurveyExporter(store: store).export(survey, format: .bundle,
                                                          into: destination)
        #expect(zip.lastPathComponent == "Bahnhofstrasse.zip")
        #expect((try Data(contentsOf: zip)).count > 0)

        let geojson = try SurveyExporter(store: store).export(survey, format: .geoJSON,
                                                              into: destination)
        #expect(geojson.pathExtension == "geojson")
        let text = try String(contentsOf: geojson, encoding: .utf8)
        #expect(text.contains("FeatureCollection"))
    }

    @Test("Im Bündel zeigen die Medienverweise in den Medienordner")
    func bundleMediaPrefix() {
        var survey = Survey(name: "Export")
        var finding = makeFinding()
        let photo = CaseMedia(kind: .photo, fileName: "abc.jpg")
        let clip = CaseMedia(kind: .video, fileName: "def.mov")
        finding.add(photo)
        finding.add(clip)
        survey.upsert(finding)

        let text = SurveyExporter.geoJSON(survey, mediaPrefix: "media/")
        #expect(text.contains("media/abc.jpg"))
        #expect(text.contains("media/def.mov"))

        let csv = SurveyExporter.csv(survey, mediaPrefix: "media/")
        #expect(csv.contains("media/abc.jpg"))
        #expect(csv.contains("media/def.mov"))
    }

    @Test("Der Export trägt Quelle, Streuung und Versatz der Position")
    func positionQualityInExport() throws {
        var survey = Survey(name: "Export")
        var finding = makeFinding()
        finding.positionSource = .averaged
        finding.positionSampleCount = 14
        finding.positionSpread = 1.8
        finding.placePin(at: point(eastOf: Self.anchor, metres: 9))
        survey.upsert(finding)

        let text = SurveyExporter.geoJSON(survey)
        let object = try #require(try JSONSerialization.jsonObject(
            with: Data(text.utf8)) as? [String: Any])
        let features = try #require(object["features"] as? [[String: Any]])
        let properties = try #require(features.first?["properties"] as? [String: Any])

        #expect(properties["positionSource"] as? String == "manual")
        #expect(properties["gpsLatitude"] as? Double == Self.anchor.latitude)
        let offset = try #require(properties["manualOffsetMetres"] as? Double)
        #expect(abs(offset - 9) < 0.05)
        // Eine Nadel hat keine Genauigkeitsangabe, und es wird auch keine erfunden.
        #expect(properties["horizontalAccuracy"] == nil)

        let csv = SurveyExporter.csv(survey)
        #expect(csv.contains("manual"))
        #expect(SurveyExporter.positionDescription(of: finding).contains("Nadel"))
    }
}
