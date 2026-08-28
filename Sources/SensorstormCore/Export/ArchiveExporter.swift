import CryptoKit
import Foundation

/// Everything on the phone as one zip, with a `manifest.json` at its root that describes
/// the rest of it.
///
/// The per-item exports answer „gib mir diese eine Begehung für QGIS". This one answers a
/// different question: „nimm alles, was das Gerät hat, und lass es eine Maschine lesen."
/// The difference is the manifest. Without it a receiving script has to guess folder
/// names, sniff file types and re-parse GeoJSON to find out which photo belongs to which
/// case. With it, one JSON at a known path lists every file with its size and SHA-256, and
/// every case with its position, its accuracy figures and the relative paths of its media.
///
/// A nested zip per item would have been less code and unreadable without unpacking twice,
/// so everything is staged into one tree and zipped once.
public struct ArchiveExporter: Sendable {
    /// What goes in. Recordings are off by default: a walk is kilobytes, a 4K recording is
    /// gigabytes, and „alles exportieren" should not silently mean „warte zehn Minuten".
    public struct Options: Sendable {
        public var includesSurveys: Bool
        /// Photos and clips of the cases. Off writes the metadata and the four formats,
        /// which still name every file — a reader sees what exists, just not the bytes.
        public var includesSurveyMedia: Bool
        public var includesRecordings: Bool
        public var recordingFormat: RecordingExporter.Format

        public init(includesSurveys: Bool = true,
                    includesSurveyMedia: Bool = true,
                    includesRecordings: Bool = false,
                    recordingFormat: RecordingExporter.Format = .csvBundle) {
            self.includesSurveys = includesSurveys
            self.includesSurveyMedia = includesSurveyMedia
            self.includesRecordings = includesRecordings
            self.recordingFormat = recordingFormat
        }
    }

    public static let schema = "sensorstorm.archive"
    public static let schemaVersion = 1
    public static let manifestFileName = "manifest.json"
    public static let surveysFolder = "surveys"
    public static let recordingsFolder = "recordings"

    private let surveyStore: SurveyStore
    private let recordingStore: RecordingStore
    private let appVersion: String
    private let build: String

    public init(surveyStore: SurveyStore, recordingStore: RecordingStore,
                appVersion: String = "", build: String = "") {
        self.surveyStore = surveyStore
        self.recordingStore = recordingStore
        self.appVersion = appVersion
        self.build = build
    }

    /// Writes the archive into `destinationDirectory` and returns the `.zip`.
    ///
    /// - Parameter progress: called on the calling thread with 0…1.
    @discardableResult
    public func export(into destinationDirectory: URL,
                       options: Options = Options(),
                       exportedAt: Date = Date(),
                       progress: (@Sendable (Double) -> Void)? = nil) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let baseName = "Sensorstorm-Export-\(Self.stamp(exportedAt))"
        let staging = destinationDirectory
            .appendingPathComponent("staging-archive", isDirectory: true)
        let payload = staging.appendingPathComponent(baseName, isDirectory: true)
        if fileManager.fileExists(atPath: staging.path) {
            try fileManager.removeItem(at: staging)
        }
        try fileManager.createDirectory(at: payload, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        try writeTree(into: payload, options: options, exportedAt: exportedAt,
                      progress: progress)

        let destination = destinationDirectory.appendingPathComponent("\(baseName).zip")
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try ZipPackager.zip(directory: payload, to: destination)
        return destination
    }

    /// The archive's contents, written into an existing folder instead of a zip.
    ///
    /// The zip is the shipping container; this is what goes in it. Kept separate so the
    /// tests can assert against the tree the user actually receives without unzipping it
    /// first — and so a future „in Dateien ablegen" needs no second implementation.
    public func writeTree(into payload: URL,
                          options: Options = Options(),
                          exportedAt: Date = Date(),
                          progress: (@Sendable (Double) -> Void)? = nil) throws {
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)

