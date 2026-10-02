import Foundation
import Network
import SensorstormCore

// MARK: - Bonjour

/// A service a device announces on the local network.
struct BonjourService: Sendable, Hashable {
    var name: String
    /// `_ipp._tcp`
    var type: String
    var address: IPv4Addr?
    var port: Int?
    var txt: [String: String]
}

/// Listens for the service types devices at home and in the office announce themselves with.
///
/// iOS only lets an app browse the types listed in `NSBonjourServices`, so this list and the
/// one in project.yml are the same list. A device announcing none of them is still found by
/// the sweep — it just has no name here.
enum Bonjour {
    static let serviceTypes: [String] = [
        "_http._tcp", "_https._tcp", "_ssh._tcp", "_sftp-ssh._tcp", "_smb._tcp",
        "_afpovertcp._tcp", "_nfs._tcp", "_adisk._tcp", "_workstation._tcp", "_device-info._tcp",
        "_ipp._tcp", "_ipps._tcp", "_printer._tcp", "_pdl-datastream._tcp", "_scanner._tcp",
        "_uscan._tcp", "_airplay._tcp", "_raop._tcp", "_companion-link._tcp",
        "_apple-mobdev2._tcp", "_homekit._tcp", "_hap._tcp", "_matter._tcp", "_googlecast._tcp",
        "_spotify-connect._tcp", "_sonos._tcp", "_daap._tcp", "_rtsp._tcp", "_mqtt._tcp",
        "_esphomelib._tcp", "_hue._tcp", "_home-assistant._tcp", "_eppc._tcp",
    ]

    /// Services found over `duration` seconds, as they are found. The stream ends by itself.
    static func discover(duration: Double, onDenied: @escaping @Sendable () -> Void = {}) -> AsyncStream<BonjourService> {
        AsyncStream { continuation in
            let run = BonjourRun(duration: duration, yield: { continuation.yield($0) },
                                 denied: onDenied, finish: { continuation.finish() })
            continuation.onTermination = { _ in run.stop() }
            run.start()
        }
    }
}

private final class BonjourRun: @unchecked Sendable {
    private let duration: Double
    private let yield: @Sendable (BonjourService) -> Void
    private let denied: @Sendable () -> Void
    private let finish: @Sendable () -> Void
    private let queue = DispatchQueue(label: "ch.sensorstorm.bonjour")
    private var browsers: [NWBrowser] = []
    private var resolving: [NWConnection] = []
    private var seen = Set<String>()
    private var stopped = false

    init(duration: Double, yield: @escaping @Sendable (BonjourService) -> Void,
         denied: @escaping @Sendable () -> Void, finish: @escaping @Sendable () -> Void) {
        self.duration = duration
        self.yield = yield
        self.denied = denied
        self.finish = finish
    }

    func start() {
        queue.async { [self] in
            for type in Bonjour.serviceTypes {
                let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: NWParameters())
                browser.stateUpdateHandler = { [self] state in
                    if case .waiting(let error) = state, case .dns(let code) = error, code == -65_570 { denied() }
                }
                browser.browseResultsChangedHandler = { [self] results, _ in
                    for result in results { resolve(result, type: type) }
                }
                browser.start(queue: queue)
                browsers.append(browser)
            }
            // Browsing itself ends at `duration`; resolutions still under way get two more seconds.
            queue.asyncAfter(deadline: .now() + duration) { [self] in
                for browser in browsers { browser.cancel() }
                browsers.removeAll()
                queue.asyncAfter(deadline: .now() + 2) { [self] in stop() }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            for browser in browsers { browser.cancel() }
            for connection in resolving { connection.cancel() }
            browsers.removeAll()
            resolving.removeAll()
            finish()
        }
    }

