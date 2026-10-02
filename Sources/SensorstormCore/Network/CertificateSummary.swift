import Foundation

/// The parts of an X.509 certificate a person checks when a connection looks wrong: who it
/// is for, who vouched for it, and until when.
///
/// Read from the DER bytes directly. The platform can validate a certificate but on iOS has no
/// call that says what is in one, and a network tool that shows „valid" without the date is a
/// tool that is no use on the day a certificate runs out. This reads only what it names; it
/// does not verify a signature and says nothing about trust.
public struct CertificateSummary: Sendable, Equatable {
    public var subjectCommonName: String?
    public var subjectOrganization: String?
    public var issuerCommonName: String?
    public var issuerOrganization: String?
    public var notBefore: Date
    public var notAfter: Date
    /// DNS names and addresses the certificate is valid for.
    public var alternativeNames: [String]
    /// Issuer and subject are the same name: signed by itself, trusted by nobody who did not
    /// install it.
    public var isSelfSigned: Bool
    public var serialNumber: String

    public func daysRemaining(at date: Date = Date()) -> Int {
        Int((notAfter.timeIntervalSince(date) / 86_400).rounded(.down))
    }

    public func isValid(at date: Date = Date()) -> Bool {
        date >= notBefore && date <= notAfter
    }

    /// A certificate for this host: the name is among the alternative names (with a leading
    /// `*.` standing for one label), or — for one without any — it is the common name.
    public func covers(host: String) -> Bool {
        let wanted = host.lowercased()
        let names = alternativeNames.isEmpty ? [subjectCommonName].compactMap { $0 } : alternativeNames
        return names.contains { name in
            let candidate = name.lowercased()
            if candidate == wanted { return true }
            guard candidate.hasPrefix("*.") else { return false }
            let suffix = String(candidate.dropFirst(1))          // ".example.com"
            guard wanted.hasSuffix(suffix) else { return false }
            return !wanted.dropLast(suffix.count).contains(".") && wanted.count > suffix.count
        }
    }

    // MARK: - Parsing

    public static func parse(der: Data) -> CertificateSummary? {
        let bytes = [UInt8](der)
        guard let certificate = DER.node(bytes, at: 0), certificate.tag == 0x30,
              let tbs = DER.children(of: certificate, in: bytes).first, tbs.tag == 0x30 else { return nil }
        var items = DER.children(of: tbs, in: bytes)
        // [0] version, present from v2 on.
        if items.first?.tag == 0xA0 { items.removeFirst() }
        // serial, signature algorithm, issuer, validity, subject, public key
        guard items.count >= 6, items[0].tag == 0x02, items[3].tag == 0x30, items[2].tag == 0x30,
              items[4].tag == 0x30 else { return nil }

        let validity = DER.children(of: items[3], in: bytes)
        guard validity.count == 2, let notBefore = date(validity[0], bytes),
              let notAfter = date(validity[1], bytes) else { return nil }

        let issuer = name(items[2], bytes)
        let subject = name(items[4], bytes)
        let serial = bytes[items[0].start..<items[0].end].drop { $0 == 0 }
            .map { String(format: "%02X", $0) }.joined(separator: ":")

        var alternativeNames: [String] = []
        if let extensions = items.first(where: { $0.tag == 0xA3 }),
           let list = DER.children(of: extensions, in: bytes).first {
            for item in DER.children(of: list, in: bytes) {
                let parts = DER.children(of: item, in: bytes)
                // OID 2.5.29.17 — subjectAltName
                guard let oid = parts.first, Array(bytes[oid.start..<oid.end]) == [0x55, 0x1D, 0x11],
                      let value = parts.last, value.tag == 0x04,
                      let names = DER.node(bytes, at: value.start), names.tag == 0x30 else { continue }
                for general in DER.children(of: names, in: bytes) {
                    switch general.tag {
                    case 0x82:  // dNSName
                        alternativeNames.append(String(decoding: bytes[general.start..<general.end], as: UTF8.self))
                    case 0x87 where general.end - general.start == 4:  // iPAddress
                        alternativeNames.append(IPv4Address(octets: Array(bytes[general.start..<general.end])).description)
                    default:
                        break
                    }
                }
            }
        }

        return CertificateSummary(
            subjectCommonName: subject.commonName, subjectOrganization: subject.organization,
            issuerCommonName: issuer.commonName, issuerOrganization: issuer.organization,
            notBefore: notBefore, notAfter: notAfter, alternativeNames: alternativeNames,
            isSelfSigned: bytes[items[2].full] == bytes[items[4].full],
            serialNumber: serial)
    }

