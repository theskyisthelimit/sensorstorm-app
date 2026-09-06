import Foundation

/// The whole recording as one self-describing JSON file.
///
/// Written by hand rather than through `JSONEncoder`, for the same reason the CSV writer
/// streams: a half-hour recording at 400 Hz is millions of samples, and building the whole
/// document as `[[Double]]` before encoding it would spike memory into the hundreds of
/// megabytes on a phone that is also holding a video file.
///
/// Unlike ``CombinedCSVExporter`` nothing is resampled here. Each stream keeps the
/// timestamps it was measured at, because JSON has no problem with ragged arrays and the
/// caller can decide for itself whether it wants a grid.
public struct JSONExporter: Sendable {
    public static let fileName = "recording.json"
    public static let schema = "sensorstorm.recording"
    public static let schemaVersion = 1

    private let store: RecordingStore

    public init(store: RecordingStore) {
        self.store = store
    }

    public func write(_ metadata: RecordingMetadata, to url: URL,
                      progress: (@Sendable (Double) -> Void)? = nil) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var out = ""
        out.reserveCapacity(1 << 16)

        func flush(force: Bool = false) throws {
            if force || out.utf8.count > 1 << 15 {
                try handle.write(contentsOf: Data(out.utf8))
                out.removeAll(keepingCapacity: true)
            }
        }

        let epochAtStart = metadata.startedAt.timeIntervalSince1970
        let streams = metadata.streams.filter { $0.sampleCount > 0 }

        out += "{\n"
        out += "  \"schema\": \(Self.string(Self.schema)),\n"
        out += "  \"schemaVersion\": \(Self.schemaVersion),\n"
        out += "  \"conventions\": {\n"
        out += "    \"time\": \"seconds since the start of the recording\",\n"
        out += "    \"epoch\": \"Unix time in seconds, UTC\",\n"
        out += "    \"clock\": \"every stream shares one host clock; samples with the same time were taken at the same instant\",\n"
        out += "    \"resampling\": \"none — each stream keeps the timestamps it was measured at\"\n"
        out += "  },\n"
        out += "  \"recording\": {\n"
        out += "    \"id\": \(Self.string(metadata.id.uuidString)),\n"
        out += "    \"name\": \(Self.string(metadata.name)),\n"
        out += "    \"startedAt\": \(Self.string(metadata.startedAt.formatted(.iso8601))),\n"
        out += "    \"startEpoch\": \(Self.number(epochAtStart)),\n"
        out += "    \"duration\": \(Self.number(metadata.duration)),\n"
        out += "    \"requestedRateHz\": \(Self.number(metadata.requestedRateHz)),\n"
        out += "    \"device\": {\n"
        out += "      \"model\": \(Self.string(metadata.device.model)),\n"
        out += "      \"systemName\": \(Self.string(metadata.device.systemName)),\n"
        out += "      \"systemVersion\": \(Self.string(metadata.device.systemVersion)),\n"
        out += "      \"appVersion\": \(Self.string(metadata.device.appVersion))\n"
        out += "    }\n"
        out += "  },\n"
        out += "  \"streams\": [\n"

        for (streamIndex, stream) in streams.enumerated() {
            let descriptor = stream.sensor.descriptor
            out += "    {\n"
            out += "      \"sensor\": \(Self.string(stream.sensor.rawValue)),\n"
            out += "      \"channels\": [\(stream.channels.map(Self.string).joined(separator: ", "))],\n"
            out += "      \"units\": [\(descriptor.channelUnits.map(Self.string).joined(separator: ", "))],\n"
            out += "      \"sampleCount\": \(stream.sampleCount),\n"
            out += "      \"effectiveRateHz\": \(Self.number(stream.effectiveRateHz)),\n"
            out += "      \"samples\": ["

            if let reader = store.reader(for: stream.sensor, recording: metadata.id) {
                var first = true
                try reader.forEachSample { hostTime, values in
                    out += first ? "\n        [" : ",\n        ["
                    first = false
                    out += Self.number(hostTime - metadata.startHostTime)
                    for value in values {
                        out += ", "
                        out += Self.number(value)
                    }
                    out += "]"
                    try flush()
                }
                if !first { out += "\n      " }
            }
            out += "]\n"
            out += streamIndex == streams.count - 1 ? "    }\n" : "    },\n"
            try flush()
            progress?(Double(streamIndex + 1) / Double(max(streams.count, 1)))
        }

        out += "  ],\n"
        out += "  \"annotations\": ["
        let annotations = store.annotations(for: metadata.id)
        for (index, annotation) in annotations.enumerated() {
            let relative = annotation.hostTime - metadata.startHostTime
            out += index == 0 ? "\n    {" : ",\n    {"
            out += "\"time\": \(Self.number(relative)), "
            out += "\"epoch\": \(Self.number(epochAtStart + relative)), "
            out += "\"text\": \(Self.string(annotation.text))}"
        }
        if !annotations.isEmpty { out += "\n  " }
        out += "]\n"
        out += "}\n"

        try flush(force: true)
        progress?(1)
    }

    // MARK: - Literals

    /// A JSON string literal. Everything a parser could choke on is escaped, including the
    /// control characters below 0x20 that JSON forbids raw.
    ///
    /// Public because the live streamer writes the same wire format by hand and must escape
    /// identically — two JSON writers in one product that disagree about a quote is a bug
    /// waiting for the first device name with an apostrophe in it.
    public static func string(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// JSON has no NaN and no infinity. `null` is the only honest way to write a value the
    /// sensor could not produce — writing 0 would be a reading that never happened.
    public static func number(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        return String(format: "%.12g", value)
    }
}
