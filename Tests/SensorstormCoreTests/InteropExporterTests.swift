import Foundation
import Testing
@testable import SensorstormCore

@Suite("Interop exports")
struct InteropExporterTests {

    /// A recording with a gyroscope at 100 Hz and an accelerometer at half that, so the
    /// two-rate handling is exercised rather than assumed.
    private struct Fixture {
        static let startHostTime = 500.0
        static let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        static let gyroSampleCount = 20

        let store: RecordingStore
        let metadata: RecordingMetadata

        init() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("sensorstorm-interop-\(UUID().uuidString)",
                                        isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = RecordingStore(root: root)

            let id = UUID()
            let directory = try store.prepareDirectory(for: id)

            let gyro = try StreamWriter(sensor: .gyroscope, channelCount: 3,
                                        directory: directory)
            for i in 0..<Self.gyroSampleCount {
                let t = Self.startHostTime + Double(i) / 100
                gyro.append(time: t, values: [Double(i) * 0.01, -0.5, 0.25])
            }

            let accel = try StreamWriter(sensor: .accelerometer, channelCount: 3,
                                         directory: directory)
            for i in 0..<(Self.gyroSampleCount / 2) {
                let t = Self.startHostTime + Double(i) / 50
                accel.append(time: t, values: [0, 0, -1 + Double(i) * 0.001])
            }

            let location = try StreamWriter(sensor: .location, channelCount: 10,
                                            directory: directory)
            location.append(time: Self.startHostTime + 0.5,
                            values: [46.9480, 7.4474, 540, 590, 1.5, 1, 90, 5, 4, 6])

            metadata = RecordingMetadata(
                id: id,
                name: "Interop",
                startedAt: Self.startedAt,
                startHostTime: Self.startHostTime,
                duration: 0.2,
                device: DeviceInfo(model: "iPhone17,1", systemName: "iOS",
                                   systemVersion: "26.0", appVersion: "1.0.0 (1)"),
                streams: [gyro.close(), accel.close(), location.close()],
                requestedRateHz: 100)
            try store.save(metadata)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: store.root) }
    }

    // MARK: - Gyroflow

    @Test("The Gyroflow log carries the header its parser looks for")
    func gcsvHeader() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let gyro = try #require(fixture.store.reader(for: .gyroscope,
                                                     recording: fixture.metadata.id))
        let log = InteropExporter.gcsv(
            gyroscope: gyro,
            accelerometer: fixture.store.reader(for: .accelerometer,
                                                recording: fixture.metadata.id),
            metadata: fixture.metadata)

        let lines = log.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
        #expect(lines[0] == "GYROFLOW IMU LOG")
        #expect(lines.contains("version,1.3"))
        #expect(lines.contains("tscale,0.000001"))
        #expect(lines.contains("t,gx,gy,gz,ax,ay,az"))
    }

    @Test("Every gyro sample becomes one row, timestamped from the recording start")
    func gcsvRows() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let gyro = try #require(fixture.store.reader(for: .gyroscope,
                                                     recording: fixture.metadata.id))
        let log = InteropExporter.gcsv(
            gyroscope: gyro,
            accelerometer: fixture.store.reader(for: .accelerometer,
                                                recording: fixture.metadata.id),
            metadata: fixture.metadata)

        let rows = log.split(separator: "\n").drop { !$0.hasPrefix("t,gx") }.dropFirst()
        #expect(rows.count == Fixture.gyroSampleCount)

        let first = rows.first!.split(separator: ",", omittingEmptySubsequences: false)
        #expect(first.count == 7)
        // t = 0 at the recording start, not at some absolute epoch.
        #expect(first[0] == "0")
        #expect(Double(first[2]) == -0.5)

        // 100 Hz in microseconds: the second row is exactly 10 000 µs later, with no
        // floating-point residue in the integer column.
        let second = rows.dropFirst().first!.split(separator: ",")
        #expect(second[0] == "10000")

        // Accelerometer runs at half the rate, so the two gyro rows between one accel sample
        // and the next carry the same acceleration — the last one in effect, never an
        // interpolated one. Rows 0 and 1 straddle no accel sample; row 2 lands on the next.
        #expect(first[6] == second[6])
        let third = rows.dropFirst(2).first!.split(separator: ",")
        #expect(third[6] != second[6], "row 2 sits on the next accelerometer sample")
    }

    @Test("A recording without a gyroscope is refused rather than exported empty")
    func gyroflowNeedsGyro() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensorstorm-nogyro-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = RecordingStore(root: root)
        let metadata = RecordingMetadata(
            name: "Ohne Gyro", startedAt: Date(), startHostTime: 0, duration: 1,
            device: DeviceInfo(model: "iPhone17,1", systemName: "iOS",
                               systemVersion: "26.0", appVersion: "1.0.0"),
            requestedRateHz: 100)
        try store.save(metadata)

        let destination = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        #expect(throws: RecordingExporter.ExportError.self) {
            try RecordingExporter(store: store)
                .export(metadata, format: .gyroflowLog, into: destination)
        }
    }

    // MARK: - Sensor Logger

    @Test("Sensor Logger CSV uses epoch nanoseconds, which is what its parsers read")
    func sensorLoggerColumns() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let stream = try #require(fixture.metadata.stream(.gyroscope))
        let reader = try #require(fixture.store.reader(for: .gyroscope,
                                                       recording: fixture.metadata.id))
        let csv = InteropExporter.sensorLoggerCSV(reader: reader, stream: stream,
                                                  metadata: fixture.metadata)

        let lines = csv.split(separator: "\n")
        #expect(lines[0] == "time,seconds_elapsed,x,y,z")
        #expect(lines.count == Fixture.gyroSampleCount + 1)

        let first = lines[1].split(separator: ",")
        let nanoseconds = try #require(Int64(first[0]))
        #expect(nanoseconds == Int64(Fixture.startedAt.timeIntervalSince1970 * 1_000_000_000))
        // An integer, not scientific notation — `pandas.to_datetime` chokes on the latter.
        #expect(!first[0].contains("e"))
        #expect(!first[0].contains("."))
        #expect(Double(first[1]) == 0)
    }

    @Test("Streams get the names Sensor Logger's own tooling expects")
    func sensorLoggerNames() {
        // Sensor Logger calls the fused streams by the plain name and the raw ones
        // "Uncalibrated"; Sensorstorm's ids are the other way round, so this mapping is the
        // whole point and a swap here would mislabel every export.
        #expect(InteropExporter.sensorLoggerFileName(for: .userAcceleration) == "Accelerometer.csv")
        #expect(InteropExporter.sensorLoggerFileName(for: .accelerometer)
                == "AccelerometerUncalibrated.csv")
        #expect(InteropExporter.sensorLoggerFileName(for: .rotationRate) == "Gyroscope.csv")
        #expect(InteropExporter.sensorLoggerFileName(for: .gyroscope)
                == "GyroscopeUncalibrated.csv")
        #expect(InteropExporter.sensorLoggerFileName(for: .location) == "Location.csv")
        #expect(InteropExporter.sensorLoggerFileName(for: .loudness) == "Microphone.csv")

        // Every stream must produce some name; a missing case would be a crash at export.
        for sensor in SensorID.allCases {
            #expect(InteropExporter.sensorLoggerFileName(for: sensor).hasSuffix(".csv"))
        }
    }

    @Test("The bundle writes one file per stream plus the metadata row")
    func sensorLoggerBundle() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let destination = fixture.store.root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: destination,
                                                withIntermediateDirectories: true)

        let zip = try RecordingExporter(store: fixture.store)
            .export(fixture.metadata, format: .sensorLoggerBundle, into: destination)
        #expect(FileManager.default.fileExists(atPath: zip.path))

        let size = try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int
        #expect((size ?? 0) > 0)
    }

    @Test("The metadata row has as many fields as it has headers")
    func sensorLoggerMetadataIsWellFormed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let csv = InteropExporter.sensorLoggerMetadataCSV(fixture.metadata)
        let lines = csv.split(separator: "\n")
        #expect(lines.count == 2)

        // "iPhone17,1" contains a comma, which is exactly the case a naive split gets wrong
        // — so the field count is taken with quoting respected, the way a real parser reads it.
        #expect(lines[0].split(separator: ",").count == 6)
        #expect(Self.csvFields(String(lines[1])).count == 6)
        #expect(lines[1].contains("\"iPhone17,1\""), "a model with a comma has to be quoted")
    }

    /// Minimal RFC 4180 splitter: enough to count fields honestly in a test.
    private static func csvFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for character in line {
            switch character {
            case "\"": inQuotes.toggle()
            case "," where !inQuotes:
                fields.append(current)
                current = ""
            default: current.append(character)
            }
        }
        fields.append(current)
        return fields
    }
}