    private static func name(_ node: DER.Node, _ bytes: [UInt8]) -> (commonName: String?, organization: String?) {
        var common: String?
        var organization: String?
        for set in DER.children(of: node, in: bytes) {
            for pair in DER.children(of: set, in: bytes) {
                let parts = DER.children(of: pair, in: bytes)
                guard parts.count == 2 else { continue }
                let oid = Array(bytes[parts[0].start..<parts[0].end])
                let text = String(decoding: bytes[parts[1].start..<parts[1].end], as: UTF8.self)
                if oid == [0x55, 0x04, 0x03], common == nil { common = text }
                if oid == [0x55, 0x04, 0x0A], organization == nil { organization = text }
            }
        }
        return (common, organization)
    }

    /// UTCTime `YYMMDDHHMMSSZ` (two-digit years from 50 are 19xx) or GeneralizedTime
    /// `YYYYMMDDHHMMSSZ`.
    private static func date(_ node: DER.Node, _ bytes: [UInt8]) -> Date? {
        let text = String(decoding: bytes[node.start..<node.end], as: UTF8.self)
        guard text.hasSuffix("Z"), text.dropLast().allSatisfy(\.isNumber) else { return nil }
        let digits = Array(text.dropLast())
        func number(_ range: Range<Int>) -> Int? { Int(String(digits[range])) }
        var year: Int
        var rest: Int
        switch node.tag {
        case 0x17 where digits.count >= 10:
            guard let yy = number(0..<2) else { return nil }
            year = yy < 50 ? 2_000 + yy : 1_900 + yy
            rest = 2
        case 0x18 where digits.count >= 12:
            guard let yyyy = number(0..<4) else { return nil }
            year = yyyy
            rest = 4
        default:
            return nil
        }
        guard let month = number(rest..<(rest + 2)), let day = number((rest + 2)..<(rest + 4)),
              let hour = number((rest + 4)..<(rest + 6)), let minute = number((rest + 6)..<(rest + 8))
        else { return nil }
        let second = digits.count >= rest + 10 ? number((rest + 8)..<(rest + 10)) ?? 0 : 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour, minute: minute, second: second))
    }
}

/// Just enough ASN.1 DER to walk a certificate: tag, length, content.
enum DER {
    struct Node {
        var tag: UInt8
        /// Content, not including the tag and length bytes.
        var start: Int
        var end: Int
        /// The whole element, tag and length included — what two names are compared by.
        var full: Range<Int>
    }

    static func node(_ bytes: [UInt8], at index: Int) -> Node? {
        guard index + 2 <= bytes.count else { return nil }
        let tag = bytes[index]
        // High-tag-number form never occurs in a certificate.
        guard tag & 0x1F != 0x1F else { return nil }
        var length = Int(bytes[index + 1])
        var header = 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count >= 1, count <= 4, index + 2 + count <= bytes.count else { return nil }
            length = (0..<count).reduce(0) { $0 << 8 | Int(bytes[index + 2 + $1]) }
            header = 2 + count
        }
        let start = index + header
        guard length >= 0, start + length <= bytes.count else { return nil }
        return Node(tag: tag, start: start, end: start + length, full: index..<(start + length))
    }

    static func children(of node: Node, in bytes: [UInt8]) -> [Node] {
        var out: [Node] = []
        var index = node.start
        while index < node.end, let child = DER.node(bytes, at: index), child.end <= node.end {
            out.append(child)
            index = child.end
        }
        return out
    }
}
