import CFNetwork
import CoreTelephony
import Foundation
import Network
import NetworkExtension
import Observation
import SensorstormCore

/// One network interface of the phone, as the system lists it.
struct NetworkInterface: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable {
        case wifi, cellular, wired, vpn, hotspot, peerToPeer, loopback, other
    }

    var name: String
    var kind: Kind
    var isUp: Bool
    var ipv4: IPv4Addr?
    var subnet: IPv4Subnet?
    var ipv6: [String]

    var id: String { name }

    /// Interfaces of the local network a scan can run on.
    var isLAN: Bool {
        guard isUp, ipv4 != nil, kind == .wifi || kind == .wired || kind == .hotspot else { return false }
        return ipv4.map { $0.isPrivate || $0.isSharedAddressSpace } ?? false
    }
}

struct WiFiInfo: Sendable, Equatable {
    var ssid: String
    var bssid: String
    /// 0…1, the system's own scale. Not dBm: iOS does not hand an app the real value.
    var signalStrength: Double
    var isSecure: Bool
    /// WEP, WPA/WPA2/WPA3 personal, enterprise or open, as the system classifies it. iOS does
    /// not say which generation of WPA.
    var security: SecurityKind
    /// The hardware address of the access point, formatted; its manufacturer comes from
    /// `VendorLookup`. `bssid` is kept as the system gave it.
    var accessPointVendor: String? { VendorLookup.name(bssid) }

    enum SecurityKind: Sendable, Equatable {
        case open, wep, personal, enterprise, unknown
    }
}

/// The HTTP proxy the system is configured with, if any. A proxy in the way is the answer to a
/// surprising number of „the app cannot connect" reports.
struct ProxyInfo: Sendable, Equatable {
    var http: String?
    var https: String?
    var autoConfigURL: String?

    var isEmpty: Bool { http == nil && https == nil && autoConfigURL == nil }

    static func read() -> ProxyInfo {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return ProxyInfo()
        }
        func endpoint(_ enable: String, _ host: String, _ port: String) -> String? {
            guard (settings[enable] as? Int) == 1, let name = settings[host] as? String, !name.isEmpty else { return nil }
            if let number = settings[port] as? Int { return "\(name):\(number)" }
            return name
        }
        let pac: String? = (settings["ProxyAutoConfigEnable"] as? Int) == 1
            ? settings["ProxyAutoConfigURLString"] as? String : nil
        return ProxyInfo(http: endpoint("HTTPEnable", "HTTPProxy", "HTTPPort"),
                         https: endpoint("HTTPSEnable", "HTTPSProxy", "HTTPSPort"),
                         autoConfigURL: pac)
    }
}

/// What a public-address lookup returned. Only ever asked for on a button press.
struct PublicAddressInfo: Sendable, Equatable {
    var address: String
    var country: String?
    var datacenter: String?
    var usesWarp: Bool
    /// The IPv6 address the internet sees, when the network has IPv6 at all.
    var ipv6: String?
    /// Who runs the network the address belongs to.
    var owner: ASNInfo?
}

/// What the phone knows about the network it is in, gathered in one place so every network
/// view reads the same answer. Most of it is free; the Wi-Fi name needs an entitlement and
/// the location permission, and the public address needs one request to a third party that
/// only happens when asked for.
@MainActor @Observable
final class NetworkEnvironment {
    struct PathSummary: Sendable, Equatable {
        var isSatisfied: Bool
        var statusText: String
        var interfaceNames: [String]
        var isExpensive: Bool
        var isConstrained: Bool
        var supportsIPv4: Bool
        var supportsIPv6: Bool
        var supportsDNS: Bool
    }

