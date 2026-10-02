import Foundation

/// One record of an NDEF message, the format NFC tags carry their data in.
///
/// Core NFC hands a record over as an `NFCNDEFPayload`, which cannot be built or compared
/// without the framework. This is the same thing as plain bytes, so the codec, the builders for
/// URLs, text, Wi-Fi, contacts and Bluetooth, and the tests that check them all run anywhere.
public struct NDEFRecord: Sendable, Equatable, Hashable {

    /// The three-bit type name format of the record header.
    public enum Format: UInt8, Sendable {
        case empty = 0, wellKnown = 1, media = 2, absoluteURI = 3, external = 4, unknown = 5, unchanged = 6
    }

    public var format: Format
    public var type: Data
    public var identifier: Data
    public var payload: Data

    public init(format: Format, type: Data = Data(), identifier: Data = Data(), payload: Data = Data()) {
        self.format = format
        self.type = type
        self.identifier = identifier
        self.payload = payload
    }

    public static let empty = NDEFRecord(format: .empty)

    public var typeString: String { String(decoding: type, as: UTF8.self) }
}

public struct NDEFMessage: Sendable, Equatable, Hashable {
    public var records: [NDEFRecord]

    public init(records: [NDEFRecord]) {
        self.records = records
    }

    /// A tag that has been erased holds this: one empty record.
    public static let erased = NDEFMessage(records: [.empty])

    /// True for a message with no records, or only empty ones: nothing to read from the tag.
    public var isBlank: Bool { records.allSatisfy { $0.format == .empty } }

    // MARK: Encoding

