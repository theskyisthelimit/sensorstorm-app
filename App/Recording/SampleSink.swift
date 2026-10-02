import Foundation
import SensorstormCore

/// The latest reading of one sensor, for the live dashboard.
struct LiveSample: Sendable, Equatable {
    var values: [Double]
    var hostTime: Double
    /// Measured update rate, smoothed — what the dashboard shows as "142 Hz".
    var rateHz: Double
}

/// The newest reading of a stream that is not a built-in sensor.
struct LiveExternalSample: Sendable, Equatable, Identifiable {
    var info: ExternalStreamInfo
    var values: [Double]
    var hostTime: Double
    var rateHz: Double

    var id: String { info.id }
}

/// The single point every sensor callback funnels into.
///
/// Sensors fire on half a dozen different queues at up to a few hundred hertz. Rather than
/// hopping each sample to the main actor (which would melt the UI), everything lands here:
/// samples go straight to their `StreamWriter` and the newest value is parked in a
/// dictionary that the UI reads at its own, much slower, refresh rate.
final class SampleSink: @unchecked Sendable {
    private let lock = NSLock()
    private var writers: [SensorID: StreamWriter] = [:]
    private var latest: [SensorID: LiveSample] = [:]
    private var rateEstimates: [SensorID: RateEstimator] = [:]
    private var isRecording = false
    /// Smallest and largest value of every channel since ``drainExtremes()`` last ran.
    private var extremes: [SensorID: ChannelRange] = [:]

    // Streams that are not built-in sensors. Created while the app runs — a device walks into
    // the room, a host starts answering — so their writers are created on the first value
    // rather than when the recording starts.
    private var externalLatest: [String: LiveExternalSample] = [:]
    private var externalRates: [String: RateEstimator] = [:]
    private var externalExtremes: [String: ChannelRange] = [:]
    private var externalWriters: [String: StreamWriter] = [:]
    private var externalDirectory: URL?

    // MARK: - Ingest (hot path, any queue)

    func ingest(_ sensor: SensorID, time: Double, values: [Double]) {
        lock.lock()
        let writer = writers[sensor]
        let tap = self.tap
        var estimator = rateEstimates[sensor] ?? RateEstimator()
        let rate = estimator.record(time: time)
        rateEstimates[sensor] = estimator
        latest[sensor] = LiveSample(values: values, hostTime: time, rateHz: rate)
        if var range = extremes[sensor], range.minimum.count == values.count {
            range.include(values)
            extremes[sensor] = range
        } else {
            extremes[sensor] = ChannelRange(values)
        }
        lock.unlock()

        // Outside the lock: the writer has its own, and file I/O must not block ingest of
        // a different sensor.
        writer?.append(time: time, values: values)
        // Same reasoning, and one more: the tap opens sockets. Holding this lock across a
        // network stack would let a slow endpoint stall every sensor in the app.
        tap?(sensor, time, values)
    }

    /// A value of a stream that is not a built-in sensor.
    ///
    /// `values.count` has to equal the description's channel count — a stream is a table of
    /// fixed width, and a row of the wrong width is dropped rather than written crooked.
    func ingestExternal(_ info: ExternalStreamInfo, time: Double, values: [Double]) {
        guard values.count == info.channelCount, info.channelCount > 0 else { return }
        lock.lock()
        var estimator = externalRates[info.id] ?? RateEstimator()
        let rate = estimator.record(time: time)
        externalRates[info.id] = estimator
        externalLatest[info.id] = LiveExternalSample(info: info, values: values,
                                                     hostTime: time, rateHz: rate)
        if var range = externalExtremes[info.id], range.minimum.count == values.count {
            range.include(values)
            externalExtremes[info.id] = range
        } else {
            externalExtremes[info.id] = ChannelRange(values)
        }
        var writer = externalWriters[info.id]
        if writer == nil, isRecording, let directory = externalDirectory {
            // Under the lock on purpose: two threads reporting the first value of the same
            // stream must not each create a file. It is one small write, once per stream.
            writer = try? StreamWriter(external: info, directory: directory)
            externalWriters[info.id] = writer
        }
        lock.unlock()
        writer?.append(time: time, values: values)
    }

    func externalSnapshot() -> [String: LiveExternalSample] {
        lock.lock(); defer { lock.unlock() }
        return externalLatest
    }

    func drainExternalExtremes() -> [String: ChannelRange] {
        lock.lock(); defer { lock.unlock() }
        let drained = externalExtremes
        externalExtremes.removeAll(keepingCapacity: true)
        return drained
    }

