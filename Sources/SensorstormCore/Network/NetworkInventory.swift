import Foundation

/// A guess at what a device in the network is, from what it answers on. Said to be a guess:
/// iOS cannot read a device's hardware address, so there is no vendor lookup — only the
/// services it offers and the name it gives.
public enum DeviceGuess: String, Codable, Sendable, CaseIterable {
    case router, printer, nas, camera, mediaPlayer, smartHome, apple, computer, server, unknown
}

public enum DeviceClassifier {
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
    /// How the host was found: `ping`, `tcp`, `bonjour`, `netbios`, `ssdp`.
    public var sources: [String]
    public var guess: DeviceGuess

    public var id: String { address }

    public init(address: String, hostNames: [String] = [], services: [String] = [],
                openPorts: [Int] = [], roundTrip: Double? = nil, sources: [String] = [],
                guess: DeviceGuess = .unknown) {
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
    public func csv() -> String {
        var lines = ["address,name,guess,open_ports,services,round_trip_ms,sources"]
        for host in hosts {
            let fields = [
                host.address,
                host.hostNames.joined(separator: "; "),
                host.guess.rawValue,
                host.openPorts.map(String.init).joined(separator: " "),
                host.services.joined(separator: " "),
                host.roundTrip.map { String(format: "%.2f", $0 * 1_000) } ?? "",
                host.sources.joined(separator: " "),
            ]
            lines.append(fields.map(RecordingExporter.csvEscape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
