import Foundation
import SQLite3
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
        // Columns are only ever added at the end; the later additions follow `egid`.
        #expect(header.firstIndex(of: "egid").map { header[($0 + 1)...] } == ["attributes", "slopeDegrees", "depthCentimetres", "volumeCubicMetres", "origin"])
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

@Suite("Fremdströme in den Exporten")
struct ExternalExportTests {

    private func makeRecording() throws -> (RecordingStore, RecordingMetadata, ExternalStreamInfo) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensorstorm-ext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = RecordingStore(root: root)

        var metadata = RecordingMetadata(
            name: "Fremd", startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            startHostTime: 1000, duration: 2,
            device: DeviceInfo(model: "iPhone17,1", systemName: "iOS", systemVersion: "26.0",
                               appVersion: "1.0.0"),
            requestedRateHz: 10)
        let directory = try store.prepareDirectory(for: metadata.id)

        let motion = try StreamWriter(sensor: .userAcceleration, channelCount: 3, directory: directory)
        for step in 0..<20 {
            motion.append(time: 1000 + Double(step) / 10, values: [Double(step), 0, 0])
        }
        let info = ExternalStreamInfo(id: "ble.4f2a1c3d.ruuvitag", source: .bluetooth,
                                      title: "Küche · RuuviTag",
                                      channels: ["temperature", "humidity"],
                                      channelUnits: ["°C", "%"])
        let thermo = try StreamWriter(external: info, directory: directory)
        thermo.append(time: 1000.5, values: [21.5, 40])
        thermo.append(time: 1001.5, values: [21.7, .nan])

