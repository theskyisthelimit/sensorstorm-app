import Foundation

/// An IPv4 address as the number it is, so that a subnet is arithmetic and not string work.
public struct IPv4Address: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let value: UInt32

    public init(_ value: UInt32) {
        self.value = value
    }

    /// `192.168.1.10`. Anything else — a missing octet, a number above 255, a leading plus,
    /// trailing text — is `nil`: an address typed into a scanner is not the place to guess.
    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let octet = UInt8(part) else { return nil }
            result = result << 8 | UInt32(octet)
        }
        self.value = result
    }

    public init(octets: [UInt8]) {
        precondition(octets.count == 4)
        self.value = octets.reduce(0) { $0 << 8 | UInt32($1) }
    }

    public var octets: [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    public var description: String {
        octets.map(String.init).joined(separator: ".")
    }

    public static func < (lhs: IPv4Address, rhs: IPv4Address) -> Bool {
        lhs.value < rhs.value
    }

    /// RFC 1918.
    public var isPrivate: Bool {
        let o = octets
        return o[0] == 10 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168)
    }

    /// 169.254.0.0/16 — what a device gives itself when no DHCP server answered.
    public var isLinkLocal: Bool {
        let o = octets
        return o[0] == 169 && o[1] == 254
    }

    public var isLoopback: Bool { octets[0] == 127 }

    /// 100.64.0.0/10 — carrier-grade NAT, and where Tailscale puts its addresses.
    public var isSharedAddressSpace: Bool {
        let o = octets
        return o[0] == 100 && (64...127).contains(o[1])
    }

    /// The name a PTR query asks for: octets reversed under `in-addr.arpa`.
    public var reverseName: String {
        octets.reversed().map(String.init).joined(separator: ".") + ".in-addr.arpa"
    }
}

/// A subnet, from an address and its netmask.
public struct IPv4Subnet: Hashable, Sendable, CustomStringConvertible {
    public let address: IPv4Address
    public let prefix: Int

    /// `nil` when the mask is not a run of ones followed by a run of zeros — which is how an
    /// interface list occasionally reports a broken one.
    public init?(address: IPv4Address, netmask: IPv4Address) {
        let mask = netmask.value
        let ones = mask.nonzeroBitCount
        guard mask == (ones == 0 ? 0 : UInt32.max << UInt32(32 - ones)) else { return nil }
        self.address = address
        self.prefix = ones
    }

    public init?(address: IPv4Address, prefix: Int) {
        guard (0...32).contains(prefix) else { return nil }
        self.address = address
        self.prefix = prefix
    }

    private var mask: UInt32 { prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix) }

    public var network: IPv4Address { IPv4Address(address.value & mask) }
    public var broadcast: IPv4Address { IPv4Address(address.value | ~mask) }

    /// Addresses a host can have: everything but the network and broadcast address. A /31 and
    /// a /32 have no such waste.
    public var hostCount: Int {
        switch prefix {
        case 32: 1
        case 31: 2
        default: Int(1 << UInt64(32 - prefix)) - 2
        }
    }

    public func contains(_ other: IPv4Address) -> Bool {
        other.value & mask == network.value
    }

    /// Host addresses in ascending order, without `excluding` — normally the phone's own.
    ///
    /// A subnet larger than `limit` hosts is cut down to the window around the phone's own
    /// address: a ping sweep of a /16 is sixty-five thousand packets and a quarter of an hour,
    /// and the neighbours are the ones that answer.
    public func hosts(excluding: Set<IPv4Address> = [], limit: Int = 1_024) -> [IPv4Address] {
        guard hostCount > 0, limit > 0 else { return [] }
        let first = prefix >= 31 ? network.value : network.value + 1
        let last = prefix >= 31 ? broadcast.value : broadcast.value - 1
        var low = first
        var high = last
        if Int(last - first) + 1 > limit {
            // The window of `limit` addresses that has the phone's own address in the middle,
            // pushed back inside the subnet where it would run over an edge.
            let half = UInt32(limit / 2)
            var start = address.value >= first + half ? address.value - half : first
            start = min(max(start, first), last - UInt32(limit) + 1)
            low = start
            high = start + UInt32(limit) - 1
        }
        return (low...high).map(IPv4Address.init).filter { !excluding.contains($0) }
    }

    public var description: String { "\(network)/\(prefix)" }
}
