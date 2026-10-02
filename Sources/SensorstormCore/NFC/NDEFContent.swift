import Foundation

/// What a record means, in words a person can read: the decoded form of the common record
/// types and the builders for the ones the NFC tool writes.
public enum NDEFContent: Sendable, Equatable {
    case uri(String)
    case text(String, language: String)
    case wifi(WiFiCredential)
    case contact(VCard)
    case bluetooth(address: String?, name: String?, lowEnergy: Bool)
    /// A smart poster: a URI with a title around it.
    case smartPoster(uri: String?, title: String?)
    case mime(type: String, byteCount: Int)
    case external(type: String, byteCount: Int)
    case empty
    case unknown(byteCount: Int)

    public init(_ record: NDEFRecord) {
        switch record.format {
        case .empty:
            self = .empty
        case .wellKnown:
            switch record.typeString {
            case "U": self = Self.decodeURI(record.payload).map(NDEFContent.uri) ?? .unknown(byteCount: record.payload.count)
            case "T": self = Self.decodeText(record.payload) ?? .unknown(byteCount: record.payload.count)
            case "Sp": self = Self.decodeSmartPoster(record.payload) ?? .unknown(byteCount: record.payload.count)
            default: self = .unknown(byteCount: record.payload.count)
            }
        case .absoluteURI:
            self = .uri(record.typeString)
        case .media:
            let type = record.typeString.lowercased()
            if type == "application/vnd.wfa.wsc", let credential = WiFiCredential(wsc: record.payload) {
                self = .wifi(credential)
            } else if type == "text/vcard" || type == "text/x-vcard",
                      let card = VCard(text: String(decoding: record.payload, as: UTF8.self)) {
                self = .contact(card)
            } else if type == "application/vnd.bluetooth.ep.oob" {
                let parsed = BluetoothOOB.parseClassic(record.payload)
                self = .bluetooth(address: parsed.address, name: parsed.name, lowEnergy: false)
            } else if type == "application/vnd.bluetooth.le.oob" {
                let parsed = BluetoothOOB.parseLowEnergy(record.payload)
                self = .bluetooth(address: parsed.address, name: parsed.name, lowEnergy: true)
            } else {
                self = .mime(type: record.typeString, byteCount: record.payload.count)
            }
        case .external:
            self = .external(type: record.typeString, byteCount: record.payload.count)
        case .unknown, .unchanged:
            self = .unknown(byteCount: record.payload.count)
        }
    }

    static func decodeURI(_ payload: Data) -> String? {
        guard let code = payload.first else { return nil }
        let prefix = Int(code) < NDEFRecord.uriPrefixes.count ? NDEFRecord.uriPrefixes[Int(code)] : ""
        return prefix + String(decoding: payload.dropFirst(), as: UTF8.self)
    }

    static func decodeText(_ payload: Data) -> NDEFContent? {
        guard let status = payload.first else { return nil }
        let languageLength = Int(status & 0x3F)
        guard payload.count >= 1 + languageLength else { return nil }
        let language = String(decoding: payload.dropFirst().prefix(languageLength), as: UTF8.self)
        let body = payload.dropFirst(1 + languageLength)
        // Bit 7 selects UTF-16 (with a byte-order mark); everything written today is UTF-8.
        let text = status & 0x80 != 0
            ? (String(data: Data(body), encoding: .utf16) ?? "")
            : String(decoding: body, as: UTF8.self)
        return .text(text, language: language)
    }

    static func decodeSmartPoster(_ payload: Data) -> NDEFContent? {
        guard let message = NDEFMessage(data: payload) else { return nil }
        var uri: String?
        var title: String?
        for record in message.records {
            switch NDEFContent(record) {
            case .uri(let value): uri = uri ?? value
            case .text(let value, _): title = title ?? value
            default: break
            }
        }
        return .smartPoster(uri: uri, title: title)
    }

    /// The text to show for the record, when it has one: the address, the message, the network.
    public var summary: String {
        switch self {
        case .uri(let value): value
        case .text(let value, _): value
        case .wifi(let credential): credential.ssid
        case .contact(let card): card.displayName
        case .bluetooth(let address, let name, _): [name, address].compactMap { $0 }.joined(separator: " ")
        case .smartPoster(let uri, let title): [title, uri].compactMap { $0 }.joined(separator: " ")
        case .mime(let type, _): type
        case .external(let type, _): type
        case .empty: ""
        case .unknown: ""
        }
    }
}

// MARK: - Wi-Fi

/// A Wi-Fi network as an NFC tag carries it: a Wi-Fi Simple Configuration record, the format
/// Android reads to join a network by touch.
public struct WiFiCredential: Sendable, Equatable {
    public enum Security: Sendable, Equatable, CaseIterable {
        case open, wep, wpa, wpa2, wpaWpa2
    }

    public var ssid: String
    public var password: String
    public var security: Security
    /// What the tag said when it was something this does not map: the raw authentication type.
    public var authenticationType: UInt16