    private(set) var interfaces: [NetworkInterface] = []
    private(set) var path: PathSummary?
    private(set) var wifi: WiFiInfo?
    /// Why there is no Wi-Fi name, when there is none: not on Wi-Fi, no entitlement, no
    /// location permission. The system does not say which; the app can only list them.
    private(set) var wifiChecked = false
    private(set) var radioTechnologies: [String] = []
    private(set) var gateways: [IPv4Addr] = []
    private(set) var dnsServers: [String] = []
    private(set) var proxy = ProxyInfo()
    private(set) var publicAddress: PublicAddressInfo?
    private(set) var isQueryingPublicAddress = false
    private(set) var publicAddressFailed = false

    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "ch.sensorstorm.pathmonitor")

    // MARK: - Derived

    /// The interface a scan runs on: Wi-Fi first, then a wired adapter, then the phone's own
    /// hotspot.
    var lanInterface: NetworkInterface? {
        let candidates = interfaces.filter(\.isLAN)
        return candidates.first { $0.kind == .wifi } ?? candidates.first { $0.kind == .wired } ?? candidates.first
    }

    var subnet: IPv4Subnet? { lanInterface?.subnet }

    /// The router, as far as the system says — from the current path's gateways. Falls back
    /// to the first address of the subnet, which is right in most home networks and is
    /// marked as a guess by ``gatewayIsGuessed``.
    var gateway: IPv4Addr? {
        if let known = gateways.first(where: { subnet?.contains($0) ?? true }) { return known }
        guard let subnet else { return nil }
        return IPv4Addr(subnet.network.value + 1)
    }

    var gatewayIsGuessed: Bool { gateways.isEmpty }

    /// What the network is called in a saved scan.
    var networkName: String {
        if let wifi { return wifi.ssid }
        switch lanInterface?.kind {
        case .wifi: return "WLAN"
        case .wired: return "Ethernet"
        case .hotspot: return "Hotspot"
        default: return subnet.map(String.init(describing:)) ?? "—"
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let summary = Self.summarise(path)
            let gateways = Self.ipv4Gateways(of: path)
            Task { @MainActor in self?.apply(summary, gateways: gateways) }
        }
        monitor.start(queue: queue)
        self.monitor = monitor
        refreshInterfaces()
        refreshRadio()
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }

    private func apply(_ summary: PathSummary, gateways: [IPv4Addr]) {
        path = summary
        self.gateways = gateways
        refreshInterfaces()
        refreshRadio()
        Task { await refreshWiFi() }
    }

    func refreshInterfaces() {
        interfaces = Self.readInterfaces()
        dnsServers = SystemDNS.servers()
        proxy = ProxyInfo.read()
    }

    func refreshWiFi() async {
        let network = await NEHotspotNetwork.fetchCurrent()
        wifiChecked = true
        guard let network else {
            wifi = nil
            return
        }
        let security: WiFiInfo.SecurityKind
        switch network.securityType {
        case .open: security = .open
        case .WEP: security = .wep
        case .personal: security = .personal
        case .enterprise: security = .enterprise
        case .unknown: security = .unknown
        @unknown default: security = .unknown
        }
        wifi = WiFiInfo(ssid: network.ssid, bssid: network.bssid,
                        signalStrength: network.signalStrength, isSecure: network.isSecure, security: security)
    }

    private func refreshRadio() {
        let info = CTTelephonyNetworkInfo()
        radioTechnologies = (info.serviceCurrentRadioAccessTechnology ?? [:])
            .sorted { $0.key < $1.key }
            .map { Self.radioName($0.value) }
    }

    /// Requests to Cloudflare's trace endpoint, which answers with the caller's address and the
    /// datacentre that handled it: one over IPv4 and one over IPv6, so a network that has both
    /// shows both. Then two name queries ask who runs the address. Nothing is sent but that.
    func queryPublicAddress() async {
        guard !isQueryingPublicAddress,
              let v4 = URL(string: "https://1.1.1.1/cdn-cgi/trace"),
              let v6 = URL(string: "https://[2606:4700:4700::1111]/cdn-cgi/trace") else { return }
        isQueryingPublicAddress = true
        publicAddressFailed = false
        defer { isQueryingPublicAddress = false }
        async let first = Self.trace(v4)
        async let second = Self.trace(v6)
        let (four, six) = await (first, second)
        // On a network without IPv4 the first request is carried over IPv6 and says so.
        guard let primary = four ?? six, let address = primary["ip"] else {
            publicAddressFailed = true
            return
        }
        let ipv6 = [four?["ip"], six?["ip"]].compactMap { $0 }.first { $0.contains(":") }
        var owner: ASNInfo?
        if let ip = IPv4Addr(address) {
            let resolver = dnsServers.first { IPv4Addr($0) != nil } ?? "1.1.1.1"
            owner = await ASNCache.shared.lookup(ip, server: resolver)
        }
        publicAddress = PublicAddressInfo(address: address, country: primary["loc"],
                                          datacenter: primary["colo"], usesWarp: primary["warp"] == "on",
                                          ipv6: ipv6 == address ? nil : ipv6, owner: owner)
    }

    nonisolated private static func trace(_ url: URL) async -> [String: String]? {
        let report = await HTTPProbe.request(url, timeout: 6)
        guard report.statusCode == 200, let text = report.bodyPreview else { return nil }
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
        }
        return fields["ip"] == nil ? nil : fields
    }

    // MARK: - Reading the system

    nonisolated private static func summarise(_ path: NWPath) -> PathSummary {
        let status: String
        switch path.status {
        case .satisfied: status = "satisfied"
        case .unsatisfied: status = "unsatisfied"
        case .requiresConnection: status = "requiresConnection"
        @unknown default: status = "unknown"
        }
        return PathSummary(isSatisfied: path.status == .satisfied, statusText: status,
                           interfaceNames: path.availableInterfaces.map(\.name),
                           isExpensive: path.isExpensive, isConstrained: path.isConstrained,
                           supportsIPv4: path.supportsIPv4, supportsIPv6: path.supportsIPv6,
                           supportsDNS: path.supportsDNS)
    }

    nonisolated private static func ipv4Gateways(of path: NWPath) -> [IPv4Addr] {
        path.gateways.compactMap { endpoint -> IPv4Addr? in
            guard case .hostPort(let host, _) = endpoint, case .ipv4(let address) = host else { return nil }
            return IPv4Addr(octets: Array(address.rawValue))
        }
    }

    nonisolated static func kind(ofInterface name: String) -> NetworkInterface.Kind {
        switch name {
        case "lo0": .loopback
        case "en0": .wifi
        case _ where name.hasPrefix("pdp_ip"): .cellular
        case _ where name.hasPrefix("utun"), _ where name.hasPrefix("ipsec"), _ where name.hasPrefix("ppp"): .vpn
        case _ where name.hasPrefix("bridge"): .hotspot
        case _ where name.hasPrefix("awdl"), _ where name.hasPrefix("llw"), _ where name.hasPrefix("ap"): .peerToPeer
        case _ where name.hasPrefix("en"): .wired
        default: .other
        }
    }

    nonisolated static func readInterfaces() -> [NetworkInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var order: [String] = []
        var byName: [String: NetworkInterface] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            guard let address = entry.pointee.ifa_addr else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            let flags = Int32(entry.pointee.ifa_flags)
            var interface = byName[name] ?? NetworkInterface(
                name: name, kind: kind(ofInterface: name),
                isUp: flags & IFF_UP != 0 && flags & IFF_RUNNING != 0, ipv4: nil, subnet: nil, ipv6: [])

            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    IPv4Addr(UInt32(bigEndian: $0.pointee.sin_addr.s_addr))
                }
                interface.ipv4 = ip
                if let mask = entry.pointee.ifa_netmask {
                    let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        IPv4Addr(UInt32(bigEndian: $0.pointee.sin_addr.s_addr))
                    }
                    interface.subnet = IPv4Subnet(address: ip, netmask: netmask)
                }
            case AF_INET6:
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    interface.ipv6.append(String(cString: buffer))
                }
            default:
                continue
            }
            if byName[name] == nil { order.append(name) }
            byName[name] = interface
        }
        return order.compactMap { byName[$0] }
            .filter { $0.kind != .loopback && ($0.ipv4 != nil || !$0.ipv6.isEmpty) }
    }

    nonisolated static func radioName(_ technology: String) -> String {
        switch technology {
        case CTRadioAccessTechnologyNR: return "5G"
        case CTRadioAccessTechnologyNRNSA: return "5G (NSA)"
        case CTRadioAccessTechnologyLTE: return "LTE"
        case CTRadioAccessTechnologyWCDMA, CTRadioAccessTechnologyHSDPA, CTRadioAccessTechnologyHSUPA: return "3G"
        case CTRadioAccessTechnologyeHRPD, CTRadioAccessTechnologyCDMAEVDORev0,
             CTRadioAccessTechnologyCDMAEVDORevA, CTRadioAccessTechnologyCDMAEVDORevB: return "3G (CDMA)"
        case CTRadioAccessTechnologyEdge: return "EDGE"
        case CTRadioAccessTechnologyGPRS, CTRadioAccessTechnologyCDMA1x: return "2G"
        default: return technology
        }
    }
}