    /// Forgets streams not heard from for `seconds` — a thermometer that left the room should
    /// not stay on the dashboard showing its last value as if it were current.
    func dropExternal(olderThan seconds: Double, now: Double) {
        lock.lock(); defer { lock.unlock() }
        let stale = externalLatest.filter { now - $0.value.hostTime > seconds }.map(\.key)
        for id in stale {
            externalLatest[id] = nil
            externalRates[id] = nil
        }
    }

    /// An observer of every ingested sample, for live streaming. Set when a recording that
    /// streams begins, cleared when it ends.
    private var tap: (@Sendable (SensorID, Double, [Double]) -> Void)?

    func setTap(_ tap: (@Sendable (SensorID, Double, [Double]) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        self.tap = tap
    }

    // MARK: - Live view

    func snapshot() -> [SensorID: LiveSample] {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    /// Smallest and largest value of every channel since the previous call, then starts over.
    ///
    /// What the rules read. The live dictionary keeps only the newest sample, and a spike of
    /// 30 ms falls between two of the rules' 100 ms looks nine times out of ten.
    func drainExtremes() -> [SensorID: ChannelRange] {
        lock.lock(); defer { lock.unlock() }
        let drained = extremes
        extremes.removeAll(keepingCapacity: true)
        return drained
    }

    func sample(for sensor: SensorID) -> LiveSample? {
        lock.lock(); defer { lock.unlock() }
        return latest[sensor]
    }

    /// Drops live values for sensors that are no longer running, so the dashboard doesn't
    /// keep showing a frozen last reading.
    func clearLive(except active: Set<SensorID>) {
        lock.lock(); defer { lock.unlock() }
        latest = latest.filter { active.contains($0.key) }
        rateEstimates = rateEstimates.filter { active.contains($0.key) }
    }

    // MARK: - Recording

    /// - Parameter externalDirectory: where streams that are not built-in sensors put their
    ///   files. `nil` leaves them out of the recording; they still show on the dashboard.
    func beginRecording(writers: [SensorID: StreamWriter], externalDirectory: URL? = nil) {
        lock.lock()
        self.writers = writers
        self.externalDirectory = externalDirectory
        self.externalWriters = [:]
        self.isRecording = true
        lock.unlock()
    }

    /// Closes every writer and returns the stream descriptions for the metadata file.
    func endRecording() -> [StreamInfo] {
        endRecordingWithExternals().streams
    }

    /// Like ``endRecording()``, and also the descriptions of the streams that are not
    /// built-in sensors — only those that received at least one value.
    func endRecordingWithExternals() -> (streams: [StreamInfo], external: [ExternalStreamInfo]) {
        lock.lock()
        let closing = writers
        let closingExternal = externalWriters
        writers = [:]
        externalWriters = [:]
        externalDirectory = nil
        isRecording = false
        lock.unlock()

        let streams = closing.values
            .map { $0.close() }
            .sorted { $0.sensor.rawValue < $1.sensor.rawValue }
        let external = closingExternal.values
            .map { $0.closeExternal() }
            .sorted { $0.id < $1.id }
        return (streams, external)
    }

    var recording: Bool {
        lock.lock(); defer { lock.unlock() }
        return isRecording
    }

    /// Total samples written so far, for the live counter.
    var writtenSampleCount: Int {
        lock.lock()
        let current = Array(writers.values) + Array(externalWriters.values)
        lock.unlock()
        return current.reduce(0) { $0 + $1.sampleCount }
    }
}

/// Per-channel minimum and maximum over an interval. A channel that only delivered NaN so
/// far stays NaN; the first finite value replaces it.
struct ChannelRange: Sendable, Equatable {
    var minimum: [Double]
    var maximum: [Double]

    init(_ values: [Double]) {
        minimum = values
        maximum = values
    }

    mutating func include(_ values: [Double]) {
        for index in values.indices where values[index].isFinite {
            let value = values[index]
            minimum[index] = minimum[index].isFinite ? Swift.min(minimum[index], value) : value
            maximum[index] = maximum[index].isFinite ? Swift.max(maximum[index], value) : value
        }
    }
}

/// Exponentially smoothed rate estimate. Cheap enough to run on every sample.
private struct RateEstimator {
    private var lastTime: Double?
    private var smoothedInterval: Double?

    mutating func record(time: Double) -> Double {
        defer { lastTime = time }
        guard let lastTime, time > lastTime else { return smoothedInterval.map { 1 / $0 } ?? 0 }

        let interval = time - lastTime
        if let current = smoothedInterval {
            smoothedInterval = current * 0.9 + interval * 0.1
        } else {
            smoothedInterval = interval
        }
        guard let smoothed = smoothedInterval, smoothed > 0 else { return 0 }
        return 1 / smoothed
    }
}
