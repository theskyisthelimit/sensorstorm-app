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

/// Who made the network chip: the IEEE's list of 24-bit prefixes, shipped with the app.
///
/// The list is the IEEE MA-L registry as compiled by the oui-data project, one prefix and
/// name per line, sorted, deflate-compressed — 53 000 manufacturers in about half a megabyte.
/// It is searched in place, with no dictionary built, so loading costs one decompression and
/// a pass over the text to find where the lines start.
public final class OUIDatabase: @unchecked Sendable {
    private let text: [UInt8]
    /// Offset of each line, in file order — which is prefix order, since the file is sorted.
    private let lines: [Int32]

    /// `text` is the decompressed list: `AABBCC<TAB>Name<LF>`, sorted by prefix.
    public init(text: Data) {
        let bytes = [UInt8](text)
        var starts: [Int32] = []
        starts.reserveCapacity(bytes.count / 32)
        var lineStart = 0
        for (index, byte) in bytes.enumerated() where byte == 0x0A {
            if index - lineStart > 7 { starts.append(Int32(lineStart)) }
            lineStart = index + 1
        }
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
        return vendor(oui: mac.oui)
    }

    public func vendor(oui: UInt32) -> String? {
        var low = 0
        var high = lines.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let start = Int(lines[middle])
            guard let key = prefix(at: start) else { return nil }
            if key == oui {
                var end = start + 7
                while end < text.count, text[end] != 0x0A { end += 1 }
                return String(decoding: text[(start + 7)..<end], as: UTF8.self)
            }
            if key < oui { low = middle + 1 } else { high = middle - 1 }
        }
        return nil
    }

    private func prefix(at start: Int) -> UInt32? {
        guard start + 7 <= text.count else { return nil }
        var value: UInt32 = 0
        for offset in 0..<6 {
            let digit = text[start + offset]
            let nibble: UInt32
            switch digit {
            case 0x30...0x39: nibble = UInt32(digit - 0x30)
            case 0x41...0x46: nibble = UInt32(digit - 0x41 + 10)
            case 0x61...0x66: nibble = UInt32(digit - 0x61 + 10)
            default: return nil
            }
            value = value << 4 | nibble
        }
        return value
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
