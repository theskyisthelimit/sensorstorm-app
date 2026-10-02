import Foundation

/// The kernel's neighbour table, read from the routing socket's message format.
///
/// The phone learns a host's hardware address the moment it exchanges a packet with it on the
/// local link, and keeps it for a few minutes. The table is where that is written down. Whether
/// iOS lets an app read it depends on the release — it has been closed off and opened up again —
/// so the reader is best effort and an empty answer means „not available", not „no hosts".
///
/// The layout is `struct rt_msghdr` followed by the addresses the `rtm_addrs` bits announce,
/// each a `sockaddr` padded to four bytes. A neighbour entry carries two: the IPv4 address
/// (`sockaddr_inarp`) and the link-layer address (`sockaddr_dl`).
public enum ARPTable {

    /// `sizeof(struct rt_msghdr)` on Darwin.
    public static let headerSize = 92

    public struct Entry: Sendable, Equatable {
        public var address: IPv4Addr
        public var mac: MACAddress
    }

    /// Every complete entry in a buffer the `NET_RT_FLAGS` sysctl returned. Entries without a
    /// hardware address yet (incomplete: the host did not answer), broadcast and multicast
    /// ones are left out. Malformed input gives what could be read before the damage.
    public static func parse(_ buffer: [UInt8], headerSize: Int = headerSize) -> [Entry] {
        var entries: [Entry] = []
        var offset = 0
        while offset + headerSize <= buffer.count {
            let length = Int(buffer[offset]) | Int(buffer[offset + 1]) << 8
            guard length >= headerSize, offset + length <= buffer.count else { break }
            let addrs = Int(buffer[offset + 12]) | Int(buffer[offset + 13]) << 8
                | Int(buffer[offset + 14]) << 16 | Int(buffer[offset + 15]) << 24
            if let entry = entry(buffer, start: offset + headerSize, end: offset + length, addrs: addrs) {
                entries.append(entry)
            }
            offset += length
        }
        return entries
    }

    private static func entry(_ b: [UInt8], start: Int, end: Int, addrs: Int) -> Entry? {
        var cursor = start
        var address: IPv4Addr?
        var mac: MACAddress?
        // RTA_DST is bit 0, RTA_GATEWAY bit 1; the others (netmask, genmask, …) follow.
        for bit in 0..<8 where addrs & (1 << bit) != 0 {
            guard cursor + 2 <= end else { return nil }
            let size = Int(b[cursor])
            let family = Int(b[cursor + 1])
            if bit == 0, family == 2, size >= 8, cursor + 8 <= end {
                address = IPv4Addr(octets: Array(b[(cursor + 4)..<(cursor + 8)]))
            } else if bit == 1, family == 18, size >= 8, cursor + 8 <= end {
                // sockaddr_dl: len, family, index(2), type, nlen, alen, slen, data…
                let nameLength = Int(b[cursor + 5])
                let addressLength = Int(b[cursor + 6])
                let first = cursor + 8 + nameLength
                if addressLength == 6, first + 6 <= end {
                    mac = MACAddress(bytes: Array(b[first..<(first + 6)]))
                }
            }
            cursor += size == 0 ? 4 : (size + 3) & ~3
        }
        guard let address, let mac, !mac.isMulticast,
              !mac.bytes.allSatisfy({ $0 == 0 }), !mac.bytes.allSatisfy({ $0 == 0xFF }) else { return nil }
        return Entry(address: address, mac: mac)
    }
}
