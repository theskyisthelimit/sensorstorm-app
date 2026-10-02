import Foundation

/// Road surface condition from a phone on the dashboard: how rough each stretch was, and
/// where the shocks came.
///
/// An indication, not a measurement in the standards' sense — the real International
/// Roughness Index comes from a profile and a quarter-car model, and a phone's vertical
/// acceleration depends on the car, its tyres and how the phone is held. What survives all
/// of that is the comparison along one drive: this stretch shook twice as much as that one,
/// and here was the pothole. Both are what a depot wants to know before it sends a crew.
public enum RoadRoughness {

    public struct Segment: Sendable, Equatable {
        public var startTime: Double
        public var endTime: Double
        /// Metres travelled in this segment.
        public var distance: Double
        /// Mean speed in m/s.
        public var speed: Double
        /// Vertical acceleration, RMS of the band-passed signal, in m/s².
        public var rms: Double
        public var position: Coordinate2D?
        /// 0…1 over the whole drive: the share of segments that were smoother.
        public var rank: Double
    }

    public struct Shock: Sendable, Equatable {
        public var time: Double
        /// Peak vertical acceleration in g.
        public var peak: Double
        public var speed: Double
        public var position: Coordinate2D?
    }

    public struct Result: Sendable, Equatable {
        public var segments: [Segment]
        public var shocks: [Shock]
        /// Metres of road that could be judged. Standing and crawling traffic cannot.
        public var distance: Double

        /// The 10 % roughest stretches.
        public var worstSegments: [Segment] { segments.filter { $0.rank >= 0.9 } }

        public init(segments: [Segment], shocks: [Shock], distance: Double) {
            self.segments = segments
            self.shocks = shocks
            self.distance = distance
        }
    }

    public struct Settings: Sendable, Equatable {
        public var segmentLength = 10.0
        /// Below this the road is not excited enough to say anything about it.
        public var minimumSpeed = 3.0
        public var maximumSpeed = 45.0
        /// The band that carries road roughness: below it the car's own body motion and the
        /// hill, above it engine and tyre noise.
        public var band: ClosedRange<Double> = 0.5...25
        /// A shock is a vertical peak above this many g after band-passing.
        public var shockThreshold = 0.35
        /// Peaks closer than this belong to one event.
        public var shockSeparation = 1.5

        public init() {}
    }

    /// - Parameters:
    ///   - vertical: acceleration along gravity, in g (`SensorID.verticalAcceleration`, channel 0).
    ///   - speed: m/s, from the location stream.
    ///   - latitude: and `longitude`, to put a position on every result; optional.
    public static func analyse(vertical: TimeSeries, speed: TimeSeries,
                               latitude: TimeSeries? = nil, longitude: TimeSeries? = nil,
                               settings: Settings = Settings()) -> Result {
        guard let rate = vertical.rate, rate >= 20, vertical.count > Int(rate) * 2 else {
            return Result(segments: [], shocks: [], distance: 0)
        }
        let filtered = FilterChain.bandPass(low: settings.band.lowerBound, high: settings.band.upperBound, rate: rate)
            .apply(to: vertical)
        // The filter starts from rest; its first two seconds are a transient, not a road.
        let usableStart = (vertical.times.first ?? 0) + 2

        func position(at time: Double) -> Coordinate2D? {
            guard let latitude, let longitude, let lat = latitude.value(at: time),
                  let lon = longitude.value(at: time) else { return nil }
            let coordinate = Coordinate2D(latitude: lat, longitude: lon)
            return coordinate.isValid && !(lat == 0 && lon == 0) ? coordinate : nil
        }

        var segments: [Segment] = []
        var shocks: [Shock] = []
        var travelled = 0.0
        var segmentStart = filtered.times[0]
        var segmentDistance = 0.0
        var segmentSquares = 0.0
        var segmentCount = 0
        var segmentSpeedSum = 0.0
        var previousTime = filtered.times[0]
        var lastShockTime = -Double.infinity
        var lastShockIndex: Int?

        for index in filtered.times.indices {
            let time = filtered.times[index]
            let step = time - previousTime
            previousTime = time
            let currentSpeed = speed.value(at: time) ?? 0
            let moving = currentSpeed >= settings.minimumSpeed && currentSpeed <= settings.maximumSpeed
                && time >= usableStart

            guard moving, step >= 0, step < 1 else {
                // A stop or a dropout ends the segment without judging it.
                segmentDistance = 0
                segmentSquares = 0
                segmentCount = 0
                segmentSpeedSum = 0
                segmentStart = time
                continue
            }

            let accelerationG = filtered.values[index]
            let acceleration = accelerationG * standardGravity
            segmentDistance += currentSpeed * step
            segmentSquares += acceleration * acceleration
            segmentCount += 1
            segmentSpeedSum += currentSpeed
            travelled += currentSpeed * step

            if abs(accelerationG) >= settings.shockThreshold {
                if time - lastShockTime > settings.shockSeparation {
                    shocks.append(Shock(time: time, peak: abs(accelerationG), speed: currentSpeed, position: position(at: time)))
                    lastShockIndex = shocks.count - 1
                } else if let i = lastShockIndex, abs(accelerationG) > shocks[i].peak {
                    shocks[i].peak = abs(accelerationG)
                    shocks[i].time = time
                    shocks[i].position = position(at: time)
                }
                lastShockTime = time
            }

            if segmentDistance >= settings.segmentLength, segmentCount > 0 {
                segments.append(Segment(startTime: segmentStart, endTime: time, distance: segmentDistance,
                                        speed: segmentSpeedSum / Double(segmentCount),
                                        rms: (segmentSquares / Double(segmentCount)).squareRoot(),
                                        position: position(at: (segmentStart + time) / 2), rank: 0))
                segmentStart = time
                segmentDistance = 0
                segmentSquares = 0
                segmentCount = 0
                segmentSpeedSum = 0
            }
        }

        // Rank within the drive: what a depot sorts by.
        let sortedRMS = segments.map(\.rms).sorted()
        for index in segments.indices {
            let below = sortedRMS.firstIndex { $0 >= segments[index].rms } ?? 0
            segments[index].rank = sortedRMS.count > 1 ? Double(below) / Double(sortedRMS.count - 1) : 0
        }
        return Result(segments: segments, shocks: shocks, distance: travelled)
    }
}