        let surveys = options.includesSurveys ? surveyStore.allSurveys() : []
        let recordings = options.includesRecordings ? recordingStore.allRecordings() : []

        // One step per item plus one for the manifest, which has to hash every file that
        // was just written and is not free on a bundle full of video.
        let steps = Double(surveys.count + recordings.count + 1)
        var completed = 0.0

        var surveyEntries: [ArchiveManifest.SurveyEntry] = []
        let surveyExporter = SurveyExporter(store: surveyStore)
        for survey in surveys {
            let folderName = Self.folderName(survey.name.isEmpty ? "Begehung" : survey.name,
                                             id: survey.id)
            let relative = "\(Self.surveysFolder)/\(folderName)"
            try surveyExporter.writePayload(survey,
                                            into: payload.appendingPathComponent(relative,
                                                                                 isDirectory: true),
                                            includingMedia: options.includesSurveyMedia)
            surveyEntries.append(Self.entry(for: survey, at: relative,
                                            includesMedia: options.includesSurveyMedia))
            completed += 1
            progress?(completed / steps)
        }

        var recordingEntries: [ArchiveManifest.RecordingEntry] = []
        let recordingExporter = RecordingExporter(store: recordingStore)
        for metadata in recordings {
            let folderName = Self.folderName(metadata.name, id: metadata.id)
            let relative = "\(Self.recordingsFolder)/\(folderName)"
            try recordingExporter.write(metadata, format: options.recordingFormat,
                                        into: payload.appendingPathComponent(relative,
                                                                             isDirectory: true))
            recordingEntries.append(Self.entry(for: metadata, at: relative,
                                               format: options.recordingFormat))
            completed += 1
            progress?(completed / steps)
        }

        try Data(Self.readme(surveys: surveyEntries.count,
                             recordings: recordingEntries.count).utf8)
            .write(to: payload.appendingPathComponent("README.txt"), options: .atomic)

