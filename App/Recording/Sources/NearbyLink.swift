import Foundation
import NearbyInteraction
import SensorstormCore

/// Ultra-wideband distance and direction to the second phone: a tape measure between two
/// iPhones, good to centimetres, with no GPS and no line of sight needed beyond a few metres.
///
/// Each phone makes a session, which has a discovery token. The tokens are swapped over the
/// Bluetooth service (see ``BLEPeripheralService``), each phone starts its session with the
/// other's token, and the system reports distance and direction a few times a second.
///
/// The direction is written as a unit vector in the phone's own frame — x to the right, y up, z
/// out of the back — rather than as angles. Angles need a convention, a convention needs a
/// reference, and a reader with the vector can compute either.
final class NearbyLink: NSObject, NISessionDelegate, @unchecked Sendable {
    private let sink: SampleSink
    private let lock = NSLock()
    private var session: NISession?
    private var peerName = "iPhone"

    init(sink: SampleSink) {
        self.sink = sink
    }

    static var isSupported: Bool {
        NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
    }

    /// This phone's token, ready to be handed to the other one. `nil` on a phone without
    /// ultra-wideband.
    @MainActor
    func prepare() -> Data? {
        guard Self.isSupported else { return nil }
        let current = lock.withLock { () -> NISession in
            if let existing = session { return existing }
            let created = NISession()
            created.delegate = self
            session = created
            return created
        }
        guard let token = current.discoveryToken else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    @MainActor
    func start(peerToken data: Data, name: String) {
        guard Self.isSupported,
              let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data)
        else { return }
        _ = prepare()
        lock.withLock { peerName = name }
        let current = lock.withLock { session }
        current?.run(NINearbyPeerConfiguration(peerToken: token))
    }

    func stop() {
        let current = lock.withLock { () -> NISession? in
            let existing = session
            session = nil
            return existing
        }
        current?.invalidate()
    }

    // MARK: - NISessionDelegate

    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let object = nearbyObjects.first else { return }
        let name = lock.withLock { peerName }
        let info = ExternalStreamInfo(
            id: "nearby.uwb", source: .nearby,
            title: String(localized: "UWB-Abstand zu \(name)"),
            channels: ["distance", "x", "y", "z"], channelUnits: ["m", "", "", ""])
        let distance = object.distance.map(Double.init) ?? .nan
        let direction = object.direction
        sink.ingestExternal(info, time: HostClock.now, values: [
            distance,
            direction.map { Double($0.x) } ?? .nan,
            direction.map { Double($0.y) } ?? .nan,
            direction.map { Double($0.z) } ?? .nan
        ])
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        RecordingLog.warn("nearby interaction ended: \(error.localizedDescription)")
    }
}
