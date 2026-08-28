import Foundation
import Testing
@testable import SensorstormCore

@Suite("Gesamtexport")
struct ArchiveTests {

    // MARK: - Fixture

    static let anchor = Coordinate2D(latitude: 46.9480, longitude: 7.4474)

    private func makeStores() throws -> (SurveyStore, RecordingStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensorstorm-archive-\(UUID().uuidString)", isDirectory: true)
        let surveys = root.appendingPathComponent("Surveys", isDirectory: true)
        let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: surveys, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        return (SurveyStore(root: surveys), RecordingStore(root: recordings), root)
    }

    private func makeLocation(_ coordinate: Coordinate2D = ArchiveTests.anchor,
                              accuracy: Double = 4) -> FindingLocation {
        FindingLocation(latitude: coordinate.latitude, longitude: coordinate.longitude,
                        altitude: 540, ellipsoidalAltitude: 590,
                        horizontalAccuracy: accuracy, verticalAccuracy: 6, heading: 182)
    }

    /// A walk with one case, a photo on disk and a marked circle — everything the manifest
    /// has a field for, so a missing one shows up as a failure rather than as an absent key
    /// nobody looked at.
    @discardableResult
    private func makeSurvey(in store: SurveyStore, name: String = "Begehung Marktgasse",
                            withPhoto: Bool = true) throws -> Survey {
        let surveyID = UUID()
        var media: [CaseMedia] = []
        if withPhoto {
            media.append(try store.writePhoto(Data("nicht wirklich ein JPEG".utf8),
                                              in: surveyID))
        }
        let finding = GroundFinding(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            hostTime: 1_234.5,
            location: makeLocation(),
            positionSource: .manual,
            measuredLocation: makeLocation(accuracy: 12),
            severity: 8,
            label: "Schlagloch",
            note: "Rand ausgebrochen",
            media: media,
            area: .circle(center: Self.anchor, radius: 5)
        )
        let survey = Survey(id: surveyID, name: name,
                            startedAt: Date(timeIntervalSince1970: 1_699_999_000),
                            findings: [finding])
        try store.save(survey)
        return survey
    }

    private func makeRecording(in store: RecordingStore, name: String = "Testfahrt") throws
        -> RecordingMetadata {
        var metadata = RecordingMetadata(
            name: name,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            startHostTime: 1_000,
            duration: 2,
            device: DeviceInfo(model: "iPhone17,1", systemName: "iOS",
                               systemVersion: "26.0", appVersion: "1.0.0"),
            requestedRateHz: 100
        )
        let directory = try store.prepareDirectory(for: metadata.id)
        let writer = try StreamWriter(sensor: .accelerometer, channelCount: 3,
                                      directory: directory)
        for step in 0..<10 {
            writer.append(time: 1_000 + Double(step) * 0.01, values: [Double(step), 0, 1])
        }
        var stream = writer.close()
        stream.channels = ["x", "y", "z"]
        stream.unit = "g"
        metadata.streams = [stream]
        try store.save(metadata)
        return metadata
    }

