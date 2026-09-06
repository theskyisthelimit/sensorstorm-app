import Foundation
import SQLite3

/// The recording as a single SQLite database: one table per sensor, plus `metadata`,
/// `streams` and `annotations`.
///
/// The format people reach for when a recording is too big for a spreadsheet and they would
/// rather write `SELECT` than a parser. Indexed on `time`, so „what was the acceleration
/// when the GPS said we were here" is a join rather than a scan.
///
/// Strings go in as escaped literals rather than bound parameters. There are only a handful
/// of them — the metadata rows and the annotations — and doing it this way keeps
/// `SQLITE_TRANSIENT`, whose Swift spelling is an `unsafeBitCast`, out of the file entirely.
/// The millions of numeric rows do use prepared statements, where it actually matters.
public struct SQLiteExporter: Sendable {
    public static let fileName = "recording.sqlite"

    public enum SQLiteError: Error, LocalizedError {
        case cannotOpen(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .cannotOpen(let name):
                String(localized: "Die Datenbank \(name) konnte nicht angelegt werden.")
            case .failed(let message):
                message
            }
        }
    }

    private let store: RecordingStore

    public init(store: RecordingStore) {
        self.store = store
    }

    public func write(_ metadata: RecordingMetadata, to url: URL,
                      progress: (@Sendable (Double) -> Void)? = nil) throws {
        try? FileManager.default.removeItem(at: url)

        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db = handle else {
            sqlite3_close(handle)
            throw SQLiteError.cannotOpen(url.lastPathComponent)
        }
        defer { sqlite3_close(db) }

        // The file is written once and read elsewhere; a rollback journal and an fsync per
        // transaction would only slow down an export that is already IO-bound.
        try exec(db, "PRAGMA journal_mode = OFF")
        try exec(db, "PRAGMA synchronous = OFF")
        try exec(db, "BEGIN")

        try writeMetadata(db, metadata)
        try writeStreams(db, metadata, progress: progress)
        try writeAnnotations(db, metadata)

        try exec(db, "COMMIT")
        progress?(1)
    }

    // MARK: - Tables

    private func writeMetadata(_ db: OpaquePointer, _ metadata: RecordingMetadata) throws {
        try exec(db, "CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT)")

        let epochAtStart = metadata.startedAt.timeIntervalSince1970
        var rows: [(String, String)] = [
            ("schema", "sensorstorm.recording"),
            ("schemaVersion", "1"),
            ("id", metadata.id.uuidString),
            ("name", metadata.name),
            ("startedAt", metadata.startedAt.formatted(.iso8601)),
            ("startEpoch", RecordingExporter.number(epochAtStart)),
            ("duration", RecordingExporter.number(metadata.duration)),
            ("requestedRateHz", RecordingExporter.number(metadata.requestedRateHz)),
            ("deviceModel", metadata.device.model),
            ("systemName", metadata.device.systemName),
            ("systemVersion", metadata.device.systemVersion),
            ("appVersion", metadata.device.appVersion),
            ("timeColumn", "seconds since the start of the recording"),
            ("epochColumn", "Unix time in seconds, UTC"),
            ("clock", "every table shares one host clock"),
        ]
        if let video = metadata.video {
            rows.append(("videoFile", video.fileName))
            rows.append(("videoOffset", RecordingExporter.number(video.offset(from: metadata.startHostTime))))
        }
        for (key, value) in rows {
            try exec(db, "INSERT INTO metadata VALUES (\(Self.literal(key)), \(Self.literal(value)))")
        }
    }

    private func writeStreams(_ db: OpaquePointer, _ metadata: RecordingMetadata,
                              progress: (@Sendable (Double) -> Void)?) throws {
        try exec(db, """
            CREATE TABLE streams (
                sensor TEXT PRIMARY KEY, table_name TEXT, channels TEXT, units TEXT,
                sample_count INTEGER, effective_rate_hz REAL)
            """)

        let streams = metadata.streams.filter { $0.sampleCount > 0 }
        let epochAtStart = metadata.startedAt.timeIntervalSince1970

        for (index, stream) in streams.enumerated() {
            let descriptor = stream.sensor.descriptor
            let table = Self.identifier(stream.sensor.rawValue)
            let columns = stream.channels.enumerated().map { position, name in
                Self.identifier(name.isEmpty ? "c\(position)" : name)
            }

            try exec(db, """
                INSERT INTO streams VALUES (
                    \(Self.literal(stream.sensor.rawValue)), \(Self.literal(table)),
                    \(Self.literal(stream.channels.joined(separator: ","))),
                    \(Self.literal(descriptor.channelUnits.joined(separator: ","))),
                    \(stream.sampleCount), \(RecordingExporter.number(stream.effectiveRateHz)))
                """)

            let definition = columns.map { "\"\($0)\" REAL" }.joined(separator: ", ")
            try exec(db, "CREATE TABLE \"\(table)\" (time REAL, epoch REAL, \(definition))")

            guard let reader = store.reader(for: stream.sensor, recording: metadata.id) else {
                continue
            }
            let placeholders = Array(repeating: "?", count: columns.count + 2).joined(separator: ", ")
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO \"\(table)\" VALUES (\(placeholders))",
                                     -1, &statement, nil) == SQLITE_OK, let insert = statement else {
                throw SQLiteError.failed(Self.message(db))
            }
            defer { sqlite3_finalize(insert) }

            try reader.forEachSample { hostTime, values in
                let relative = hostTime - metadata.startHostTime
                sqlite3_bind_double(insert, 1, relative)
                sqlite3_bind_double(insert, 2, epochAtStart + relative)
                for (position, value) in values.enumerated() where position < columns.count {
                    // SQLite has no NaN: a value the sensor could not produce becomes NULL
                    // rather than a number nobody measured.
                    if value.isFinite {
                        sqlite3_bind_double(insert, Int32(position + 3), value)
                    } else {
                        sqlite3_bind_null(insert, Int32(position + 3))
                    }
                }
                guard sqlite3_step(insert) == SQLITE_DONE else {
                    throw SQLiteError.failed(Self.message(db))
                }
                sqlite3_reset(insert)
            }

            try exec(db, "CREATE INDEX \"\(table)_time\" ON \"\(table)\" (time)")
            progress?(Double(index + 1) / Double(max(streams.count + 1, 1)))
        }
    }

    private func writeAnnotations(_ db: OpaquePointer, _ metadata: RecordingMetadata) throws {
        try exec(db, "CREATE TABLE annotations (time REAL, epoch REAL, text TEXT)")
        let epochAtStart = metadata.startedAt.timeIntervalSince1970
        for annotation in store.annotations(for: metadata.id) {
            let relative = annotation.hostTime - metadata.startHostTime
            try exec(db, """
                INSERT INTO annotations VALUES (
                    \(RecordingExporter.number(relative)),
                    \(RecordingExporter.number(epochAtStart + relative)),
                    \(Self.literal(annotation.text)))
                """)
        }
    }

    // MARK: - Plumbing

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.failed(Self.message(db))
        }
    }

    private static func message(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }

    /// A single-quoted SQL string literal.
    static func literal(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// A table or column name safe to interpolate: letters, digits and underscores, never
    /// starting with a digit. Everything here comes from our own catalog rather than from
    /// user input, but a name is still not a place to find out.
    static func identifier(_ value: String) -> String {
        var cleaned = ""
        for character in value {
            if character.isLetter || character.isNumber {
                cleaned.append(character)
            } else if !cleaned.hasSuffix("_") && !cleaned.isEmpty {
                cleaned.append("_")
            }
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if cleaned.isEmpty { return "unnamed" }
        return cleaned.first!.isNumber ? "n\(cleaned)" : cleaned
    }
}
