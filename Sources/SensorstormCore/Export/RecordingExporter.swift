import Foundation

/// Turns a recording into a self-describing `.zip`: one CSV per sensor, the annotations,
/// the untouched video file and the raw `metadata.json`.
///
/// CSV is the lowest common denominator every analysis tool reads. Values are written with
/// 12 significant digits — enough to round-trip a latitude to well under a millimetre, and
/// tight enough to avoid `0.30000000000000004` noise.
public struct RecordingExporter: Sendable {
    public enum Format: String, Sendable, CaseIterable {
        /// One CSV per sensor plus video and metadata, zipped.
        case csvBundle
        /// The recording folder as it is on disk (binary streams), zipped.
        case rawBundle
        /// Camera poses per video frame plus the video and the GPS track, for Blender and
        /// other 3D tools. See ``SceneBundleExporter``.
        case sceneBundle
        /// Sensor Logger's file and column layout, so that ecosystem's parsers and notebooks
        /// read the recording unmodified. See ``InteropExporter``.
        case sensorLoggerBundle
        /// A Gyroflow `.gcsv` IMU log for stabilising the video after the fact.
        case gyroflowLog
    }

    private let store: RecordingStore

    public init(store: RecordingStore) {
        self.store = store
    }

    /// Writes the export into `destinationDirectory` and returns the resulting `.zip`.
    ///
    /// - Parameter progress: called on the calling thread with 0…1.
    public func export(_ metadata: RecordingMetadata,
                       format: Format,
                       into destinationDirectory: URL,
                       progress: (@Sendable (Double) -> Void)? = nil) throws -> URL {
        let fileManager = FileManager.default
        let folderName = Self.sanitize(metadata.name)
        let staging = destinationDirectory
            .appendingPathComponent("staging-\(metadata.id.uuidString)", isDirectory: true)
        let payload = staging.appendingPathComponent(folderName, isDirectory: true)

        if fileManager.fileExists(atPath: staging.path) {
            try fileManager.removeItem(at: staging)
        }
        try fileManager.createDirectory(at: payload, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        try write(metadata, format: format, into: payload, progress: progress)

        let zipURL = destinationDirectory.appendingPathComponent("\(folderName).zip")
        if fileManager.fileExists(atPath: zipURL.path) {
            try fileManager.removeItem(at: zipURL)
        }
        try ZipPackager.zip(directory: payload, to: zipURL)
        progress?(1)
        return zipURL
    }

    /// The export's contents, written into an existing folder instead of a zip.
    ///
    /// Split out for the whole-archive export, which collects many recordings and walks
    /// into one staging tree and zips that once.
    public func write(_ metadata: RecordingMetadata, format: Format, into folder: URL,
                      progress: (@Sendable (Double) -> Void)? = nil) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        switch format {
        case .csvBundle:
            try writeCSVBundle(metadata, into: folder, progress: progress)
        case .rawBundle:
            try copyRawBundle(metadata, into: folder, progress: progress)
        case .sceneBundle:
            try SceneBundleExporter(store: store)
                .write(metadata, into: folder, progress: progress)
        case .sensorLoggerBundle:
            try writeSensorLoggerBundle(metadata, into: folder, progress: progress)
        case .gyroflowLog:
            try writeGyroflowLog(metadata, into: folder)
        }
    }

    // MARK: - CSV bundle

