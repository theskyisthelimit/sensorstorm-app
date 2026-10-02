import Foundation

/// The last few seconds of one stream, kept in memory, for the recording that did not exist yet
/// when the thing happened.
///
/// A crash recorder cannot start recording when the crash begins — by then the first bang is
/// over. It listens all the time, throws away what is older than the pre-roll, and when the
/// trigger fires the recording already contains the seconds before it.
public struct SampleRing: Sendable {
    public struct Sample: Sendable, Equatable {
        public var time: Double
        public var values: [Double]
    }

    public let maxSeconds: Double
    private var storage: [Sample] = []
    /// Index of the oldest sample still wanted. Advancing it is O(1); the array is compacted
    /// when half of it is dead, so appends stay O(1) amortised and nothing shifts per sample.
    private var head = 0

    public init(maxSeconds: Double) {
        self.maxSeconds = max(maxSeconds, 0)
    }

    public var count: Int { storage.count - head }

    public mutating func append(time: Double, values: [Double]) {
        storage.append(Sample(time: time, values: values))
        let oldest = time - maxSeconds
        while head < storage.count, storage[head].time < oldest { head += 1 }
        if head > 1_024, head * 2 > storage.count {
            storage.removeFirst(head)
            head = 0
        }
    }

    /// Everything from `time` on, oldest first.
    public func samples(since time: Double) -> [Sample] {
        var start = head
        // Samples arrive in time order, so a binary search would do; the pre-roll is short
        // and this runs once per event.
        while start < storage.count, storage[start].time < time { start += 1 }
        return Array(storage[start...])
    }
}

/// Fires when the acceleration is sharp, and then stays quiet for a while: one crash is one
/// event, not four hundred.
public struct ShockTrigger: Sendable, Equatable {
    /// Magnitude of the user acceleration, in g.
    public var threshold: Double
    /// Seconds after a trigger during which another is ignored.
    public var holdOff: Double
    private var lastFired = -Double.infinity

    public init(threshold: Double, holdOff: Double) {
        self.threshold = threshold
        self.holdOff = holdOff
    }

    /// `values` are the three axes of ``SensorID/userAcceleration``. Returns the magnitude when
    /// this sample fires the trigger.
    public mutating func check(time: Double, values: [Double]) -> Double? {
        guard values.count >= 3, time - lastFired >= holdOff else { return nil }
        let magnitude = (values[0] * values[0] + values[1] * values[1] + values[2] * values[2]).squareRoot()
        guard magnitude >= threshold else { return nil }
        lastFired = time
        return magnitude
    }

    public mutating func reset() {
        lastFired = -Double.infinity
    }
}
