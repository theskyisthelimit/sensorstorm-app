import Foundation

/// A walked or driven track cut into short pieces, each with the value of some other stream
/// at that moment — what turns a line on a map into a picture of speed, noise, vibration or
/// Wi-Fi strength along the way.
public struct TrackColoring: Sendable, Equatable {
    public struct Segment: Sendable, Equatable {
        public var start: Coordinate2D
        public var end: Coordinate2D
        public var time: Double
        /// The metric at the segment's time; `nil` where the stream had nothing yet.
        public var value: Double?
        /// 0…1 inside ``TrackColoring/low``…``TrackColoring/high``. `nil` when `value` is.
        public var fraction: Double?
    }

    public var segments: [Segment]
    /// The values the ends of the colour scale stand for: the 5th and 95th percentile, so one
    /// spike does not turn the rest of the track the same colour.
    public var low: Double
    public var high: Double

    public var isEmpty: Bool { segments.isEmpty }

    public static let empty = TrackColoring(segments: [], low: 0, high: 1)

    /// - Parameters:
    ///   - latitude: and `longitude` come from the same stream, so their times match.
    ///   - accuracy: horizontal accuracy in metres; fixes without one, or worse than
    ///     `maximumAccuracy`, are left out of the line.
    ///   - maximumSegments: a two-hour drive at 1 Hz would be 7 200 map overlays.
    public static func make(latitude: TimeSeries, longitude: TimeSeries, accuracy: TimeSeries? = nil,
                            metric: TimeSeries, maximumAccuracy: Double = 50,
                            maximumSegments: Int = 600) -> TrackColoring {
        guard latitude.count == longitude.count, latitude.count >= 2 else { return .empty }

        var points: [(time: Double, coordinate: Coordinate2D)] = []
        for index in latitude.times.indices {
            let coordinate = Coordinate2D(latitude: latitude.values[index], longitude: longitude.values[index])
            guard coordinate.isValid, !(coordinate.latitude == 0 && coordinate.longitude == 0) else { continue }
            if let accuracy, accuracy.count == latitude.count {
                let value = accuracy.values[index]
                guard value.isFinite, value > 0, value <= maximumAccuracy else { continue }
            }
            points.append((latitude.times[index], coordinate))
        }
        guard points.count >= 2 else { return .empty }

        if points.count - 1 > maximumSegments {
            let stride = Int((Double(points.count - 1) / Double(maximumSegments)).rounded(.up))
            let thinned = points.enumerated().filter { $0.offset % stride == 0 || $0.offset == points.count - 1 }
            points = thinned.map(\.element)
        }

        var raw: [(Segment, Double?)] = []
        for (from, to) in zip(points, points.dropFirst()) {
            let middle = (from.time + to.time) / 2
            raw.append((Segment(start: from.coordinate, end: to.coordinate, time: middle, value: nil, fraction: nil),
                        metric.value(at: middle)))
        }
        let values = raw.compactMap(\.1)
        let low = Statistics.percentile(values, 0.05) ?? 0
        var high = Statistics.percentile(values, 0.95) ?? low + 1
        if high <= low { high = low + 1 }

        let segments = raw.map { segment, value -> Segment in
            var result = segment
            if let value {
                result.value = value
                result.fraction = min(max((value - low) / (high - low), 0), 1)
            }
            return result
        }
        return TrackColoring(segments: segments, low: low, high: high)
    }
}
