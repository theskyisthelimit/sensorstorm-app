import Foundation

/// Buffered, lock-protected append writer for one sensor stream.
///
/// Sensor callbacks arrive on several queues at once and at up to a few hundred hertz, so
/// the hot path has to stay allocation-light and must never touch the file system: samples
/// go into an in-memory buffer and are handed to the file only every ``flushThreshold``
/// bytes (or on ``flush()``/``close()``).
public final class StreamWriter: @unchecked Sendable {
    public let sensor: SensorID
    public let channelCount: Int
    public let url: URL

    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer: Data
    private var _sampleCount = 0
    private var _firstTime: Double?
    private var _lastTime: Double?
    private var isClosed = false

    private let flushThreshold = 64 * 1024

    public init(sensor: SensorID, channelCount: Int, directory: URL) throws {
        self.sensor = sensor
        self.channelCount = channelCount
        self.url = directory.appendingPathComponent("\(sensor.rawValue).ssbin")

        let header = StreamFormat.header(channelCount: channelCount)
        try header.write(to: url, options: .atomic)
        self.handle = try FileHandle(forWritingTo: url)
        try self.handle.seekToEnd()

        self.buffer = Data()
        self.buffer.reserveCapacity(flushThreshold + StreamFormat.recordSize(channelCount: channelCount))
    }

    public var sampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _sampleCount
    }

    /// Samples per second measured across the whole stream. Zero for streams with fewer
    /// than two samples.
    public var effectiveRateHz: Double {
        lock.lock(); defer { lock.unlock() }
        guard let first = _firstTime, let last = _lastTime, _sampleCount > 1, last > first else {
            return 0
        }
        return Double(_sampleCount - 1) / (last - first)
    }

    public func append(time: Double, values: [Double]) {
        precondition(values.count == channelCount,
                     "\(sensor.rawValue): expected \(channelCount) channels, got \(values.count)")
        lock.lock()
        guard !isClosed else { lock.unlock(); return }

        appendDouble(time)
        for value in values { appendDouble(value) }

        _sampleCount += 1
        if _firstTime == nil { _firstTime = time }
        _lastTime = time

        let pending: Data?
        if buffer.count >= flushThreshold {
            pending = buffer
            buffer.removeAll(keepingCapacity: true)
        } else {
            pending = nil
        }
        lock.unlock()

        if let pending { write(pending) }
    }

    public func flush() {
        lock.lock()
        let pending = buffer
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
        guard !pending.isEmpty else { return }
        write(pending)
    }

    /// Flushes and closes. Returns the info needed for the recording's metadata.
    @discardableResult
    public func close() -> StreamInfo {
        flush()
        lock.lock()
        isClosed = true
        let count = _sampleCount
        let rate: Double
        if let first = _firstTime, let last = _lastTime, count > 1, last > first {
            rate = Double(count - 1) / (last - first)
        } else {
            rate = 0
        }
        lock.unlock()

        try? handle.close()

        let descriptor = sensor.descriptor
        return StreamInfo(sensor: sensor,
                          channels: descriptor.channels,
                          unit: descriptor.unit,
                          sampleCount: count,
                          effectiveRateHz: rate)
    }

    // MARK: - Private

    /// Caller holds the lock.
    private func appendDouble(_ value: Double) {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { buffer.append(contentsOf: $0) }
    }

    private func write(_ data: Data) {
        do {
            try handle.write(contentsOf: data)
        } catch {
            // A failed write must not take the recording down: the remaining streams and
            // the video keep going, and the stream simply ends early.
            RecordingLog.warn("write failed for \(sensor.rawValue): \(error.localizedDescription)")
        }
    }
}
