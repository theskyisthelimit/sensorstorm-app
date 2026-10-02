import Foundation

public enum DNSRecordType: UInt16, Sendable, CaseIterable {
    case a = 1
    case ns = 2
    case cname = 5
    case soa = 6
    case ptr = 12
    case mx = 15
    case txt = 16
    case aaaa = 28
    case srv = 33
    case any = 255

    public var label: String {
        switch self {
        case .a: "A"
        case .ns: "NS"
        case .cname: "CNAME"
        case .soa: "SOA"
        case .ptr: "PTR"
        case .mx: "MX"
        case .txt: "TXT"
        case .aaaa: "AAAA"
        case .srv: "SRV"
        case .any: "ANY"
        }
    }
}

public struct DNSRecord: Sendable, Equatable {
    public var name: String
    public var type: UInt16
    public var ttl: UInt32
    /// The data in the form a person reads it: an address, a name, `10 mail.example.com`,
    /// the text of a TXT record. Hex for a type this does not know.
    public var value: String

    public var typeLabel: String { DNSRecordType(rawValue: type)?.label ?? "TYPE\(type)" }
}

public struct DNSResponse: Sendable, Equatable {
    public var id: UInt16
    public var isResponse: Bool
    /// 0 no error, 2 server failure, 3 name does not exist, 5 refused.
    public var rcode: Int
    /// The answer did not fit in a UDP packet; asking again over TCP would give all of it.
    public var isTruncated: Bool
    public var answers: [DNSRecord]
    public var authorities: [DNSRecord]

    public var rcodeLabel: String {
        switch rcode {
        case 0: "NOERROR"
        case 1: "FORMERR"
        case 2: "SERVFAIL"
        case 3: "NXDOMAIN"
        case 4: "NOTIMP"
        case 5: "REFUSED"
        default: "RCODE\(rcode)"
        }
    }
}

/// DNS on the wire (RFC 1035): enough to ask any resolver a question and read what it says.
///
/// The system resolver answers for the app, but only for names the app has an address for —
/// it cannot say who handles a domain's mail, or ask a particular server, or time it. A
/// network tool has to do those itself.
public enum DNSMessage {

    /// A query for one name and type, recursion desired. `nil` for a name that cannot be
    /// encoded: an empty label, a label over 63 bytes, a whole name over 253.
    public static func query(id: UInt16, name: String, type: DNSRecordType,
                             recursionDesired: Bool = true) -> Data? {
        guard let encoded = encode(name) else { return nil }
        var data = Data()
        data.append(UInt8(id >> 8)); data.append(UInt8(id & 0xFF))
        data.append(recursionDesired ? 0x01 : 0x00); data.append(0x00)   // flags
        data.append(contentsOf: [0, 1, 0, 0, 0, 0, 0, 0])               // one question
        data.append(encoded)
        data.append(UInt8(type.rawValue >> 8)); data.append(UInt8(type.rawValue & 0xFF))
        data.append(contentsOf: [0, 1])                                  // class IN
        return data
    }

