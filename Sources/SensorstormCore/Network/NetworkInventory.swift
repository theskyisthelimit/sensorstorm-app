import Foundation

/// A guess at what a device in the network is, from what it answers on and, when the hardware
/// address could be read, who made its network chip. Said to be a guess: a company that makes
/// routers also makes smart plugs.
public enum DeviceGuess: String, Codable, Sendable, CaseIterable {
    case router, printer, nas, camera, mediaPlayer, smartHome, apple, computer, server, unknown
}

public enum DeviceClassifier {
    /// What a manufacturer's name suggests, for a host nothing else could place. Only
    /// companies that make one kind of thing: a name that covers laptops and printers, or
    /// routers and phones, says nothing and gives `nil`.
    public static func guess(vendor: String) -> DeviceGuess? {
        let name = vendor.lowercased()
        func any(_ words: [String]) -> Bool { words.contains { name.contains($0) } }
        if any(["apple"]) { return .apple }
        if any(["espressif", "tuya", "shelly", "allterco", "sonoff", "itead", "signify", "philips lighting",
                "ikea of sweden", "nordic semiconductor", "ring llc", "ecobee", "nest labs", "lifx",
                "wiz connected", "yeelink", "xiaomi", "aqara", "lumi united", "ledvance", "tp-link smart"]) {
            return .smartHome
        }
        if any(["sonos", "roku", "chromecast", "vizio", "bose", "denon", "yamaha corporation"]) { return .mediaPlayer }
        if any(["hikvision", "dahua", "axis communications", "reolink", "amcrest", "foscam", "vivotek",
                "uniview", "arlo"]) { return .camera }
        if any(["brother industries", "canon", "seiko epson", "epson", "lexmark", "kyocera", "ricoh", "xerox",
                "konica", "oki data", "zebra technologies"]) { return .printer }
        if any(["synology", "qnap", "western digital", "buffalo"]) { return .nas }
        if any(["raspberry pi", "intel corporate", "dell", "lenovo", "micro-star", "gigabyte", "asustek"]) {
            return .computer
        }
        return nil
    }

    public static func guess(address: String, gateway: String?, openPorts: [Int],
                             services: [String], names: [String]) -> DeviceGuess {
        let ports = Set(openPorts)
        let kinds = Set(services.map { $0.lowercased() })
        let name = names.joined(separator: " ").lowercased()
        func any(_ list: [String]) -> Bool { list.contains { kinds.contains($0) } }

        if let gateway, address == gateway { return .router }
        if any(["_ipp._tcp", "_printer._tcp", "_pdl-datastream._tcp", "_ipps._tcp"])
            || !ports.isDisjoint(with: [631, 9100, 515]) { return .printer }
        if name.contains("synology") || name.contains("qnap") || name.contains("diskstation")
            || name.contains("nas") && !ports.isDisjoint(with: [445, 548, 2049, 5000]) { return .nas }
        if any(["_rtsp._tcp"]) || ports.contains(554) || name.contains("cam") { return .camera }
        if any(["_hap._tcp", "_matter._tcp", "_hue._tcp", "_esphomelib._tcp", "_home-assistant._tcp",
                "_mqtt._tcp"]) || !ports.isDisjoint(with: [1883, 6053, 8123, 1880, 6668]) { return .smartHome }
        if any(["_googlecast._tcp", "_spotify-connect._tcp", "_sonos._tcp"])
            || name.contains("tv") && ports.contains(8008) { return .mediaPlayer }
        if any(["_airplay._tcp", "_raop._tcp", "_companion-link._tcp", "_apple-mobdev2._tcp",
                "_device-info._tcp"]) || ports.contains(62078) { return .apple }
        if !ports.isDisjoint(with: [3389, 445, 139, 5900]) { return .computer }
        if !ports.isDisjoint(with: [22, 80, 443, 3306, 5432, 8080]) { return .server }
        return .unknown
    }
}

/// One address in the network and everything learned about it.
public struct HostRecord: Codable, Sendable, Hashable, Identifiable {
    public var address: String
    public var hostNames: [String]
    /// Bonjour service types the host announced, e.g. `_ipp._tcp`.
    public var services: [String]
    public var openPorts: [Int]
    public var roundTrip: Double?
    /// How the host was found: `ping`, `tcp`, `bonjour`, `netbios`, `ssdp`, `arp`.
    public var sources: [String]
    public var guess: DeviceGuess
    /// The hardware address from the neighbour table, when iOS let the app read it. Absent is
    /// the normal case on some releases, not an error.
    public var mac: String?

    public var id: String { address }

    public init(address: String, hostNames: [String] = [], services: [String] = [],
                openPorts: [Int] = [], roundTrip: Double? = nil, sources: [String] = [],
                guess: DeviceGuess = .unknown, mac: String? = nil) {
        self.mac = mac
        self.address = address
        self.hostNames = hostNames
        self.services = services
        self.openPorts = openPorts
        self.roundTrip = roundTrip
        self.sources = sources
        self.guess = guess
    }

    /// The name to show: the first one learned, or the address.
    public var displayName: String { hostNames.first ?? address }

    /// Folds what another probe learned into this record. Lists grow, never shrink: a host
    /// that answered a ping but not a port probe still did answer the ping.
    public mutating func merge(_ other: HostRecord) {
        for name in other.hostNames where !hostNames.contains(name) { hostNames.append(name) }
        for service in other.services where !services.contains(service) { services.append(service) }
        openPorts = Array(Set(openPorts + other.openPorts)).sorted()
        for source in other.sources where !sources.contains(source) { sources.append(source) }
        if let rtt = other.roundTrip { roundTrip = min(roundTrip ?? rtt, rtt) }
        if let mac = other.mac { self.mac = mac }
    }
}

