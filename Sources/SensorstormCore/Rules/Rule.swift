import Foundation

/// „When this holds, do that" — evaluated while a recording runs.
///
/// Conditions are joined with *and*: „faster than 8 m/s and outside the yard" is one rule,
/// not two that each fire on half of it.
public struct Rule: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var mode: Mode
    public var conditions: [Condition]
    public var actions: [Action]

    public init(id: UUID = UUID(), name: String, isEnabled: Bool = true, mode: Mode = .onChange,
                conditions: [Condition] = [], actions: [Action] = []) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.mode = mode
        self.conditions = conditions
        self.actions = actions
    }

    public enum Mode: String, Codable, Sendable, Hashable, CaseIterable {
        /// Fires when the conditions start to hold, not again until they stopped holding.
        case onChange
        /// Fires as long as the conditions hold, throttled by ``cooldown``.
        case everyTime

        /// Seconds a rule stays quiet after it fired. Per rule, so a chatty rule cannot
        /// silence a rare one. Short for `onChange`, which only fires on an edge anyway and
        /// only needs protecting from a value flickering across its threshold.
        public var cooldown: Double {
            switch self {
            case .onChange: 5
            case .everyTime: 60
            }
        }
    }

    public enum Comparison: String, Codable, Sendable, Hashable, CaseIterable {
        case above
        case below
    }

    public enum Condition: Codable, Sendable, Hashable {
        /// One channel of one stream against a threshold.
        case value(sensor: SensorID, channel: Int, comparison: Comparison, threshold: Double)
        /// Inside or outside a circle around a point, on the GPS fix.
        case geofence(latitude: Double, longitude: Double, radius: Double, inside: Bool)
        /// Time since the recording started.
        case elapsed(seconds: Double)
        /// A message arrived on a subscribed topic. An empty `contains` matches any payload.
        case mqtt(topic: String, contains: String)
        /// One channel of a stream that is not a built-in sensor — a Bluetooth thermometer, a
        /// round-trip time. Addressed by the stream's stable id.
        case external(stream: String, channel: Int, comparison: Comparison, threshold: Double)
    }

    public enum Action: Codable, Sendable, Hashable {
        case notify(title: String, message: String, emoji: String)
        case annotate(text: String)
        case stopRecording
    }
}

/// Everything a rule may look at, gathered once per evaluation.
public struct RuleContext: Sendable {
    /// Newest value of every running stream.
    public var values: [SensorID: [Double]]
    /// Smallest and largest value of every channel since the previous evaluation.
    ///
    /// Rules run ten times a second; a sensor at 100 Hz delivers ten samples in between, and
    /// only the last of them is the "newest". A pothole is a spike of 20–60 ms — nine times
    /// in ten it falls between two evaluations and the newest value never sees it. The
    /// extremes do. A stream missing here falls back to ``values``.
    public var minimum: [SensorID: [Double]]
    public var maximum: [SensorID: [Double]]
    /// The same three for streams addressed by id rather than by ``SensorID``.
    public var externalValues: [String: [Double]]
    public var externalMinimum: [String: [Double]]
    public var externalMaximum: [String: [Double]]
    /// Seconds since the recording started.
    public var elapsed: Double
    /// Messages received since the previous evaluation.
    public var messages: [(topic: String, payload: String)]

    public init(values: [SensorID: [Double]], elapsed: Double,
                messages: [(topic: String, payload: String)] = [],
                minimum: [SensorID: [Double]] = [:],
                maximum: [SensorID: [Double]] = [:],
                externalValues: [String: [Double]] = [:],
                externalMinimum: [String: [Double]] = [:],
                externalMaximum: [String: [Double]] = [:]) {
        self.values = values
        self.minimum = minimum
        self.maximum = maximum
        self.externalValues = externalValues
        self.externalMinimum = externalMinimum
        self.externalMaximum = externalMaximum
        self.elapsed = elapsed
        self.messages = messages
    }
}

/// Decides which rules fire. Pure apart from its own memory of edges and cooldowns, so the
/// timing rules are tested without a clock or a phone.
public struct RuleEngine: Sendable {
    private var held: [UUID: Bool] = [:]
    private var lastFired: [UUID: Double] = [:]

    public init() {}

    /// - Parameter now: any monotonic clock in seconds; only differences are used.
    public mutating func evaluate(_ rules: [Rule], context: RuleContext, now: Double) -> [Rule] {
        var firing: [Rule] = []
        for rule in rules where rule.isEnabled && !rule.conditions.isEmpty && !rule.actions.isEmpty {
            let holds = rule.conditions.allSatisfy { Self.holds($0, in: context) }
            let wasHeld = held[rule.id] ?? false
            held[rule.id] = holds
            guard holds else { continue }
            if rule.mode == .onChange, wasHeld { continue }
            if let last = lastFired[rule.id], now - last < rule.mode.cooldown { continue }
            lastFired[rule.id] = now
            firing.append(rule)
        }
        return firing
    }

    public static func holds(_ condition: Rule.Condition, in context: RuleContext) -> Bool {
        switch condition {
        case let .value(sensor, channel, comparison, threshold):
            // "Above" asks whether the largest value since the last look crossed, "below"
            // whether the smallest did — either way the question is about the interval,
            // not about whichever sample happened to arrive last.
            let extremes = comparison == .above ? context.maximum[sensor] : context.minimum[sensor]
            let pool = extremes.flatMap { $0.indices.contains(channel) ? $0 : nil }
            guard let values = pool ?? context.values[sensor], values.indices.contains(channel) else {
                return false
            }
            let value = values[channel]
            guard value.isFinite else { return false }
            return comparison == .above ? value > threshold : value < threshold

        case let .external(stream, channel, comparison, threshold):
            let extremes = comparison == .above
                ? context.externalMaximum[stream] : context.externalMinimum[stream]
            let pool = extremes.flatMap { $0.indices.contains(channel) ? $0 : nil }
            guard let values = pool ?? context.externalValues[stream],
                  values.indices.contains(channel) else { return false }
            let value = values[channel]
            guard value.isFinite else { return false }
            return comparison == .above ? value > threshold : value < threshold

        case let .geofence(latitude, longitude, radius, inside):
            // No fix is neither inside nor outside: a rule must not fire on „outside" just
            // because the GPS has not answered yet.
            guard let fix = context.values[.location], fix.count >= 2,
                  fix[0].isFinite, fix[1].isFinite else { return false }
            let distance = Self.distance(latitude, longitude, fix[0], fix[1])
            return inside ? distance <= radius : distance > radius

        case let .elapsed(seconds):
            return context.elapsed >= seconds

        case let .mqtt(topic, contains):
            return context.messages.contains { message in
                MQTTTopic.matches(filter: topic, topic: message.topic)
                    && (contains.isEmpty || message.payload.localizedCaseInsensitiveContains(contains))
            }
        }
    }

    /// Haversine on a sphere. A geofence is tens to hundreds of metres; the ellipsoid would
    /// change the answer by less than the GPS error.
    static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let radians = Double.pi / 180
        let dLat = (lat2 - lat1) * radians
        let dLon = (lon2 - lon1) * radians
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * radians) * cos(lat2 * radians) * sin(dLon / 2) * sin(dLon / 2)
        return 6_371_008.8 * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
