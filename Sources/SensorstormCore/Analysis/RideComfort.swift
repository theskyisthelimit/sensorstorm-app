import Foundation

/// Ride comfort in a train, tram or bus, in the spirit of EN 12299: how much the vehicle
/// shakes in each direction, in five-second windows, and where it jolted.
///
/// The standard weights each axis with its own filter and a table; this uses a plain band-pass
/// instead (0.4–30 Hz), which comes out higher than the standard's figure for the same ride.
/// Good for comparing one line with another and one run with the next, not for an acceptance
/// certificate — which is why the result is called an index and the interface says so.
public enum RideComfort {

    public enum Class: Int, Sendable, Comparable {
        case veryComfortable = 0, comfortable, medium, lessComfortable, uncomfortable

        public static func < (lhs: Class, rhs: Class) -> Bool { lhs.rawValue < rhs.rawValue }

        /// EN 12299's ranges for the comfort index.
        public init(index: Double) {
            switch index {
            case ..<1.5: self = .veryComfortable
            case ..<2.5: self = .comfortable
            case ..<4: self = .medium
            case ..<5: self = .lessComfortable
            default: self = .uncomfortable
            }
        }
    }

    public struct Jolt: Sendable, Equatable {
        public enum Axis: String, Sendable { case vertical, lateral, longitudinal }
        public var time: Double
        public var axis: Axis
        /// m/s².
        public var peak: Double
        public var position: Coordinate2D?
    }

    public struct Result: Sendable, Equatable {
        /// 95th percentile of the five-second RMS per axis, m/s².
        public var vertical: Double
        public var lateral: Double
        public var longitudinal: Double
        /// 6 · √(a_x² + a_y² + a_z²), with the 95th percentiles in m/s².
        public var comfortIndex: Double
        public var comfortClass: Class
        public var jolts: [Jolt]
        public var windows: Int
    }

    /// - Parameters: the three axes in g, in the phone's own frame, with the phone lying flat
    ///   or fixed in the vehicle: `x` across, `y` along, `z` up. A phone held in the hand
    ///   gives a figure that is mostly the hand.
    public static func analyse(x: TimeSeries, y: TimeSeries, z: TimeSeries,
                               latitude: TimeSeries? = nil, longitude: TimeSeries? = nil,
                               joltThreshold: Double = 1.0) -> Result? {
        guard let rate = z.rate, rate >= 20, x.count == z.count, y.count == z.count, z.count > Int(rate) * 10 else { return nil }
        let band = FilterChain.bandPass(low: 0.4, high: 30, rate: rate)
        let across = band.apply(to: x).map { $0 * standardGravity }
        let along = band.apply(to: y).map { $0 * standardGravity }
        let up = band.apply(to: z).map { $0 * standardGravity }

        let windowSize = Int(5 * rate)
        func p95(_ series: TimeSeries) -> Double {
            var values: [Double] = []
            var index = Int(2 * rate)    // skip the filter's start-up
            while index + windowSize <= series.count {
                if let rms = Statistics.rms(Array(series.values[index..<(index + windowSize)])) { values.append(rms) }
                index += windowSize
            }
            return Statistics.percentile(values, 0.95) ?? 0
        }
        let (vertical, lateral, longitudinal) = (p95(up), p95(across), p95(along))
        let index = 6 * (vertical * vertical + lateral * lateral + longitudinal * longitudinal).squareRoot()

        var jolts: [Jolt] = []
        var lastTime = -Double.infinity
        for (axis, series) in [(Jolt.Axis.vertical, up), (.lateral, across), (.longitudinal, along)] {
            for sampleIndex in series.times.indices where sampleIndex >= Int(2 * rate) {
                let value = abs(series.values[sampleIndex])
                guard value >= joltThreshold else { continue }
                let time = series.times[sampleIndex]
                var position: Coordinate2D?
                if let latitude, let longitude, let lat = latitude.value(at: time), let lon = longitude.value(at: time) {
                    let candidate = Coordinate2D(latitude: lat, longitude: lon)
                    position = candidate.isValid ? candidate : nil
                }
                if let last = jolts.last, last.axis == axis, time - lastTime < 2 {
                    if value > last.peak { jolts[jolts.count - 1] = Jolt(time: time, axis: axis, peak: value, position: position) }
                } else {
                    jolts.append(Jolt(time: time, axis: axis, peak: value, position: position))
                }
                lastTime = time
            }
        }
        jolts.sort { $0.time < $1.time }
        return Result(vertical: vertical, lateral: lateral, longitudinal: longitudinal,
                      comfortIndex: index, comfortClass: Class(index: index), jolts: jolts,
                      windows: max((z.count - Int(2 * rate)) / windowSize, 0))
    }
}