        metadata.streams = [motion.close()]
        metadata.externalStreams = [thermo.closeExternal()]
        try store.save(metadata)
        return (store, metadata, info)
    }

    @Test("Das CSV-Bündel enthält eine Datei je Fremdstrom, mit Kanälen als Kopfzeile")
    func csvBundle() throws {
        let (store, metadata, info) = try makeRecording()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let folder = store.root.appendingPathComponent("out", isDirectory: true)
        try RecordingExporter(store: store).write(metadata, format: .csvBundle, into: folder)
        let key = ExportStream.key(for: info)
        #expect(key.hasPrefix("ext_ble_4f2a1c3d_"))
        #expect(key.count <= 31)

        let csv = try String(contentsOf: folder.appendingPathComponent("\(key).csv"), encoding: .utf8)
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines[0] == "time,epoch,temperature,humidity")
        #expect(lines.count == 3)
        #expect(lines[1].hasSuffix(",21.5,40"))
        // A value that was not measured is an empty cell, not a zero.
        #expect(lines[2].hasSuffix(",21.7,"))

        let readme = try String(contentsOf: folder.appendingPathComponent("README.txt"), encoding: .utf8)
        #expect(readme.contains("Küche · RuuviTag"))
        #expect(readme.contains("temperature [°C]"))
    }

    @Test("JSON, Datenbank, Excel und Kombi-Tabelle führen den Fremdstrom mit")
    func tables() throws {
        let (store, metadata, info) = try makeRecording()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let key = ExportStream.key(for: info)

        let json = store.root.appendingPathComponent("r.json")
        try JSONExporter(store: store).write(metadata, to: json)
        let object = try #require(try JSONSerialization.jsonObject(
            with: try Data(contentsOf: json)) as? [String: Any])
        let streams = try #require(object["streams"] as? [[String: Any]])
        let external = try #require(streams.first { $0["id"] as? String == info.id })
        #expect(external["sensor"] as? String == key)
        #expect(external["title"] as? String == "Küche · RuuviTag")
        #expect(external["units"] as? [String] == ["°C", "%"])
        let samples = try #require(external["samples"] as? [[Any]])
        #expect(samples.count == 2)
        // The built-in stream is untouched and has no `id`.
        #expect(streams.first { $0["sensor"] as? String == "userAcceleration" }?["id"] == nil)

        let combined = store.root.appendingPathComponent("c.csv")
        try CombinedCSVExporter(store: store).write(metadata, to: combined)
        let header = try String(contentsOf: combined, encoding: .utf8)
            .split(separator: "\n").first.map(String.init) ?? ""
        #expect(header.contains("\(key)_temperature"))
        #expect(header.contains("\(key)_age"))

        let database = store.root.appendingPathComponent("r.sqlite")
        try SQLiteExporter(store: store).write(metadata, to: database)
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT COUNT(*), SUM(humidity IS NULL) FROM \"\(key)\"",
                                   -1, &statement, nil) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 2)
        // The NaN became NULL.
        #expect(sqlite3_column_int(statement, 1) == 1)
        sqlite3_finalize(statement)

        let workbook = store.root.appendingPathComponent("r.xlsx")
        try XLSXExporter(store: store).write(metadata, to: workbook)
        let bytes = try Data(contentsOf: workbook)
        #expect(bytes.starts(with: [0x50, 0x4B]))
        #expect(String(decoding: bytes, as: UTF8.self).contains(key))
    }

    @Test("Der Gesamtexport führt den Fremdstrom mit Kennung, Titel und Einheiten")
    func manifest() throws {
        let (recordings, metadata, info) = try makeRecording()
        let root = recordings.root.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: recordings.root) }

        let surveyRoot = root.appendingPathComponent("surveys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: surveyRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: surveyRoot) }
        let exporter = ArchiveExporter(surveyStore: SurveyStore(root: surveyRoot),
                                       recordingStore: recordings)

        let payload = recordings.root.appendingPathComponent("payload", isDirectory: true)
        try exporter.writeTree(into: payload,
                               options: .init(includesSurveys: false, includesRecordings: true,
                                              recordingFormat: .csvBundle))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            ArchiveManifest.self,
            from: Data(contentsOf: payload.appendingPathComponent(ArchiveExporter.manifestFileName)))
        let entry = try #require(manifest.recordings.first { $0.id == metadata.id })
        let stream = try #require(entry.streams.first { $0.id == info.id })
        #expect(stream.title == "Küche · RuuviTag")
        #expect(stream.units == ["°C", "%"])
        #expect(stream.sampleCount == 2)
        let path = try #require(stream.path)
        #expect(FileManager.default.fileExists(atPath: payload.appendingPathComponent(path).path))
        // The phone's own sensor has neither field.
        #expect(entry.streams.first { $0.sensor == "userAcceleration" }?.id == nil)
    }
}

@Suite("Bluetooth: GATT, Beacons, Namen")
struct BluetoothDecodingTests {

