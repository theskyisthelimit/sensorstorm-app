import Foundation
import Network
import SensorstormCore
import UIKit

/// Battery, screen brightness and network reachability.
///
/// Sampled once per second rather than only on change: a continuous curve is what makes a
/// recording useful afterwards ("the battery fell off a cliff exactly when the GPS went to
/// 1 Hz"), and three doubles per second is 32 bytes of file.
@MainActor
final class DeviceStateSource {
    private let sink: SampleSink
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "ch.sensorstorm.network")

    private var timer: Timer?
    private var active: Set<SensorID> = []
    private let pathState = NetworkPathState()

    init(sink: SampleSink) {
        self.sink = sink
    }

    var availableSensors: Set<SensorID> { [.battery, .brightness, .network] }

    func start(sensors: Set<SensorID>) {
        active = sensors.intersection(availableSensors)
        guard !active.isEmpty else { return }

        if active.contains(.battery) {
            UIDevice.current.isBatteryMonitoringEnabled = true
        }
        if active.contains(.network) {
            pathMonitor.pathUpdateHandler = { [pathState] path in
                pathState.update(path)
            }
            pathMonitor.start(queue: monitorQueue)
        }

        sampleNow()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleNow() }
        }
        // .common so the samples keep coming while the user scrolls the dashboard.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if active.contains(.network) {
            pathMonitor.cancel()
            pathMonitor.pathUpdateHandler = nil
        }
        if active.contains(.battery) {
            UIDevice.current.isBatteryMonitoringEnabled = false
        }
        active = []
    }

    private func sampleNow() {
        let time = HostClock.now

        if active.contains(.battery) {
            let device = UIDevice.current
            // -1 means "unknown"; keep it out of the data as NaN rather than as a value.
            let level = device.batteryLevel < 0 ? Double.nan : Double(device.batteryLevel) * 100
            sink.ingest(.battery, time: time,
                        values: [level, Double(device.batteryState.rawValue)])
        }
        if active.contains(.brightness) {
            let screen = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.screen }
                .first ?? UIScreen.main
            sink.ingest(.brightness, time: time, values: [Double(screen.brightness) * 100])
        }
        if active.contains(.network) {
            let snapshot = pathState.snapshot()
            sink.ingest(.network, time: time, values: [
                Double(snapshot.kind.rawValue),
                snapshot.isExpensive ? 1 : 0,
                snapshot.isConstrained ? 1 : 0
            ])
        }
    }
}

/// The numeric encoding written into the `network` stream's `type` column.
enum NetworkKind: Int, Sendable, CaseIterable {
    case none = 0
    case wifi = 1
    case cellular = 2
    case wired = 3
    case other = 4

    var label: String {
        switch self {
        case .none: "—"
        case .wifi: "WLAN"
        case .cellular: "Mobil"
        case .wired: "Kabel"
        case .other: "Anderes"
        }
    }
}

/// `NWPathMonitor` reports on its own queue; the 1 Hz sampler reads from the main actor.
/// A tiny lock is cheaper and clearer here than bouncing the whole sampler onto a queue.
private final class NetworkPathState: @unchecked Sendable {
    struct Snapshot {
        var kind: NetworkKind = .none
        var isExpensive = false
        var isConstrained = false
    }

    private let lock = NSLock()
    private var current = Snapshot()

    func update(_ path: NWPath) {
        var snapshot = Snapshot()
        if path.status == .satisfied {
            if path.usesInterfaceType(.wifi) {
                snapshot.kind = .wifi
            } else if path.usesInterfaceType(.cellular) {
                snapshot.kind = .cellular
            } else if path.usesInterfaceType(.wiredEthernet) {
                snapshot.kind = .wired
            } else {
                snapshot.kind = .other
            }
        }
        snapshot.isExpensive = path.isExpensive
        snapshot.isConstrained = path.isConstrained

        lock.lock()
        current = snapshot
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return current
    }
}
