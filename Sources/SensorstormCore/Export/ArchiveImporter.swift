import Foundation

/// Takes an export back in — the other half of ``ArchiveExporter``, and the way a team puts
/// its phones together without a server.
///
/// What comes back is what the exporter wrote with the walk's own `survey.json` beside the
/// four formats: every route in the archive is merged into the one on this phone that has
/// the same id, or added when there is none. Raw recordings (`recordings-raw/`) are copied
/// in when this phone does not have them yet; the table exports of a recording cannot be
/// turned back into one and are left alone.
public struct ArchiveImporter: Sendable {

    public struct Result: Sendable, Equatable {
        /// Routes this phone did not have.
        public var surveysAdded = 0
        /// Routes both had, with something from the archive folded in.
        public var surveysMerged = 0
        /// Routes both had that the archive changed nothing in.
        public var surveysUnchanged = 0
        public var findings = SurveyMerge.Report()
        public var recordingsAdded = 0
        /// `survey.json` files that could not be read.
        public var unreadable = 0

        public var isEmpty: Bool { surveysAdded + surveysMerged + surveysUnchanged + recordingsAdded == 0 }
    }

    public enum ImportError: Error, LocalizedError, Equatable {
        case nothingToImport

        public var errorDescription: String? {
            String(localized: "Im Archiv liegt keine Route und keine Aufnahme, die sich übernehmen lässt.")
        }
    }

    private let surveyStore: SurveyStore
    private let recordingStore: RecordingStore

    public init(surveyStore: SurveyStore, recordingStore: RecordingStore) {
        self.surveyStore = surveyStore
        self.recordingStore = recordingStore
    }

    /// Unpacks a `.zip` in a scratch folder and imports from there.
    public func importArchive(at url: URL, progress: (@Sendable (Double) -> Void)? = nil) throws -> Result {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try ZipReader.extract(url, to: scratch) { progress?($0 * 0.7) }
        let result = try importTree(at: scratch)
        progress?(1)
        return result
    }

    /// Imports from an already unpacked folder.
    public func importTree(at folder: URL) throws -> Result {
        let fileManager = FileManager.default
        var result = Result()

        guard let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw ImportError.nothingToImport
        }
        var surveyFiles: [URL] = []
        var recordingFolders: [URL] = []
        for case let url as URL in enumerator {
            switch url.lastPathComponent {
            case SurveyStore.surveyFileName:
                surveyFiles.append(url)
            case RecordingStore.metadataFileName where url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "recordings-raw":
                recordingFolders.append(url.deletingLastPathComponent())
            default:
                break
            }
        }

        for file in surveyFiles.sorted(by: { $0.path < $1.path }) {
            guard let data = try? Data(contentsOf: file),
                  let incoming = try? SurveyStore.decoder.decode(Survey.self, from: data) else {
                result.unreadable += 1
                continue
            }
            let media = file.deletingLastPathComponent().appendingPathComponent("media", isDirectory: true)
            if let local = try? surveyStore.load(id: incoming.id) {
                let merged = SurveyMerge.merge(local: local, remote: incoming)
                if merged.report.changedAnything {
                    try surveyStore.save(merged.survey)
                    try copyMedia(of: incoming, from: media)
                    result.surveysMerged += 1
                    result.findings.added += merged.report.added
                    result.findings.updated += merged.report.updated
                    result.findings.trackPointsAdded += merged.report.trackPointsAdded
                } else {
                    result.surveysUnchanged += 1
                }
                result.findings.kept += merged.report.kept
            } else {
                try surveyStore.save(incoming)
                try copyMedia(of: incoming, from: media)
                result.surveysAdded += 1
                result.findings.added += incoming.findings.count
            }
        }

        for source in recordingFolders {
            guard let id = UUID(uuidString: source.lastPathComponent),
                  !fileManager.fileExists(atPath: recordingStore.directory(for: id).path) else { continue }
            try fileManager.copyItem(at: source, to: recordingStore.directory(for: id))
            result.recordingsAdded += 1
        }

        if result.isEmpty && result.unreadable == 0 { throw ImportError.nothingToImport }
        return result
    }

    /// Photos and clips of the incoming walk that this phone does not have, copied beside its
    /// `survey.json`. A file already there stays: ids are unique, so it is the same picture.
    private func copyMedia(of survey: Survey, from mediaFolder: URL) throws {
        let fileManager = FileManager.default
        let target = try surveyStore.prepareDirectory(for: survey.id)
        for finding in survey.findings {
            for item in finding.media {
                let source = mediaFolder.appendingPathComponent(item.fileName)
                let destination = target.appendingPathComponent(item.fileName)
                guard fileManager.fileExists(atPath: source.path),
                      !fileManager.fileExists(atPath: destination.path) else { continue }
                try fileManager.copyItem(at: source, to: destination)
            }
        }
    }
}