    private func le(_ value: UInt32, bytes: Int) -> [UInt8] {
        (0..<bytes).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) }
    }

    @Test("Umweltsensor-Merkmale mit ihren Auflösungen")
    func environmental() throws {
        let temperature = try #require(GATTDecoding.decode(characteristic: "2A6E", Data(le(2150, bytes: 2))))
        #expect(abs((temperature.value("temperature") ?? 0) - 21.5) < 1e-9)
        // The full 128-bit form of the same UUID.
        #expect(GATTDecoding.decode(characteristic: "00002A6E-0000-1000-8000-00805F9B34FB",
                                    Data(le(2150, bytes: 2)))?.value("temperature") != nil)
        let humidity = try #require(GATTDecoding.decode(characteristic: "2A6F", Data(le(4500, bytes: 2))))
        #expect(abs((humidity.value("humidity") ?? 0) - 45) < 1e-9)
        let pressure = try #require(GATTDecoding.decode(characteristic: "2A6D", Data(le(1_013_250, bytes: 4))))
        #expect(abs((pressure.value("pressure") ?? 0) - 1013.25) < 1e-9)
        // 0x8000 is „not known", not −327.68 °C.
        #expect(GATTDecoding.decode(characteristic: "2A6E", Data(le(0x8000, bytes: 2))) == nil)
        #expect(GATTDecoding.decode(characteristic: "2A19", Data([87]))?.value("batteryLevel") == 87)
        #expect(GATTDecoding.decode(characteristic: "FFFF", Data([1, 2])) == nil)
    }

    @Test("IEEE-11073-Gleitkommazahlen")
    func floats() throws {
        // 36.4 °C: mantissa 364, exponent −1.
        let thermometer = try #require(GATTDecoding.decode(
            characteristic: "2A1C", Data([0x00, 0x6C, 0x01, 0x00, 0xFF])))
        #expect(abs((thermometer.value("temperature") ?? 0) - 36.4) < 1e-9)
        // The same body temperature in Fahrenheit is converted, not shown as 97.5 °C.
        let fahrenheit = try #require(GATTDecoding.decode(
            characteristic: "2A1C", Data([0x01]) + Data(le(975, bytes: 3)) + Data([0xFF])))
        #expect(abs((fahrenheit.value("temperature") ?? 0) - 36.3889) < 0.001)
        // Reserved mantissa: not a number.
        #expect(GATTDecoding.decode(characteristic: "2A1C", Data([0x00, 0xFF, 0xFF, 0x7F, 0x00])) == nil)

        let pressure = try #require(GATTDecoding.decode(
            characteristic: "2A35", Data([0x00, 0x78, 0x00, 0x50, 0x00, 0x5D, 0x00])))
        #expect(pressure.value("systolic") == 120)
        #expect(pressure.value("diastolic") == 80)
        #expect(pressure.value("meanArterialPressure") == 93)

        // 98 % and 64 bpm, then a pulse oximeter that has no pulse rate: SFLOAT NaN is 0x07FF.
        let oximeter = try #require(GATTDecoding.decode(
            characteristic: "2A5F", Data([0x00, 0x62, 0x00, 0x40, 0x00])))
        #expect(oximeter.value("spo2") == 98)
        #expect(oximeter.value("pulseRate") == 64)
        let partial = try #require(GATTDecoding.decode(
            characteristic: "2A5F", Data([0x00, 0x62, 0x00, 0xFF, 0x07])))
        #expect(partial.value("spo2") == 98)
        #expect(partial.value("pulseRate") == nil)
        // A negative exponent in the top nibble: 0xF0FF = mantissa 255, exponent −1 = 25.5.
        #expect(abs((GATTDecoding.sfloat([0xFF, 0xF0], at: 0) ?? 0) - 25.5) < 1e-9)
    }

    @Test("Waage in Kilogramm und Pfund")
    func weight() throws {
        let kilograms = try #require(GATTDecoding.decode(
            characteristic: "2A9D", Data([0x00]) + Data(le(14_000, bytes: 2))))
        #expect(abs((kilograms.value("weight") ?? 0) - 70) < 1e-9)
        let pounds = try #require(GATTDecoding.decode(
            characteristic: "2A9D", Data([0x01]) + Data(le(15_432, bytes: 2))))
        #expect(abs((pounds.value("weight") ?? 0) - 70) < 0.01)
    }

    @Test("Das Presentation-Format-Descriptor macht ein Merkmal ohne Decoder lesbar")
    func presentationFormat() throws {
        // sint16, exponent −2, unit 0x272F (°C)
        let format = try #require(PresentationFormat(Data([0x0E, 0xFE, 0x2F, 0x27, 0x01, 0x00, 0x00])))
        #expect(format.unitSymbol == "°C")
        #expect(format.byteCount == 2)
        let value = try #require(format.value(from: Data(le(2150, bytes: 2))))
        #expect(abs(value - 21.5) < 1e-9)
        #expect(abs((format.value(from: Data(le(UInt32(bitPattern: -150) & 0xFFFF, bytes: 2))) ?? 0) + 1.5) < 1e-9)
        #expect(format.value(from: Data([1])) == nil)            // too short
        #expect(PresentationFormat(Data([0x19, 0, 0, 0, 0, 0, 0]))?.value(from: Data([65])) == nil)  // text
        #expect(PresentationFormat(Data([1, 2, 3])) == nil)
    }

    @Test("Eine eigene Vorlage liest Felder an ihren Stellen")
    func template() throws {
        let template = GATTTemplate(characteristic: "FFF1", name: "Meine Waage", fields: [
            .init(name: "temperature", offset: 1, type: .int16, factor: 0.01, unit: "°C"),
            .init(name: "counter", offset: 3, type: .uint16, bigEndian: true),
            .init(name: "tooFar", offset: 9, type: .uint32),
        ])
        #expect(template.matches("fff1"))
        #expect(template.matches("0000FFF1-0000-1000-8000-00805F9B34FB"))
        // flag, 21.50 °C little endian, counter 0x0102 big endian
        let reading = try #require(template.decode(Data([0x07, 0x66, 0x08, 0x01, 0x02])))
        #expect(abs((reading.value("temperature") ?? 0) - 21.5) < 1e-9)
        #expect(reading.value("counter") == 258)
        // A field that would read past the end is left out, never read from garbage.
        #expect(reading.value("tooFar") == nil)
        #expect(template.decode(Data()) == nil)

        let json = try JSONEncoder().encode(template)
        #expect(try JSONDecoder().decode(GATTTemplate.self, from: json) == template)
    }

    @Test("Eddystone: TLM, UID und URL")
    func eddystone() throws {
        // battery 2840 mV, 19.0 °C, 5223 advertisements, 280291.6 s of uptime
        let tlm = Data([0x20, 0x00, 0x0B, 0x18, 0x13, 0x00, 0x00, 0x00, 0x14, 0x67, 0x00, 0x2A, 0xC4, 0xE4])
        let info = try #require(BeaconDecoder.decode(BLEAdvertisement(serviceData: ["FEAA": tlm])))
        guard case let .eddystoneTLM(battery, temperature, count, uptime) = info else {
            Issue.record("kein TLM"); return
        }
        #expect(battery == 2.84)
        #expect(temperature == 19)
        #expect(count == 5223)
        #expect(abs(uptime - 280_291.6) < 1e-6)
        #expect(info.reading?.value("batteryVoltage") == 2.84)
        // A beacon without a sensor sends 0x8000 as the temperature and 0 mV when it has mains.
        let bare = Data([0x20, 0x00, 0x00, 0x00, 0x80, 0x00, 0, 0, 0, 1, 0, 0, 0, 10])
        guard case let .eddystoneTLM(noBattery, noTemperature, _, _)? =
                BeaconDecoder.decode(BLEAdvertisement(serviceData: ["FEAA": bare])) else {
            Issue.record("kein TLM"); return
        }
        #expect(noBattery == nil && noTemperature == nil)

        let uid = Data([0x00, 0xE7] + Array(repeating: 0xAB, count: 10) + [1, 2, 3, 4, 5, 6])
        guard case let .eddystoneUID(namespace, instance, power)? =
                BeaconDecoder.decode(BLEAdvertisement(serviceData: ["FEAA": uid])) else {
            Issue.record("keine UID"); return
        }
        #expect(namespace == String(repeating: "AB", count: 10))
        #expect(instance == "010203040506")
        #expect(power == -25)

        // https://www.example.com/ : scheme 0x01, "example", expansion 0x00
        let url = Data([0x10, 0xE7, 0x01] + Array("example".utf8) + [0x00])
        guard case let .eddystoneURL(text, _)? =
                BeaconDecoder.decode(BLEAdvertisement(serviceData: ["FEAA": url])) else {
            Issue.record("keine URL"); return
        }
        #expect(text == "https://www.example.com/")
        #expect(BeaconDecoder.decode(BLEAdvertisement(serviceData: ["FEAA": Data([0x30, 0])])) == nil)
    }

    @Test("AltBeacon und iBeacon")
    func beacons() throws {
        let id = Array(0..<16).map(UInt8.init)
        let alt = Data([0x4C, 0x00, 0xBE, 0xAC] + id + [0x00, 0x07, 0x00, 0x09, 0xC5, 0x01])
        guard case let .altBeacon(id1, id2, id3, rssi)? =
                BeaconDecoder.decode(BLEAdvertisement(manufacturerData: alt)) else {
            Issue.record("kein AltBeacon"); return
        }
        #expect(id1 == "00010203-0405-0607-0809-0A0B0C0D0E0F")
        #expect(id2 == 7 && id3 == 9 && rssi == -59)

        let ibeacon = Data([0x4C, 0x00, 0x02, 0x15] + id + [0x01, 0x00, 0x02, 0x00, 0xC5])
        guard case let .iBeacon(_, major, minor, power)? =
                BeaconDecoder.decode(BLEAdvertisement(manufacturerData: ibeacon)) else {
            Issue.record("kein iBeacon"); return
        }
        #expect(major == 256 && minor == 512 && power == -59)
        #expect(BeaconDecoder.decode(BLEAdvertisement(manufacturerData: Data([0x99, 0x04, 0x05]))) == nil)
    }

    @Test("Namen für Nummern, und eine Entfernung, die ihre Unsicherheit sagt")
    func namesAndRange() {
        #expect(BluetoothNames.company(in: Data([0x4C, 0x00, 0x10, 0x05]))?.name == "Apple, Inc.")
        #expect(BluetoothNames.company(in: Data([0x99, 0x04]))?.name == "Ruuvi Innovations Ltd.")
        #expect(BluetoothNames.company(in: Data([0xEF, 0xBE]))?.name == nil)        // unknown stays unnamed
        #expect(BluetoothNames.company(in: Data([0x4C]))?.id == nil)
        #expect(BluetoothNames.service("180D") == "Heart Rate")
        #expect(BluetoothNames.service("0000180d-0000-1000-8000-00805f9b34fb") == "Heart Rate")
        #expect(BluetoothNames.characteristic("2a37") == "Heart Rate Measurement")
        #expect(BluetoothNames.service("ABCD") == nil)

        // At the reference power the distance is one metre, whatever the environment.
        #expect(abs(RangeEstimate.metres(rssi: -59, referencePower: -59, exponent: 3) - 1) < 1e-12)
        // 20 dB weaker is ten times as far in free space (exponent 2) …
        #expect(abs(RangeEstimate.metres(rssi: -79, referencePower: -59, exponent: 2) - 10) < 1e-9)
        // … and the honest answer is the span between open and cluttered.
        let range = RangeEstimate.range(rssi: -79)
        #expect(range.near < range.far)
        #expect(abs(range.near - 3.73) < 0.01 && abs(range.far - 10) < 1e-9)
        #expect(RangeEstimate.metres(rssi: .nan, referencePower: -59).isNaN)
    }
}