    private func resolve(_ result: NWBrowser.Result, type: String) {
        guard case .service(let name, _, _, _) = result.endpoint else { return }
        let key = "\(type)|\(name)"
        guard seen.insert(key).inserted else { return }

        var txt: [String: String] = [:]
        if case .bonjour(let record) = result.metadata { txt = record.dictionary }

        // The service endpoint carries no address. Opening a connection to it makes the
        // system resolve one, and the path then says which — the cheapest way to get an
        // IPv4 address without the deprecated NetService.
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: result.endpoint, using: parameters)
        resolving.append(connection)
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                var address: IPv4Addr?
                var port: Int?
                if case .hostPort(let host, let endpointPort)? = connection.currentPath?.remoteEndpoint {
                    if case .ipv4(let ip) = host { address = IPv4Addr(octets: Array(ip.rawValue)) }
                    port = Int(endpointPort.rawValue)
                }
                connection.cancel()
                yield(BonjourService(name: name, type: type, address: address, port: port, txt: txt))
            case .failed, .waiting:
                connection.cancel()
                // Still worth listing: the name is known even when the address is not.
                yield(BonjourService(name: name, type: type, address: nil, port: nil, txt: txt))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
}

// MARK: - Port scan

enum PortScanner {
    struct Finding: Sendable, Hashable {
        var port: Int
        var banner: String?
        var roundTrip: Double?
    }

    /// The open TCP ports among `ports`, ascending.
    static func scan(host: String, ports: [Int], concurrency: Int = 64, timeout: Double = 0.8,
                     banners: Bool = false,
                     progress: (@Sendable (Int) -> Void)? = nil) async -> [Finding] {
        let results = await concurrentMap(ports, limit: concurrency) { port -> (result: TCPResult, port: Int) in
            let result = await TCP.probe(host: host, port: port, timeout: timeout, banner: banners)
            progress?(port)
            return (result, port)
        }
        return results
            .filter { $0.result.outcome == .open }
            .map { Finding(port: $0.port, banner: $0.result.banner, roundTrip: $0.result.roundTrip) }
            .sorted { $0.port < $1.port }
    }
}

// MARK: - Sweep

struct ScanOptions: Sendable, Equatable {
    var pingSweep = true
    /// Hosts that ignore pings still refuse or accept a connection.
    var tcpFallback = true
    var bonjour = true
    var netbios = true
    var reverseDNS = true
    var scansPorts = true
    var portPreset: PortCatalog.Preset = .top100
    var customPorts: [Int] = []
}

enum NetworkScanEngine {
    struct Callbacks: Sendable {
        var host: @Sendable (HostRecord) -> Void
        /// 0…1, and what is happening.
        var progress: @Sendable (Double, Phase) -> Void
        var localNetworkDenied: @Sendable () -> Void
    }

    enum Phase: Sendable, Equatable {
        case discovering, enriching
    }

    /// Ports a host that ignores pings is asked on: web, ssh, file sharing, and the port an
    /// iPhone answers on.
    private static let aliveProbePorts = [443, 80, 22, 445, 62_078, 8_080, 53]

    static func run(addresses: [IPv4Addr], gateway: IPv4Addr?, options: ScanOptions,
                    callbacks: Callbacks) async -> [HostRecord] {
        // Bonjour runs alongside the sweep; its answers are folded in at the end.
        let bonjourTask: Task<[BonjourService], Never>? = options.bonjour
            ? Task {
                var found: [BonjourService] = []
                for await service in Bonjour.discover(duration: 6, onDenied: callbacks.localNetworkDenied) {
                    found.append(service)
                }
                return found
            }
            : nil

        // --- Who is there?
        let total = max(addresses.count, 1)
        let counter = Counter()
        let alive = await concurrentMap(addresses, limit: 48) { address -> HostRecord? in
            let record = await probeAlive(address, options: options, callbacks: callbacks)
            let done = counter.increment()
            callbacks.progress(Double(done) / Double(total) * 0.55, .discovering)
            if let record { callbacks.host(record) }
            return record
        }
        var records = Dictionary(alive.compactMap { $0 }.map { ($0.address, $0) },
                                 uniquingKeysWith: { first, _ in first })

        // Bonjour may reveal hosts that answered neither ping nor probe.
        let services = await bonjourTask?.value ?? []
        var byAddress: [String: [BonjourService]] = [:]
        for service in services {
            guard let address = service.address, addresses.contains(address) else { continue }
            byAddress[address.description, default: []].append(service)
            if records[address.description] == nil {
                let record = HostRecord(address: address.description, sources: ["bonjour"])
                records[address.description] = record
                callbacks.host(record)
            }
        }

        // --- What are they?
        let list = records.values.sorted { ($0.address) < ($1.address) }
        let enrichCounter = Counter()
        let enriched = await concurrentMap(list, limit: 10) { record -> HostRecord in
            var record = record
            record = await enrich(record, services: byAddress[record.address] ?? [], gateway: gateway,
                                  options: options)
            let done = enrichCounter.increment()
            callbacks.progress(0.55 + Double(done) / Double(max(list.count, 1)) * 0.45, .enriching)
            callbacks.host(record)
            return record
        }
        callbacks.progress(1, .enriching)
        return enriched.sorted { (IPv4Addr($0.address)?.value ?? 0) < (IPv4Addr($1.address)?.value ?? 0) }
    }

