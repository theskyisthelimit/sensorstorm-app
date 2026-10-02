import Foundation

/// How far two devices' clocks are apart, measured the way NTP does it, over any link that
/// carries a question and an answer — here a Bluetooth read.
///
/// The local device notes when it asked (`t0`), the remote device says what its clock read when
/// it answered (`t1`), the local device notes when the answer arrived (`t2`). If the way there
/// and back took equally long, the remote clock was read at the local moment `(t0 + t2) / 2`,
/// and the difference is the offset. They never take exactly equally long, which is why the
/// result carries its own uncertainty: half the round trip is the most the asymmetry can hide.
public struct PeerClockSample: Sendable, Equatable {
    public var asked: Double
    public var remote: Double
    public var answered: Double

    public init(asked: Double, remote: Double, answered: Double) {
        self.asked = asked
        self.remote = remote
        self.answered = answered
    }

    public var roundTrip: Double { answered - asked }
    /// What to add to a local time to get the remote time.
    public var offset: Double { remote - (asked + answered) / 2 }
}

public struct PeerClockEstimate: Codable, Sendable, Hashable {
    /// Remote clock minus local clock, seconds. A remote time `t` is local time `t − offset`.
    public var offset: Double
    /// Seconds. The shortest round trip seen, halved, or the spread of the best offsets if
    /// that is larger: the error one cannot rule out.
    public var uncertainty: Double
    public var sampleCount: Int
    public var bestRoundTrip: Double

    public init(offset: Double, uncertainty: Double, sampleCount: Int, bestRoundTrip: Double) {
        self.offset = offset
        self.uncertainty = uncertainty
        self.sampleCount = sampleCount
        self.bestRoundTrip = bestRoundTrip
    }
}

public enum PeerClock {
    /// The median offset of the quicker half of the exchanges. A slow exchange is a slow
    /// exchange mostly on one leg, and its offset is wrong by that much; a quick one cannot
    /// be wrong by more than its round trip.
    public static func estimate(_ samples: [PeerClockSample]) -> PeerClockEstimate? {
        let usable = samples.filter { $0.roundTrip >= 0 && $0.roundTrip.isFinite && $0.offset.isFinite }
        guard usable.count >= 3 else { return nil }
        let quick = usable.sorted { $0.roundTrip < $1.roundTrip }.prefix(max(usable.count / 2, 3))
        let offsets = quick.map(\.offset).sorted()
        let median = offsets[offsets.count / 2]
        let spread = (offsets.last ?? median) - (offsets.first ?? median)
        let best = quick.first?.roundTrip ?? 0
        return PeerClockEstimate(offset: median, uncertainty: max(best / 2, spread / 2),
                                 sampleCount: usable.count, bestRoundTrip: best)
    }

    /// A remote timestamp on the local clock.
    public static func local(from remote: Double, using estimate: PeerClockEstimate) -> Double {
        remote - estimate.offset
    }
}
