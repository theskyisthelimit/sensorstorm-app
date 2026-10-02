import Foundation
import Observation
import SensorstormCore

/// What the person told the app about a host that the network cannot: a name of their own and
/// the hardware address, which iOS never lets an app read. Kept per network, because
/// 192.168.1.20 at home and 192.168.1.20 at a customer are two different machines.
struct HostAnnotation: Codable, Sendable, Hashable {
    var alias: String?
    var mac: String?
    var note: String?

    var isEmpty: Bool { (alias ?? "").isEmpty && (mac ?? "").isEmpty && (note ?? "").isEmpty }
}

/// The scans of earlier visits and the names the person gave. Small JSON files in Application
/// Support: a few hundred hosts at most, read once, written after each change.
@MainActor @Observable
final class NetworkInventoryStore {
    /// Newest first.
    private(set) var snapshots: [NetworkSnapshot] = []
    private var annotations: [String: HostAnnotation] = [:]

    private let directory: URL
    /// More than this and the oldest scans go: a snapshot of a busy office is some 100 kB.
    static let keptSnapshots = 60

    init(directory: URL? = nil) {
        let base = directory ?? (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?
            .appendingPathComponent("Network", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Network", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        load()
    }

    // MARK: Scans

    func save(_ snapshot: NetworkSnapshot) {
        snapshots.removeAll { $0.id == snapshot.id }
        snapshots.insert(snapshot, at: 0)
        snapshots.sort { $0.date > $1.date }
        if snapshots.count > Self.keptSnapshots { snapshots.removeLast(snapshots.count - Self.keptSnapshots) }
        persist()
    }

    func delete(_ snapshot: NetworkSnapshot) {
        snapshots.removeAll { $0.id == snapshot.id }
        persist()
    }

    /// The scan of the same network just before this one — what „what changed" compares against.
    func previous(to snapshot: NetworkSnapshot) -> NetworkSnapshot? {
        snapshots.first {
            $0.subnet == snapshot.subnet && $0.networkName == snapshot.networkName && $0.date < snapshot.date
        }
    }

    // MARK: Names

    func annotation(address: String, subnet: String) -> HostAnnotation {
        annotations[key(address, subnet)] ?? HostAnnotation()
    }

    func setAnnotation(_ annotation: HostAnnotation, address: String, subnet: String) {
        if annotation.isEmpty {
            annotations[key(address, subnet)] = nil
        } else {
            annotations[key(address, subnet)] = annotation
        }
        persist()
    }

    private func key(_ address: String, _ subnet: String) -> String { "\(subnet)|\(address)" }

    // MARK: Storage

    private var snapshotsURL: URL { directory.appendingPathComponent("snapshots.json") }
    private var annotationsURL: URL { directory.appendingPathComponent("annotations.json") }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: snapshotsURL),
           let decoded = try? decoder.decode([NetworkSnapshot].self, from: data) {
            snapshots = decoded.sorted { $0.date > $1.date }
        }
        if let data = try? Data(contentsOf: annotationsURL),
           let decoded = try? decoder.decode([String: HostAnnotation].self, from: data) {
            annotations = decoded
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshots) { try? data.write(to: snapshotsURL, options: .atomic) }
        if let data = try? encoder.encode(annotations) { try? data.write(to: annotationsURL, options: .atomic) }
    }
}

/// The scan the network tab shows: runs the sweep off the main actor, folds what comes back
/// into one list and keeps the result when it ends.
@MainActor @Observable
final class NetworkScanner {
    enum State: Equatable {
        case idle, running, finished
        /// There is no local network to scan: not on Wi-Fi, or no address.
        case unavailable
    }

    private(set) var state: State = .idle
    private(set) var progress = 0.0
    private(set) var phase: NetworkScanEngine.Phase = .discovering
    private(set) var hosts: [HostRecord] = []
    private(set) var localNetworkDenied = false
    /// The subnet was larger than a sweep can sensibly cover and only the part around the
    /// phone was scanned.
    private(set) var isWindowed = false
    private(set) var scannedCount = 0
    private(set) var latest: NetworkSnapshot?
    var options = ScanOptions()

    private var task: Task<Void, Never>?

    var isRunning: Bool { state == .running }

    func start(environment: NetworkEnvironment, inventory: NetworkInventoryStore) {
        guard !isRunning else { return }
        environment.refreshInterfaces()
        guard let interface = environment.lanInterface, let own = interface.ipv4, let subnet = interface.subnet else {
            state = .unavailable
            return
        }
        let addresses = subnet.hosts(excluding: [own], limit: 1_024)
        isWindowed = subnet.hostCount - 1 > addresses.count
        scannedCount = addresses.count
        let gateway = environment.gateway
        let name = environment.networkName
        let options = self.options

        hosts = []
        progress = 0
        phase = .discovering
        localNetworkDenied = false
        state = .running

        task = Task { [weak self] in
            let callbacks = NetworkScanEngine.Callbacks(
                host: { record in Task { @MainActor in self?.merge(record) } },
                progress: { value, phase in Task { @MainActor in self?.update(value, phase) } },
                localNetworkDenied: { Task { @MainActor in self?.localNetworkDenied = true } })
            let found = await NetworkScanEngine.run(addresses: addresses, gateway: gateway,
                                                    options: options, callbacks: callbacks)
            let cancelled = Task.isCancelled
            await self?.finish(found, cancelled: cancelled, name: name, subnet: subnet,
                               gateway: gateway, inventory: inventory)
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func merge(_ record: HostRecord) {
        if let index = hosts.firstIndex(where: { $0.address == record.address }) {
            var existing = hosts[index]
            existing.merge(record)
            if record.guess != .unknown { existing.guess = record.guess }
            hosts[index] = existing
        } else {
            hosts.append(record)
        }
        hosts.sort { (IPv4Addr($0.address)?.value ?? 0) < (IPv4Addr($1.address)?.value ?? 0) }
    }

    private func update(_ value: Double, _ phase: NetworkScanEngine.Phase) {
        progress = max(progress, value)
        self.phase = phase
    }

    private func finish(_ found: [HostRecord], cancelled: Bool, name: String, subnet: IPv4Subnet,
                        gateway: IPv4Addr?, inventory: NetworkInventoryStore) {
        for record in found { merge(record) }
        progress = 1
        state = .finished
        task = nil
        // A scan that was stopped is half a picture, and a half picture saved as „the network
        // as it was" would make the next comparison report every missing host as gone.
        guard !cancelled, !hosts.isEmpty else { return }
        let snapshot = NetworkSnapshot(networkName: name, subnet: subnet.description,
                                       gateway: gateway?.description, hosts: hosts)
        latest = snapshot
        inventory.save(snapshot)
    }
}

/// The figures of the last speed test, kept so the acceptance protocol can quote them.
struct SpeedTestSummary: Sendable, Equatable {
    var date: Date
    var downloadMegabits: Double?
    var uploadMegabits: Double?
    var idleLatency: Double?
    var loadedLatency: Double?
}

/// Everything the network tab needs, created once at launch.
@MainActor @Observable
final class NetworkHub {
    let environment = NetworkEnvironment()
    let scanner = NetworkScanner()
    let inventory = NetworkInventoryStore()
    var lastSpeedTest: SpeedTestSummary?
}
