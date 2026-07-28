import Foundation
import Testing
@testable import SensorstormCore

@Suite("Store and export")
struct RecordingStoreTests {

    private func makeStore() throws -> RecordingStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensorstorm-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return RecordingStore(root: root)
    }

    private func makeMetadata(name: String = "Testfahrt", start: Double = 1000) -> RecordingMetadata {
        RecordingMetadata(
            name: name,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            startHostTime: start,
            duration: 10,
            device: DeviceInfo(model: "iPhone17,1", systemName: "iOS",
                               systemVersion: "26.0", appVersion: "1.0.0"),
            requestedRateHz: 100
        )
    }

    @Test("Metadata survives a save/load cycle")
    func metadataRoundTrip() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        var metadata = makeMetadata()
        metadata.streams = [StreamInfo(sensor: .accelerometer, channels: ["x", "y", "z"],
                                       unit: "g", sampleCount: 42, effectiveRateHz: 100)]
        metadata.video = VideoInfo(fileName: "video.mov", startHostTime: 1000.25, duration: 9.5,
                                   width: 1920, height: 1080, nominalFrameRate: 30,
                                   hasAudio: true, isFrontCamera: false)
        try store.save(metadata)

        let loaded = try store.loadMetadata(id: metadata.id)
        #expect(loaded == metadata)
        #expect(loaded.video?.offset(from: loaded.startHostTime) == 0.25)
    }

    @Test("Listing sorts newest first and ignores broken folders")
    func listing() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        var older = makeMetadata(name: "Alt")
        older.startedAt = Date(timeIntervalSince1970: 1_000_000)
        var newer = makeMetadata(name: "Neu")
        newer.startedAt = Date(timeIntervalSince1970: 2_000_000)
        try store.save(older)
        try store.save(newer)

        // A folder that looks like a recording but has no metadata must not break listing.
        let junk = store.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)

        let all = store.allRecordings()
        #expect(all.map(\.name) == ["Neu", "Alt"])
    }

    @Test("Deleting removes the whole folder")
    func deletion() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let metadata = makeMetadata()
        try store.save(metadata)
        let writer = try StreamWriter(sensor: .gravity, channelCount: 3,
                                      directory: store.directory(for: metadata.id))
        writer.append(time: 1, values: [0, 0, 1])
        writer.close()

        #expect(store.byteSize(of: metadata.id) > 0)
        try store.delete(metadata.id)
        #expect(store.allRecordings().isEmpty)
        #expect(FileManager.default.fileExists(atPath: store.directory(for: metadata.id).path) == false)
    }

    @Test("Annotations round-trip and come back in time order")
    func annotations() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let metadata = makeMetadata()
        try store.save(metadata)
        try store.saveAnnotations([
            Annotation(hostTime: 1005, text: "Kurve"),
            Annotation(hostTime: 1002, text: "Start, mit \"Anführung\", und Komma")
        ], for: metadata.id)

        let loaded = store.annotations(for: metadata.id)
        #expect(loaded.map(\.hostTime) == [1002, 1005])
    }

    @Test("CSV export produces one aligned file per stream")
    func csvExport() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        var metadata = makeMetadata()
        try store.save(metadata)

        let writer = try StreamWriter(sensor: .accelerometer, channelCount: 3,
                                      directory: store.directory(for: metadata.id))
        for i in 0..<5 {
            writer.append(time: 1000 + Double(i) * 0.01, values: [Double(i), 0.5, -9.81])
        }
        metadata.streams = [writer.close()]
        try store.save(metadata)
        try store.saveAnnotations([Annotation(hostTime: 1000.02, text: "a,b")], for: metadata.id)

        let destination = store.root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let zip = try RecordingExporter(store: store)
            .export(metadata, format: .csvBundle, into: destination)

        #expect(FileManager.default.fileExists(atPath: zip.path))
        #expect(zip.lastPathComponent == "Testfahrt.zip")
        #expect((try Data(contentsOf: zip)).count > 0)
    }

    @Test("Export file names are safe on every file system")
    func sanitising() {
        // Umlauts are alphanumeric and stay; path separators and dashes do not.
        #expect(RecordingExporter.sanitize("Fahrt 12/05 – Zürich") == "Fahrt 12-05 Zürich")
        #expect(RecordingExporter.sanitize("") == "Recording")
        #expect(RecordingExporter.sanitize("///") == "Recording")
        #expect(RecordingExporter.sanitize("a // b") == "a b")
        #expect(RecordingExporter.sanitize("..hidden") == "hidden")
        // The default recording name must not come out with a stray "- " in it.
        #expect(RecordingExporter.sanitize("28.07.2026, 21:02") == "28-07-2026-21-02")
    }

    @Test("CSV escaping quotes only what needs quoting")
    func csvEscaping() {
        #expect(RecordingExporter.csvEscape("plain") == "plain")
        #expect(RecordingExporter.csvEscape("a,b") == "\"a,b\"")
        #expect(RecordingExporter.csvEscape("say \"hi\"") == "\"say \"\"hi\"\"\"")
    }

    @Test("Numbers keep enough digits for GPS")
    func numberFormatting() {
        #expect(RecordingExporter.number(47.376887654321) == "47.3768876543")
        #expect(RecordingExporter.number(.nan) == "")
        #expect(RecordingExporter.number(.infinity) == "")
        // The classic float artefact must not leak into the CSV.
        #expect(RecordingExporter.number(0.1 + 0.2) == "0.3")
    }
}

@Suite("Sensor catalog")
struct SensorCatalogTests {

    @Test("Every sensor has a descriptor with matching channel units")
    func descriptorsAreComplete() {
        for id in SensorID.allCases {
            let descriptor = id.descriptor
            #expect(descriptor.id == id)
            #expect(descriptor.channels.isEmpty == false)
            #expect(descriptor.channels.count == descriptor.channelUnits.count,
                    "\(id.rawValue) has \(descriptor.channels.count) channels but \(descriptor.channelUnits.count) units")
        }
    }

    @Test("Raw values are stable — they are the on-disk file names")
    func rawValuesAreStable() {
        #expect(SensorID.accelerometer.rawValue == "accelerometer")
        #expect(SensorID.userAcceleration.rawValue == "userAcceleration")
        #expect(SensorID.headphoneOrientation.rawValue == "headphoneOrientation")
        #expect(SensorID.allCases.count == 17)
    }
}

@Suite("Host clock")
struct HostClockTests {

    @Test("The clock advances and never goes backwards")
    func monotonic() {
        let first = HostClock.now
        var last = first
        for _ in 0..<1000 {
            let now = HostClock.now
            #expect(now >= last)
            last = now
        }
        #expect(last > first)
    }

    @Test("Wall-clock dates map into the host timeline")
    func wallClockMapping() {
        let offset = HostClock.wallToHostOffset
        let date = Date()
        let host = HostClock.hostSeconds(for: date, offset: offset)
        #expect(abs(host - HostClock.now) < 0.5)
    }
}