/// The one-letter marks of a host in the list: what it offers, at a glance.
///
/// They are derived from what the scan found — the ports that answered and the ways the host
/// announced itself — so a badge is a fact about the host and never a guess. `ipv6` is not here
/// because a sweep of an IPv4 subnet cannot see a host's other address.
public enum HostBadge: String, Sendable, CaseIterable, Codable {
    case gateway, web, ssh, files, printer, upnp, bonjour, netbios, dns, mail, database

    public var letter: String {
        switch self {
        case .gateway: "G"
        case .web: "W"
        case .ssh: "S"
        case .files: "F"
        case .printer: "P"
        case .upnp: "U"
        case .bonjour: "B"
        case .netbios: "N"
        case .dns: "D"
        case .mail: "M"
        case .database: "Q"
        }
    }

    public static func badges(for host: HostRecord, isGateway: Bool) -> [HostBadge] {
        let ports = Set(host.openPorts)
        let kinds = Set(host.services.map { $0.lowercased() })
        var badges: [HostBadge] = []
        if isGateway { badges.append(.gateway) }
        if !ports.isDisjoint(with: [80, 81, 443, 8000, 8008, 8080, 8081, 8123, 8443, 8888, 9090])
            || !kinds.isDisjoint(with: ["_http._tcp", "_https._tcp"]) { badges.append(.web) }
        if ports.contains(22) || kinds.contains("_ssh._tcp") || kinds.contains("_sftp-ssh._tcp") { badges.append(.ssh) }
        if !ports.isDisjoint(with: [21, 139, 445, 548, 2049, 873, 990])
            || !kinds.isDisjoint(with: ["_smb._tcp", "_afpovertcp._tcp", "_nfs._tcp", "_ftp._tcp"]) { badges.append(.files) }
        if !ports.isDisjoint(with: [515, 631, 9100])
            || !kinds.isDisjoint(with: ["_ipp._tcp", "_ipps._tcp", "_printer._tcp", "_pdl-datastream._tcp"]) { badges.append(.printer) }
        if host.sources.contains("ssdp") { badges.append(.upnp) }
        if host.sources.contains("bonjour") || !host.services.isEmpty { badges.append(.bonjour) }
        if host.sources.contains("netbios") { badges.append(.netbios) }
        if ports.contains(53) { badges.append(.dns) }
        if !ports.isDisjoint(with: [25, 110, 143, 465, 587, 993, 995]) { badges.append(.mail) }
        if !ports.isDisjoint(with: [1433, 3306, 5432, 6379, 27017, 1521]) { badges.append(.database) }
        return badges
    }
}

/// All the hosts of one scan, to keep and to compare against the next.
public struct NetworkSnapshot: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var date: Date
    /// The Wi-Fi name, or `Ethernet`, or whatever the interface was called.
    public var networkName: String
    public var subnet: String
    public var gateway: String?
    public var hosts: [HostRecord]

    public init(id: UUID = UUID(), date: Date = Date(), networkName: String, subnet: String,
                gateway: String? = nil, hosts: [HostRecord]) {
        self.id = id
        self.date = date
        self.networkName = networkName
        self.subnet = subnet
        self.gateway = gateway
        self.hosts = hosts
    }
}

public struct InventoryDiff: Sendable, Equatable {
    public struct Change: Sendable, Equatable {
        public var address: String
        public var name: String
        public var openedPorts: [Int]
        public var closedPorts: [Int]
    }

    public var added: [HostRecord]
    public var removed: [HostRecord]
    public var changed: [Change]

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }

    /// What differs between an earlier scan and a later one: hosts that appeared, hosts that
    /// are gone, and hosts whose open ports are not the same. „Port 23 is newly open" is the
    /// line a network person comes for.
    public static func between(_ old: NetworkSnapshot, _ new: NetworkSnapshot) -> InventoryDiff {
        let before = Dictionary(old.hosts.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(new.hosts.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
        let added = new.hosts.filter { before[$0.address] == nil }
        let removed = old.hosts.filter { after[$0.address] == nil }
        var changed: [Change] = []
        for host in new.hosts {
            guard let previous = before[host.address] else { continue }
            let opened = Set(host.openPorts).subtracting(previous.openPorts).sorted()
            let closed = Set(previous.openPorts).subtracting(host.openPorts).sorted()
            if !opened.isEmpty || !closed.isEmpty {
                changed.append(Change(address: host.address, name: host.displayName,
                                      openedPorts: opened, closedPorts: closed))
            }
        }
        return InventoryDiff(added: added, removed: removed, changed: changed)
    }
}

extension NetworkSnapshot {
    /// One row per host, for a spreadsheet: what a network person hands to a customer.
    public func csv(vendor: (MACAddress) -> String? = { _ in nil }) -> String {
        var lines = ["address,name,guess,open_ports,services,round_trip_ms,sources,mac,vendor"]
        for host in hosts {
            let mac = host.mac.flatMap { MACAddress($0) }
            let fields = [
                host.address,
                host.hostNames.joined(separator: "; "),
                host.guess.rawValue,
                host.openPorts.map(String.init).joined(separator: " "),
                host.services.joined(separator: " "),
                host.roundTrip.map { String(format: "%.2f", $0 * 1_000) } ?? "",
                host.sources.joined(separator: " "),
                mac?.description ?? "",
                mac.flatMap(vendor) ?? "",
            ]
            lines.append(fields.map(RecordingExporter.csvEscape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
