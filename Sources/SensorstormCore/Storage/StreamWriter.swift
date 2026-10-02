import Foundation

/// Buffered, lock-protected append writer for one stream.
///
/// Sensor callbacks arrive on several queues at once and at up to a few hundred hertz, so
/// the hot path has to stay allocation-light and must never touch the file system: samples
/// go into an in-memory buffer and are handed to the file only every ``flushThreshold``
/// bytes (or on ``flush()``/``close()``).
public final class StreamWriter: @unchecked Sendable {
    /// The built-in sensor this stream belongs to; `nil` for an ``ExternalStreamInfo`` stream.
    public let sensor: SensorID?
    /// What the stream is called in log lines and in the precondition message.
    public let name: String
    private let external: ExternalStreamInfo?
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

    public convenience init(sensor: SensorID, channelCount: Int, directory: URL) throws {
        try self.init(sensor: sensor, external: nil, name: sensor.rawValue,
                      fileName: "\(sensor.rawValue).ssbin", channelCount: channelCount,
                      directory: directory)
    }

    /// A stream that is not a built-in sensor. The channel count comes from the description.
    public convenience init(external info: ExternalStreamInfo, directory: URL) throws {
        try self.init(sensor: nil, external: info, name: info.id, fileName: info.fileName,
                      channelCount: info.channelCount, directory: directory)
    }

    private init(sensor: SensorID?, external: ExternalStreamInfo?, name: String, fileName: String,
                 channelCount: Int, directory: URL) throws {
        self.sensor = sensor
        self.external = external
        self.name = name
        self.channelCount = channelCount
        self.url = directory.appendingPathComponent(fileName)

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
                     "\(name): expected \(channelCount) channels, got \(values.count)")
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
    ///
    /// Only for built-in sensors — an external stream has its own description, see
    /// ``closeExternal()``.
    @discardableResult
    public func close() -> StreamInfo {
        let (count, rate) = finish()
        guard let sensor else {
            preconditionFailure("\(name) is an external stream; use closeExternal()")
        }
        let descriptor = sensor.descriptor
        return StreamInfo(sensor: sensor,
                          channels: descriptor.channels,
                          unit: descriptor.unit,
                          sampleCount: count,
                          effectiveRateHz: rate)
    }

    /// The description of an external stream, with the count and the rate it ended up with.
    @discardableResult
    public func closeExternal() -> ExternalStreamInfo {
        let (count, rate) = finish()
        var info = external ?? ExternalStreamInfo(id: name, source: .accessory, title: name,
                                                  channels: (0..<channelCount).map { "c\($0)" })
        info.sampleCount = count
        info.effectiveRateHz = rate
        return info
    }

    private func finish() -> (count: Int, rate: Double) {
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
        return (count, rate)
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
            RecordingLog.warn("write failed for \(name): \(error.localizedDescription)")
        }
    }
}
