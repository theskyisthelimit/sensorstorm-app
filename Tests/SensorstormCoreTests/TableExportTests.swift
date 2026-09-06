import Foundation
import SQLite3
import Testing
@testable import SensorstormCore

@Suite("Kombinierte Exporte")
struct TableExportTests {

    // MARK: - Fixture

    /// Two streams at deliberately different rates and with different start times — the
    /// situation the combined table exists for. Acceleration runs at 10 Hz from the very
    /// start; the GPS produces its first fix half a second in, at 1 Hz.
    private func makeRecording() throws -> (RecordingStore, RecordingMetadata) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensorstorm-table-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = RecordingStore(root: root)

        var metadata = RecordingMetadata(
            name: "Kombitest",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            startHostTime: 1000,
            duration: 2,
            device: DeviceInfo(model: "iPhone17,1", systemName: "iOS",
                               systemVersion: "26.0", appVersion: "1.0.0"),
            requestedRateHz: 10)

        let directory = try store.prepareDirectory(for: metadata.id)

        let motion = try StreamWriter(sensor: .userAcceleration, channelCount: 3,
                                      directory: directory)
        for step in 0..<20 {
            let t = 1000 + Double(step) / 10
            motion.append(time: t, values: [Double(step), Double(step) * 2, Double(step) * 3])
        }
        motion.flush()

        let location = try StreamWriter(sensor: .location, channelCount: 10, directory: directory)
        location.append(time: 1000.5, values: [46.9, 7.4, 542, 4.5, 2.4, 78, 3, 6, 0, 0])
        location.append(time: 1001.5, values: [46.91, 7.41, 543, 4.0, 2.5, 79, 3, 6, 0, 0])
        location.flush()

