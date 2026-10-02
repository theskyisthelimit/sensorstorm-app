import Foundation

/// A hardware address, six bytes, with the two bits of the first byte that say what kind it is.
public struct MACAddress: Hashable, Sendable, Codable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == 6 else { return nil }
        self.bytes = bytes
    }

    /// „aa:bb:cc:dd:ee:ff", with `-`, `.` or nothing between the pairs. `nil` for anything that
    /// is not exactly six bytes of hex.
    public init?(_ text: String) {
        guard let parsed = WakeOnLAN.parseMAC(text) else { return nil }
        self.bytes = parsed
    }

    /// The first three bytes: the part the IEEE hands to a manufacturer.
    public var oui: UInt32 {
        UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[2])
    }

    /// Bit 1 of the first byte. Set means the address was made up by software rather than
    /// burned in by the manufacturer — the „private Wi-Fi address" an iPhone, a recent Android
    /// or a Windows machine uses on purpose. It has no vendor, and saying so is the honest
    /// answer; a lookup would match some unrelated company by accident.
    public var isLocallyAdministered: Bool { bytes[0] & 0x02 != 0 }

    /// Bit 0 of the first byte: a group address, never a single device's own.
    public var isMulticast: Bool { bytes[0] & 0x01 != 0 }

    /// `aa:bb:cc:dd:ee:ff`.
    public var description: String { formatted() }

    public func formatted(uppercase: Bool = false, separator: String = ":") -> String {
        bytes.map { String(format: uppercase ? "%02X" : "%02x", $0) }.joined(separator: separator)
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = WakeOnLAN.parseMAC(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "not a hardware address"))
        }
        self.bytes = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Who made the network chip: the IEEE's registers of address blocks, shipped with the app.
///
/// The list holds the three registers the IEEE keeps: MA-L (24-bit prefixes, six hex digits),
/// MA-M (28 bit, seven digits) and MA-S (36 bit, nine digits). Many small makers of sensors
/// and smart plugs own only an MA-S block carved out of a larger one, so the longest prefix
/// that matches wins. One prefix and name per line, sorted by bytes, deflate-compressed: some
/// 53 000 entries in about half a megabyte. It is searched in place, with no dictionary built,
/// so loading costs one decompression and a pass over the text to find where the lines start.
public final class OUIDatabase: @unchecked Sendable {
    private let text: [UInt8]
    /// Offset of each line, in file order — which is key order, since the file is sorted.
    private let lines: [Int32]

    /// `text` is the decompressed list: `KEY<TAB>Name<LF>`, sorted by the bytes of the key.
    public init(text: Data) {
        let bytes = [UInt8](text)
        var starts: [Int32] = []
        starts.reserveCapacity(bytes.count / 32)
        var lineStart = 0
        for (index, byte) in bytes.enumerated() where byte == 0x0A {
            if index - lineStart >= 8 { starts.append(Int32(lineStart)) }
            lineStart = index + 1
        }
        if bytes.count - lineStart >= 8 { starts.append(Int32(lineStart)) }
        self.text = bytes
        self.lines = starts
    }

    /// From the list as shipped: raw deflate. `nil` if it does not decompress.
    public convenience init?(compressed: Data) {
        guard let data = try? (compressed as NSData).decompressed(using: .zlib) as Data, !data.isEmpty else { return nil }
        self.init(text: data)
    }

    public var count: Int { lines.count }

    /// The manufacturer, or `nil` for a prefix that is not listed and for a locally
    /// administered address, which has no manufacturer to find.
    public func vendor(of mac: MACAddress) -> String? {
        guard !mac.isLocallyAdministered, !mac.isMulticast else { return nil }
        let hex = Array(mac.formatted(uppercase: true, separator: "").utf8)
        for length in [9, 7, 6] {
            if let name = find(Array(hex.prefix(length))) { return name }
        }
        return nil
    }

    /// The owner of a 24-bit prefix.
    public func vendor(oui: UInt32) -> String? {
        find(Array(String(format: "%06X", oui).utf8))
    }

    private func find(_ key: [UInt8]) -> String? {
        var low = 0
        var high = lines.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let start = Int(lines[middle])
            switch compare(at: start, with: key) {
            case 0:
                var begin = start
                while begin < text.count, text[begin] != 0x09 { begin += 1 }
                begin += 1
                var end = begin
                while end < text.count, text[end] != 0x0A { end += 1 }
                return String(decoding: text[begin..<end], as: UTF8.self)
            case ..<0:
                low = middle + 1
            default:
                high = middle - 1
            }
        }
        return nil
    }

    /// Orders the key of the line at `start` against `key`, byte by byte; a key that is a
    /// prefix of the other comes first, as in the sorted file.
    private func compare(at start: Int, with key: [UInt8]) -> Int {
        var offset = 0
        while true {
            let position = start + offset
            let lineEnded = position >= text.count || text[position] == 0x09
            if lineEnded { return offset == key.count ? 0 : -1 }
            if offset == key.count { return 1 }
            if text[position] != key[offset] { return text[position] < key[offset] ? -1 : 1 }
            offset += 1
        }
    }

    /// A manufacturer's name as the registry writes it — „Apple, Inc.", „Hon Hai Precision
    /// Ind. Co.,Ltd." — cut down to what fits a list row: the legal form and the tail after the
    /// first comma go.
    public static func shortName(_ registered: String) -> String {
        var name = registered
        if let comma = name.firstIndex(of: ","), name.distance(from: name.startIndex, to: comma) >= 3 {
            name = String(name[..<comma])
        }
        let suffixes = [" Inc.", " Inc", " Corporation", " Corp.", " Corp", " Co., Ltd.", " Co.,Ltd.", " Co.,Ltd",
                        " Co. Ltd.", " Co.", " Ltd.", " Ltd", " GmbH", " LLC", " AG", " B.V.", " S.A.", " Limited",
                        " Technologies", " Technology", " Electronics", " Electric", " Communications"]
        var changed = true
        while changed {
            changed = false
            for suffix in suffixes where name.count > suffix.count + 2 && name.lowercased().hasSuffix(suffix.lowercased()) {
                name = String(name.dropLast(suffix.count))
                changed = true
            }
        }
        return name.trimmingCharacters(in: .whitespaces)
    }
}
