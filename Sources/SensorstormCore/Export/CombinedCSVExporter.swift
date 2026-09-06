import Foundation

/// Every sensor in one table, on one time grid.
///
/// The per-sensor CSVs keep each stream at the rate it was actually sampled at. That is the
/// honest thing to write and the awkward thing to read: a 400 Hz accelerometer and a 1 Hz
/// GPS fix have no rows in common, so a dataframe wants a join before it wants anything
/// else. This exporter answers the other question — „gib mir eine Tabelle" — and pays for
/// it with a resampling that is stated rather than hidden.
///
/// **The resampling is a zero-order hold.** Every column carries the last value that was
/// actually measured at or before the row's timestamp. Nothing is interpolated, on purpose:
/// interpolating between two GPS fixes invents a position the receiver never reported, and
/// interpolating a step counter invents fractions of a step. A held value is at least a
/// measurement that happened, and the `age` columns say how stale each one was allowed to
/// get. Cells before a stream's first sample stay empty rather than being back-filled.
public struct CombinedCSVExporter: Sendable {
    public static let fileName = "combined.csv"

    private let store: RecordingStore

    public init(store: RecordingStore) {
        self.store = store
    }

    /// Rows per second on the output grid.
    ///
    /// Defaults to the rate the recording was asked for. Going faster than that cannot add
    /// information — it would only repeat held values — and going slower silently drops
    /// samples the user chose to pay for in battery.
    public static func defaultRate(for metadata: RecordingMetadata) -> Double {
        let requested = metadata.requestedRateHz
        return requested.isFinite && requested > 0 ? requested : 100
    }

    /// - Parameter includesAge: adds one `<sensor>_age` column per stream, holding the
    ///   seconds since that stream's value was actually measured. Off by default because it
    ///   doubles the column count; on, it is the difference between a table you can trust
    ///   and one where a stale GPS fix looks exactly like a fresh one.
    public func write(_ metadata: RecordingMetadata,
                      rateHz: Double? = nil,
                      includesAge: Bool = true,
                      to url: URL,
                      progress: (@Sendable (Double) -> Void)? = nil) throws {
        let rate = rateHz ?? Self.defaultRate(for: metadata)
        let streams = metadata.streams.filter { $0.sampleCount > 0 }
        let readers = streams.compactMap { stream in
            store.reader(for: stream.sensor, recording: metadata.id).map { (stream, $0) }
        }

        var header = "time,epoch"
        for (stream, _) in readers {
            for channel in stream.channels {
                header += "," + Self.column(stream.sensor, channel)
            }
            if includesAge {
                header += "," + Self.column(stream.sensor, "age")
            }
        }
        header += "\n"

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(header.utf8))

        let epochAtStart = metadata.startedAt.timeIntervalSince1970
        let duration = max(metadata.duration, 0)
        let rowCount = Int((duration * rate).rounded(.down)) + 1

        // One cursor per stream, advanced forwards. The grid is monotonic and so is every
        // stream, so the whole table is one linear pass — a binary search per cell would
        // turn a half-hour recording at 400 Hz into millions of them for no benefit.
        var cursors = [Int](repeating: -1, count: readers.count)

        var out = ""
        out.reserveCapacity(1 << 16)

        for row in 0..<rowCount {
            let relative = Double(row) / rate
            let target = metadata.startHostTime + relative

            out += Self.fixed(relative)
            out += ","
            out += Self.fixed(epochAtStart + relative)

            for (index, entry) in readers.enumerated() {
                let (stream, reader) = entry
                var cursor = cursors[index]
                while cursor + 1 < reader.sampleCount, reader.time(at: cursor + 1) <= target {
                    cursor += 1
                }
                cursors[index] = cursor

                if cursor >= 0 {
                    for channel in 0..<min(stream.channels.count, reader.channelCount) {
                        out += ","
                        out += Self.number(reader.value(at: cursor, channel: channel))
                    }
                    // Pad if the metadata claims more channels than the file carries, so
                    // the row never comes up short against the header.
                    if stream.channels.count > reader.channelCount {
                        out += String(repeating: ",", count: stream.channels.count - reader.channelCount)
                    }
                    if includesAge {
                        out += ","
                        out += Self.fixed(target - reader.time(at: cursor))
                    }
                } else {
                    // Nothing measured yet. Empty, not zero: a zero is a reading.
                    out += String(repeating: ",", count: stream.channels.count + (includesAge ? 1 : 0))
                }
            }
            out += "\n"

            if row % 4096 == 0 {
                try handle.write(contentsOf: Data(out.utf8))
                out.removeAll(keepingCapacity: true)
                progress?(Double(row) / Double(max(rowCount, 1)))
            }
        }
        if !out.isEmpty {
            try handle.write(contentsOf: Data(out.utf8))
        }
        progress?(1)
    }

    /// A column name that survives a trip through pandas, R and a spreadsheet: letters,
    /// digits and underscores only.
    static func column(_ sensor: SensorID, _ channel: String) -> String {
        var cleaned = ""
        for character in channel {
            if character.isLetter || character.isNumber {
                cleaned.append(character)
            } else if !cleaned.hasSuffix("_") {
                cleaned.append("_")
            }
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return cleaned.isEmpty ? sensor.rawValue : "\(sensor.rawValue)_\(cleaned)"
    }

    static func fixed(_ value: Double) -> String {
        RecordingExporter.fixed(value)
    }

    static func number(_ value: Double) -> String {
        RecordingExporter.number(value)
    }
}