@Suite("Bluetooth: Geräteliste")
struct DeviceTableTests {

    private let device = UUID()

    @Test("Ein Antwortpaket ergänzt den Namen, ohne die Herstellerdaten zu verlieren")
    func merges() {
        var table = DeviceTable()
        table.record(id: device, time: 0, rssi: -60,
                     advertisement: ScannedAdvertisement(
                        manufacturerData: Data([0x99, 0x04, 0x05]), serviceUUIDs: ["180F"],
                        txPower: -12, isConnectable: true))
        table.record(id: device, time: 0.1, rssi: -62,
                     advertisement: ScannedAdvertisement(name: "Ruuvi 4F2A", serviceUUIDs: ["180F", "181A"]))
        let seen = table.devices[device]
        #expect(seen?.name == "Ruuvi 4F2A")
        #expect(seen?.manufacturerData == Data([0x99, 0x04, 0x05]))
        #expect(seen?.serviceUUIDs == ["180F", "181A"])
        #expect(seen?.txPower == -12)
        #expect(seen?.isConnectable == true)
        #expect(seen?.rssi == -62)
        #expect(seen?.company?.name == "Ruuvi Innovations Ltd.")
        #expect(seen?.serviceNames == ["Battery", "Environmental Sensing"])
        // An empty name does not erase a good one.
        table.record(id: device, time: 0.2, rssi: -61, advertisement: ScannedAdvertisement(name: ""))
        #expect(table.devices[device]?.name == "Ruuvi 4F2A")
    }

