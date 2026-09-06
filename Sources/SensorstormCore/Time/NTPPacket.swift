import Foundation

/// The wire format of SNTP (RFC 4330), and the offset computed from one exchange.
///
/// **This never touches the clock the app records on.** Every sample is stamped with
/// `mach_absolute_time` seconds, and that is what makes a video frame and an acceleration
/// value line up without calibration — a value fetched over a network has no business
/// moving it. The offset is measured, written into the recording's metadata, and left
/// there: two phones that each recorded their own offset can be put on one timeline
/// afterwards, and nothing on either device changes in the meantime.
///
/// The packet building and parsing live here, apart from the socket, because this is where
/// the mistakes are: a 64-bit fixed-point timestamp with an epoch 70 years before Unix's,
/// and a four-timestamp formula that is easy to write with the signs swapped.
public enum NTPPacket {

    /// Seconds between 1900-01-01 (the NTP epoch) and 1970-01-01 (the Unix one).
    /// 70 years, of which 17 were leap years.
    public static let epochDelta: Double = 2_208_988_800

    public static let size = 48

    /// A client request: LI = 0, VN = 4, Mode = 3, everything else zero except the
    /// transmit timestamp, which the server echoes back as the originate timestamp.
    public static func request(transmitTime: Double) -> Data {
        var packet = Data(repeating: 0, count: size)
        packet[0] = 0b00_100_011
        writeTimestamp(transmitTime + epochDelta, into: &packet, at: 40)
        return packet
    }

    /// What one exchange measured.
    public struct Reading: Sendable, Hashable {
        /// Add this to the device's clock to get network time. Positive means the device
        /// is running behind.
        public var offsetSeconds: Double
        /// Round-trip delay. The offset is only ever as good as this is small — the whole
        /// method assumes the two legs of the journey took the same time.
        public var roundTripSeconds: Double

        public init(offsetSeconds: Double, roundTripSeconds: Double) {
            self.offsetSeconds = offsetSeconds
            self.roundTripSeconds = roundTripSeconds
        }
    }

    /// The four-timestamp formula, spelled out because the signs are easy to get wrong:
    ///
    /// - `t1` the client's transmit time, `t2` the server's receive time,
    ///   `t3` the server's transmit time, `t4` the client's receive time.
    /// - `offset  = ((t2 − t1) + (t3 − t4)) / 2`
    /// - `delay   = (t4 − t1) − (t3 − t2)`
    ///
    /// Returns `nil` for a reply that is not a usable server response: wrong mode, a
    /// stratum of 0 (a "kiss-o'-death" packet, which is a refusal, not a time), or a zero
    /// transmit timestamp.
    public static func reading(from data: Data, sentAt t1: Double, receivedAt t4: Double)
        -> Reading? {
        guard data.count >= size else { return nil }
        let mode = data[0] & 0b111
        let stratum = data[1]
        guard mode == 4, stratum > 0, stratum < 16 else { return nil }

        let t2 = timestamp(in: data, at: 32) - epochDelta
        let t3 = timestamp(in: data, at: 40) - epochDelta
        guard t2 > 0, t3 > 0 else { return nil }

        return Reading(offsetSeconds: ((t2 - t1) + (t3 - t4)) / 2,
                       roundTripSeconds: (t4 - t1) - (t3 - t2))
    }

    // MARK: - The 64-bit fixed-point timestamp

    /// 32 bits of seconds since 1900, then 32 bits of fraction. Big-endian, like everything
    /// else on the wire.
    static func timestamp(in data: Data, at offset: Int) -> Double {
        var seconds: UInt32 = 0
        var fraction: UInt32 = 0
        for index in 0..<4 {
            seconds = seconds << 8 | UInt32(data[data.startIndex + offset + index])
            fraction = fraction << 8 | UInt32(data[data.startIndex + offset + 4 + index])
        }
        return Double(seconds) + Double(fraction) / 4_294_967_296
    }

    static func writeTimestamp(_ value: Double, into data: inout Data, at offset: Int) {
        let seconds = UInt32(truncatingIfNeeded: Int64(value.rounded(.down)))
        let fraction = UInt32((value - value.rounded(.down)) * 4_294_967_296)
        for index in 0..<4 {
            data[data.startIndex + offset + index] =
                UInt8(truncatingIfNeeded: seconds >> (8 * (3 - index)))
            data[data.startIndex + offset + 4 + index] =
                UInt8(truncatingIfNeeded: fraction >> (8 * (3 - index)))
        }
    }
}

/// What a recording knows about network time, if anything.
///
/// Stored, never applied. See ``NTPPacket`` for why.
public struct TimeReference: Codable, Sendable, Hashable {
    public var server: String
    /// Add to the device clock to get network time.
    public var offsetSeconds: Double
    public var roundTripSeconds: Double
    /// Host time at which the exchange happened, so the offset can be aged.
    public var hostTime: Double

    public init(server: String, offsetSeconds: Double, roundTripSeconds: Double,
                hostTime: Double) {
        self.server = server
        self.offsetSeconds = offsetSeconds
        self.roundTripSeconds = roundTripSeconds
        self.hostTime = hostTime
    }
}