    public init(ssid: String, password: String, security: Security) {
        self.ssid = ssid
        self.password = security == .open ? "" : password
        self.security = security
        self.authenticationType = Self.authentication(security)
    }

    static func authentication(_ security: Security) -> UInt16 {
        switch security {
        case .open: 0x0001
        case .wep: 0x0001
        case .wpa: 0x0002
        case .wpa2: 0x0020
        case .wpaWpa2: 0x0022
        }
    }

    static func encryption(_ security: Security) -> UInt16 {
        switch security {
        case .open: 0x0001
        case .wep: 0x0002
        case .wpa: 0x0004
        case .wpa2: 0x0008
        case .wpaWpa2: 0x000C
        }
    }

    /// The record's payload: a version and one credential with the network index, SSID,
    /// authentication and encryption type, key, and a broadcast MAC address.
    public func wscPayload() -> Data {
        func field(_ id: UInt16, _ value: Data) -> Data {
            Data([UInt8(id >> 8), UInt8(id & 0xFF), UInt8(value.count >> 8), UInt8(value.count & 0xFF)]) + value
        }
        func word(_ value: UInt16) -> Data { Data([UInt8(value >> 8), UInt8(value & 0xFF)]) }
        var credential = Data()
        credential += field(0x1026, Data([0x01]))
        credential += field(0x1045, Data(ssid.utf8))
        credential += field(0x1003, word(Self.authentication(security)))
        credential += field(0x100F, word(Self.encryption(security)))
        credential += field(0x1027, Data(password.utf8))
        credential += field(0x1020, Data(repeating: 0xFF, count: 6))
        return field(0x104A, Data([0x10])) + field(0x100E, credential)
    }

    public var record: NDEFRecord { .mime("application/vnd.wfa.wsc", payload: wscPayload()) }

    /// Reads the payload of a Wi-Fi Simple Configuration record. `nil` without an SSID.
    public init?(wsc payload: Data) {
        let b = [UInt8](payload)
        var ssid: String?
        var password = ""
        var auth: UInt16 = 0
        var encryption: UInt16 = 0

        func walk(_ start: Int, _ end: Int) {
            var offset = start
            while offset + 4 <= end {
                let id = UInt16(b[offset]) << 8 | UInt16(b[offset + 1])
                let length = Int(UInt16(b[offset + 2]) << 8 | UInt16(b[offset + 3]))
                let value = offset + 4
                guard value + length <= end else { return }
                switch id {
                case 0x100E: walk(value, value + length)
                case 0x1045: ssid = String(decoding: b[value..<(value + length)], as: UTF8.self)
                case 0x1027: password = String(decoding: b[value..<(value + length)], as: UTF8.self)
                case 0x1003 where length == 2: auth = UInt16(b[value]) << 8 | UInt16(b[value + 1])
                case 0x100F where length == 2: encryption = UInt16(b[value]) << 8 | UInt16(b[value + 1])
                default: break
                }
                offset = value + length
            }
        }
        walk(0, b.count)
        guard let ssid else { return nil }
        self.ssid = ssid
        self.password = password
        self.authenticationType = auth
        switch (auth, encryption) {
        case (0x0001, 0x0002): self.security = .wep
        case (0x0001, _): self.security = .open
        case (0x0002, _): self.security = .wpa
        case (0x0022, _): self.security = .wpaWpa2
        case (0x0020, _): self.security = .wpa2
        default: self.security = password.isEmpty ? .open : .wpaWpa2
        }
    }
}

// MARK: - Contact

/// The few fields of a business card an NFC sticker holds, as vCard 3.0.
public struct VCard: Sendable, Equatable {
    public var firstName = ""
    public var lastName = ""
    public var organization = ""
    public var title = ""
    public var phone = ""
    public var email = ""
    public var website = ""
    public var address = ""

    public init(firstName: String = "", lastName: String = "", organization: String = "", title: String = "",
                phone: String = "", email: String = "", website: String = "", address: String = "") {
        self.firstName = firstName
        self.lastName = lastName
        self.organization = organization
        self.title = title
        self.phone = phone
        self.email = email
        self.website = website
        self.address = address
    }