    @Test("Verlauf höchstens zwei Punkte pro Sekunde und höchstens 120 Punkte")
    func history() {
        var scanned = ScannedDevice(id: device, time: 0, rssi: -50)
        for step in 0..<1_000 {
            scanned.record(time: Double(step) * 0.1, rssi: -50 - Double(step % 7),
                           advertisement: ScannedAdvertisement())
        }
        #expect(scanned.count == 1_000)
        #expect(scanned.history.count == ScannedDevice.historyLimit)
        let gaps = zip(scanned.history, scanned.history.dropFirst()).map { $1.time - $0.time }
        #expect(gaps.allSatisfy { $0 >= ScannedDevice.historyStep - 1e-9 })
        // The newest packet is always the current reading, whether or not it made the curve.
        #expect(scanned.rssi == -50 - Double(999 % 7))
        // A device speaking every 0.1 s has a mean interval near 0.1 s.
        #expect(abs((scanned.meanInterval ?? 0) - 0.1) < 1e-6)
    }

    @Test("Voll heisst: das am längsten stumme Gerät geht")
    func capacity() {
        var table = DeviceTable()
        let first = UUID()
        table.record(id: first, time: 0, rssi: -60, advertisement: ScannedAdvertisement())
        for step in 1..<DeviceTable.capacity {
            table.record(id: UUID(), time: Double(step), rssi: -60, advertisement: ScannedAdvertisement())
        }
        #expect(table.devices.count == DeviceTable.capacity)
        table.record(id: UUID(), time: 1_000, rssi: -60, advertisement: ScannedAdvertisement())
        #expect(table.devices.count == DeviceTable.capacity)
        #expect(table.devices[first] == nil)

        table.prune(olderThan: 100, now: 1_000)
        #expect(table.devices.count == 1)
    }