    static func encode(_ name: String) -> Data? {
        let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
        guard trimmed.utf8.count <= 253 else { return nil }
        var data = Data()
        if !trimmed.isEmpty {
            for label in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
                let bytes = Array(label.utf8)
                guard !bytes.isEmpty, bytes.count <= 63 else { return nil }
                data.append(UInt8(bytes.count))
                data.append(contentsOf: bytes)
            }
        }
        data.append(0)
        return data
    }

    /// `4.3.2.1.in-addr.arpa` for 1.2.3.4.
    public static func ptrName(for address: IPv4Addr) -> String { address.reverseName }

    public static func parse(_ data: Data) -> DNSResponse? {
        let b = [UInt8](data)
        guard b.count >= 12 else { return nil }
        let flags = UInt16(b[2]) << 8 | UInt16(b[3])
        let counts = (0..<4).map { Int(UInt16(b[4 + 2 * $0]) << 8 | UInt16(b[5 + 2 * $0])) }
        guard counts.allSatisfy({ $0 < 512 }) else { return nil }

        var offset = 12
        for _ in 0..<counts[0] {
            guard let (_, next) = readName(b, offset), next + 4 <= b.count else { return nil }
            offset = next + 4
        }
        func records(_ count: Int) -> [DNSRecord]? {
            var out: [DNSRecord] = []
            for _ in 0..<count {
                guard let (name, next) = readName(b, offset), next + 10 <= b.count else { return nil }
                let type = UInt16(b[next]) << 8 | UInt16(b[next + 1])
                let ttl = (4..<8).reduce(UInt32(0)) { $0 << 8 | UInt32(b[next + $1]) }
                let length = Int(UInt16(b[next + 8]) << 8 | UInt16(b[next + 9]))
                let start = next + 10
                guard start + length <= b.count else { return nil }
                out.append(DNSRecord(name: name, type: type, ttl: ttl,
                                     value: readData(b, type: type, start: start, length: length)))
                offset = start + length
            }
            return out
        }
        guard let answers = records(counts[1]), let authorities = records(counts[2]) else { return nil }
        return DNSResponse(id: UInt16(b[0]) << 8 | UInt16(b[1]),
                           isResponse: flags & 0x8000 != 0,
                           rcode: Int(flags & 0x000F),
                           isTruncated: flags & 0x0200 != 0,
                           answers: answers, authorities: authorities)
    }

    /// A name at `offset`, following compression pointers, and where the name ends *in place*
    /// (a pointer ends it after two bytes, however long the name it points to is). A pointer
    /// loop, or one that points forward past the packet, is `nil`.
    static func readName(_ b: [UInt8], _ start: Int) -> (String, Int)? {
        var labels: [String] = []
        var offset = start
        var end: Int?
        var jumps = 0
        while true {
            guard offset < b.count else { return nil }
            let length = Int(b[offset])
            if length == 0 {
                offset += 1
                break
            }
            if length & 0xC0 == 0xC0 {
                guard offset + 1 < b.count else { return nil }
                if end == nil { end = offset + 2 }
                offset = (length & 0x3F) << 8 | Int(b[offset + 1])
                jumps += 1
                guard jumps <= 16 else { return nil }
                continue
            }
            guard length & 0xC0 == 0, offset + 1 + length <= b.count else { return nil }
            labels.append(String(decoding: b[(offset + 1)..<(offset + 1 + length)], as: UTF8.self))
            offset += 1 + length
        }
        return (labels.joined(separator: "."), end ?? offset)
    }

    private static func readData(_ b: [UInt8], type: UInt16, start: Int, length: Int) -> String {
        let end = start + length
        switch type {
        case 1 where length == 4:
            return IPv4Addr(octets: Array(b[start..<end])).description
        case 28 where length == 16:
            return ipv6(Array(b[start..<end]))
        case 2, 5, 12:
            return readName(b, start)?.0 ?? hex(b[start..<end])
        case 15 where length >= 3:
            let preference = Int(UInt16(b[start]) << 8 | UInt16(b[start + 1]))
            return "\(preference) \(readName(b, start + 2)?.0 ?? "")"
        case 16:
            var parts: [String] = []
            var offset = start
            while offset < end {
                let size = Int(b[offset])
                guard offset + 1 + size <= end else { break }
                parts.append(String(decoding: b[(offset + 1)..<(offset + 1 + size)], as: UTF8.self))
                offset += 1 + size
            }
            return parts.joined()
        case 33 where length >= 7:
            let priority = Int(UInt16(b[start]) << 8 | UInt16(b[start + 1]))
            let weight = Int(UInt16(b[start + 2]) << 8 | UInt16(b[start + 3]))
            let port = Int(UInt16(b[start + 4]) << 8 | UInt16(b[start + 5]))
            return "\(priority) \(weight) \(port) \(readName(b, start + 6)?.0 ?? "")"
        case 6:
            guard let (primary, afterPrimary) = readName(b, start),
                  let (mailbox, afterMailbox) = readName(b, afterPrimary),
                  afterMailbox + 4 <= end else { return hex(b[start..<end]) }
            let serial = (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(b[afterMailbox + $1]) }
            return "\(primary) \(mailbox) \(serial)"
        default:
            return hex(b[start..<end])
        }
    }

    private static func hex(_ bytes: ArraySlice<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The compressed text form: the longest run of zero groups becomes `::`.
    static func ipv6(_ bytes: [UInt8]) -> String {
        let groups = (0..<8).map { UInt16(bytes[2 * $0]) << 8 | UInt16(bytes[2 * $0 + 1]) }
        var bestStart = -1, bestLength = 0, index = 0
        while index < 8 {
            if groups[index] == 0 {
                var run = index
                while run < 8, groups[run] == 0 { run += 1 }
                if run - index > bestLength { bestStart = index; bestLength = run - index }
                index = run
            } else {
                index += 1
            }
        }
        if bestLength < 2 { bestStart = -1 }
        var out = ""
        index = 0
        while index < 8 {
            if index == bestStart {
                out += "::"
                index += bestLength
                continue
            }
            if !out.isEmpty, !out.hasSuffix(":") { out += ":" }
            out += String(groups[index], radix: 16)
            index += 1
        }
        return out
    }
}

