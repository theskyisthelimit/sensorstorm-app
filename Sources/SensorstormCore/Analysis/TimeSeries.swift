import Foundation

/// One channel of one stream as two arrays: when, and what.
///
/// The analyses below work on these rather than on files, so that a test can hand them a
/// sine wave and a recording can hand them a hundred megabytes of accelerometer without the
/// analysis knowing the difference.
public struct TimeSeries: Sendable, Equatable {
    /// Host-clock seconds, ascending.
    public var times: [Double]
    public var values: [Double]

    public init(times: [Double], values: [Double]) {
        precondition(times.count == values.count)
        self.times = times
        self.values = values
    }

    /// Reads one channel of a stream, optionally only inside `range`.
    public init(reader: StreamReader, channel: Int, range: ClosedRange<Double>? = nil) {
        var times: [Double] = []
        var values: [Double] = []
        times.reserveCapacity(reader.sampleCount)
        values.reserveCapacity(reader.sampleCount)
        let channel = min(max(channel, 0), max(reader.channelCount - 1, 0))
        reader.forEachSample { time, row in
            if let range, !range.contains(time) { return }
            times.append(time)
            values.append(row.indices.contains(channel) ? row[channel] : .nan)
        }
        self.times = times
        self.values = values
    }

    /// An evenly sampled series — for tests and for resampled data.
    public static func uniform(_ values: [Double], rate: Double, start: Double = 0) -> TimeSeries {
        TimeSeries(times: values.indices.map { start + Double($0) / rate }, values: values)
    }

    public var count: Int { times.count }
    public var isEmpty: Bool { times.isEmpty }
    public var duration: Double { (times.last ?? 0) - (times.first ?? 0) }

    /// The middle interval between samples, which a few dropped ones do not move.
    public var medianInterval: Double? {
        guard times.count >= 2 else { return nil }
        var steps = zip(times.dropFirst(), times).map { $0 - $1 }.filter { $0 > 0 }
        guard !steps.isEmpty else { return nil }
        steps.sort()
        return steps[steps.count / 2]
    }

    /// Samples per second, from the median interval.
    public var rate: Double? { medianInterval.map { 1 / $0 } }

    /// Index of the last sample at or before `time`.
    public func index(atOrBefore time: Double) -> Int? {
        guard let first = times.first, time >= first else { return nil }
        var low = 0
        var high = times.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if times[mid] <= time { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The value in effect at `time` — held from the last sample, not interpolated: a speed
    /// of 12 m/s a second ago is the best statement about now that was ever made. `nil`
    /// before the first sample and where the value is not a number.
    public func value(at time: Double) -> Double? {
        guard let index = index(atOrBefore: time), values[index].isFinite else { return nil }
        return values[index]
    }

    /// The samples inside `range`.
    public func slice(_ range: ClosedRange<Double>) -> TimeSeries {
        var times: [Double] = []
        var values: [Double] = []
        for (time, value) in zip(self.times, self.values) where range.contains(time) {
            times.append(time)
            values.append(value)
        }
        return TimeSeries(times: times, values: values)
    }

    /// The series with `transform` applied to every value.
    public func map(_ transform: (Double) -> Double) -> TimeSeries {
        TimeSeries(times: times, values: values.map(transform))
    }

    /// Linear interpolation onto an even grid — for filters, which assume one.
    public func resampled(rate: Double) -> TimeSeries {
        guard let first = times.first, let last = times.last, last > first, rate > 0 else { return self }
        let step = 1 / rate
        var outTimes: [Double] = []
        var outValues: [Double] = []
        var cursor = 0
        var time = first
        while time <= last {
            while cursor + 1 < times.count, times[cursor + 1] <= time { cursor += 1 }
            let value: Double
            if cursor + 1 < times.count, times[cursor + 1] > times[cursor],
               values[cursor].isFinite, values[cursor + 1].isFinite {
                let fraction = (time - times[cursor]) / (times[cursor + 1] - times[cursor])
                value = values[cursor] + (values[cursor + 1] - values[cursor]) * fraction
            } else {
                value = values[cursor]
            }
            outTimes.append(time)
            outValues.append(value)
            time += step
        }
        return TimeSeries(times: outTimes, values: outValues)
    }

    /// The central moving average over `seconds`, on an evenly sampled series.
    public func smoothed(seconds: Double) -> TimeSeries {
        guard let rate, rate > 0 else { return self }
        let window = max(Int((seconds * rate).rounded()), 1)
        guard window > 1, values.count > window else { return self }
        var prefix = [Double](repeating: 0, count: values.count + 1)
        for (index, value) in values.enumerated() { prefix[index + 1] = prefix[index] + (value.isFinite ? value : 0) }
        let half = window / 2
        let smoothed: [Double] = values.indices.map { index in
            let low = max(index - half, 0)
            let high = min(index + half, values.count - 1)
            return (prefix[high + 1] - prefix[low]) / Double(high - low + 1)
        }
        return TimeSeries(times: times, values: smoothed)
    }
}

/// Order statistics that tolerate non-finite input by ignoring it.
public enum Statistics {
    public static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        let finite = values.filter(\.isFinite).sorted()
        guard !finite.isEmpty else { return nil }
        let position = min(max(fraction, 0), 1) * Double(finite.count - 1)
        let low = Int(position.rounded(.down))
        let high = min(low + 1, finite.count - 1)
        return finite[low] + (finite[high] - finite[low]) * (position - Double(low))
    }

    public static func median(_ values: [Double]) -> Double? { percentile(values, 0.5) }

    public static func mean(_ values: [Double]) -> Double? {
        let finite = values.filter(\.isFinite)
        guard !finite.isEmpty else { return nil }
        return finite.reduce(0, +) / Double(finite.count)
    }

    public static func rms(_ values: [Double]) -> Double? {
        let finite = values.filter(\.isFinite)
        guard !finite.isEmpty else { return nil }
        return (finite.reduce(0) { $0 + $1 * $1 } / Double(finite.count)).squareRoot()
    }

    public static func standardDeviation(_ values: [Double]) -> Double? {
        let finite = values.filter(\.isFinite)
        guard finite.count > 1, let mean = mean(finite) else { return nil }
        return (finite.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(finite.count - 1)).squareRoot()
    }
}

/// Standard gravity, for the sensors that report in g.
public let standardGravity = 9.80665