        // Hashing last, over the finished tree: the inventory then describes exactly what
        // is in the zip, including the README and every file the sub-exporters wrote
        // without this one having to know their names.
        let files = try Self.inventory(of: payload)
        let manifest = ArchiveManifest(
            schema: Self.schema,
            schemaVersion: Self.schemaVersion,
            generator: .init(app: "Sensorstorm", version: appVersion, build: build,
                             platform: Self.platform),
            exportedAt: exportedAt,
            conventions: .standard,
            surveys: surveyEntries,
            recordings: recordingEntries,
            files: files
        )
        try Self.encoder.encode(manifest)
            .write(to: payload.appendingPathComponent(Self.manifestFileName), options: .atomic)
        progress?(1)
    }

    // MARK: - Manifest entries

    private static func entry(for survey: Survey, at path: String,
                              includesMedia: Bool) -> ArchiveManifest.SurveyEntry {
        ArchiveManifest.SurveyEntry(
            id: survey.id,
            name: survey.name,
            startedAt: survey.startedAt,
            notes: survey.notes,
            recordingID: survey.recordingID,
            path: path,
            findingCount: survey.findings.count,
            worstSeverity: survey.worstSeverity,
            averageSeverity: survey.averageSeverity,
            markedSquareMetres: survey.markedSquareMetres,
            geoJSON: "\(path)/findings.geojson",
            csv: "\(path)/findings.csv",
            gpx: "\(path)/findings.gpx",
            kml: "\(path)/findings.kml",
            source: "\(path)/\(SurveyStore.surveyFileName)",
            findings: survey.findingsByTime.map {
                finding(for: $0, in: path, includesMedia: includesMedia)
            }
        )
    }

    private static func finding(for finding: GroundFinding, in path: String,
                                includesMedia: Bool) -> ArchiveManifest.FindingEntry {
        let lv95 = finding.location.lv95
        return ArchiveManifest.FindingEntry(
            id: finding.id,
            capturedAt: finding.capturedAt,
            hostTime: finding.hostTime,
            severity: finding.severity,
            label: finding.label,
            note: finding.note,
            positionSource: finding.positionSource,
            latitude: finding.location.latitude,
            longitude: finding.location.longitude,
            altitude: finding.location.altitude,
            horizontalAccuracy: finding.location.horizontalAccuracy > 0
                ? finding.location.horizontalAccuracy : nil,
            uncertaintyRadius: finding.uncertaintyRadius,
            positionSampleCount: finding.positionSampleCount,
            positionSpread: finding.positionSpread,
            heading: finding.location.heading,
            lv95East: lv95.east,
            lv95North: lv95.north,
            gpsLatitude: finding.measuredLocation?.latitude,
            gpsLongitude: finding.measuredLocation?.longitude,
            gpsHorizontalAccuracy: finding.measuredLocation.flatMap {
                $0.horizontalAccuracy > 0 ? $0.horizontalAccuracy : nil
            },
            manualOffsetMetres: finding.manualOffsetMetres,
            recordingID: finding.recordingID,
            area: finding.area.flatMap(area(for:)),
            media: finding.media.map { item in
                ArchiveManifest.MediaEntry(
                    id: item.id,
                    kind: item.kind,
                    capturedAt: item.capturedAt,
                    duration: item.duration,
                    note: item.note,
                    fileName: item.fileName,
                    path: includesMedia
                        ? "\(path)/\(SurveyExporter.bundleMediaFolder)/\(item.fileName)"
                        : nil
                )
            }
        )
    }

    /// A circle is written both ways: its centre and radius, and the ring every consumer
    /// of a polygon needs. Handing over only the ring would lose the fact that it was a
    /// radius; handing over only the radius would make every reader redo the maths.
    private static func area(for area: FindingArea) -> ArchiveManifest.AreaEntry? {
        guard area.isValid else { return nil }
        return ArchiveManifest.AreaEntry(
            kind: area.kind,
            radius: area.kind == .circle ? area.radius : nil,
            squareMetres: area.squareMetres,
            ring: area.ring().map { [$0.longitude, $0.latitude] }
        )
    }

    private static func entry(for metadata: RecordingMetadata, at path: String,
                              format: RecordingExporter.Format) -> ArchiveManifest.RecordingEntry {
        let streams = metadata.streams.map { stream in
            ArchiveManifest.StreamEntry(
                sensor: stream.sensor.rawValue,
                channels: stream.channels,
                sampleCount: stream.sampleCount,
                unit: stream.unit,
                rateHz: stream.effectiveRateHz,
                path: format == .csvBundle && stream.sampleCount > 0
                    ? "\(path)/\(stream.sensor.rawValue).csv"
                    : nil
            )
        }
        return ArchiveManifest.RecordingEntry(
            id: metadata.id,
            name: metadata.name,
            startedAt: metadata.startedAt,
            startHostTime: metadata.startHostTime,
            durationSeconds: metadata.duration,
            notes: metadata.notes,
            path: path,
            format: format.rawValue,
            deviceModel: metadata.device.model,
            systemVersion: metadata.device.systemVersion,
            captureEngine: metadata.captureEngine?.rawValue,
            attitudeReferenceFrame: metadata.attitudeReferenceFrame?.rawValue,
            anchorLatitude: metadata.geodeticAnchor?.latitude,
            anchorLongitude: metadata.geodeticAnchor?.longitude,
            video: metadata.video.map { "\(path)/\($0.fileName)" },
            streams: streams
        )
    }

    // MARK: - Inventory

    /// Every file in the finished tree with its size and SHA-256, sorted by path.
    ///
    /// The hash is what makes the archive checkable after a trip through mail, a share
    /// sheet or a USB stick: a truncated video is otherwise a valid zip entry with the
    /// wrong number of bytes in it.
    static func inventory(of root: URL) throws -> [ArchiveManifest.FileEntry] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return [] }

        // Both sides resolved before they are compared: a temporary directory is handed out
        // as /var/… and enumerated as /private/var/…, and a plain string subtraction would
        // leave the machine's own paths in an archive meant for someone else's machine.
        let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents

        var entries: [ArchiveManifest.FileEntry] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let components = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            let relative = components.dropFirst(base.count).joined(separator: "/")
            entries.append(ArchiveManifest.FileEntry(
                path: relative,
                bytes: Int64(values.fileSize ?? 0),
                sha256: try sha256(of: url)
            ))
        }
        return entries.sorted { $0.path < $1.path }
    }

    /// Chunked on purpose: a 4K clip read in one `Data` is a few hundred megabytes resident
    /// on a phone that is also holding a staging copy of it.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Naming

    /// Name plus the first block of the UUID: two walks started in the same minute have the
    /// same name, and a folder that silently overwrote the other one would lose a walk.
    ///
    /// Spaces become hyphens here even though the per-item exports keep them. This archive
    /// is aimed at a script, and a path with a space in it is the thing that breaks the
    /// one-liner someone writes to loop over the folders.
    static func folderName(_ name: String, id: UUID) -> String {
        let base = RecordingExporter.sanitize(name)
            .replacingOccurrences(of: " ", with: "-")
        return "\(base.isEmpty ? "Eintrag" : base)-\(id.uuidString.prefix(8))"
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: date)
    }

    private static var platform: String {
        #if os(iOS)
        "iOS"
        #elseif os(macOS)
        "macOS"
        #else
        "unknown"
        #endif
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }()

    private static func readme(surveys: Int, recordings: Int) -> String {
        """
        Sensorstorm — Gesamtexport

        \(Self.manifestFileName) beschreibt dieses Archiv vollständig und maschinenlesbar:
        jede Datei mit Grösse und SHA-256, jede Begehung mit ihren Fällen, jede Aufnahme
        mit ihren Streams. Ein Skript liest \(Self.manifestFileName) und braucht sonst
        nichts über die Ordnerstruktur zu wissen. Die Liste "files" enthält jede Datei
        ausser \(Self.manifestFileName) selbst — sie wird geschrieben, nachdem alles
        andere feststeht.

        Enthalten: \(surveys) Begehungen, \(recordings) Aufnahmen.

        \(Self.surveysFolder)/<name>-<id>/
          survey.json        die Begehung und jeder Fall darin, wie auf dem Gerät
          findings.geojson   Punkte und Bereiche, EPSG:4326
          findings.csv       eine Zeile pro Fall, WGS84 und LV95 nebeneinander
          findings.gpx       Wegpunkte
          findings.kml       Google Earth, nach Bewertung eingefärbt
          media/             jedes Foto und jeder Clip

        \(Self.recordingsFolder)/<name>-<id>/
          metadata.json      Gerät, Streams, Zeitbasis
          <sensor>.csv       eine Datei pro Sensor, Spalte "time" ab Aufnahmebeginn
          video.mov          falls vorhanden

        Koordinaten: WGS84 (EPSG:4326), zusätzlich LV95 (EPSG:2056).
        Längen in Metern, Winkel in Grad, Zeitstempel ISO 8601 in UTC.
        Bewertung 1–10, 10 ist am schlimmsten.
        """
    }
}