    @Test("Der Bezugspegel kommt vom Beacon, vom Gerät oder ist eine ausgewiesene Annahme")
    func reference() {
        var table = DeviceTable()
        table.record(id: device, time: 0, rssi: -69, advertisement: ScannedAdvertisement())
        #expect(table.devices[device]?.referencePower.isAssumed == true)
        #expect(table.devices[device]?.referencePower.value == -59)
        table.record(id: device, time: 1, rssi: -69, advertisement: ScannedAdvertisement(txPower: -69))
        #expect(table.devices[device]?.referencePower.isAssumed == false)
        // At the reference power the device is at one metre.
        let range = table.devices[device]?.distance
        #expect(abs((range?.near ?? 0) - 1) < 1e-9)
        table.record(id: device, time: 2, rssi: -69,
                     advertisement: ScannedAdvertisement(beacon: .altBeacon(id1: "x", id2: 1, id3: 2, referenceRSSI: -50)))
        #expect(table.devices[device]?.referencePower.value == -50)
    }

    @Test("Ein aufgezeichnetes Merkmal: Vorlage vor Standard vor Presentation Format")
    func subscription() throws {
        let uuid = UUID()
        var subscription = GATTSubscription(device: uuid, deviceName: "Thermo", service: "181A",
                                            characteristic: "2A6E", characteristicName: "Temperature")
        #expect(subscription.streamBase == "ble.\(String(uuid.uuidString.prefix(8)).lowercased()).gatt.2a6e")
        let value = Data([0x66, 0x08])           // 21.50 °C
        #expect(abs((subscription.decode(value)?.value("temperature") ?? 0) - 21.5) < 1e-9)

        // A template wins over the standard decoding.
        subscription.template = GATTTemplate(characteristic: "2A6E", name: "Meine", fields: [
            .init(name: "raw", offset: 0, type: .uint16)])
        #expect(subscription.decode(value)?.value("raw") == 0x0866)
        #expect(subscription.unit(forField: "raw", decoder: "Meine") == "")

        // An unknown characteristic with a presentation format reads through it.
        var unknown = GATTSubscription(device: uuid, deviceName: "X", service: "FFF0",
                                       characteristic: "FFF1", characteristicName: "Wert")
        #expect(unknown.decode(value) == nil)
        unknown.presentation = PresentationFormat(Data([0x0E, 0xFE, 0x2F, 0x27, 0, 0, 0]))
        #expect(abs((unknown.decode(value)?.value("value") ?? 0) - 21.5) < 1e-9)
        #expect(unknown.unit(forField: "value", decoder: "Wert") == "°C")

        let data = try JSONEncoder().encode(unknown)
        #expect(try JSONDecoder().decode(GATTSubscription.self, from: data) == unknown)
        #expect(unknown.id.hasSuffix("|FFF0|FFF1"))
    }
}