    /// The message as it lies on the tag: MB on the first record, ME on the last, short-record
    /// form where the payload is under 256 bytes. An empty list encodes as one empty record,
    /// because a message with no record at all is not valid NDEF.
    public func serialized() -> Data {
        let list = records.isEmpty ? [NDEFRecord.empty] : records
        var data = Data()
        for (index, record) in list.enumerated() {
            let short = record.payload.count < 256
            var header = record.format.rawValue & 0x07
            if index == 0 { header |= 0x80 }
            if index == list.count - 1 { header |= 0x40 }
            if short { header |= 0x10 }
            if !record.identifier.isEmpty { header |= 0x08 }
            data.append(header)
            data.append(UInt8(min(record.type.count, 255)))
            if short {
                data.append(UInt8(record.payload.count))
            } else {
                let length = UInt32(record.payload.count)
                data.append(contentsOf: [UInt8(length >> 24), UInt8(length >> 16 & 0xFF),
                                         UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
            }
            if !record.identifier.isEmpty { data.append(UInt8(min(record.identifier.count, 255))) }
            data.append(record.type.prefix(255))
            data.append(record.identifier.prefix(255))
            data.append(record.payload)
        }
        return data
    }

    /// The bytes of the message in the bytes' size on the tag, for „fits / does not fit".
    public var byteCount: Int { serialized().count }

    // MARK: Decoding

    /// A message from bytes. `nil` for anything that is not well-formed NDEF: no begin or end
    /// mark, a length that runs past the data, a chunked record (which no tag in the wild
    /// carries), or trailing bytes after the last record.
    public init?(data: Data) {
        let b = [UInt8](data)
        var records: [NDEFRecord] = []
        var offset = 0
        var sawEnd = false
        while offset < b.count {
            guard !sawEnd else { return nil }
            let header = b[offset]
            offset += 1
            let begins = header & 0x80 != 0
            let ends = header & 0x40 != 0
            let chunked = header & 0x20 != 0
            let short = header & 0x10 != 0
            let hasIdentifier = header & 0x08 != 0
            guard begins == records.isEmpty, !chunked, let format = Format(rawValue: header & 0x07) else { return nil }
            guard offset < b.count else { return nil }
            let typeLength = Int(b[offset])
            offset += 1
            let payloadLength: Int
            if short {
                guard offset < b.count else { return nil }
                payloadLength = Int(b[offset])
                offset += 1
            } else {
                guard offset + 4 <= b.count else { return nil }
                payloadLength = (0..<4).reduce(0) { $0 << 8 | Int(b[offset + $1]) }
                offset += 4
            }
            var identifierLength = 0
            if hasIdentifier {
                guard offset < b.count else { return nil }
                identifierLength = Int(b[offset])
                offset += 1
            }
            guard payloadLength >= 0, offset + typeLength + identifierLength + payloadLength <= b.count else { return nil }
            let type = Data(b[offset..<(offset + typeLength)])
            offset += typeLength
            let identifier = Data(b[offset..<(offset + identifierLength)])
            offset += identifierLength
            let payload = Data(b[offset..<(offset + payloadLength)])
            offset += payloadLength
            records.append(NDEFRecord(format: format, type: type, identifier: identifier, payload: payload))
            sawEnd = ends
        }
        guard sawEnd, !records.isEmpty else { return nil }
        self.records = records
    }
}

// MARK: - Builders

extension NDEFRecord {

    /// The URI prefixes of the NFC Forum's URI record type: one byte stands for a whole
    /// `https://www.`, which is how a URL fits on a 48-byte sticker.
    static let uriPrefixes: [String] = [
        "", "http://www.", "https://www.", "http://", "https://", "tel:", "mailto:",
        "ftp://anonymous:anonymous@", "ftp://ftp.", "ftps://", "sftp://", "smb://", "nfs://", "ftp://",
        "dav://", "news:", "telnet://", "imap:", "rtsp://", "urn:", "pop:", "sip:", "sips:", "tftp:",
        "btspp://", "btl2cap://", "btgoep://", "tcpobex://", "irdaobex://", "file://", "urn:epc:id:",
        "urn:epc:tag:", "urn:epc:pat:", "urn:epc:raw:", "urn:epc:", "urn:nfc:",
    ]

    /// A URI record, with the longest known prefix folded into its first byte.
    public static func uri(_ text: String) -> NDEFRecord {
        var code = 0
        var length = 0
        for (index, prefix) in uriPrefixes.enumerated() where index > 0 && prefix.count > length
            && text.lowercased().hasPrefix(prefix) {
            code = index
            length = prefix.count
        }
        let rest = String(text.dropFirst(length))
        return NDEFRecord(format: .wellKnown, type: Data("U".utf8), payload: Data([UInt8(code)]) + Data(rest.utf8))
    }

    /// A text record in UTF-8 with its language tag (`de`, `en-GB`).
    public static func text(_ text: String, language: String = "de") -> NDEFRecord {
        let code = Data(language.utf8.prefix(63))
        return NDEFRecord(format: .wellKnown, type: Data("T".utf8),
                          payload: Data([UInt8(code.count)]) + code + Data(text.utf8))
    }

    public static func phone(_ number: String) -> NDEFRecord {
        uri("tel:" + number.filter { !" \t\n()-./".contains($0) })
    }

    /// `mailto:` with the subject and body percent-encoded.
    public static func mail(_ address: String, subject: String = "", body: String = "") -> NDEFRecord {
        var text = "mailto:" + address.trimmingCharacters(in: .whitespaces)
        var query: [String] = []
        if !subject.isEmpty { query.append("subject=" + percentEncoded(subject)) }
        if !body.isEmpty { query.append("body=" + percentEncoded(body)) }
        if !query.isEmpty { text += "?" + query.joined(separator: "&") }
        return uri(text)
    }

    public static func sms(_ number: String, body: String = "") -> NDEFRecord {
        let digits = number.filter { !" \t\n()-./".contains($0) }
        return uri("sms:" + digits + (body.isEmpty ? "" : "?body=" + percentEncoded(body)))
    }

    /// `geo:47.3769,8.5417`, six decimals: about ten centimetres.
    public static func geo(latitude: Double, longitude: Double) -> NDEFRecord {
        uri(String(format: "geo:%.6f,%.6f", latitude, longitude))
    }

    public static func mime(_ type: String, payload: Data) -> NDEFRecord {
        NDEFRecord(format: .media, type: Data(type.utf8), payload: payload)
    }

    /// An NFC Forum external type: `example.com:mytype`.
    public static func external(_ type: String, payload: Data) -> NDEFRecord {
        NDEFRecord(format: .external, type: Data(type.utf8), payload: payload)
    }

    static func percentEncoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? text
    }
}

extension CharacterSet {
    /// Letters, digits and the unreserved marks; everything else, `&` and `=` included, is
    /// escaped so a value cannot end its own field.
    static let urlQueryValueAllowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
