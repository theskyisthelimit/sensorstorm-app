import CoreMotion
import Foundation
import SensorstormCore

/// What the phone thinks the body carrying it is doing: standing still, walking, running,
/// cycling, or riding in a vehicle.
///
/// Event-driven — iOS emits an update when its opinion changes, not on a clock. Each class
/// gets its own 0/1 column rather than one enumerated value, because Core Motion genuinely
/// reports more than one at a time (walking *and* automotive, on a moving train), and a
/// single column would have to throw one of them away.
///
/// `CMMotionActivity` inherits `CMLogItem`, so its `timestamp` is already seconds on the
/// host clock — the same reason the IMU streams need no conversion either.
final class ActivitySource: @unchecked Sendable {
    private let sink: SampleSink
    private let manager = CMMotionActivityManager()

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "ch.sensorstorm.activity"
        // Utility rather than userInitiated: these arrive every few seconds at most, and
        // they must not compete with the IMU for the CPU during a 400 Hz recording.
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private var isRunning = false

    init(sink: SampleSink) {
        self.sink = sink
    }

    var availableSensors: Set<SensorID> {
        CMMotionActivityManager.isActivityAvailable() ? [.activity] : []
    }

    /// Triggers the „Bewegung & Fitness" prompt without starting anything.
    ///
    /// Core Motion has no `requestAuthorization`. The prompt is a side effect of the first
    /// query, so a one-second query into the past is the smallest thing that provokes it —
    /// the result is thrown away, only the answer to the prompt matters. Returns once the
    /// user has decided, so the caller can redraw against the new state.
    func requestAuthorization() async {
        guard CMMotionActivityManager.isActivityAvailable(),
              CMMotionActivityManager.authorizationStatus() == .notDetermined else { return }
        let now = Date()
        await withCheckedContinuation { continuation in
            manager.queryActivityStarting(from: now.addingTimeInterval(-1), to: now, to: queue) { _, _ in
                continuation.resume()
            }
        }
    }

    func start(sensors: Set<SensorID>) {
        guard sensors.contains(.activity),
              CMMotionActivityManager.isActivityAvailable(),
              !isRunning else { return }
        isRunning = true

        manager.startActivityUpdates(to: queue) { [sink] activity in
            guard let activity else { return }
            sink.ingest(.activity, time: activity.timestamp, values: [
                activity.stationary ? 1 : 0,
                activity.walking ? 1 : 0,
                activity.running ? 1 : 0,
                activity.automotive ? 1 : 0,
                activity.cycling ? 1 : 0,
                activity.unknown ? 1 : 0,
                // low = 0, medium = 1, high = 2. Written because a "walking" the classifier
                // is unsure about is a different claim from one it is certain of.
                Double(activity.confidence.rawValue),
            ])
        }
    }

    func stop() {
        guard isRunning else { return }
        manager.stopActivityUpdates()
        isRunning = false
    }
}
