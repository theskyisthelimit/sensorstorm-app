import Foundation

/// Peak particle velocity from the phone's accelerometer, against the guide values of
/// DIN 4150-3 (also the basis of the Swiss SN 640 312a): a first look at whether a nearby
/// construction site, a train or a compactor shakes a building more than it should.
///
/// A screening, not a certified measurement. The phone's accelerometer is a few percent
/// accurate between 1 and 80 Hz, which is the range that decides; it is not calibrated, not
/// mounted on the foundation, and not what an expert opinion may rest on. What it does is
/// show whether the figures are near the limit or a factor of ten away — and to leave the
/// phone running overnight for the price of a charging cable.
public enum VibrationScreening {

    /// The three lines of DIN 4150-3 table 1, for the foundation.
    public enum Category: String, Sendable, CaseIterable {
        /// Commercial and industrial buildings.
        case commercial
        /// Dwellings and buildings of similar use.
        case dwelling
        /// Sensitive structures and those of particular value, listed buildings.
        case sensitive

        /// mm/s at below 10 Hz, at 50 Hz and at 100 Hz.
        var limits: (low: Double, mid: Double, high: Double) {
            switch self {
            case .commercial: (20, 40, 50)
            case .dwelling: (5, 15, 20)
            case .sensitive: (3, 8, 10)
            }
        }
    }

    /// The guide value in mm/s at a frequency: flat below 10 Hz, straight lines between the
    /// table's frequencies, flat above 100 Hz.
    public static func guideValue(_ category: Category, frequency: Double) -> Double {
        let (low, mid, high) = category.limits
        switch frequency {
        case ..<10: return low
        case ..<50: return low + (mid - low) * (frequency - 10) / 40
        case ..<100: return mid + (high - mid) * (frequency - 50) / 50
        default: return high
        }
    }

    public struct Axis: Sendable, Equatable {
        /// mm/s.
        public var peakVelocity: Double
        public var time: Double
        /// Hz, from the zero crossings around the peak.
        public var frequency: Double
    }

    public struct Result: Sendable, Equatable {
        public var x: Axis
        public var y: Axis
        public var z: Axis
        public var category: Category
        /// The axis with the highest peak, and the guide value at its frequency.
        public var governing: Axis
        public var guideValue: Double

        public var ratio: Double { guideValue > 0 ? governing.peakVelocity / guideValue : 0 }
        public var exceeded: Bool { ratio > 1 }
    }

    /// - Parameters: the three acceleration axes in g, at 100 Hz or more — below that the band
    ///   up to 80 Hz is not covered.
    public static func analyse(x: TimeSeries, y: TimeSeries, z: TimeSeries, category: Category) -> Result? {
        guard let rate = x.rate, rate >= 100, x.count == y.count, y.count == z.count,
              x.count > Int(rate) * 4 else { return nil }
        let axes = [x, y, z].map { velocity($0, rate: rate) }
        let results = axes.map(peak)
        guard results.count == 3 else { return nil }
        let governing = results.max { $0.peakVelocity < $1.peakVelocity } ?? results[0]
        return Result(x: results[0], y: results[1], z: results[2], category: category, governing: governing,
                      guideValue: guideValue(category, frequency: governing.frequency))
    }

    /// Acceleration in g to velocity in mm/s: band-limit first, integrate, and take the drift
    /// out of the integral with a high-pass — an accelerometer's offset would otherwise grow
    /// into a velocity of metres per second.
    static func velocity(_ acceleration: TimeSeries, rate: Double) -> TimeSeries {
        var pre = FilterChain.bandPass(low: 1, high: 80, rate: rate)
        var drift = Biquad.highPass(cutoff: 1, rate: rate)
        let dt = 1 / rate
        var previous = 0.0
        var integral = 0.0
        var values: [Double] = []
        values.reserveCapacity(acceleration.count)
        for raw in acceleration.values {
            let a = pre.process(raw.isFinite ? raw : 0) * standardGravity
            integral += (a + previous) / 2 * dt
            previous = a
            values.append(drift.process(integral) * 1_000)
        }
        return TimeSeries(times: acceleration.times, values: values)
    }

    private static func peak(_ velocity: TimeSeries) -> Axis {
        // The first two seconds are the filters settling.
        let skip = Int(2 * (velocity.rate ?? 100))
        var best = 0
        var bestValue = 0.0
        for index in skip..<velocity.count where abs(velocity.values[index]) > bestValue {
            bestValue = abs(velocity.values[index])
            best = index
        }
        let rate = velocity.rate ?? 100
        let half = Int(0.5 * rate)
        let low = max(best - half, 0)
        let high = min(best + half, velocity.count - 1)
        var crossings = 0
        for index in (low + 1)...max(high, low + 1) where index < velocity.count
            && (velocity.values[index - 1] < 0) != (velocity.values[index] < 0) {
            crossings += 1
        }
        let seconds = Double(high - low) / rate
        let frequency = seconds > 0 ? Double(crossings) / 2 / seconds : 0
        return Axis(peakVelocity: bestValue, time: velocity.times.isEmpty ? 0 : velocity.times[best], frequency: frequency)
    }
}
