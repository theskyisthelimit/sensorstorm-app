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

    /// Writes the folder a crash mid-recording leaves behind: samples on disk, no metadata.
    @discardableResult
    private func makeOrphan(in store: RecordingStore, samples: Int = 10) throws -> UUID {
        let id = UUID()
        let directory = try store.prepareDirectory(for: id)
        let writer = try StreamWriter(sensor: .accelerometer, channelCount: 3,
                                      directory: directory)
        for i in 0..<samples {
            writer.append(time: Double(i) * 0.01, values: [Double(i), 0.5, -9.81])
        }
        writer.close()
        return id
    }

    @Test("A recording killed before its metadata was written is reported as an orphan")
    func orphanIsFound() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        try store.save(makeMetadata(name: "Heil"))
        let crashed = try makeOrphan(in: store)

        let orphans = store.orphanedRecordings()
        #expect(orphans.map(\.id) == [crashed])
        #expect(orphans[0].byteSize == store.byteSize(of: crashed))
        #expect(orphans[0].byteSize > 0)
        #expect(store.orphanedByteSize == orphans[0].byteSize)
        // The healthy recording stays where it was; listing behaviour is untouched.
        #expect(store.allRecordings().map(\.name) == ["Heil"])
    }

    @Test("Orphans come back largest first, so the biggest waste is named first")
    func orphansSortBySize() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let small = try makeOrphan(in: store, samples: 5)
        let large = try makeOrphan(in: store, samples: 500)

        let orphans = store.orphanedRecordings()
        #expect(orphans.map(\.id) == [large, small])
        #expect(store.orphanedByteSize == orphans.reduce(0) { $0 + $1.byteSize })
    }

    @Test("Only UUID-named directories count as orphans")
    func orphansIgnoreForeignClutter() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        // Someone else's folder, and a stray file that happens to be named like a recording.
        try FileManager.default.createDirectory(
            at: store.root.appendingPathComponent("exports", isDirectory: true),
            withIntermediateDirectories: true)
        try Data("junk".utf8).write(
            to: store.root.appendingPathComponent(UUID().uuidString))

        #expect(store.orphanedRecordings().isEmpty)
        #expect(store.orphanedByteSize == 0)
    }

    @Test("Deleting an orphan gives the disk space back")
    func orphanDeletion() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        let crashed = try makeOrphan(in: store)
        #expect(store.orphanedByteSize > 0)

        try store.delete(crashed)

        #expect(store.orphanedRecordings().isEmpty)
        #expect(store.orphanedByteSize == 0)
        #expect(FileManager.default.fileExists(atPath: store.directory(for: crashed).path) == false)
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
        #expect(SensorID.cameraPose.rawValue == "cameraPose")
        #expect(SensorID.allCases.count == 18)
    }

    @Test("The camera pose stream carries a full pinhole camera per frame")
    func cameraPoseLayout() {
        let channels = SensorID.cameraPose.descriptor.channels
        #expect(channels.prefix(3) == ["px", "py", "pz"])
        #expect(channels[3...6] == ["qx", "qy", "qz", "qw"])
        #expect(channels[7...10] == ["fx", "fy", "cx", "cy"])
        #expect(channels.suffix(2) == ["trackingState", "trackingReason"])
        #expect(SensorID.engineControlled.contains(.cameraPose))
    }
}

@Suite("Recording metadata")
struct RecordingMetadataTests {

    /// Build 1 shipped without these fields. A recording made with it has to keep opening,
    /// and has to come back saying it does not know rather than guessing.
    @Test("Metadata written before the pose fields existed still decodes")
    func decodesLegacyMetadata() throws {
        let legacy = """
        {
          "id": "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
          "name": "Alt",
          "startedAt": "2026-01-02T03:04:05Z",
          "startHostTime": 100.5,
          "duration": 12.25,
          "device": { "model": "iPhone17,1", "systemName": "iOS",
                      "systemVersion": "18.2", "appVersion": "1.0.0 (1)" },
          "streams": [],
          "requestedRateHz": 100,
          "notes": "",
          "video": { "fileName": "video.mov", "startHostTime": 100.6, "duration": 12.0,
                     "width": 1920, "height": 1080, "nominalFrameRate": 30,
                     "hasAudio": true, "isFrontCamera": false }
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(RecordingMetadata.self, from: Data(legacy.utf8))

        #expect(metadata.captureEngine == nil)
        #expect(metadata.attitudeReferenceFrame == nil)
        #expect(metadata.geodeticAnchor == nil)
        #expect(metadata.video?.appliedRotationAngle == nil)
        // Unknown rotation is not the same as no rotation.
        #expect(metadata.video?.isSensorNative == false)
    }

    @Test("A sensor-native video is the only one intrinsics apply to unchanged")
    func sensorNativeVideo() {
        func video(rotation: Double?, mirrored: Bool?) -> VideoInfo {
            VideoInfo(fileName: "v.mov", startHostTime: 0, duration: 1,
                      width: 1920, height: 1080, nominalFrameRate: 30,
                      hasAudio: false, isFrontCamera: false,
                      appliedRotationAngle: rotation, isMirrored: mirrored)
        }
        #expect(video(rotation: 0, mirrored: false).isSensorNative)
        #expect(video(rotation: 90, mirrored: false).isSensorNative == false)
        #expect(video(rotation: 0, mirrored: true).isSensorNative == false)
        #expect(video(rotation: nil, mirrored: nil).isSensorNative == false)
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