/// The archive's table of contents — the file a receiving script opens first.
///
/// Deliberately flat and explicit: every path is relative to the archive root, every
/// measurement carries its unit in the field name or in ``Conventions``, and a value that
/// was never measured is absent rather than zero.
public struct ArchiveManifest: Codable, Sendable {
    public struct Generator: Codable, Sendable {
        public var app: String
        public var version: String
        public var build: String
        public var platform: String
    }

    /// What the numbers mean, stated once instead of in a README nobody parses.
    public struct Conventions: Codable, Sendable {
        public var geographicCRS: String
        public var projectedCRS: String
        public var lengthUnit: String
        public var angleUnit: String
        public var timestamps: String
        public var severityMinimum: Int
        public var severityMaximum: Int
        public var positionSources: [String]
        public var hostTime: String

        public static let standard = Conventions(
            geographicCRS: "EPSG:4326",
            projectedCRS: "EPSG:2056",
            lengthUnit: "metre",
            angleUnit: "degree",
            timestamps: "ISO 8601, UTC",
            severityMinimum: GroundFinding.severityRange.lowerBound,
            severityMaximum: GroundFinding.severityRange.upperBound,
            positionSources: PositionSource.allCases.map(\.rawValue),
            hostTime: "Seconds on the device's monotonic clock. Subtract a recording's "
                + "startHostTime for seconds since that recording began."
        )
    }