    private func manifest(in folder: URL) throws -> ArchiveManifest {
        let data = try Data(contentsOf: folder
            .appendingPathComponent(ArchiveExporter.manifestFileName))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ArchiveManifest.self, from: data)
    }

    /// The exporter zips its staging tree and throws it away, so the assertions run against
    /// a written-out copy of the same tree.
    private func exportUnzipped(_ exporter: ArchiveExporter, options: ArchiveExporter.Options,
                                into directory: URL) throws -> URL {
        let payload = directory.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try exporter.writeTree(into: payload, options: options,
                               exportedAt: Date(timeIntervalSince1970: 1_700_000_100))
        return payload
    }

    // MARK: - Tests

    @Test("Das Manifest führt jede Datei mit Grösse und Prüfsumme")
    func manifestListsEveryFile() throws {
        let (surveys, recordings, root) = try makeStores()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSurvey(in: surveys)

        let exporter = ArchiveExporter(surveyStore: surveys, recordingStore: recordings,
                                       appVersion: "1.0.0", build: "7")
        let payload = try exportUnzipped(exporter, options: .init(), into: root)
        let manifest = try manifest(in: payload)

        #expect(manifest.schema == ArchiveExporter.schema)
        #expect(manifest.schemaVersion == ArchiveExporter.schemaVersion)
        #expect(manifest.generator.build == "7")
        #expect(!manifest.files.isEmpty)

        // Every listed file exists with exactly the stated size and hash, and nothing in the
        // tree is missing from the list. That pair is the whole promise of the inventory.
        for entry in manifest.files where entry.path != ArchiveExporter.manifestFileName {
            let url = payload.appendingPathComponent(entry.path)
            let data = try Data(contentsOf: url)
            #expect(Int64(data.count) == entry.bytes)
            #expect(try ArchiveExporter.sha256(of: url) == entry.sha256)
        }

        let listed = Set(manifest.files.map(\.path))
        let onDisk = try ArchiveExporter.inventory(of: payload).map(\.path)
            .filter { $0 != ArchiveExporter.manifestFileName }
        for path in onDisk {
            #expect(listed.contains(path), "\(path) fehlt im Manifest")
        }
    }

    @Test("Jeder Fall steht mit Position, Genauigkeit und Medienpfad im Manifest")
    func findingsAreDescribed() throws {
        let (surveys, recordings, root) = try makeStores()
        defer { try? FileManager.default.removeItem(at: root) }
        let survey = try makeSurvey(in: surveys)

        let exporter = ArchiveExporter(surveyStore: surveys, recordingStore: recordings)
        let payload = try exportUnzipped(exporter, options: .init(), into: root)
        let manifest = try manifest(in: payload)

        let entry = try #require(manifest.surveys.first)
        #expect(entry.id == survey.id)
        #expect(entry.findingCount == 1)
        #expect(entry.worstSeverity == 8)

        let finding = try #require(entry.findings.first)
        #expect(finding.severity == 8)
        #expect(finding.positionSource == .manual)
        #expect(abs(finding.latitude - Self.anchor.latitude) < 1e-9)
        // LV95 is in the manifest so an office working in Swiss coordinates needs no
        // conversion step: Bern is around 2 600 000 / 1 200 000.
        #expect(abs(finding.lv95East - 2_600_670) < 500)
        #expect(abs(finding.lv95North - 1_199_650) < 500)
        #expect(finding.gpsLatitude != nil)
        #expect(finding.manualOffsetMetres != nil)

        let area = try #require(finding.area)
        #expect(area.kind == .circle)
        #expect(area.radius == 5)
        #expect(abs(area.squareMetres - .pi * 25) < 0.001)
        // GeoJSON axis order, so a reader can hand the ring straight to a GIS library.
        #expect(area.ring.allSatisfy { $0.count == 2 && $0[0] > 7 && $0[1] > 46 })

        let media = try #require(finding.media.first)
        let path = try #require(media.path)
        #expect(FileManager.default.fileExists(atPath: payload.appendingPathComponent(path).path))
        #expect(manifest.files.contains { $0.path == path })
    }

    @Test("Die vier Formate und survey.json liegen dort, wo das Manifest sie ansagt")
    func advertisedFilesExist() throws {
        let (surveys, recordings, root) = try makeStores()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSurvey(in: surveys)

        let exporter = ArchiveExporter(surveyStore: surveys, recordingStore: recordings)
        let payload = try exportUnzipped(exporter, options: .init(), into: root)
        let entry = try #require(try manifest(in: payload).surveys.first)

        for path in [entry.geoJSON, entry.csv, entry.gpx, entry.kml, entry.source] {
            #expect(FileManager.default.fileExists(
                atPath: payload.appendingPathComponent(path).path), "\(path) fehlt")
        }

        // The GeoJSON has to survive being read as JSON — an export that only looks right
        // in a text editor is not machine-readable.
        let data = try Data(contentsOf: payload.appendingPathComponent(entry.geoJSON))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["type"] as? String == "FeatureCollection")
    }

    @Test("Ohne Medien bleiben die Aufnahmen benannt, aber ohne Pfad")
    func mediaCanBeLeftOut() throws {
        let (surveys, recordings, root) = try makeStores()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSurvey(in: surveys)

        let exporter = ArchiveExporter(surveyStore: surveys, recordingStore: recordings)
        let payload = try exportUnzipped(exporter,
                                         options: .init(includesSurveyMedia: false), into: root)
        let manifest = try manifest(in: payload)
        let media = try #require(manifest.surveys.first?.findings.first?.media.first)

        #expect(media.path == nil)
        #expect(!media.fileName.isEmpty)
        #expect(!manifest.files.contains { $0.path.hasSuffix(media.fileName) })
    }

    @Test("Aufnahmen kommen mit ihren Streams dazu, wenn sie angehakt sind")
    func recordingsAreIncluded() throws {
        let (surveys, recordings, root) = try makeStores()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSurvey(in: surveys)
        let metadata = try makeRecording(in: recordings)

        let exporter = ArchiveExporter(surveyStore: surveys, recordingStore: recordings)
        let payload = try exportUnzipped(exporter,
                                         options: .init(includesRecordings: true), into: root)
        let manifest = try manifest(in: payload)

        let entry = try #require(manifest.recordings.first)
        #expect(entry.id == metadata.id)
        #expect(entry.durationSeconds == 2)
        let stream = try #require(entry.streams.first)
        #expect(stream.sampleCount == 10)
        let path = try #require(stream.path)
        let csv = try String(contentsOf: payload.appendingPathComponent(path), encoding: .utf8)
        #expect(csv.hasPrefix("time,epoch,x,y,z"))
        #expect(csv.split(separator: "\n").count == 11)
    }

    @Test("Gleichnamige Begehungen bekommen getrennte Ordner")
    func sameNamesDoNotCollide() throws {
        let (surveys, recordings, root) = try makeStores()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSurvey(in: surveys, name: "Begehung", withPhoto: false)
        try makeSurvey(in: surveys, name: "Begehung", withPhoto: false)

        let exporter = ArchiveExporter(surveyStore: surveys, recordingStore: recordings)
        let payload = try exportUnzipped(exporter, options: .init(), into: root)
        let manifest = try manifest(in: payload)

        #expect(manifest.surveys.count == 2)
        #expect(Set(manifest.surveys.map(\.path)).count == 2)
        for entry in manifest.surveys {
            #expect(FileManager.default.fileExists(
                atPath: payload.appendingPathComponent(entry.source).path))
        }
    }

    @Test("Der Export ist am Ende eine lesbare Zip-Datei")
    func exportProducesAZip() throws {
        let (surveys, recordings, root) = try makeStores()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeSurvey(in: surveys)

        let exporter = ArchiveExporter(surveyStore: surveys, recordingStore: recordings)
        let reported = Reported()
        let zip = try exporter.export(into: root.appendingPathComponent("out", isDirectory: true),
                                      progress: { reported.append($0) })

        #expect(zip.pathExtension == "zip")
        let size = try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int ?? 0
        #expect(size > 0)
        #expect(reported.values.last == 1)

        // A zip starts with "PK\u{3}\u{4}" — cheap proof that the file is an archive and
        // not a staging folder that was renamed.
        let handle = try FileHandle(forReadingFrom: zip)
        defer { try? handle.close() }
        #expect(try handle.read(upToCount: 4) == Data([0x50, 0x4B, 0x03, 0x04]))
    }
}

/// The progress callback is `@Sendable`, so the test collects into a locked box rather
/// than a captured `var`.
private final class Reported: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    func append(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
