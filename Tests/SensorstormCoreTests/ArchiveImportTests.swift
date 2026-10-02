import Foundation
import Testing
@testable import SensorstormCore

private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sensorstorm-import-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeStores(in root: URL, _ name: String) throws -> (SurveyStore, RecordingStore) {
    let surveys = root.appendingPathComponent("\(name)-surveys", isDirectory: true)
    let recordings = root.appendingPathComponent("\(name)-recordings", isDirectory: true)
    try FileManager.default.createDirectory(at: surveys, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    return (SurveyStore(root: surveys), RecordingStore(root: recordings))
}

@Suite("Zip lesen und Archiv einlesen")
struct ArchiveImportTests {

    @Test("Gespeicherte und gepackte Einträge kommen unverändert heraus")
    func zipReader() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }

        // Stored, with a nested path and a file read from disk in pieces.
        let big = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })
        let bigURL = root.appendingPathComponent("big.bin")
        try big.write(to: bigURL)
        let stored = root.appendingPathComponent("stored.zip")
        let writer = try ZipWriter(url: stored)
        try writer.add("a/b/hello.txt", Data("Grüezi".utf8))
        try writer.addFile("data/big.bin", from: bigURL)
        try writer.finish()

        let entries = try ZipReader.entries(of: stored)
        #expect(entries.map(\.name) == ["a/b/hello.txt", "data/big.bin"])
        let out = root.appendingPathComponent("out-stored")
        try ZipReader.extract(stored, to: out)
        #expect(try String(contentsOf: out.appendingPathComponent("a/b/hello.txt"), encoding: .utf8) == "Grüezi")
        #expect(try Data(contentsOf: out.appendingPathComponent("data/big.bin")) == big)

        // Deflated: what the system's zip makes, which is what a laptop hands over.
        let folder = root.appendingPathComponent("pack")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let text = String(repeating: "Sensorstorm misst alles. ", count: 20_000)
        try Data(text.utf8).write(to: folder.appendingPathComponent("sub/text.txt"))
        try big.write(to: folder.appendingPathComponent("random.bin"))
        let deflated = root.appendingPathComponent("deflated.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", deflated.path, "."]
        process.currentDirectoryURL = folder
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let packed = try ZipReader.entries(of: deflated)
        #expect(packed.contains { $0.name == "sub/text.txt" && $0.method == 8 })
        let out2 = root.appendingPathComponent("out-deflated")
        try ZipReader.extract(deflated, to: out2)
        #expect(try String(contentsOf: out2.appendingPathComponent("sub/text.txt"), encoding: .utf8) == text)
        #expect(try Data(contentsOf: out2.appendingPathComponent("random.bin")) == big)
    }

    @Test("Ein Zip mit Pfad nach draussen wird abgelehnt, und eine Textdatei ist kein Zip")
    func hostileZip() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let evil = root.appendingPathComponent("evil.zip")
        let writer = try ZipWriter(url: evil)
        try writer.add("../escape.txt", Data("x".utf8))
        try writer.finish()
        #expect(throws: ZipReader.ZipError.unsafePath("../escape.txt")) {
            try ZipReader.extract(evil, to: root.appendingPathComponent("target"))
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.txt").path))

        let notZip = root.appendingPathComponent("plain.zip")
        try Data("das ist kein Archiv, nur Text, lang genug für die Prüfung.".utf8).write(to: notZip)
        #expect(throws: ZipReader.ZipError.notAZip) { _ = try ZipReader.entries(of: notZip) }

        // A corrupted byte in the data fails the checksum rather than writing garbage.
        let good = root.appendingPathComponent("good.zip")
        let w = try ZipWriter(url: good)
        try w.add("f.txt", Data("0123456789".utf8))
        try w.finish()
        var bytes = try Data(contentsOf: good)
        bytes[bytes.startIndex + 30 + 5 + 3] ^= 0xFF
        let broken = root.appendingPathComponent("broken.zip")
        try bytes.write(to: broken)
        #expect(throws: ZipReader.ZipError.corrupt("f.txt")) {
            try ZipReader.extract(broken, to: root.appendingPathComponent("target2"))
        }
    }

    @Test("Ein Export lässt sich auf einem anderen Gerät einlesen, zweimal ändert nichts")
    func roundTrip() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (sourceSurveys, sourceRecordings) = try makeStores(in: root, "source")
        let (targetSurveys, targetRecordings) = try makeStores(in: root, "target")

        var survey = Survey(name: "Quartier", startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        var item = GroundFinding(capturedAt: Date(timeIntervalSince1970: 1_700_000_100),
                                 location: FindingLocation(latitude: 46.948, longitude: 7.4474, horizontalAccuracy: 4),
                                 severity: 7, label: "Riss")
        item.add(try sourceSurveys.writePhoto(Data("jpeg-bytes".utf8), in: survey.id))
        survey.findings = [item]
        survey.track = [
            WalkPoint(time: survey.startedAt, latitude: 46.948, longitude: 7.4474, horizontalAccuracy: 3),
            WalkPoint(time: survey.startedAt.addingTimeInterval(30), latitude: 46.9485, longitude: 7.448, horizontalAccuracy: 3),
        ]
        try sourceSurveys.save(survey)

        // A recording, copied raw.
        var metadata = RecordingMetadata(
            name: "Fahrt", startedAt: Date(timeIntervalSince1970: 1_700_000_000), startHostTime: 10, duration: 5,
            device: DeviceInfo(model: "iPhone17,1", systemName: "iOS", systemVersion: "26.0", appVersion: "1.0.0"),
            requestedRateHz: 10)
        let directory = try sourceRecordings.prepareDirectory(for: metadata.id)
        let writer = try StreamWriter(sensor: .userAcceleration, channelCount: 3, directory: directory)
        writer.append(time: 10, values: [1, 2, 3])
        metadata.streams = [writer.close()]
        try sourceRecordings.save(metadata)

        let archive = try ArchiveExporter(surveyStore: sourceSurveys, recordingStore: sourceRecordings)
            .export(into: root.appendingPathComponent("out"),
                    options: .init(includesSurveys: true, includesRecordings: false, includesRawRecordings: true))

        let importer = ArchiveImporter(surveyStore: targetSurveys, recordingStore: targetRecordings)
        let first = try importer.importArchive(at: archive)
        #expect(first.surveysAdded == 1 && first.recordingsAdded == 1 && first.findings.added == 1)
        let loaded = try targetSurveys.load(id: survey.id)
        #expect(loaded.findings.count == 1 && loaded.track.count == 2)
        let photo = try #require(loaded.findings[0].photos.first)
        #expect(try Data(contentsOf: try #require(targetSurveys.url(for: photo, in: survey.id))) == Data("jpeg-bytes".utf8))
        let restored = try targetRecordings.loadMetadata(id: metadata.id)
        #expect(restored.name == "Fahrt")
        #expect(targetRecordings.reader(for: .userAcceleration, recording: metadata.id)?.sampleCount == 1)

        // Again: nothing is new.
        let second = try importer.importArchive(at: archive)
        #expect(second.surveysAdded == 0 && second.surveysUnchanged == 1 && second.recordingsAdded == 0)

        // Another phone changed the case since: the newer version comes in as a merge.
        var changed = loaded
        changed.findings[0].setStatus(.resolved, at: Date(timeIntervalSince1970: 1_800_000_000))
        try sourceSurveys.save(changed)
        let archive2 = try ArchiveExporter(surveyStore: sourceSurveys, recordingStore: sourceRecordings)
            .export(into: root.appendingPathComponent("out2"), options: .init(includesSurveys: true))
        let third = try importer.importArchive(at: archive2)
        #expect(third.surveysMerged == 1 && third.findings.updated == 1)
        #expect(try targetSurveys.load(id: survey.id).findings[0].status == .resolved)
    }

    @Test("Ein Archiv ohne Route und ohne Aufnahme ist ein Fehler")
    func nothingToImport() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (surveys, recordings) = try makeStores(in: root, "t")
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data("nichts".utf8).write(to: empty.appendingPathComponent("README.txt"))
        #expect(throws: ArchiveImporter.ImportError.nothingToImport) {
            _ = try ArchiveImporter(surveyStore: surveys, recordingStore: recordings).importTree(at: empty)
        }
    }

    @Test("Ein KMZ hat doc.kml an der Wurzel und die Fotos im Ordner files")
    func kmz() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (surveys, _) = try makeStores(in: root, "k")
        var survey = Survey(name: "KMZ")
        var item = GroundFinding(location: FindingLocation(latitude: 46.9, longitude: 7.4, horizontalAccuracy: 3), label: "Loch")
        item.add(try surveys.writePhoto(Data("foto".utf8), in: survey.id))
        survey.findings = [item]
        try surveys.save(survey)

        let url = root.appendingPathComponent("route.kmz")
        try KMZExporter(store: surveys).write(survey, to: url)
        let names = try ZipReader.entries(of: url).map(\.name)
        #expect(names.first == "doc.kml" && names.count == 2 && names[1].hasPrefix("files/"))
        let out = root.appendingPathComponent("unzipped")
        try ZipReader.extract(url, to: out)
        let kml = try String(contentsOf: out.appendingPathComponent("doc.kml"), encoding: .utf8)
        #expect(kml.contains("&lt;img src=&quot;files/") || kml.contains("&lt;img src=\"files/"))
    }
}