/// NetBIOS name service (UDP 137): what a Windows machine, a NAS or a printer calls itself.
///
/// A node status request for the wildcard name makes the machine list every name it has. It
/// is how an address that answers to nothing else gets a name — and iOS cannot read the
/// router's ARP table, so this is one of the few ways to put a name to a host.
public enum NetBIOSName {

    public struct Entry: Sendable, Equatable {
        public var name: String
        /// 0x00 workstation, 0x20 file server, 0x1B domain master browser, …
        public var suffix: UInt8
        public var isGroup: Bool
    }

    /// 50 bytes: a header and one NBSTAT question for `*`, first-level encoded.
    public static func statusRequest(id: UInt16) -> Data {
        var data = Data([UInt8(id >> 8), UInt8(id & 0xFF), 0, 0, 0, 1, 0, 0, 0, 0, 0, 0])
        data.append(0x20)
        data.append(contentsOf: Array("CKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".utf8))
        data.append(0)
        data.append(contentsOf: [0x00, 0x21, 0x00, 0x01])
        return data
    }

    public static func parse(_ data: Data) -> [Entry]? {
        let b = [UInt8](data)
        guard b.count >= 12, b[2] & 0x80 != 0 else { return nil }
        let answers = Int(UInt16(b[6]) << 8 | UInt16(b[7]))
        guard answers >= 1, let (_, next) = DNSMessage.readName(b, 12), next + 11 <= b.count else { return nil }
        // type, class, ttl, rdlength, then the name count
        let count = Int(b[next + 10])
        var offset = next + 11
        var entries: [Entry] = []
        for _ in 0..<count {
            guard offset + 18 <= b.count else { break }
            let name = String(decoding: b[offset..<(offset + 15)], as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
            let flags = UInt16(b[offset + 16]) << 8 | UInt16(b[offset + 17])
            entries.append(Entry(name: name, suffix: b[offset + 15], isGroup: flags & 0x8000 != 0))
            offset += 18
        }
        return entries.isEmpty ? nil : entries
    }

    /// The machine's own name: the first unique workstation entry.
    public static func hostName(_ entries: [Entry]) -> String? {
        entries.first { $0.suffix == 0x00 && !$0.isGroup }?.name
    }

    public static func workgroup(_ entries: [Entry]) -> String? {
        entries.first { $0.suffix == 0x00 && $0.isGroup }?.name
    }
}