    public struct FileEntry: Codable, Sendable {
        public var path: String
        public var bytes: Int64
        public var sha256: String
    }

    public struct MediaEntry: Codable, Sendable {
        public var id: UUID
        public var kind: CaseMedia.Kind
        public var capturedAt: Date
        public var duration: TimeInterval?
        public var note: String
        public var fileName: String
        /// `nil` when the media were left out of this archive.
        public var path: String?
    }

    public struct AreaEntry: Codable, Sendable {
        public var kind: FindingArea.Kind
        public var radius: Double?
        public var squareMetres: Double
        /// Closed in order, `[longitude, latitude]` per point — GeoJSON's axis order.
        public var ring: [[Double]]
    }

    public struct FindingEntry: Codable, Sendable {
        public var id: UUID
        public var capturedAt: Date
        public var hostTime: Double
        public var severity: Int
        public var label: String
        public var note: String
        public var positionSource: PositionSource
        public var latitude: Double
        public var longitude: Double
        public var altitude: Double?
        public var horizontalAccuracy: Double?
        public var uncertaintyRadius: Double?
        public var positionSampleCount: Int?
        public var positionSpread: Double?
        public var heading: Double?
        public var lv95East: Double
        public var lv95North: Double
        public var gpsLatitude: Double?
        public var gpsLongitude: Double?
        public var gpsHorizontalAccuracy: Double?
        public var manualOffsetMetres: Double?
        public var recordingID: UUID?
        public var area: AreaEntry?
        public var media: [MediaEntry]
    }

    public struct SurveyEntry: Codable, Sendable {
        public var id: UUID
        public var name: String
        public var startedAt: Date
        public var notes: String
        public var recordingID: UUID?
        public var path: String
        public var findingCount: Int
        public var worstSeverity: Int?
        public var averageSeverity: Double?
        public var markedSquareMetres: Double
        public var geoJSON: String
        public var csv: String
        public var gpx: String
        public var kml: String
        public var source: String
        public var findings: [FindingEntry]
    }

    public struct StreamEntry: Codable, Sendable {
        public var sensor: String
        public var channels: [String]
        public var sampleCount: Int
        public var unit: String
        /// Samples per second actually achieved, measured over the recording.
        public var rateHz: Double
        public var path: String?
    }

    public struct RecordingEntry: Codable, Sendable {
        public var id: UUID
        public var name: String
        public var startedAt: Date
        public var startHostTime: Double
        public var durationSeconds: TimeInterval
        public var notes: String
        public var path: String
        public var format: String
        public var deviceModel: String
        public var systemVersion: String
        public var captureEngine: String?
        public var attitudeReferenceFrame: String?
        public var anchorLatitude: Double?
        public var anchorLongitude: Double?
        public var video: String?
        public var streams: [StreamEntry]
    }

    public var schema: String
    public var schemaVersion: Int
    public var generator: Generator
    public var exportedAt: Date
    public var conventions: Conventions
    public var surveys: [SurveyEntry]
    public var recordings: [RecordingEntry]
    public var files: [FileEntry]
}
