import Foundation

/// One stream as an exporter sees it: a name that is safe as a file, table, sheet and
/// column prefix, the channels and units, and the samples.
///
/// Built-in sensors and external streams used to be two different things to every exporter.
/// This is the one thing they iterate instead — a Bluetooth thermometer lands in the CSV,
/// the JSON, the database and the workbook exactly as the accelerometer does.
struct ExportStream {
    /// `accelerometer`, or `ext_ble_4f2a1c3d_ruuvitag_1a2b3c` — letters, digits, underscore.
    let key: String
    /// What a person calls it. Empty for built-in sensors, whose key already reads well.
    let title: String
    let channels: [String]
    let units: [String]
    let sampleCount: Int
    let effectiveRateHz: Double
    let reader: StreamReader
    /// The external stream's stable id, `nil` for built-in sensors.
    let externalID: String?

    var isExternal: Bool { externalID != nil }

    /// Sheet names stop at 31 characters and may not repeat; a readable prefix plus six
    /// characters of the hash stays under that and stays unique.
    static func key(for info: ExternalStreamInfo) -> String {
        let readable = ExternalStreamInfo.slug(info.id).replacingOccurrences(of: "-", with: "_")
        let hash = ExternalStreamInfo.hash(info.id).prefix(6)
        return "ext_\(readable.prefix(18))_\(hash)"
    }
}

extension RecordingStore {
    /// Every stream of a recording that has samples and a readable file, built-in sensors
    /// first in the metadata's order, then external streams sorted by id.
    func exportStreams(for metadata: RecordingMetadata) -> [ExportStream] {
        var result: [ExportStream] = []
        for stream in metadata.streams where stream.sampleCount > 0 {
            guard let reader = reader(for: stream.sensor, recording: metadata.id) else { continue }
            result.append(ExportStream(
                key: stream.sensor.rawValue, title: "",
                channels: stream.channels, units: stream.sensor.descriptor.channelUnits,
                sampleCount: stream.sampleCount, effectiveRateHz: stream.effectiveRateHz,
                reader: reader, externalID: nil))
        }
        for info in (metadata.externalStreams ?? []).sorted(by: { $0.id < $1.id })
        where info.sampleCount > 0 {
            guard let reader = reader(for: info, recording: metadata.id) else { continue }
            result.append(ExportStream(
                key: ExportStream.key(for: info), title: info.title,
                channels: info.channels,
                units: (0..<info.channels.count).map { info.unit(forChannel: $0) },
                sampleCount: info.sampleCount, effectiveRateHz: info.effectiveRateHz,
                reader: reader, externalID: info.id))
        }
        return result
    }
}
