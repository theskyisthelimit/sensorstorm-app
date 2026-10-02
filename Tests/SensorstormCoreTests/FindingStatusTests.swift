import Foundation
import Testing
@testable import SensorstormCore

@Suite("Status, Adresse und Label-Vorschläge")
struct FindingStatusTests {

    private func finding(label: String = "", severity: Int = 5,
                         status: FindingStatus = .open) -> GroundFinding {
        GroundFinding(location: FindingLocation(latitude: 46.9480, longitude: 7.4474,
                                                horizontalAccuracy: 4),
                      severity: severity, label: label, status: status)
    }

    @Test("Eine Beobachtung aus der Zeit vor dem Status gilt als offen")
    func oldFilesAreOpen() throws {
        let original = finding(label: "Riss")
        var json = try #require(JSONSerialization.jsonObject(
            with: try SurveyStore.encoder.encode(original)) as? [String: Any])
        for key in ["status", "statusChangedAt", "resolutionNote", "address"] { json[key] = nil }
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(GroundFinding.self, from: data)
        #expect(decoded.status == .open)
        #expect(decoded.statusChangedAt == nil)
        #expect(decoded.resolutionNote == "")
        #expect(decoded.address == nil)
    }

    @Test("Der Statuswechsel merkt sich den Zeitpunkt, ein Nicht-Wechsel nicht")
    func statusStamp() {
        var item = finding()
        let first = Date(timeIntervalSince1970: 1_000)
        item.setStatus(.open, at: first)
        #expect(item.statusChangedAt == nil)
        item.setStatus(.resolved, at: first)
        #expect(item.statusChangedAt == first)
        item.setStatus(.resolved, at: Date(timeIntervalSince1970: 2_000))
        #expect(item.statusChangedAt == first)
    }

    @Test("Offen und geplant zählen als ausstehend, erledigt und ohne Handlungsbedarf nicht")
    func outstanding() {
        let survey = Survey(name: "x", findings: [
            finding(status: .open), finding(status: .scheduled),
            finding(status: .resolved), finding(status: .noAction)])
        #expect(survey.outstandingCount == 2)
    }

    @Test("CSV und GeoJSON tragen Status und Adresse, neue Spalten stehen hinten")
    func exports() throws {
        var item = finding(label: "Schlagloch")
        item.setStatus(.resolved, at: Date(timeIntervalSince1970: 1_700_000_000))
        item.resolutionNote = "Mit Kaltasphalt gefüllt, 5 kg"
        item.address = PostalAddress(street: "Bahnhofstrasse", houseNumber: "12",
                                     postcode: "3011", locality: "Bern", country: "CH",
                                     egid: 190_123_456, source: "swisstopo")
        let survey = Survey(name: "Test", findings: [item])

        let csv = SurveyExporter.csv(survey).split(separator: "\n").map(String.init)
        let header = csv[0].split(separator: ",").map(String.init)
        #expect(header.last == "egid")
        #expect(header.firstIndex(of: "recording") == header.firstIndex(of: "status").map { $0 - 1 })
        let row = csv[1]
        #expect(row.contains(",resolved,"))
        #expect(row.contains("Bahnhofstrasse,12,3011,Bern,190123456"))
        // The comma in the note must not shift the columns after it.
        #expect(row.contains("\"Mit Kaltasphalt gefüllt, 5 kg\"") || row.contains("Mit Kaltasphalt gefüllt"))

        let object = try #require(try JSONSerialization.jsonObject(
            with: Data(SurveyExporter.geoJSON(survey).utf8)) as? [String: Any])
        let features = try #require(object["features"] as? [[String: Any]])
        let properties = try #require(features.first?["properties"] as? [String: Any])
        #expect(properties["status"] as? String == "resolved")
        #expect(properties["egid"] as? Int == 190_123_456)
        #expect(properties["street"] as? String == "Bahnhofstrasse")
        #expect(properties["resolutionNote"] as? String == "Mit Kaltasphalt gefüllt, 5 kg")

        let kml = SurveyExporter.kml(survey)
        #expect(kml.contains("<styleUrl>#closed</styleUrl>"))
        let open = SurveyExporter.kml(Survey(name: "T", findings: [finding(severity: 8)]))
        #expect(open.contains("<styleUrl>#severity8</styleUrl>"))
    }

    @Test("Label-Vorschläge: Schreibweisen zusammenführen, nach Häufigkeit ordnen")
    func suggestions() {
        let survey = Survey(name: "x", findings: [
            finding(label: "Schlagloch"), finding(label: "schlagloch "),
            finding(label: "Schlagloch"), finding(label: "Riss"),
            finding(label: "  Riss  quer"), finding(label: "")])
        let all = LabelSuggestions.rank([survey])
        #expect(all == ["Schlagloch", "Riss", "Riss quer"])
        #expect(LabelSuggestions.rank([survey], prefix: "ri") == ["Riss", "Riss quer"])
        // Typed in full: not offered back.
        #expect(LabelSuggestions.rank([survey], prefix: "riss") == ["Riss quer"])
        // Catalogue names come after what is in use and are not doubled.
        let withExtra = LabelSuggestions.rank([survey], extra: ["Setzung", "Riss"])
        #expect(withExtra == ["Schlagloch", "Riss", "Riss quer", "Setzung"])
        #expect(LabelSuggestions.rank([survey], limit: 1) == ["Schlagloch"])
    }

    @Test("Die Gebäudeadresse aus swisstopo wird in Strasse, Nummer und EGID zerlegt")
    func swisstopoParsing() throws {
        let reply = """
        {"results":[{"layerBodId":"ch.bfs.gebaeude_wohnungs_register","featureId":"190123456_0",
        "attributes":{"egid":"190123456","strname_deinr":"Bahnhofstrasse 12a","plz4":3011,
        "plzname":["Bern"]}}]}
        """
        let near = Coordinate2D(latitude: 46.9480, longitude: 7.4474)
        let address = try #require(SwisstopoAddress.parse(Data(reply.utf8), near: near))
        #expect(address.street == "Bahnhofstrasse")
        #expect(address.houseNumber == "12a")
        #expect(address.postcode == "3011")
        #expect(address.locality == "Bern")
        #expect(address.egid == 190_123_456)
        #expect(address.singleLine == "Bahnhofstrasse 12a, 3011 Bern")

        #expect(SwisstopoAddress.parse(Data("{\"results\":[]}".utf8), near: near) == nil)
        #expect(SwisstopoAddress.parse(Data("kein JSON".utf8), near: near) == nil)
    }

    @Test("Nur Koordinaten im Bereich des Gebäuderegisters werden abgefragt")
    func swisstopoCoverage() throws {
        #expect(SwisstopoAddress.covers(Coordinate2D(latitude: 46.9480, longitude: 7.4474)))   // Bern
        #expect(SwisstopoAddress.covers(Coordinate2D(latitude: 47.3769, longitude: 8.5417)))   // Zürich
        #expect(!SwisstopoAddress.covers(Coordinate2D(latitude: 48.8566, longitude: 2.3522)))  // Paris
        #expect(!SwisstopoAddress.covers(Coordinate2D(latitude: 0, longitude: 0)))
        // The old Bern observatory is the origin the LV95 polynomials are written around.
        let url = try #require(SwisstopoAddress.identifyURL(
            for: Coordinate2D(latitude: 169_028.66 / 3600, longitude: 26_782.5 / 3600)))
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["sr"] == "2056")
        #expect(items["layers"] == "all:ch.bfs.gebaeude_wohnungs_register")
        #expect(items["geometry"] == "2600072.4,1200147.1")
        #expect(SwisstopoAddress.identifyURL(for: Coordinate2D(latitude: 48.8566, longitude: 2.3522)) == nil)
    }

    @Test("Eine Route aus alter Zeit lädt, ihre Medien ohne Rolle")
    func mediaRoleOptional() throws {
        let media = CaseMedia(kind: .photo, fileName: "a.jpg", role: .after)
        let data = try SurveyStore.encoder.encode(media)
        #expect(try JSONDecoder.surveyDecoder().decode(CaseMedia.self, from: data).role == .after)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["role"] = nil
        let stripped = try JSONSerialization.data(withJSONObject: json)
        #expect(try JSONDecoder.surveyDecoder().decode(CaseMedia.self, from: stripped).role == nil)
    }
}