    private static func probeAlive(_ address: IPv4Addr, options: ScanOptions,
                                   callbacks: Callbacks) async -> HostRecord? {
        if options.pingSweep {
            let ping = await ICMP.ping(address, timeout: 0.9)
            if ping.reachedTarget {
                return HostRecord(address: address.description, roundTrip: ping.roundTrip, sources: ["ping"])
            }
        }
        guard options.tcpFallback else { return nil }
        let results = await withTaskGroup(of: (Int, TCPResult).self) { group -> [(Int, TCPResult)] in
            for port in aliveProbePorts {
                group.addTask { (port, await TCP.probe(host: address.description, port: port, timeout: 0.7)) }
            }
            var collected: [(Int, TCPResult)] = []
            for await item in group { collected.append(item) }
            return collected
        }
        if results.contains(where: { $0.1.localNetworkDenied }) { callbacks.localNetworkDenied() }
        let answering = results.filter { $0.1.hostAnswered }
        guard !answering.isEmpty else { return nil }
        let open = answering.filter { $0.1.outcome == .open }.map(\.0).sorted()
        return HostRecord(address: address.description, openPorts: open,
                          roundTrip: answering.compactMap { $0.1.roundTrip }.min(), sources: ["tcp"])
    }

    private static func reverseName(of address: IPv4Addr, via gateway: IPv4Addr?, enabled: Bool) async -> String? {
        guard enabled, let gateway else { return nil }
        return await DNS.reverse(address, server: gateway.description)
    }

    private static func netbiosEntries(of address: IPv4Addr, enabled: Bool) async -> [NetBIOSName.Entry]? {
        guard enabled else { return nil }
        let request = NetBIOSName.statusRequest(id: UInt16.random(in: 1...UInt16.max))
        guard let data = await UDP.exchange(host: address.description, port: 137, payload: request, timeout: 0.8)
        else { return nil }
        return NetBIOSName.parse(data)
    }

    private static func openPorts(of address: IPv4Addr, options: ScanOptions) async -> [PortScanner.Finding] {
        guard options.scansPorts else { return [] }
        let list = PortCatalog.services(options.portPreset, custom: options.customPorts)
        return await PortScanner.scan(host: address.description, ports: list, concurrency: 48, timeout: 0.7)
    }

    private static func enrich(_ record: HostRecord, services: [BonjourService], gateway: IPv4Addr?,
                               options: ScanOptions) async -> HostRecord {
        var record = record
        guard let address = IPv4Addr(record.address) else { return record }

        for service in services {
            if !record.services.contains(service.type) { record.services.append(service.type) }
            if !record.hostNames.contains(service.name) { record.hostNames.append(service.name) }
            if !record.sources.contains("bonjour") { record.sources.append("bonjour") }
        }

        async let reverse = reverseName(of: address, via: gateway, enabled: options.reverseDNS)
        async let netbios = netbiosEntries(of: address, enabled: options.netbios)
        async let ports = openPorts(of: address, options: options)

        if let name = await reverse, !record.hostNames.contains(name) {
            record.hostNames.append(name)
            if !record.sources.contains("dns") { record.sources.append("dns") }
        }
        if let entries = await netbios, let name = NetBIOSName.hostName(entries) {
            if !record.hostNames.contains(name) { record.hostNames.append(name) }
            if !record.sources.contains("netbios") { record.sources.append("netbios") }
        }
        let open = await ports
        record.openPorts = Array(Set(record.openPorts + open.map(\.port))).sorted()

        record.guess = DeviceClassifier.guess(address: record.address, gateway: gateway?.description,
                                              openPorts: record.openPorts, services: record.services,
                                              names: record.hostNames)
        return record
    }
}

/// A counter several tasks may bump.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
