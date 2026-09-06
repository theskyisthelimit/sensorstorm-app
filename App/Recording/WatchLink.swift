import Foundation
import SensorstormCore
import WatchConnectivity

/// Receives heart rate and wrist motion from the paired Apple Watch.
///
/// **The clocks are not the same one.** Every other stream in this app is stamped on the
/// phone's host clock, which is what makes a video frame and an acceleration value line up
/// with no calibration. Two devices have two `mach_absolute_time` origins and no shared
/// oscillator, so watch samples travel as wall-clock seconds and are converted here through
/// the same offset the pedometer and the GPS use.
///
/// That buys alignment on the order of the two systems' clock agreement — tens of
/// milliseconds — rather than the sub-millisecond the on-device streams have. Good enough
/// for a heart rate against a route; not good enough to correlate against a 400 Hz IMU, and
/// said out loud here so nobody discovers it in an export six months from now.
final class WatchLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let sink: SampleSink
    private let lock = NSLock()
    private var wallToHostOffset: Double = 0
    private var isRunning = false
    /// Newest accepted timestamp per stream. `StreamReader`'s binary search — the thing that
    /// makes scrubbing instant — is only correct on monotonic timestamps, and these arrive
    /// from a second device over a queue. One out-of-order heart-rate sample would corrupt
    /// that silently, so it is dropped instead.
    private var lastTime: [SensorID: Double] = [:]

    init(sink: SampleSink) {
        self.sink = sink
        super.init()
    }

    /// The watch is available when one is paired and has the app installed. Unlike the other
    /// sources this cannot be answered synchronously at launch — `WCSession` has to activate
    /// first — so the streams are offered whenever a session exists at all and simply stay
    /// empty if nothing arrives.
    var availableSensors: Set<SensorID> {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled else { return [] }
        return [.heartRate, .wristMotion]
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func start(sensors: Set<SensorID>, wallToHostOffset: Double) {
        lock.withLock {
            self.wallToHostOffset = wallToHostOffset
            // Both streams come from one transfer, so there is nothing to switch on per
            // sensor — either the watch is sending or it is not.
            isRunning = !sensors.isDisjoint(with: [.heartRate, .wristMotion])
            lastTime.removeAll()
        }
    }

    func stop() {
        lock.withLock { isRunning = false }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // Reactivate so a switch to another watch keeps working.
        WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let batch = userInfo["batch"] as? [[String: Any]] else { return }
        let (running, offset) = lock.withLock { (isRunning, wallToHostOffset) }
        guard running else { return }

        for entry in batch {
            guard let name = entry["s"] as? String,
                  let sensor = SensorID(rawValue: name),
                  let wallTime = entry["t"] as? Double,
                  let values = entry["v"] as? [Double] else { continue }

            let time = wallTime + offset
            let accepted = lock.withLock { () -> Bool in
                guard time > (lastTime[sensor] ?? -.greatestFiniteMagnitude) else { return false }
                lastTime[sensor] = time
                return true
            }
            guard accepted else { continue }
            sink.ingest(sensor, time: time, values: values)
        }
    }
}
