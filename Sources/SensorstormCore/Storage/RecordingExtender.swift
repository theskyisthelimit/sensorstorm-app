import Foundation

/// Streams that did not come from a sensor during the recording but from somewhere else
/// afterwards: the Health app's heart-rate samples for the hour of the walk, say. They land
/// next to the recording's own streams, in the same format, and every exporter and every chart
/// reads them like the rest.
public struct ExtraStream: Sendable {
    public var info: ExternalStreamInfo
    /// `time` is on the recording's host clock, the same origin as every other stream.
    public var samples: [(time: Double, values: [Double])]

    public init(info: ExternalStreamInfo, samples: [(time: Double, values: [Double])]) {
        self.info = info
        self.samples = samples
    }
}

public enum RecordingExtender {
    /// The recording's host clock at a wall-clock moment. The two clocks run at the same
    /// rate for the hour a recording lasts; the offset is fixed at the start.
    public static func hostTime(for date: Date, in metadata: RecordingMetadata) -> Double {
        metadata.startHostTime + date.timeIntervalSince(metadata.startedAt)
    }

    /// Writes the streams into the recording's folder and returns the metadata with them
    /// listed. A stream with the same id as one already there replaces it — importing twice
    /// is a refresh, not a duplicate. A stream without samples is skipped, as it is during a
    /// recording.
    @discardableResult
    public static func append(_ streams: [ExtraStream], to metadata: RecordingMetadata,
                              in store: RecordingStore) throws -> RecordingMetadata {
        var result = metadata
        let directory = store.directory(for: metadata.id)
        var external = result.externalStreams ?? []

        for stream in streams where !stream.samples.isEmpty {
            let writer = try StreamWriter(external: stream.info, directory: directory)
            for sample in stream.samples.sorted(by: { $0.time < $1.time })
            where sample.values.count == stream.info.channelCount {
                writer.append(time: sample.time, values: sample.values)
            }
            let written = writer.closeExternal()
            external.removeAll { $0.id == written.id }
            external.append(written)
        }
        external.sort { $0.id < $1.id }
        result.externalStreams = external.isEmpty ? nil : external
        try store.save(result)
        return result
    }
}