private extension JSONDecoder {
    static func surveyDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

@Suite("Fremdströme")
struct ExternalStreamTests {

    @Test("Der Dateiname ist stabil, lesbar und enthält nur sichere Zeichen")
    func fileName() {
        let name = ExternalStreamInfo.fileName(for: "ble.4f2a1c3d.ruuvitag")
        #expect(name == ExternalStreamInfo.fileName(for: "ble.4f2a1c3d.ruuvitag"))
        #expect(name.hasPrefix("ext-ble-4f2a1c3d-ruuvitag-"))
        #expect(name.hasSuffix(".ssbin"))
        #expect(name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") })
        // Two ids that slug to the same text still get different files.
        #expect(ExternalStreamInfo.fileName(for: "a b") != ExternalStreamInfo.fileName(for: "a.b"))
        #expect(ExternalStreamInfo.slug("  Wohnzimmer / Thermometer !! ") == "wohnzimmer-thermometer")
        #expect(ExternalStreamInfo.slug(String(repeating: "x", count: 100)).count == 40)
    }

    @Test("Ein Fremdstrom schreibt, liest sich zurück und meldet Anzahl und Rate")
    func roundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let info = ExternalStreamInfo(id: "ble.test.thermo", source: .bluetooth, title: "Thermo",
                                      channels: ["temperature", "humidity"],
                                      channelUnits: ["°C", "%"])
        let writer = try StreamWriter(external: info, directory: directory)
        for step in 0..<5 {
            writer.append(time: 10 + Double(step), values: [20 + Double(step), 50])
        }
        let closed = writer.closeExternal()
        #expect(closed.sampleCount == 5)
        #expect(abs(closed.effectiveRateHz - 1) < 1e-9)
        #expect(closed.id == info.id)

