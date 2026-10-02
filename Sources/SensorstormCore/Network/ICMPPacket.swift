import Foundation

/// ICMP echo, the packet behind ping and traceroute.
///
/// iOS lets an app open a datagram ICMP socket without any privilege — what it may not do is
/// open a raw one. The kernel then hands back whole IP packets, header included, so reading a
/// reply means skipping that header first. All of that is bytes in, bytes out, and sits here
/// where it can be tested; opening the socket does not.
public enum ICMPPacket {

    /// The Internet checksum: the ones' complement of the ones' complement sum of 16-bit
    /// words, with an odd last byte padded by a zero.
    public static func checksum(_ data: Data) -> UInt16 {
        var sum: UInt32 = 0
        let bytes = [UInt8](data)
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count { sum += UInt32(bytes[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum & 0xFFFF)
    }

    /// Type 8, code 0.
    public static func echoRequest(identifier: UInt16, sequence: UInt16, payload: Data = Data()) -> Data {
        var packet = Data([8, 0, 0, 0])
        packet.append(UInt8(identifier >> 8)); packet.append(UInt8(identifier & 0xFF))
        packet.append(UInt8(sequence >> 8)); packet.append(UInt8(sequence & 0xFF))
        packet.append(payload)
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xFF)
        return packet
    }

    public struct Reply: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case echoReply
            /// A router on the way dropped the packet because its TTL ran out — what
            /// traceroute listens for.
            case timeExceeded
            case destinationUnreachable(code: Int)
            case other(type: Int)
        }

        public var kind: Kind
        /// Who sent this packet: the target for an echo reply, a router for the others.
        public var source: IPv4Address?
        public var identifier: UInt16?
        public var sequence: UInt16?
        public var ttl: Int?
    }

    /// Reads what came back on an ICMP datagram socket. `nil` for anything too short to be one.
    ///
    /// For time-exceeded and unreachable the identifier and sequence are those of the packet
    /// that provoked the answer, taken from the copy the router sends back, so the reply can
    /// be matched to the probe that caused it.
    public static func parseReply(_ data: Data) -> Reply? {
        let b = [UInt8](data)
        guard b.count >= 8 else { return nil }

        var offset = 0
        var source: IPv4Address?
        var ttl: Int?
        if b[0] >> 4 == 4 {
            let headerLength = Int(b[0] & 0x0F) * 4
            guard headerLength >= 20, b.count >= headerLength + 8 else { return nil }
            ttl = Int(b[8])
            source = IPv4Address(octets: Array(b[12..<16]))
            offset = headerLength
        }
        let type = Int(b[offset])
        let code = Int(b[offset + 1])

        func word(_ array: [UInt8], _ index: Int) -> UInt16 {
            UInt16(array[index]) << 8 | UInt16(array[index + 1])
        }

        switch type {
        case 0:
            return Reply(kind: .echoReply, source: source, identifier: word(b, offset + 4),
                         sequence: word(b, offset + 6), ttl: ttl)
        case 3, 11:
            // 8 bytes of ICMP header, then the offending packet's IP header and its first 8 bytes.
            let inner = offset + 8
            var identifier: UInt16?
            var sequence: UInt16?
            if b.count > inner, b[inner] >> 4 == 4 {
                let innerHeader = Int(b[inner] & 0x0F) * 4
                let echo = inner + innerHeader
                if innerHeader >= 20, b.count >= echo + 8 {
                    identifier = word(b, echo + 4)
                    sequence = word(b, echo + 6)
                }
            }
            return Reply(kind: type == 11 ? .timeExceeded : .destinationUnreachable(code: code),
                         source: source, identifier: identifier, sequence: sequence, ttl: ttl)
        default:
            return Reply(kind: .other(type: type), source: source, identifier: nil, sequence: nil, ttl: ttl)
        }
    }
}

/// What a series of pings says, in the numbers a network person reads.
public struct PingStatistics: Sendable, Equatable {
    public private(set) var sent = 0
    public private(set) var received = 0
    public private(set) var minimum: Double?
    public private(set) var maximum: Double?
    private var sum = 0.0
    private var previous: Double?
    private var jitterSum = 0.0
    private var jitterCount = 0

    public init() {}

    /// Seconds, or `nil` for a probe that got no answer.
    public mutating func record(_ roundTrip: Double?) {
        sent += 1
        guard let roundTrip else { return }
        received += 1
        sum += roundTrip
        minimum = min(minimum ?? roundTrip, roundTrip)
        maximum = max(maximum ?? roundTrip, roundTrip)
        // Jitter as RFC 3550 means it for a stream: the mean difference between successive
        // round trips, not the spread around the average.
        if let previous {
            jitterSum += abs(roundTrip - previous)
            jitterCount += 1
        }
        previous = roundTrip
    }

    public var average: Double? { received > 0 ? sum / Double(received) : nil }
    public var lossPercent: Double { sent > 0 ? Double(sent - received) / Double(sent) * 100 : 0 }
    public var jitter: Double? { jitterCount > 0 ? jitterSum / Double(jitterCount) : nil }
}
