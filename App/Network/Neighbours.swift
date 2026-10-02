import Darwin
import Foundation
import SensorstormCore

/// The hardware addresses the phone has learned, the manufacturers behind them, and the DNS
/// servers the system uses — the three things a LAN scanner shows next to an address that
/// iOS makes awkward to get.

// MARK: - ARP

enum ARPCache {
    /// Every neighbour with a complete entry, by address. Empty when the sysctl is refused,
    /// which is how iOS releases that close the table answer: nothing, not an error.
    ///
    /// The table only knows hosts the phone has exchanged packets with in the last minutes, so
    /// it is read after a sweep, never before.
    static func read() -> [String: MACAddress] {
        // CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO. Spelled as numbers: the
        // names are macros the Swift importer is not guaranteed to bring along.
        var mib: [Int32] = [4, 17, 0, 2, 2, 0x400]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return [:] }
        var table: [String: MACAddress] = [:]
        for entry in ARPTable.parse(Array(buffer.prefix(size))) {
            table[entry.address.description] = entry.mac
        }
        return table
    }
}

// MARK: - Manufacturers

/// The IEEE prefix list shipped as `oui.bin`, loaded the first time a vendor is asked for.
enum VendorLookup {
    private static let database: OUIDatabase? = {
        guard let url = Bundle.main.url(forResource: "oui", withExtension: "bin"),
              let data = try? Data(contentsOf: url) else { return nil }
        return OUIDatabase(compressed: data)
    }()

    /// The manufacturer as the registry spells it, or `nil`.
    static func registered(_ mac: MACAddress) -> String? {
        database?.vendor(of: mac)
    }

    /// The same, short enough for a list row.
    static func name(_ mac: MACAddress) -> String? {
        registered(mac).map(OUIDatabase.shortName)
    }

    /// The vendor of a hardware address given as text: a BSSID, a typed address.
    static func name(_ text: String) -> String? {
        MACAddress(text).flatMap(name)
    }
}

// MARK: - System DNS

enum SystemDNS {
    /// The resolvers the system is configured with: what the router or the carrier handed out.
    /// Read by a small C function (`App/Bridging`), because `<resolv.h>` is not visible to Swift.
    static func servers() -> [String] {
        var buffer = [CChar](repeating: 0, count: 512)
        guard sensorstorm_copy_dns_servers(&buffer, buffer.count) > 0 else { return [] }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        var servers: [String] = []
        for line in String(decoding: bytes, as: UTF8.self).split(separator: "\n") where !servers.contains(String(line)) {
            servers.append(String(line))
        }
        return servers
    }
}

// MARK: - Autonomous system of an address

actor ASNCache {
    static let shared = ASNCache()

    private var known: [UInt32: ASNInfo?] = [:]
    private var names: [Int: String] = [:]

    /// Two TXT questions: who announces the address, and what that system is called. Answers
    /// are kept for the session, because the same few transit networks turn up in every trace.
    func lookup(_ address: IPv4Addr, server: String) async -> ASNInfo? {
        guard ASNLookup.isLookupable(address) else { return nil }
        if let cached = known[address.value] { return cached }

        let origin = await DNS.query(ASNLookup.originQuery(for: address), type: .txt, server: server, timeout: 2.5)
        guard let text = origin.response?.answers.first(where: { $0.type == DNSRecordType.txt.rawValue })?.value,
              var info = ASNLookup.parseOrigin(text) else {
            known[address.value] = .some(nil)
            return nil
        }
        if let name = names[info.asn] {
            info.name = name
        } else {
            let named = await DNS.query(ASNLookup.nameQuery(asn: info.asn), type: .txt, server: server, timeout: 2.5)
            if let value = named.response?.answers.first(where: { $0.type == DNSRecordType.txt.rawValue })?.value {
                info = ASNLookup.parseName(value, into: info)
                if let name = info.name { names[info.asn] = name }
            }
        }
        known[address.value] = .some(info)
        return info
    }
}
