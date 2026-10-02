import CoreLocation
import Foundation
import SensorstormCore

/// iBeacons the person named by UUID: signal strength and distance, each beacon its own stream.
///
/// iOS ranges beacons only for UUIDs it is told about — there is no "list every beacon" — and
/// only while the app is in the foreground. A beacon in a corridor ceiling is a zone marker:
/// the recording says which zone the phone was in, to within a few metres, without GPS.
final class BeaconSource: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let sink: SampleSink
    private let lock = NSLock()
    private var manager: CLLocationManager?
    private var constraints: [CLBeaconIdentityConstraint] = []

    init(sink: SampleSink) {
        self.sink = sink
    }

    /// The UUIDs written one per line in the settings; anything that is not one is skipped.
    static func parse(_ lines: [String]) -> [UUID] {
        lines.compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    @MainActor
    func start(uuids: [UUID]) {
        guard CLLocationManager.isRangingAvailable(), !uuids.isEmpty else { return }
        let manager = CLLocationManager()
        manager.delegate = self
        var started: [CLBeaconIdentityConstraint] = []
        for uuid in uuids {
            let constraint = CLBeaconIdentityConstraint(uuid: uuid)
            manager.startRangingBeacons(satisfying: constraint)
            started.append(constraint)
        }
        lock.withLock {
            self.manager = manager
            constraints = started
        }
    }

    func stop() {
        let (manager, constraints) = lock.withLock { () -> (CLLocationManager?, [CLBeaconIdentityConstraint]) in
            let current = (self.manager, self.constraints)
            self.manager = nil
            self.constraints = []
            return current
        }
        guard let manager else { return }
        for constraint in constraints { manager.stopRangingBeacons(satisfying: constraint) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didRange beacons: [CLBeacon],
                                     satisfying constraint: CLBeaconIdentityConstraint) {
        let time = HostClock.now
        for beacon in beacons {
            let uuid = beacon.uuid.uuidString
            let short = String(uuid.prefix(8)).lowercased()
            let major = beacon.major.intValue
            let minor = beacon.minor.intValue
            let info = ExternalStreamInfo(
                id: "beacon.\(short).\(major).\(minor)", source: .beacon,
                title: "iBeacon \(short.uppercased()) · \(major)/\(minor)",
                channels: ["rssi", "distance", "proximity"], channelUnits: ["dBm", "m", ""])
            // rssi 0 means "no signal"; accuracy −1 means "unknown". Neither is a measurement.
            let rssi = beacon.rssi == 0 ? Double.nan : Double(beacon.rssi)
            let distance = beacon.accuracy < 0 ? Double.nan : beacon.accuracy
            sink.ingestExternal(info, time: time, values: [rssi, distance, Double(beacon.proximity.rawValue)])
        }
    }
}
