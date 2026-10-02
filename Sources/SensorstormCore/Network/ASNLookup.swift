import Foundation

/// Who runs the network an address belongs to: its autonomous system number, the company
/// behind it and the country it is registered in.
///
/// The answer comes from Team Cymru's IP-to-ASN mapping, which is served over plain DNS: a TXT
/// query for the address's octets reversed under `origin.asn.cymru.com` gives the number and the
/// prefix, and one for `AS<number>.asn.cymru.com` gives the name. This file builds those
/// questions and reads the answers; sending them is the app's business.
public struct ASNInfo: Sendable, Equatable, Codable {
    public var asn: Int
    public var prefix: String?
    public var countryCode: String?
    public var registry: String?
    public var name: String?

    public init(asn: Int, prefix: String? = nil, countryCode: String? = nil,
                registry: String? = nil, name: String? = nil) {
        self.asn = asn
        self.prefix = prefix
        self.countryCode = countryCode
        self.registry = registry
        self.name = name
    }

    /// `AS15169`
    public var number: String { "AS\(asn)" }

    /// `🇺🇸`, or `nil` without a country.
    public var flag: String? { countryCode.flatMap(CountryFlag.emoji) }

    /// `AS15169 GOOGLE`
    public var label: String { [number, name].compactMap { $0 }.joined(separator: " ") }
}

public enum ASNLookup {

    /// An address worth asking about: one a stranger's network could own. Private, loopback,
    /// link-local, shared (carrier-grade NAT) and multicast space has no autonomous system, and
    /// sending it to a resolver would only tell the resolver about the inside of someone's LAN.
    public static func isLookupable(_ address: IPv4Addr) -> Bool {
        let first = address.octets[0]
        return !address.isPrivate && !address.isLinkLocal && !address.isLoopback
            && !address.isSharedAddressSpace && first != 0 && first < 224
    }

    /// `8.8.4.4` → `4.4.8.8.origin.asn.cymru.com`
    public static func originQuery(for address: IPv4Addr) -> String {
        address.octets.reversed().map(String.init).joined(separator: ".") + ".origin.asn.cymru.com"
    }

    public static func nameQuery(asn: Int) -> String { "AS\(asn).asn.cymru.com" }

    /// `15169 | 8.8.8.0/24 | US | arin | 2023-12-28`. An address announced by several systems
    /// lists them all in the first field; the first is the one that is shown.
    public static func parseOrigin(_ text: String) -> ASNInfo? {
        let fields = split(text)
        guard fields.count >= 3, let first = fields[0].split(separator: " ").first,
              let asn = Int(first), asn > 0 else { return nil }
        return ASNInfo(asn: asn,
                       prefix: fields[1].isEmpty ? nil : fields[1],
                       countryCode: fields[2].count == 2 ? fields[2].uppercased() : nil,
                       registry: fields.count > 3 && !fields[3].isEmpty ? fields[3] : nil)
    }

    /// `15169 | US | arin | 2000-03-30 | GOOGLE, US` fills in the name. The registry appends
    /// the country to it after a comma, which is dropped when it only repeats what is known.
    public static func parseName(_ text: String, into info: ASNInfo) -> ASNInfo {
        let fields = split(text)
        var result = info
        guard fields.count >= 5 else { return result }
        var name = fields[4...].joined(separator: " | ")
        if let comma = name.lastIndex(of: ","),
           name[name.index(after: comma)...].trimmingCharacters(in: .whitespaces).uppercased() == fields[1].uppercased() {
            name = String(name[..<comma])
        }
        name = name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { result.name = name }
        if result.countryCode == nil, fields[1].count == 2 { result.countryCode = fields[1].uppercased() }
        return result
    }

    private static func split(_ text: String) -> [String] {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

public enum CountryFlag {
    /// The flag a two-letter country code stands for, made of two regional-indicator symbols.
    /// `nil` for anything that is not two ASCII letters.
    public static func emoji(_ code: String) -> String? {
        let letters = code.uppercased().unicodeScalars
        guard letters.count == 2, letters.allSatisfy({ (65...90).contains($0.value) }) else { return nil }
        var flag = ""
        for letter in letters {
            guard let scalar = Unicode.Scalar(0x1F1E6 + letter.value - 65) else { return nil }
            flag.unicodeScalars.append(scalar)
        }
        return flag
    }
}
