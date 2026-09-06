import CoreMotion
import Foundation
import HealthKit
import WatchConnectivity

/// The watch half of a recording: heart rate and wrist motion, batched over to the phone.
///
/// **On time.** Everything else in Sensorstorm shares one host clock, which is what lets a
/// video frame and an acceleration value line up without calibration. The watch cannot join
/// that: `mach_absolute_time` on the wrist counts from the watch's own boot, and there is no
/// shared oscillator between two devices. So watch samples are stamped with **wall-clock
/// time** and converted on the phone through its own wall-to-host offset.
///
/// That is a weaker guarantee and it is stated rather than hidden: both clocks are kept by
/// the system within tens of milliseconds of each other, which is fine for a heart rate and
/// useless for correlating a 400 Hz IMU. `WatchLink` on the phone records which base was
/// used, so nobody later mistakes one for the other.
///
/// Deliberately independent of `SensorstormCore`: the watch needs three sensor names and a
/// wire format, not a storage engine, a geodesy library and eight exporters.
@MainActor
@Observable
final class WatchRecorder: NSObject {

    enum Phase: Equatable {
        case idle
        case starting
        case running
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var heartRate: Double?
    private(set) var sentSamples = 0
    private(set) var startedAt: Date?

    /// Sensor names on the wire. They match `SensorID` on the phone, which is also the file
    /// name on disk — so these strings are as fixed as those are.
    static let heartRateStream = "heartRate"
    static let wristMotionStream = "wristMotion"

    private let healthStore = HKHealthStore()
    private let motion = CMMotionManager()
    private let queue = OperationQueue()

    private var workout: HKWorkoutSession?
    private var heartRateQuery: HKAnchoredObjectQuery?
    private var pending: [[String: Any]] = []
    private var flushTimer: Timer?

    /// How often a batch goes over. Every transfer costs radio time on both ends, so
    /// samples are pooled rather than sent one by one.
    private static let flushInterval: TimeInterval = 2

    override init() {
        queue.name = "ch.sensorstorm.watch.motion"
        queue.maxConcurrentOperationCount = 1
        super.init()
        activateConnectivity()
    }

    // MARK: - Lifecycle

    func start() async {
        guard phase == .idle || isFailed else { return }
        phase = .starting

        guard HKHealthStore.isHealthDataAvailable() else {
            phase = .failed(String(localized: "Auf diesem Gerät gibt es keine Gesundheitsdaten."))
            return
        }
        let heartRateType = HKQuantityType(.heartRate)
        do {
            // Read-only: Sensorstorm never writes anything into Health.
            try await healthStore.requestAuthorization(toShare: [], read: [heartRateType])
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        // A workout session is what keeps the app running with the wrist down and what
        // makes the heart rate sensor sample continuously instead of every few minutes.
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .outdoor
        do {
            let session = try HKWorkoutSession(healthStore: healthStore,
                                               configuration: configuration)
            session.delegate = self
            session.startActivity(with: Date())
            workout = session
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        startHeartRate(heartRateType)
        startWristMotion()

        startedAt = Date()
        sentSamples = 0
        phase = .running

        let timer = Timer(timeInterval: Self.flushInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
    }

    func stop() {
        flushTimer?.invalidate()
        flushTimer = nil
        motion.stopDeviceMotionUpdates()
        if let heartRateQuery {
            healthStore.stop(heartRateQuery)
            self.heartRateQuery = nil
        }
        workout?.end()
        workout = nil
        flush()
        heartRate = nil
        startedAt = nil
        phase = .idle
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    // MARK: - Sensors

    private func startHeartRate(_ type: HKQuantityType) {
        let handler: @Sendable (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = {
            [weak self] _, samples, _, _, _ in
            guard let samples = samples as? [HKQuantitySample], !samples.isEmpty else { return }
            let unit = HKUnit.count().unitDivided(by: .minute())
            let readings = samples.map { ($0.endDate.timeIntervalSince1970,
                                          $0.quantity.doubleValue(for: unit)) }
            Task { @MainActor in self?.ingestHeartRate(readings) }
        }
        let query = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: nil,
                                          limit: HKObjectQueryNoLimit, resultsHandler: handler)
        query.updateHandler = handler
        healthStore.execute(query)
        heartRateQuery = query
    }

    private func ingestHeartRate(_ readings: [(Double, Double)]) {
        for (time, beatsPerMinute) in readings {
            append(Self.heartRateStream, time: time, values: [beatsPerMinute])
        }
        heartRate = readings.last?.1
    }

    private func startWristMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 50
        motion.startDeviceMotionUpdates(to: queue) { [weak self] data, _ in
            guard let data else { return }
            // Sampled on the watch's own clock, converted to wall time here so the phone has
            // one thing to reason about rather than two.
            let time = Date().timeIntervalSince1970
            let attitude = data.attitude
            let values = [
                data.userAcceleration.x, data.userAcceleration.y, data.userAcceleration.z,
                data.rotationRate.x, data.rotationRate.y, data.rotationRate.z,
                attitude.roll, attitude.pitch, attitude.yaw,
            ]
            Task { @MainActor in self?.append(Self.wristMotionStream, time: time, values: values) }
        }
    }

    // MARK: - Sending

    private func append(_ stream: String, time: Double, values: [Double]) {
        pending.append(["s": stream, "t": time, "v": values])
        // A watch out of range queues transfers rather than dropping them, but an unbounded
        // queue on a device with this little memory is its own failure. The phone's own
        // sensors are unaffected either way.
        if pending.count > 20_000 {
            pending.removeFirst(pending.count / 4)
        }
    }

    private func flush() {
        guard !pending.isEmpty, WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        let batch = pending
        pending.removeAll(keepingCapacity: true)
        // `transferUserInfo` queues and delivers in the background, unlike `sendMessage`,
        // which needs the phone reachable at that instant. A walk around a building should
        // not punch a hole in the recording.
        session.transferUserInfo(["batch": batch])
        sentSamples += batch.count
    }

    private func activateConnectivity() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WatchRecorder: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState,
                                    date: Date) {
        guard toState == .ended || toState == .stopped else { return }
        Task { @MainActor [weak self] in
            guard let self, self.phase == .running else { return }
            self.stop()
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.phase = .failed(error.localizedDescription)
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchRecorder: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        // Nothing to do: transfers queue until activation completes on their own.
    }
}
