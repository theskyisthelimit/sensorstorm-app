import Foundation

/// Owns the on-disk layout of all recordings.
///
/// ```
/// Documents/Recordings/<uuid>/
///   metadata.json
///   annotations.json
///   accelerometer.ssbin, gyroscope.ssbin, …
///   video.mov
/// ```
///
/// One self-contained folder per recording means export is a copy, delete is a single
/// `removeItem`, and a half-written recording can never corrupt its neighbours.
public struct RecordingStore: Sendable {
    public let root: URL

    public static let metadataFileName = "metadata.json"
    public static let annotationsFileName = "annotations.json"
    public static let videoFileName = "video.mov"

    public init(root: URL) {
        self.root = root
    }

    public static func makeDefault() throws -> RecordingStore {
        let documents = try FileManager.default.url(for: .documentDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        let root = documents.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return RecordingStore(root: root)
    }

    // MARK: - Layout

    public func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    @discardableResult
    public func prepareDirectory(for id: UUID) throws -> URL {
        let url = directory(for: id)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func videoURL(for metadata: RecordingMetadata) -> URL? {
        guard let video = metadata.video else { return nil }
        let url = directory(for: metadata.id).appendingPathComponent(video.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func streamURL(for sensor: SensorID, recording id: UUID) -> URL {
        directory(for: id).appendingPathComponent("\(sensor.rawValue).ssbin")
    }

    public func reader(for sensor: SensorID, recording id: UUID) -> StreamReader? {
        let url = streamURL(for: sensor, recording: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? StreamReader(url: url)
    }

    // MARK: - Metadata

    public func save(_ metadata: RecordingMetadata) throws {
        try prepareDirectory(for: metadata.id)
        let data = try Self.encoder.encode(metadata)
        try data.write(to: directory(for: metadata.id)
            .appendingPathComponent(Self.metadataFileName), options: .atomic)
    }

    public func loadMetadata(id: UUID) throws -> RecordingMetadata {
        let url = directory(for: id).appendingPathComponent(Self.metadataFileName)
        return try Self.decoder.decode(RecordingMetadata.self, from: Data(contentsOf: url))
    }

    /// All readable recordings, newest first. Folders without valid metadata are skipped
    /// rather than surfaced as errors — those are crashed or half-deleted recordings.
    public func allRecordings() -> [RecordingMetadata] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []

        return contents
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
            .compactMap { try? loadMetadata(id: $0) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func delete(_ id: UUID) throws {
        let url = directory(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Annotations

    public func annotations(for id: UUID) -> [Annotation] {
        let url = directory(for: id).appendingPathComponent(Self.annotationsFileName)
        guard let data = try? Data(contentsOf: url),
              let list = try? Self.decoder.decode([Annotation].self, from: data) else { return [] }
        return list.sorted { $0.hostTime < $1.hostTime }
    }

    public func saveAnnotations(_ annotations: [Annotation], for id: UUID) throws {
        try prepareDirectory(for: id)
        let data = try Self.encoder.encode(annotations.sorted { $0.hostTime < $1.hostTime })
        try data.write(to: directory(for: id)
            .appendingPathComponent(Self.annotationsFileName), options: .atomic)
    }

    // MARK: - Size

    public func byteSize(of id: UUID) -> Int64 {
        let url = directory(for: id)
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    public var totalByteSize: Int64 {
        allRecordings().reduce(0) { $0 + byteSize(of: $1.id) }
    }

    // MARK: - Coding

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