        metadata.streams = [motion.close(), location.close()]
        try store.save(metadata)
        return (store, metadata)
    }

    private func rows(_ csv: String) -> [[String]] {
        csv.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.components(separatedBy: ",") }
    }

    // MARK: - Kombi-CSV

    @Test("Jede Zeile hat so viele Felder wie die Kopfzeile")
    func combinedCSVIsRectangular() throws {
        let (store, metadata) = try makeRecording()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let url = store.root.appendingPathComponent("combined.csv")
        try CombinedCSVExporter(store: store).write(metadata, to: url)

        let table = rows(try String(contentsOf: url, encoding: .utf8))
        let width = table[0].count
        // time, epoch, 3 acceleration channels + age, 10 GPS channels + age
        #expect(width == 2 + 3 + 1 + 10 + 1)
        for (index, row) in table.enumerated() {
            #expect(row.count == width, "Zeile \(index) hat \(row.count) Felder")
        }
    }

    /// The promise the whole format rests on: a cell is a measurement that happened, held
    /// until the next one. If this ever gets "fixed" into interpolation, the export starts
    /// inventing GPS positions the receiver never reported.
    @Test("Werte werden gehalten, nicht interpoliert")
    func combinedCSVHoldsRatherThanInterpolates() throws {
        let (store, metadata) = try makeRecording()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let url = store.root.appendingPathComponent("combined.csv")
        try CombinedCSVExporter(store: store).write(metadata, to: url)
        let table = rows(try String(contentsOf: url, encoding: .utf8))

        let latitude = try #require(table[0].firstIndex(of: "location_latitude"))

        // Rows at t = 0.6 … 1.4 all sit between the two fixes and must all read the first.
        for step in 6...14 {
            #expect(table[step + 1][latitude] == "46.9", "Zeile bei t=\(Double(step) / 10)")
        }
        // At t = 1.5 the second fix arrives.
        #expect(table[16][latitude] == "46.91")
    }

    @Test("Vor dem ersten Sample bleibt die Zelle leer, nicht null")
    func combinedCSVLeavesUnmeasuredCellsEmpty() throws {
        let (store, metadata) = try makeRecording()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let url = store.root.appendingPathComponent("combined.csv")
        try CombinedCSVExporter(store: store).write(metadata, to: url)
        let table = rows(try String(contentsOf: url, encoding: .utf8))

        let latitude = try #require(table[0].firstIndex(of: "location_latitude"))
        // The GPS has nothing before t = 0.5. A zero here would be a reading at null island.
        for step in 0...4 {
            #expect(table[step + 1][latitude].isEmpty, "Zeile bei t=\(Double(step) / 10)")
        }
        #expect(!table[6][latitude].isEmpty)
    }

    @Test("Die Alterspalte sagt, wie alt der gehaltene Wert ist")
    func combinedCSVReportsAge() throws {
        let (store, metadata) = try makeRecording()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let url = store.root.appendingPathComponent("combined.csv")
        try CombinedCSVExporter(store: store).write(metadata, to: url)
        let table = rows(try String(contentsOf: url, encoding: .utf8))

        let age = try #require(table[0].firstIndex(of: "location_age"))
        // t = 1.4, last fix at t = 0.5 → held for 0.9 s.
        let held = try #require(Double(table[15][age]))
        #expect(abs(held - 0.9) < 1e-6)
    }

    @Test("Ohne Alterspalten wird die Tabelle entsprechend schmaler")
    func combinedCSVCanOmitAge() throws {
        let (store, metadata) = try makeRecording()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let url = store.root.appendingPathComponent("combined.csv")
        try CombinedCSVExporter(store: store).write(metadata, includesAge: false, to: url)
        let table = rows(try String(contentsOf: url, encoding: .utf8))
        #expect(table[0].count == 2 + 3 + 10)
        #expect(!table[0].contains { $0.hasSuffix("_age") })
    }

    // MARK: - JSON

    @Test("Das JSON ist gültig und trägt jeden Stream mit allen Samples")
    func jsonParsesBack() throws {
        let (store, metadata) = try makeRecording()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let url = store.root.appendingPathComponent("recording.json")
        try JSONExporter(store: store).write(metadata, to: url)

        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let root = try #require(parsed as? [String: Any])
        #expect(root["schema"] as? String == JSONExporter.schema)

        let streams = try #require(root["streams"] as? [[String: Any]])
        #expect(streams.count == 2)

        let motion = try #require(streams.first { $0["sensor"] as? String == "userAcceleration" })
        // `[[Any]]` rather than `[[Double]]`: JSONSerialization hands back NSNumbers, and a
        // whole-array bridge to Double is not something to bet a red build on.
        let samples = try #require(motion["samples"] as? [[Any]])
        #expect(samples.count == 20)

        func number(_ value: Any) -> Double { (value as? NSNumber)?.doubleValue ?? .nan }
        // [time, x, y, z], time relative to the recording start.
        #expect(samples[0].count == 4)
        #expect(number(samples[0][0]) == 0)
        #expect(abs(number(samples[5][0]) - 0.5) < 1e-9)
        #expect(number(samples[5][1]) == 5)
    }

    /// JSON has no NaN. Writing 0 instead would turn "the sensor could not produce a value"
    /// into "the sensor measured zero", which is a different and wrong statement.
    @Test("Ein nicht messbarer Wert wird null, nicht 0")
    func jsonWritesNullForNonFinite() throws {
        #expect(JSONExporter.number(.nan) == "null")
        #expect(JSONExporter.number(.infinity) == "null")
        #expect(JSONExporter.number(0) == "0")
    }

    @Test("Steuerzeichen und Anführungszeichen überleben die Maskierung")
    func jsonEscapesText() throws {
        #expect(JSONExporter.string("a\"b") == "\"a\\\"b\"")
        #expect(JSONExporter.string("a\nb") == "\"a\\nb\"")
        #expect(JSONExporter.string("a\u{01}b") == "\"a\\u0001b\"")
    }

    // MARK: - SQLite

    @Test("Die Datenbank hat pro Sensor eine Tabelle mit allen Zeilen")
    func sqliteHasATablePerSensor() throws {
        let (store, metadata) = try makeRecording()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let url = store.root.appendingPathComponent("recording.sqlite")
        try SQLiteExporter(store: store).write(metadata, to: url)

        var handle: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        let db = try #require(handle)
        defer { sqlite3_close(db) }

        #expect(count(db, "SELECT COUNT(*) FROM userAcceleration") == 20)
        #expect(count(db, "SELECT COUNT(*) FROM location") == 2)
        #expect(count(db, "SELECT COUNT(*) FROM streams") == 2)
        // The metadata table is what makes the file readable without this app.
        #expect(count(db, "SELECT COUNT(*) FROM metadata WHERE key = 'schema'") == 1)
    }

    @Test("Die Zeiten stehen relativ zum Aufnahmebeginn in der Datenbank")
    func sqliteTimesAreRelative() throws {
        let (store, metadata) = try makeRecording()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let url = store.root.appendingPathComponent("recording.sqlite")
        try SQLiteExporter(store: store).write(metadata, to: url)

        var handle: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        let db = try #require(handle)
        defer { sqlite3_close(db) }

        let first = double(db, "SELECT MIN(time) FROM userAcceleration")
        let last = double(db, "SELECT MAX(time) FROM userAcceleration")
        #expect(abs(first - 0) < 1e-9)
        #expect(abs(last - 1.9) < 1e-9)
    }

    @Test("Namen werden zu sicheren SQL-Bezeichnern und Literalen")
    func sqliteSanitises() {
        #expect(SQLiteExporter.identifier("true heading") == "true_heading")
        #expect(SQLiteExporter.identifier("x/y") == "x_y")
        #expect(SQLiteExporter.identifier("") == "unnamed")
        #expect(SQLiteExporter.identifier("2d") == "n2d")
        #expect(SQLiteExporter.literal("O'Brien") == "'O''Brien'")
    }

    // MARK: - Gating

    /// The new formats are Pro, and CSV per sensor stays free. The data escape hatch does
    /// not narrow because the app grew more ways out.
    @Test("Die neuen Formate sind Pro, der CSV-Export bleibt frei")
    func newFormatsAreGated() {
        #expect(RecordingExporter.Format.combinedCSV.proFeature == .tableExport)
        #expect(RecordingExporter.Format.json.proFeature == .tableExport)
        #expect(RecordingExporter.Format.sqlite.proFeature == .tableExport)
        #expect(ProAccess.free.allows(recordingFormat: .csvBundle))
        #expect(!ProAccess.free.allows(recordingFormat: .combinedCSV))
        #expect(ProAccess.pro.allows(recordingFormat: .sqlite))
    }

    // MARK: - SQLite helpers

    private func count(_ db: OpaquePointer, _ sql: String) -> Int {
        Int(double(db, sql))
    }

    private func double(_ db: OpaquePointer, _ sql: String) -> Double {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return sqlite3_column_double(statement, 0)
    }
}