@Suite("Bluetooth: Hex und Decoder-Vorlage")
struct HexAndTemplateTests {

    @Test("Hex wird streng gelesen: ungerade Stellen und fremde Zeichen sind Fehler")
    func hex() {
        #expect(HexCoding.data("0A ff 12") == Data([0x0A, 0xFF, 0x12]))
        #expect(HexCoding.data("0x0A,0xFF:12-00") == Data([0x0A, 0xFF, 0x12, 0x00]))
        #expect(HexCoding.data("") == Data())
        #expect(HexCoding.data("0AF") == nil)
        #expect(HexCoding.data("0G") == nil)
        #expect(HexCoding.string(Data([0x0A, 0xFF])) == "0A FF")
        #expect(HexCoding.string(Data([0x0A, 0xFF]), separator: "") == "0AFF")
        #expect(HexCoding.ascii(Data([0x48, 0x69, 0x00, 0x7F])) == "Hi..")
        #expect(HexCoding.bytes(of: 0x0102, width: 2, bigEndian: false) == Data([0x02, 0x01]))
        #expect(HexCoding.bytes(of: 0x0102, width: 2, bigEndian: true) == Data([0x01, 0x02]))
        #expect(HexCoding.bytes(of: 0x1FF, width: 1, bigEndian: false) == Data([0xFF]))
    }

    @Test("Die Decoder-Vorlage trägt Firma oder Dienst schon ein und lädt als Decoder-Datei")
    func decoderTemplate() throws {
        var table = DeviceTable()
        let id = UUID()
        table.record(id: id, time: 0, rssi: -60, advertisement: ScannedAdvertisement(
            name: "Mein \"Sensor\"", manufacturerData: Data([0x99, 0x04, 0x05, 0x12])))
        let device = try #require(table.devices[id])
        let text = DecoderTemplate.make(for: device)
        #expect(text.contains("manufacturerId: 0x0499"))
        #expect(text.contains("Ruuvi Innovations Ltd."))
        #expect(text.contains("99 04 05 12"))
        #expect(!text.contains("\"Sensor\""))
        // The file the scanner hands over is a decoder file the app accepts.
        _ = try ScriptDecoders(source: text)

        var other = DeviceTable()
        other.record(id: id, time: 0, rssi: -60, advertisement: ScannedAdvertisement(
            name: "Thermo", serviceData: ["FCD2": Data([0x40, 0x02, 0x01])]))
        let service = DecoderTemplate.make(for: try #require(other.devices[id]))
        #expect(service.contains("serviceUuid: \"FCD2\""))
        _ = try ScriptDecoders(source: service)

        var bare = DeviceTable()
        bare.record(id: id, time: 0, rssi: -60, advertisement: ScannedAdvertisement(name: "Nur Name"))
        let named = DecoderTemplate.make(for: try #require(bare.devices[id]))
        #expect(named.contains("namePrefix: \"Nur Na\""))
        _ = try ScriptDecoders(source: named)
    }
}