    public var displayName: String {
        let name = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? organization : name
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: "\n", with: "\\n")
    }

    static func unescape(_ text: String) -> String {
        var out = ""
        var escaped = false
        for character in text {
            if escaped {
                out.append(character == "n" || character == "N" ? "\n" : character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                out.append(character)
            }
        }
        return out
    }

    public func text() -> String {
        var lines = ["BEGIN:VCARD", "VERSION:3.0",
                     "N:\(Self.escape(lastName));\(Self.escape(firstName));;;",
                     "FN:\(Self.escape(displayName))"]
        if !organization.isEmpty { lines.append("ORG:\(Self.escape(organization))") }
        if !title.isEmpty { lines.append("TITLE:\(Self.escape(title))") }
        if !phone.isEmpty { lines.append("TEL;TYPE=CELL:\(phone)") }
        if !email.isEmpty { lines.append("EMAIL:\(email)") }
        if !website.isEmpty { lines.append("URL:\(website)") }
        if !address.isEmpty { lines.append("ADR;TYPE=WORK:;;\(Self.escape(address));;;;") }
        lines.append("END:VCARD")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    public var record: NDEFRecord { .mime("text/vcard", payload: Data(text().utf8)) }

    /// Reads a vCard of version 2.1 to 4.0 for the fields above. `nil` for text that is not a card.
    public init?(text: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n").map(String.init)
        guard lines.contains(where: { $0.uppercased() == "BEGIN:VCARD" }) else { return nil }
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].split(separator: ";").first.map { $0.uppercased() } ?? ""
            let value = String(line[line.index(after: colon)...])
            switch name {
            case "N":
                let parts = value.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
                lastName = Self.unescape(parts.first ?? "")
                firstName = parts.count > 1 ? Self.unescape(parts[1]) : ""
            case "FN" where firstName.isEmpty && lastName.isEmpty:
                let parts = Self.unescape(value).split(separator: " ", maxSplits: 1).map(String.init)
                firstName = parts.first ?? ""
                lastName = parts.count > 1 ? parts[1] : ""
            case "ORG": organization = Self.unescape(value.replacingOccurrences(of: ";", with: " ")).trimmingCharacters(in: .whitespaces)
            case "TITLE": title = Self.unescape(value)
            case "TEL" where phone.isEmpty: phone = value
            case "EMAIL" where email.isEmpty: email = value
            case "URL" where website.isEmpty: website = value
            case "ADR" where address.isEmpty:
                address = value.split(separator: ";", omittingEmptySubsequences: true).map { Self.unescape(String($0)) }
                    .joined(separator: ", ")
            default: break
            }
        }
    }
}

// MARK: - Bluetooth

/// The out-of-band records that carry a Bluetooth address on a tag: touching the tag hands a
/// phone or a speaker everything it needs to find the device.
public enum BluetoothOOB {

    /// A classic (BR/EDR) record: the length, the address with the last byte first, then the
    /// device name and the device class when there is one.
    public static func classic(address: MACAddress, name: String?, deviceClass: UInt32? = nil) -> NDEFRecord {
        var body = Data(address.bytes.reversed())
        if let deviceClass {
            body += Data([4, 0x0D, UInt8(deviceClass & 0xFF), UInt8(deviceClass >> 8 & 0xFF), UInt8(deviceClass >> 16 & 0xFF)])
        }
        if let name, !name.isEmpty {
            let bytes = Data(name.utf8.prefix(200))
            body += Data([UInt8(bytes.count + 1), 0x09]) + bytes
        }
        let total = UInt16(body.count + 2)
        return .mime("application/vnd.bluetooth.ep.oob", payload: Data([UInt8(total & 0xFF), UInt8(total >> 8)]) + body)
    }

    /// A Bluetooth Low Energy record: the address with its type, the role, the name.
    public static func lowEnergy(address: MACAddress, isRandom: Bool, name: String?) -> NDEFRecord {
        var body = Data([8, 0x1B]) + Data(address.bytes.reversed()) + Data([isRandom ? 1 : 0])
        body += Data([2, 0x1C, 0x00])
        if let name, !name.isEmpty {
            let bytes = Data(name.utf8.prefix(200))
            body += Data([UInt8(bytes.count + 1), 0x09]) + bytes
        }
        return .mime("application/vnd.bluetooth.le.oob", payload: body)
    }

    public static func parseClassic(_ payload: Data) -> (address: String?, name: String?) {
        let b = [UInt8](payload)
        guard b.count >= 8 else { return (nil, nil) }
        let address = MACAddress(bytes: Array(b[2..<8].reversed()))?.formatted(uppercase: true)
        return (address, name(in: Array(b[8...])))
    }

    public static func parseLowEnergy(_ payload: Data) -> (address: String?, name: String?) {
        let b = [UInt8](payload)
        var address: String?
        var offset = 0
        while offset + 1 < b.count {
            let length = Int(b[offset])
            guard length > 0, offset + 1 + length <= b.count else { break }
            if b[offset + 1] == 0x1B, length >= 7 {
                address = MACAddress(bytes: Array(b[(offset + 2)..<(offset + 8)].reversed()))?.formatted(uppercase: true)
            }
            offset += 1 + length
        }
        return (address, name(in: b))
    }

    /// The complete (0x09) or shortened (0x08) local name among the EIR/AD structures.
    static func name(in b: [UInt8]) -> String? {
        var offset = 0
        while offset + 1 < b.count {
            let length = Int(b[offset])
            guard length > 0, offset + 1 + length <= b.count else { return nil }
            if b[offset + 1] == 0x09 || b[offset + 1] == 0x08 {
                return String(decoding: b[(offset + 2)..<(offset + 1 + length)], as: UTF8.self)
            }
            offset += 1 + length
        }
        return nil
    }
}
