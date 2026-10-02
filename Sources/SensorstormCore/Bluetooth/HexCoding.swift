import Foundation

/// Bytes as the text a person types and reads: `0A FF 12`.
public enum HexCoding {

    /// Reads hexadecimal bytes out of text. Spaces, commas, dashes, colons and a leading `0x`
    /// on each byte are ignored; an odd number of digits, or a character that is not one, is
    /// not guessed at — a write to a device is not the place for a forgiving parser.
    public static func data(_ text: String) -> Data? {
        var digits = ""
        for token in text.split(whereSeparator: { " ,;:-\n\t".contains($0) }) {
            var part = token.lowercased()
            if part.hasPrefix("0x") { part.removeFirst(2) }
            digits += part
        }
        guard digits.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    public static func string(_ data: Data, separator: String = " ") -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: separator)
    }

    /// The printable-ASCII reading of a value, with a dot for everything else — the right
    /// column of a hex dump, enough to see that a characteristic holds a name.
    public static func ascii(_ data: Data) -> String {
        String(data.map { $0 >= 0x20 && $0 < 0x7F ? Character(UnicodeScalar($0)) : "." })
    }

    /// A hex dump: an offset, `width` bytes in hex and the printable reading, one line each.
    ///
    ///     0000  48 65 6C 6C 6F 20 77 6F 72 6C 64 21 00 00 00 00  Hello world!....
    ///
    /// `firstOffset` shifts the offsets, so a window of a larger memory keeps its addresses.
    public static func dump(_ data: Data, width: Int = 16, firstOffset: Int = 0) -> String {
        let width = max(width, 1)
        let bytes = [UInt8](data)
        var lines: [String] = []
        var start = 0
        while start < bytes.count {
            let row = Array(bytes[start..<min(start + width, bytes.count)])
            let hex = row.map { String(format: "%02X", $0) }.joined(separator: " ")
            let padding = String(repeating: "   ", count: width - row.count)
            lines.append(String(format: "%04X  ", firstOffset + start) + hex + padding + "  " + ascii(Data(row)))
            start += width
        }
        return lines.joined(separator: "\n")
    }

    /// A number as the bytes a characteristic takes.
    public static func bytes(of value: UInt64, width: Int, bigEndian: Bool) -> Data {
        var out = (0..<max(width, 1)).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
        if bigEndian { out.reverse() }
        return Data(out)
    }
}

/// A starting point for a decoder file, written from a device that is in front of the person.
///
/// Most of the work in writing a decoder is finding out which company ID or service UUID to
/// match and what the bytes look like. The scanner knows both, so the file it hands over has
/// the match filled in and the current bytes in a comment — what is left is the arithmetic.
public enum DecoderTemplate {
    public static func make(for device: ScannedDevice) -> String {
        let name = (device.name?.isEmpty == false ? device.name! : "My device")
            .replacingOccurrences(of: "\"", with: "'")
        if let data = device.manufacturerData, let company = BluetoothNames.company(in: data) {
            return """
            // Decoder for \(name). bytes holds the manufacturer data including its two
            // company-ID bytes (company \(String(format: "0x%04X", company.id))\(company.name.map { ", \($0)" } ?? "")).
            // Right now: \(HexCoding.string(data))
            decoder({
              name: "\(name)",
              manufacturerId: \(String(format: "0x%04X", company.id)),
              decode: function (bytes) {
                // Return numbers as { name: value }, or null when the packet does not fit.
                return { value: bytes[2] };
              }
            });
            """
        }
        if let (uuid, data) = device.serviceData.sorted(by: { $0.key < $1.key }).first {
            return """
            // Decoder for \(name). bytes holds the service data of \(uuid).
            // Right now: \(HexCoding.string(data))
            decoder({
              name: "\(name)",
              serviceUuid: "\(uuid)",
              decode: function (bytes) {
                return { value: bytes[0] };
              }
            });
            """
        }
        let prefix = String(name.prefix(6))
        return """
        // Decoder for \(name). This device sends neither manufacturer data nor service data;
        // its name is the only thing to recognise it by.
        decoder({
          name: "\(name)",
          namePrefix: "\(prefix)",
          decode: function (bytes) {
            return null;
          }
        });
        """
    }
}