    private func writeCSVBundle(_ metadata: RecordingMetadata, into folder: URL,
                                progress: (@Sendable (Double) -> Void)?) throws {
        let streams = metadata.streams.filter { $0.sampleCount > 0 }
        let steps = Double(streams.count + 3)
        var completed = 0.0

        for stream in streams {
            if let reader = store.reader(for: stream.sensor, recording: metadata.id) {
                try writeCSV(reader: reader, stream: stream, metadata: metadata,
                             to: folder.appendingPathComponent("\(stream.sensor.rawValue).csv"))
            }
            completed += 1
            progress?(completed / steps)
        }

        try writeAnnotationsCSV(metadata, to: folder.appendingPathComponent("annotations.csv"))
        completed += 1
        progress?(completed / steps)

        try RecordingStore.encoder.encode(metadata)
            .write(to: folder.appendingPathComponent("metadata.json"), options: .atomic)
        try readme(for: metadata).data(using: .utf8)?
            .write(to: folder.appendingPathComponent("README.txt"), options: .atomic)
        completed += 1
        progress?(completed / steps)

        if let videoURL = store.videoURL(for: metadata), let video = metadata.video {
            try FileManager.default.copyItem(
                at: videoURL, to: folder.appendingPathComponent(video.fileName))
        }
        if let audio = metadata.audio {
            let source = store.directory(for: metadata.id).appendingPathComponent(audio.fileName)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(
                    at: source, to: folder.appendingPathComponent(audio.fileName))
            }
        }
        progress?(1)
    }

    private func writeCSV(reader: StreamReader, stream: StreamInfo,
                          metadata: RecordingMetadata, to url: URL) throws {
        let epochAtStart = metadata.startedAt.timeIntervalSince1970
        var out = "time,epoch," + stream.channels.joined(separator: ",") + "\n"
        out.reserveCapacity(1 << 16)

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var index = 0
        try reader.forEachSample { hostTime, values in
            let relative = hostTime - metadata.startHostTime
            out += Self.fixed(relative)
            out += ","
            out += Self.fixed(epochAtStart + relative)
            for value in values {
                out += ","
                out += Self.number(value)
            }
            out += "\n"

            index += 1
            if index % 4096 == 0 {
                try handle.write(contentsOf: Data(out.utf8))
                out.removeAll(keepingCapacity: true)
            }
        }
        if !out.isEmpty {
            try handle.write(contentsOf: Data(out.utf8))
        }
    }

    private func writeAnnotationsCSV(_ metadata: RecordingMetadata, to url: URL) throws {
        let epochAtStart = metadata.startedAt.timeIntervalSince1970
        var out = "time,epoch,text\n"
        for annotation in store.annotations(for: metadata.id) {
            let relative = annotation.hostTime - metadata.startHostTime
            out += "\(Self.fixed(relative)),\(Self.fixed(epochAtStart + relative)),"
            out += Self.csvEscape(annotation.text)
            out += "\n"
        }
        try Data(out.utf8).write(to: url, options: .atomic)
    }

    // MARK: - Interop bundles

    private func writeSensorLoggerBundle(_ metadata: RecordingMetadata, into folder: URL,
                                         progress: (@Sendable (Double) -> Void)?) throws {
        let streams = metadata.streams.filter { $0.sampleCount > 0 }
        let steps = Double(streams.count + 2)
        var completed = 0.0

        for stream in streams {
            if let reader = store.reader(for: stream.sensor, recording: metadata.id) {
                let csv = InteropExporter.sensorLoggerCSV(reader: reader, stream: stream,
                                                          metadata: metadata)
                let name = InteropExporter.sensorLoggerFileName(for: stream.sensor)
                try Data(csv.utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
            }
            completed += 1
            progress?(completed / steps)
        }

        try Data(InteropExporter.sensorLoggerMetadataCSV(metadata).utf8)
            .write(to: folder.appendingPathComponent("metadata.csv"), options: .atomic)
        try writeAnnotationsCSV(metadata, to: folder.appendingPathComponent("Annotation.csv"))
        completed += 1
        progress?(completed / steps)

        try copyMedia(metadata, into: folder)
        progress?(1)
    }

    private func writeGyroflowLog(_ metadata: RecordingMetadata, into folder: URL) throws {
        guard let gyroscope = store.reader(for: .gyroscope, recording: metadata.id),
              gyroscope.sampleCount > 0 else {
            throw ExportError.noGyroscopeData
        }
        let log = InteropExporter.gcsv(
            gyroscope: gyroscope,
            accelerometer: store.reader(for: .accelerometer, recording: metadata.id),
            metadata: metadata)

        let name = "\(Self.sanitize(metadata.name)).gcsv"
        try Data(log.utf8).write(to: folder.appendingPathComponent(name), options: .atomic)

        if let video = metadata.video {
            // Gyroflow needs to know where the log starts relative to the movie; the number
            // is in the metadata, but nobody reads JSON while wiring up a stabiliser.
            let offset = video.offset(from: metadata.startHostTime)
            let note = """
            Gyroflow: load \(video.fileName) and this .gcsv together.

            The log's t = 0 is the start of the recording, and the first video frame sits
            \(Self.fixed(offset)) s after it. If Gyroflow's automatic sync does not land,
            that is the offset to enter by hand.

            Video stabilisation was off during capture on purpose, so the image and the IMU
            still describe the same motion — which is what makes this log usable at all.

            """
            try Data(note.utf8).write(to: folder.appendingPathComponent("README.txt"),
                                      options: .atomic)
        }
        try copyMedia(metadata, into: folder)
    }

    /// Copies the movie and any standalone audio file next to whatever was just written.
    private func copyMedia(_ metadata: RecordingMetadata, into folder: URL) throws {
        if let videoURL = store.videoURL(for: metadata), let video = metadata.video {
            try FileManager.default.copyItem(
                at: videoURL, to: folder.appendingPathComponent(video.fileName))
        }
        if let audio = metadata.audio {
            let source = store.directory(for: metadata.id).appendingPathComponent(audio.fileName)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(
                    at: source, to: folder.appendingPathComponent(audio.fileName))
            }
        }
    }

    // MARK: - Raw bundle

    private func copyRawBundle(_ metadata: RecordingMetadata, into folder: URL,
                               progress: (@Sendable (Double) -> Void)?) throws {
        let source = store.directory(for: metadata.id)
        let contents = try FileManager.default.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil)

        for (index, file) in contents.enumerated() {
            try FileManager.default.copyItem(
                at: file, to: folder.appendingPathComponent(file.lastPathComponent))
            progress?(Double(index + 1) / Double(max(contents.count, 1)))
        }
        try readme(for: metadata).data(using: .utf8)?
            .write(to: folder.appendingPathComponent("README.txt"), options: .atomic)
    }

    // MARK: - Helpers

    private func readme(for metadata: RecordingMetadata) -> String {
        var text = """
        Sensorstorm — \(metadata.name)
        \(metadata.startedAt.formatted(.iso8601))
        \(metadata.device.model), \(metadata.device.systemName) \(metadata.device.systemVersion)

        Columns
          time   seconds since recording start
          epoch  Unix time in seconds (UTC)

        All streams share one clock, so a row in one file lines up exactly with the row at
        the same `time` in every other file.

        Streams

        """

        for stream in metadata.streams where stream.sampleCount > 0 {
            let descriptor = stream.sensor.descriptor
            let columns = zip(stream.channels, descriptor.channelUnits)
                .map { $1.isEmpty ? $0 : "\($0) [\($1)]" }
                .joined(separator: ", ")
            text += "  \(stream.sensor.rawValue): \(stream.sampleCount) samples "
            text += "@ \(String(format: "%.1f", stream.effectiveRateHz)) Hz — \(columns)\n"
        }

        if let video = metadata.video {
            let offset = video.offset(from: metadata.startHostTime)
            text += """

            Video: \(video.fileName), \(video.width)×\(video.height) @ \
            \(String(format: "%.0f", video.nominalFrameRate)) fps
              First frame is at time = \(Self.fixed(offset)) s on the shared clock.
              To align: sensorTime = videoPlayerTime + \(Self.fixed(offset))

            """
        }
        return text
    }

    public enum ExportError: Error, LocalizedError {
        case noGyroscopeData

        public var errorDescription: String? {
            switch self {
            case .noGyroscopeData:
                String(localized: "Diese Aufnahme enthält keine Drehratendaten.")
            }
        }
    }

    static func fixed(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        return String(format: "%.6f", value)
    }

    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        return String(format: "%.12g", value)
    }

    static func csvEscape(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let separators: Set<Character> = ["-", "_", " "]

        var cleaned = ""
        for scalar in name.unicodeScalars {
            let character: Character = allowed.contains(scalar) ? Character(scalar) : "-"
            // Collapse any run of separators to the first one, so a default name like
            // "28.07.2026, 21:02" becomes "28-07-2026-21-02" and not "28-07-2026- 21-02".
            if separators.contains(character), let last = cleaned.last,
               separators.contains(last) {
                continue
            }
            cleaned.append(character)
        }

        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
        return cleaned.isEmpty ? "Recording" : cleaned
    }
}
