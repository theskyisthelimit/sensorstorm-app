import Foundation

/// One line of the IPv4 routing table: where traffic for a destination goes next.
public struct RouteEntry: Sendable, Equatable {
    public enum Gateway: Sendable, Equatable {
        /// Hand the packet to this router.
        case address(IPv4Addr)
        /// The destination is on the link of this interface: no router in between. The hardware
        /// address is there when the entry came from a resolved neighbour.
        case link(interface: Int, mac: MACAddress?)
        case none
    }

    /// `nil` is the default route, `0.0.0.0/0`.
    public var destination: IPv4Addr?
    /// `nil` for a route to one host.
    public var prefix: Int?
    public var gateway: Gateway
    public var flags: UInt32
    public var interfaceIndex: Int

    public var isDefault: Bool { destination == nil && prefix == 0 }
    public var isHostRoute: Bool { flags & 0x4 != 0 }

    /// A neighbour the kernel made a route for when the phone talked to it, not a route that
    /// anyone configured. A busy network has hundreds, which hide the few that matter.
    public var isCloned: Bool { flags & 0x20000 != 0 }

    /// `UGSc`: the flags as `netstat -r` prints them.
    public var flagLetters: String {
        Self.letters.filter { flags & $0.0 != 0 }.map(\.1).joined()
    }

    static let letters: [(UInt32, String)] = [
        (0x1, "U"), (0x2, "G"), (0x4, "H"), (0x8, "R"), (0x10, "D"), (0x20, "M"), (0x40, "d"),
        (0x100, "C"), (0x200, "X"), (0x400, "L"), (0x800, "S"), (0x1000, "B"), (0x4000, "2"),
        (0x8000, "1"), (0x10000, "c"), (0x20000, "W"), (0x40000, "3"), (0x100000, "p"),
        (0x200000, "l"), (0x400000, "b"), (0x800000, "m"), (0x1000000, "I"), (0x2000000, "Z"),
        (0x4000000, "i"), (0x8000000, "Y"), (0x10000000, "r"), (0x40000000, "g"),
    ]

    /// What each letter means, for a legend. The ones a person meets in a home network come first.
    public static let legend: [(letter: String, meaning: String)] = [
        ("U", "up"), ("G", "gateway"), ("H", "host"), ("S", "static"), ("C", "cloning"),
        ("c", "generates host routes"), ("W", "was cloned"), ("L", "link-layer info"), ("I", "interface scoped"),
        ("b", "broadcast"), ("m", "multicast"), ("R", "reject"), ("B", "blackhole"), ("D", "dynamic (redirect)"),
        ("M", "modified (redirect)"), ("g", "global"), ("r", "router"), ("i", "interface reference"),
    ]
}

/// The kernel's routing table, read from the `NET_RT_DUMP` message list. Same layout as the
/// neighbour table (`ARPTable`): a route header, then the addresses its bit mask announces.
public enum RouteTable {

    public static func parse(_ buffer: [UInt8], headerSize: Int = ARPTable.headerSize) -> [RouteEntry] {
        var routes: [RouteEntry] = []
        var offset = 0
        while offset + headerSize <= buffer.count {
            let length = Int(buffer[offset]) | Int(buffer[offset + 1]) << 8
            guard length >= headerSize, offset + length <= buffer.count else { break }
            let interface = Int(buffer[offset + 4]) | Int(buffer[offset + 5]) << 8
            let flags = (0..<4).reduce(UInt32(0)) { $0 | UInt32(buffer[offset + 8 + $1]) << UInt32(8 * $1) }
            let addrs = (0..<4).reduce(0) { $0 | Int(buffer[offset + 12 + $1]) << (8 * $1) }
            if let route = route(buffer, start: offset + headerSize, end: offset + length,
                                 addrs: addrs, flags: flags, interface: interface) {
                routes.append(route)
            }
            offset += length
        }
        return routes
    }

    private static func route(_ b: [UInt8], start: Int, end: Int, addrs: Int, flags: UInt32,
                              interface: Int) -> RouteEntry? {
        var cursor = start
        var destination: IPv4Addr?
        var hasDestination = false
        var gateway = RouteEntry.Gateway.none
        var mask: UInt32?

        for bit in 0..<8 where addrs & (1 << bit) != 0 {
            guard cursor + 1 <= end else { return nil }
            let size = Int(b[cursor])
            let family = cursor + 1 < end ? Int(b[cursor + 1]) : 0
            switch bit {
            case 0 where family == 2:
                hasDestination = true
                destination = IPv4Addr(UInt32(octets(b, cursor + 4, min(cursor + size, end))))
            case 1 where family == 2:
                gateway = .address(IPv4Addr(UInt32(octets(b, cursor + 4, min(cursor + size, end)))))
            case 1 where family == 18 && size >= 8 && cursor + 8 <= end:
                let index = Int(b[cursor + 2]) | Int(b[cursor + 3]) << 8
                let nameLength = Int(b[cursor + 5])
                let addressLength = Int(b[cursor + 6])
                let first = cursor + 8 + nameLength
                let mac = addressLength == 6 && first + 6 <= end
                    ? MACAddress(bytes: Array(b[first..<(first + 6)])) : nil
                gateway = .link(interface: index, mac: mac)
            case 2:
                // A netmask is stored cut short: only as many bytes as have a one in them.
                mask = size <= 4 ? 0 : octets(b, cursor + 4, min(cursor + size, end))
            default:
                break
            }
            cursor += size == 0 ? 4 : (size + 3) & ~3
        }
        guard hasDestination else { return nil }

        let isHost = flags & 0x4 != 0
        var prefix: Int? = isHost ? nil : (mask.map { $0.nonzeroBitCount } ?? 32)
        // 0.0.0.0 with an empty mask is the default route, which is shown as one.
        if !isHost, prefix == 0, destination?.value == 0 { destination = nil }
        return RouteEntry(destination: destination, prefix: prefix, gateway: gateway, flags: flags,
                          interfaceIndex: interface)
    }

    /// Up to four bytes of an address, big endian, the missing ones zero.
    private static func octets(_ b: [UInt8], _ from: Int, _ to: Int) -> UInt32 {
        var value: UInt32 = 0
        for position in 0..<4 {
            let index = from + position
            value = value << 8 | (index < to && index < b.count ? UInt32(b[index]) : 0)
        }
        return value
    }
}
