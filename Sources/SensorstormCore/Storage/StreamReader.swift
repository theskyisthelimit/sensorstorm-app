import Foundation

/// One point of a decimated series. `low`/`high` carry the min/max of the samples the
/// point stands for, so a downsampled chart still shows spikes instead of averaging them
/// away.
public struct SeriesPoint: Sendable, Hashable {
    public let time: Double
    public let value: Double
    public let low: Double
    public let high: Double

    public init(time: Double, value: Double, low: Double, high: Double) {
        self.time = time
        self.value = value
        self.low = low
        self.high = high
    }
}

/// Random-access reader over a `.ssbin` stream. The file is memory-mapped, so opening a
/// large recording costs nothing and only the pages actually scrubbed to are faulted in.
public struct StreamReader: Sendable {
    public let channelCount: Int
    public let sampleCount: Int
    public let url: URL

    private let data: Data
    private let recordSize: Int

    public init(url: URL) throws {
        self.url = url
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= StreamFormat.headerSize else { throw StreamError.truncated }
        guard Array(data[0..<4]) == StreamFormat.magic else { throw StreamError.badMagic }

        let version = data.loadUInt16(at: 4)
        guard version == StreamFormat.version else { throw StreamError.unsupportedVersion(version) }

        let channels = Int(data.loadUInt16(at: 6))
        guard channels > 0 else { throw StreamError.truncated }

        self.data = data
        self.channelCount = channels
        self.recordSize = StreamFormat.recordSize(channelCount: channels)
        self.sampleCount = (data.count - StreamFormat.headerSize) / recordSize
    }

    public var isEmpty: Bool { sampleCount == 0 }

    /// Host-clock timestamp of a sample.
    public func time(at index: Int) -> Double {
        precondition(index >= 0 && index < sampleCount)
        return data.loadDouble(at: StreamFormat.headerSize + index * recordSize)
    }

    public func value(at index: Int, channel: Int) -> Double {
        precondition(index >= 0 && index < sampleCount)
        precondition(channel >= 0 && channel < channelCount)
        let offset = StreamFormat.headerSize + index * recordSize + (channel + 1) * MemoryLayout<Double>.size
        return data.loadDouble(at: offset)
    }

    public func sample(at index: Int) -> [Double] {
        (0..<channelCount).map { value(at: index, channel: $0) }
    }

    public var timeRange: ClosedRange<Double>? {
        guard sampleCount > 0 else { return nil }
        let first = time(at: 0)
        let last = time(at: sampleCount - 1)
        return first <= last ? first...last : last...first
    }

    /// Index of the last sample at or before `time`, or `nil` if `time` precedes the
    /// stream. Timestamps are monotonic per stream, so a plain binary search is exact.
    public func index(atOrBefore target: Double) -> Int? {
        guard sampleCount > 0, time(at: 0) <= target else { return nil }
        var low = 0
        var high = sampleCount - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if time(at: mid) <= target { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The sample in effect at `time` — what a playback cursor should display.
    public func sample(atOrBefore target: Double) -> [Double]? {
        guard let index = index(atOrBefore: target) else { return nil }
        return sample(at: index)
    }

    /// Decimates one channel down to at most `maxPoints`, preserving per-bucket extremes.
    ///
    /// - Parameter range: host-time window to read, or `nil` for the whole stream.
    public func series(channel: Int, maxPoints: Int = 600,
                       in range: ClosedRange<Double>? = nil) -> [SeriesPoint] {
        guard sampleCount > 0, maxPoints > 0, channel < channelCount else { return [] }

        let startIndex: Int
        let endIndex: Int
        if let range {
            startIndex = index(atOrBefore: range.lowerBound) ?? 0
            endIndex = index(atOrBefore: range.upperBound).map { min($0 + 1, sampleCount - 1) } ?? sampleCount - 1
        } else {
            startIndex = 0
            endIndex = sampleCount - 1
        }
        guard endIndex >= startIndex else { return [] }

        let count = endIndex - startIndex + 1
        if count <= maxPoints {
            return (startIndex...endIndex).map {
                let v = value(at: $0, channel: channel)
                return SeriesPoint(time: time(at: $0), value: v, low: v, high: v)
            }
        }

        let bucketSize = Double(count) / Double(maxPoints)
        var points: [SeriesPoint] = []
        points.reserveCapacity(maxPoints)

        for bucket in 0..<maxPoints {
            let from = startIndex + Int(Double(bucket) * bucketSize)
            let to = min(startIndex + Int(Double(bucket + 1) * bucketSize) - 1, endIndex)
            guard to >= from else { continue }

            var sum = 0.0
            var low = Double.greatestFiniteMagnitude
            var high = -Double.greatestFiniteMagnitude
            for i in from...to {
                let v = value(at: i, channel: channel)
                sum += v
                low = Swift.min(low, v)
                high = Swift.max(high, v)
            }
            let mid = from + (to - from) / 2
            points.append(SeriesPoint(time: time(at: mid),
                                      value: sum / Double(to - from + 1),
                                      low: low, high: high))
        }
        return points
    }

    /// Min/max across a channel — the y-domain a chart should use.
    public func extent(channel: Int) -> ClosedRange<Double>? {
        guard sampleCount > 0, channel < channelCount else { return nil }
        var low = Double.greatestFiniteMagnitude
        var high = -Double.greatestFiniteMagnitude
        // Sampling is enough for an axis domain and keeps this O(1)-ish on long recordings.
        let stride = Swift.max(1, sampleCount / 4000)
        for i in Swift.stride(from: 0, to: sampleCount, by: stride) {
            let v = value(at: i, channel: channel)
            guard v.isFinite else { continue }
            low = Swift.min(low, v)
            high = Swift.max(high, v)
        }
        guard low <= high else { return nil }
        return low...high
    }

    /// Streams every sample to `body` without materialising the whole file — used by export.
    public func forEachSample(_ body: (Double, [Double]) throws -> Void) rethrows {
        for i in 0..<sampleCount {
            try body(time(at: i), sample(at: i))
        }
    }
}

private extension Data {
    func loadUInt16(at offset: Int) -> UInt16 {
        var value: UInt16 = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { copyBytes(to: $0, from: offset..<(offset + 2)) }
        return UInt16(littleEndian: value)
    }

    func loadDouble(at offset: Int) -> Double {
        var bits: UInt64 = 0
        _ = Swift.withUnsafeMutableBytes(of: &bits) { copyBytes(to: $0, from: offset..<(offset + 8)) }
        return Double(bitPattern: UInt64(littleEndian: bits))
    }
}