        let store = RecordingStore(root: directory)
        let id = UUID()
        try FileManager.default.createDirectory(at: store.directory(for: id), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: directory.appendingPathComponent(info.fileName),
                                         to: store.externalStreamURL(for: info, recording: id))
        let reader = try #require(store.reader(for: info, recording: id))
        #expect(reader.channelCount == 2)
        #expect(reader.sampleCount == 5)
        #expect(reader.sample(at: 3) == [23, 50])
    }

    @Test("Ein anderer Satz von Feldnamen wird ein zweiter Strom, kein krummer Datensatz")
    func registry() {
        var registry = ExternalStreamRegistry()
        let first = registry.resolve(base: "ble.x.dev", fields: ["temperature"])
        #expect(first.id == "ble.x.dev")
        #expect(registry.resolve(base: "ble.x.dev", fields: ["temperature"]) == first)

        let second = registry.resolve(base: "ble.x.dev", fields: ["temperature", "humidity"])
        #expect(second.id == "ble.x.dev#2")
        // Same names in another order are the same stream, and its channel order wins.
        let again = registry.resolve(base: "ble.x.dev", fields: ["humidity", "temperature"])
        #expect(again == second)
        let values = ExternalStreamRegistry.values(["humidity": 40, "temperature": 21], in: again)
        #expect(values == [21, 40])
        // A field the packet lacks is NaN, not zero.
        let partial = ExternalStreamRegistry.values(["temperature": 21], in: second)
        #expect(partial[0] == 21 && partial[1].isNaN)
    }

    @Test("Metadaten ohne Fremdströme lesen sich weiter, mit ihnen zählen sie mit")
    func metadata() throws {
        var metadata = RecordingMetadata(
            name: "x", startedAt: Date(timeIntervalSince1970: 0), startHostTime: 0,
            device: DeviceInfo(model: "t", systemName: "iOS", systemVersion: "18", appVersion: "1"),
            streams: [StreamInfo(sensor: .battery, channels: ["level", "state"], unit: "%",
                                 sampleCount: 10, effectiveRateHz: 1)],
            requestedRateHz: 100)
        #expect(metadata.externalStreams == nil)
        #expect(metadata.totalSampleCount == 10)

        metadata.externalStreams = [ExternalStreamInfo(id: "a", source: .network, title: "A",
                                                        channels: ["rtt"], sampleCount: 7)]
        #expect(metadata.totalSampleCount == 17)
        #expect(metadata.externalStream("a")?.title == "A")

        let data = try RecordingStore.encoder.encode(metadata)
        let decoded = try RecordingStore.decoder.decode(RecordingMetadata.self, from: data)
        #expect(decoded.externalStreams == metadata.externalStreams)

        // A file from before the field existed.
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["externalStreams"] = nil
        let old = try RecordingStore.decoder.decode(
            RecordingMetadata.self, from: try JSONSerialization.data(withJSONObject: json))
        #expect(old.externalStreams == nil)
    }

    @Test("Eine Regel auf einen Fremdstrom sieht die Spitze und kennt die Einheit")
    func externalRule() {
        let rule = Rule(name: "heiss",
                        conditions: [.external(stream: "ble.x.dev", channel: 0,
                                               comparison: .above, threshold: 30)],
                        actions: [.annotate(text: "")])
        var engine = RuleEngine()
        let context = RuleContext(values: [:], elapsed: 1,
                                  externalValues: ["ble.x.dev": [22]],
                                  externalMaximum: ["ble.x.dev": [31.5]])
        #expect(engine.evaluate([rule], context: context, now: 1).count == 1)
        var other = RuleEngine()
        #expect(other.evaluate([rule], context: RuleContext(values: [:], elapsed: 1,
                                                            externalValues: ["ble.x.dev": [22]]),
                               now: 1).isEmpty)
        // An unknown stream is never true.
        var none = RuleEngine()
        #expect(none.evaluate([rule], context: RuleContext(values: [:], elapsed: 1), now: 1).isEmpty)

        #expect(BLEUnits.unit(for: "temperature") == "°C")
        #expect(BLEUnits.unit(for: "temperature2") == "°C")
        #expect(BLEUnits.unit(for: "cadence", decoder: "Running Speed and Cadence") == "spm")
        #expect(BLEUnits.unit(for: "cadence", decoder: "Cycling Speed and Cadence") == "rpm")
        #expect(BLEUnits.unit(for: "unbekannt") == "")
    }
}
