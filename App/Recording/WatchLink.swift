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
    private var lastFastTime = -Double.greatestFiniteMagnitude
    private var lastStatus: (isRecording: Bool, since: Date?) = (false, nil)
    private var wantsFast = false

    init(sink: SampleSink) {
        self.sink = sink
        super.init()
    }

    /// The watch is available when one is paired and has the app installed. Unlike the other
    /// sources this cannot be answered synchronously at launch — `WCSession` has to activate
    /// first — so the streams are offered whenever a session exists at all and simply stay
    /// empty if nothing arrives.
    var availableSensors: Set<SensorID> {
        gap == nil ? [.heartRate, .wristMotion] : []
    }

    /// What is missing, when something is. `nil` means a watch is paired, has the app, and
    /// the session is up — the only state in which the two streams can arrive.
    ///
    /// The settings screen shows this instead of a bare „nicht verfügbar": a phone with no
    /// watch and a phone whose watch lacks the app are the same empty set but two different
    /// instructions, and only one of them is „install Sensorstorm on the watch".
    var gap: WatchGap? {
        guard WCSession.isSupported() else { return .notSupported }
        guard WCSession.default.activationState == .activated else { return .notPaired }
        guard WCSession.default.isPaired else { return .notPaired }
        guard WCSession.default.isWatchAppInstalled else { return .appNotInstalled }
        return nil
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
            lastFastTime = -Double.greatestFiniteMagnitude
        }
    }

    func stop() {
        lock.withLock { isRunning = false }
    }

    // MARK: - WCSessionDelegate

    /// Called whenever the pairing or the installed-app state changes. Without it the
    /// settings screen kept saying „keine Uhr" after a watch had just been paired, until
    /// the app was relaunched.
    var onReachabilityChange: (@Sendable () -> Void)?

    /// Commands from the watch: `start`, `stop`, `mark`. Run by whoever owns the recording.
    var onCommand: (@Sendable (String) -> Void)?

    /// Tells the watch whether the phone is recording, and since when. An application context
    /// rather than a message: the watch may not be looking, and the latest state is all it will
    /// ever want.
    func publishStatus(isRecording: Bool, since: Date?) {
        lock.withLock { lastStatus = (isRecording, since) }
        sendContext()
    }

    /// Whether the watch should stream its wrist acceleration at the high rate. Rides in the
    /// same application context, so the watch reads it when it starts, whoever starts it.
    func setFastRate(_ on: Bool) {
        let changed = lock.withLock { () -> Bool in
            guard wantsFast != on else { return false }
            wantsFast = on
            return true
        }
        if changed { sendContext() }
    }

    private func sendContext() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled else { return }
        let (status, fast) = lock.withLock { (lastStatus, wantsFast) }
        var context: [String: Any] = ["recording": status.isRecording, "fast": fast]
        if let since = status.since { context["since"] = since.timeIntervalSince1970 }
        try? WCSession.default.updateApplicationContext(context)
    }

    static let fastAccelerometerStream = ExternalStreamInfo(
        id: "watch.accelerometer.fast", source: .device,
        title: String(localized: "Uhr: Beschleunigung (hohe Rate)"),
        channels: ["x", "y", "z"], channelUnits: ["g", "g", "g"])

    private func ingestBinary(_ packets: [Data]) {
        let (running, offset) = lock.withLock { (isRunning, wallToHostOffset) }
        guard running else { return }
        for data in packets {
            guard let packet = WatchPacket.decode(data) else { continue }
            for row in packet.rows {
                let time = row.time + offset
                // Monotonic, like every stream: a reader's binary search depends on it.
                let accepted = lock.withLock { () -> Bool in
                    guard time > lastFastTime else { return false }
                    lastFastTime = time
                    return true
                }
                if accepted { sink.ingestExternal(Self.fastAccelerometerStream, time: time, values: row.values) }
            }
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let command = message["cmd"] as? String else { return }
        onCommand?(command)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        onReachabilityChange?()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        onReachabilityChange?()
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // Reactivate so a switch to another watch keeps working.
        WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let packets = userInfo["bin"] as? [Data] {
            ingestBinary(packets)
            return
        }
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
