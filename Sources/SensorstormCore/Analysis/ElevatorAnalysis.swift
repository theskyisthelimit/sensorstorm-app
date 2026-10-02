import Foundation

/// Elevator rides from a phone standing on the floor of the car: how fast, how hard it
/// starts and stops, how much it shakes on the way.
///
/// What a service technician or a facility manager is asked about — „der Aufzug ruckelt" —
/// and what ISO 18738 measures with a dedicated instrument: peak acceleration, peak jerk and
/// the vibration while cruising. The phone's accelerometer is good enough to find the
/// ride, the floor change and the order of magnitude; it is not a type-tested instrument,
/// and the figures are labelled as indicative.
public enum ElevatorAnalysis {

    public struct Ride: Sendable, Equatable {
        public var start: Double
        public var end: Double
        /// Metres, positive upwards, from the barometer.
        public var heightChange: Double
        public var peakSpeed: Double
        /// m/s², the strongest push up and the strongest pull down while starting and
        /// stopping.
        public var peakAcceleration: Double
        public var peakDeceleration: Double
        /// m/s³.
        public var peakJerk: Double
        /// Peak-to-peak vertical vibration while cruising, 95th percentile of one-second
        /// windows, in milli-g. ISO 18738 reports exactly this (A95).
        public var cruiseVibration: Double?

        public var duration: Double { end - start }
        public var isUp: Bool { heightChange > 0 }
    }

    public struct Settings: Sendable, Equatable {
        /// Below this the car is standing.
        public var movingSpeed = 0.25
        public var minimumHeight = 1.5
        public var minimumDuration = 3.0

        public init() {}
    }

    /// - Parameters:
    ///   - altitude: relative altitude in metres (barometer channel 1), at 1 Hz or better.
    ///   - vertical: acceleration along gravity in g, 20 Hz or better.
    public static func analyse(altitude: TimeSeries, vertical: TimeSeries,
                               settings: Settings = Settings()) -> [Ride] {
        guard altitude.count >= 5, let altitudeRate = altitude.rate, altitudeRate >= 0.5 else { return [] }

        // Speed from the barometer, smoothed: its quantisation is a few centimetres, which as
        // a derivative at 1 Hz would be noise the size of the signal.
        let smooth = altitude.resampled(rate: min(altitudeRate, 4)).smoothed(seconds: 2)
        guard smooth.count >= 5 else { return [] }
        var speed = [Double](repeating: 0, count: smooth.count)
        for index in 1..<smooth.count {
            let dt = smooth.times[index] - smooth.times[index - 1]
            if dt > 0 { speed[index] = (smooth.values[index] - smooth.values[index - 1]) / dt }
        }
        let speedSeries = TimeSeries(times: smooth.times, values: speed).smoothed(seconds: 2)

        // Contiguous stretches with a speed above the threshold, allowing a short lull
        // (a car easing at the top of its travel) inside one ride.
        var rides: [(Int, Int)] = []
        var start: Int?
        var lastMoving = 0
        let lull = Int(3 * (smooth.rate ?? 1))
        for index in speedSeries.values.indices {
            if abs(speedSeries.values[index]) >= settings.movingSpeed {
                if start == nil { start = index }
                lastMoving = index
            } else if let begin = start, index - lastMoving > lull {
                rides.append((begin, lastMoving))
                start = nil
            }
        }
        if let begin = start { rides.append((begin, lastMoving)) }

        var result: [Ride] = []
        for (first, last) in rides {
            let t0 = speedSeries.times[first]
            let t1 = speedSeries.times[last]
            guard t1 - t0 >= settings.minimumDuration else { continue }
            guard let h0 = smooth.value(at: t0 - 1.5) ?? smooth.values.first,
                  let h1 = smooth.value(at: t1 + 1.5) ?? smooth.values.last else { continue }
            let change = h1 - h0
            guard abs(change) >= settings.minimumHeight else { continue }

            let peakSpeed = speedSeries.values[first...last].map(abs).max() ?? 0
            let motion = motionFigures(vertical: vertical, from: t0 - 2, to: t1 + 2, up: change > 0)
            result.append(Ride(start: t0, end: t1, heightChange: change, peakSpeed: peakSpeed,
                               peakAcceleration: motion.acceleration, peakDeceleration: motion.deceleration,
                               peakJerk: motion.jerk, cruiseVibration: motion.vibration))
        }
        return result
    }

    private static func motionFigures(vertical: TimeSeries, from start: Double, to end: Double,
                                      up: Bool) -> (acceleration: Double, deceleration: Double,
                                                    jerk: Double, vibration: Double?) {
        let window = vertical.slice(start...end)
        guard let rate = window.rate, rate >= 20, window.count >= Int(rate) * 2 else { return (0, 0, 0, nil) }

        // The slow part is the ride's own acceleration; the fast part is the car shaking.
        let slow = window.smoothed(seconds: 0.5).map { $0 * standardGravity }
        let fast = TimeSeries(times: window.times,
                              values: zip(window.values, window.smoothed(seconds: 0.5).values).map { ($0 - $1) * 1_000 })

        // Positive is up. A ride downwards starts with a pull the other way.
        let signed = up ? slow.values : slow.values.map { -$0 }
        let acceleration = max(signed.max() ?? 0, 0)
        let deceleration = max(-(signed.min() ?? 0), 0)

        var jerk = 0.0
        for index in 1..<slow.count {
            let dt = slow.times[index] - slow.times[index - 1]
            if dt > 0 { jerk = max(jerk, abs(slow.values[index] - slow.values[index - 1]) / dt) }
        }

        // Cruise: the middle half of the ride, where neither start nor stop is going on.
        let quarter = (end - start) / 4
        let cruise = fast.slice((start + quarter)...(end - quarter))
        var peaks: [Double] = []
        if let cruiseRate = cruise.rate, cruise.count > Int(cruiseRate) {
            let size = Int(cruiseRate)
            var index = 0
            while index + size <= cruise.count {
                let part = cruise.values[index..<(index + size)]
                peaks.append((part.max() ?? 0) - (part.min() ?? 0))
                index += size
            }
        }
        return (acceleration, deceleration, jerk, Statistics.percentile(peaks, 0.95))
    }
}
