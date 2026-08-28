import Foundation

/// Owns the on-disk layout of all surveys — the ground-documentation side of the app.
///
/// ```
/// Documents/Surveys/<uuid>/
///   survey.json                    the walk and every finding in it
///   <finding-uuid>.jpg             the photo of the ground
///   <finding-uuid>.mov             the clip, when one was taken
/// ```
///
/// Deliberately the same shape as ``RecordingStore``: one self-contained folder, one JSON
/// sidecar, media next to it. Export is a copy, delete is a single `removeItem`, and a
/// survey folder can be pulled off the phone through Files.app and read without this app.
public struct SurveyStore: Sendable {
    public let root: URL

    public static let surveyFileName = "survey.json"

    public init(root: URL) {
        self.root = root
    }

    public static func makeDefault() throws -> SurveyStore {
        let documents = try FileManager.default.url(for: .documentDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        let root = documents.appendingPathComponent("Surveys", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return SurveyStore(root: root)
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

    // MARK: - Documents

    public func save(_ survey: Survey) throws {
        try prepareDirectory(for: survey.id)
        let data = try Self.encoder.encode(survey)
        try data.write(to: directory(for: survey.id)
            .appendingPathComponent(Self.surveyFileName), options: .atomic)
    }

    public func load(id: UUID) throws -> Survey {
        let url = directory(for: id).appendingPathComponent(Self.surveyFileName)
        return try Self.decoder.decode(Survey.self, from: Data(contentsOf: url))
    }

    /// All readable surveys, newest first. A folder without a readable `survey.json` is
    /// skipped rather than reported: that is a crashed or half-deleted walk, and there is
    /// nothing the list could show for it.
    public func allSurveys() -> [Survey] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []

        return contents
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
            .compactMap { try? load(id: $0) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func delete(_ id: UUID) throws {
        let url = directory(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Media

    /// The URL of a file inside a survey folder, or `nil` if it is not there. Returning
    /// `nil` for a missing file rather than a URL that does not resolve keeps every caller
    /// from having to check twice.
    public func mediaURL(_ fileName: String?, in surveyID: UUID) -> URL? {
        guard let fileName, !fileName.isEmpty else { return nil }
        let url = directory(for: surveyID).appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func url(for media: CaseMedia, in surveyID: UUID) -> URL? {
        mediaURL(media.fileName, in: surveyID)
    }

    /// Writes a still into the survey folder and returns the entry to hang on the case.
    public func writePhoto(_ data: Data, id: UUID = UUID(), capturedAt: Date = Date(),
                           in surveyID: UUID) throws -> CaseMedia {
        try prepareDirectory(for: surveyID)
        let fileName = CaseMedia.fileName(for: id, kind: .photo)
        try data.write(to: directory(for: surveyID).appendingPathComponent(fileName),
                       options: .atomic)
        return CaseMedia(id: id, kind: .photo, fileName: fileName, capturedAt: capturedAt)
    }

    /// Moves a freshly recorded clip out of the temporary directory into the survey folder.
    /// A move rather than a copy: a 4K clip is not worth writing twice, and the temporary
    /// copy would be deleted moments later anyway.
    public func importVideo(from url: URL, id: UUID = UUID(), capturedAt: Date = Date(),
                            duration: TimeInterval? = nil, in surveyID: UUID) throws -> CaseMedia {
        try prepareDirectory(for: surveyID)
        let fileName = CaseMedia.fileName(for: id, kind: .video)
        let destination = directory(for: surveyID).appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: url, to: destination)
        return CaseMedia(id: id, kind: .video, fileName: fileName,
                         capturedAt: capturedAt, duration: duration)
    }

    public func delete(_ media: CaseMedia, in surveyID: UUID) {
        guard let url = url(for: media, in: surveyID) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes every photo and clip of a case. Called when the case goes, because otherwise
    /// the bytes stay behind with nothing left to point at them.
    public func deleteMedia(of finding: GroundFinding, in surveyID: UUID) {
        for item in finding.media {
            delete(item, in: surveyID)
        }
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
        allSurveys().reduce(0) { $0 + byteSize(of: $1.id) }
    }

    // MARK: - Coding

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // A stray non-finite value must not cost the user a whole walk. The model keeps
        // them out, this is the net under it.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }()
}
