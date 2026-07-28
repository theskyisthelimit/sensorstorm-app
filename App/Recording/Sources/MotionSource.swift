import CoreMotion
import Foundation
import SensorstormCore

/// Everything CoreMotion delivers: the three raw IMU sensors, the five fused
/// `CMDeviceMotion` streams, the barometer, the pedometer and AirPods head motion.
///
/// `CMLogItem.timestamp` is already seconds on the host clock — the same base the video
/// encoder's presentation timestamps use — so IMU samples need no conversion at all. Only
/// the pedometer, which reports `Date`s, goes through the wall-clock offset.
final class MotionSource: SensorSource, @unchecked Sendable {
    private let sink: SampleSink
    private let manager = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let pedometer = CMPedometer()
    private let headphoneManager = CMHeadphoneMotionManager()

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "ch.sensorstorm.motion"
        queue.qualityOfService = .userInitiated
        // Serial: sample order per stream must be preserved, and the writers assume
        // monotonically increasing timestamps.
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private var wallToHostOffset: Double = 0
    private var active: Set<SensorID> = []

    /// `.xTrueNorthZVertical` yields a yaw referenced to true north, which is what makes
    /// the orientation stream comparable across recordings — but it needs location
    /// authorisation. Set before ``start(sensors:rateHz:wallToHostOffset:)``.
    var usesTrueNorthReference = false

    init(sink: SampleSink) {
        self.sink = sink
    }

    var availableSensors: Set<SensorID> {
        var result: Set<SensorID> = []
        if manager.isAccelerometerAvailable { result.insert(.accelerometer) }
        if manager.isGyroAvailable { result.insert(.gyroscope) }
        if manager.isMagnetometerAvailable { result.insert(.magnetometer) }
        if manager.isDeviceMotionAvailable {
            result.formUnion([.userAcceleration, .gravity, .rotationRate, .orientation, .magneticField])
        }
        if CMAltimeter.isRelativeAltitudeAvailable() { result.insert(.barometer) }
        if CMPedometer.isStepCountingAvailable() { result.insert(.pedometer) }
        if headphoneManager.isDeviceMotionAvailable { result.insert(.headphoneOrientation) }
        return result
    }

    func start(sensors: Set<SensorID>, rateHz: Double, wallToHostOffset: Double) {
        self.wallToHostOffset = wallToHostOffset
        let wanted = sensors.intersection(availableSensors)
        active = wanted
        let interval = 1.0 / max(rateHz, 1)

        if wanted.contains(.accelerometer) {
            manager.accelerometerUpdateInterval = interval
            manager.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
                guard let self, let data else { return }
                sink.ingest(.accelerometer, time: data.timestamp,
                            values: [data.acceleration.x, data.acceleration.y, data.acceleration.z])
            }
        }

        if wanted.contains(.gyroscope) {
            manager.gyroUpdateInterval = interval
            manager.startGyroUpdates(to: queue) { [weak self] data, _ in
                guard let self, let data else { return }
                sink.ingest(.gyroscope, time: data.timestamp,
                            values: [data.rotationRate.x, data.rotationRate.y, data.rotationRate.z])
            }
        }

        if wanted.contains(.magnetometer) {
            manager.magnetometerUpdateInterval = interval
            manager.startMagnetometerUpdates(to: queue) { [weak self] data, _ in
                guard let self, let data else { return }
                sink.ingest(.magnetometer, time: data.timestamp,
                            values: [data.magneticField.x, data.magneticField.y, data.magneticField.z])
            }
        }

        startDeviceMotionIfNeeded(wanted: wanted, interval: interval)

        if wanted.contains(.barometer) {
            altimeter.startRelativeAltitudeUpdates(to: queue) { [weak self] data, _ in
                guard let self, let data else { return }
                sink.ingest(.barometer, time: data.timestamp,
                            values: [data.pressure.doubleValue, data.relativeAltitude.doubleValue])
            }
        }

        if wanted.contains(.pedometer) {
            pedometer.startUpdates(from: Date()) { [weak self] data, _ in
                guard let self, let data else { return }
                let time = HostClock.hostSeconds(for: data.endDate, offset: self.wallToHostOffset)
                sink.ingest(.pedometer, time: time, values: [
                    data.numberOfSteps.doubleValue,
                    data.distance?.doubleValue ?? .nan,
                    data.currentCadence?.doubleValue ?? .nan,
                    data.currentPace?.doubleValue ?? .nan,
                    data.floorsAscended?.doubleValue ?? .nan,
                    data.floorsDescended?.doubleValue ?? .nan
                ])
            }
        }

        if wanted.contains(.headphoneOrientation) {
            headphoneManager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
                guard let self, let motion else { return }
                let attitude = motion.attitude
                sink.ingest(.headphoneOrientation, time: motion.timestamp, values: [
                    attitude.roll.degrees, attitude.pitch.degrees, attitude.yaw.degrees,
                    motion.userAcceleration.x, motion.userAcceleration.y, motion.userAcceleration.z
                ])
            }
        }
    }

    func stop() {
        manager.stopAccelerometerUpdates()
        manager.stopGyroUpdates()
        manager.stopMagnetometerUpdates()
        manager.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        pedometer.stopUpdates()
        headphoneManager.stopDeviceMotionUpdates()
        queue.cancelAllOperations()
        active = []
    }

    // MARK: - Private

    private static let deviceMotionSensors: Set<SensorID> =
        [.userAcceleration, .gravity, .rotationRate, .orientation, .magneticField]

    private func startDeviceMotionIfNeeded(wanted: Set<SensorID>, interval: TimeInterval) {
        let fused = wanted.intersection(Self.deviceMotionSensors)
        guard !fused.isEmpty else { return }

        manager.deviceMotionUpdateInterval = interval
        let frame: CMAttitudeReferenceFrame = usesTrueNorthReference
            ? .xTrueNorthZVertical
            : .xArbitraryCorrectedZVertical

        manager.startDeviceMotionUpdates(using: frame, to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let time = motion.timestamp

            if fused.contains(.userAcceleration) {
                sink.ingest(.userAcceleration, time: time, values: [
                    motion.userAcceleration.x, motion.userAcceleration.y, motion.userAcceleration.z
                ])
            }
            if fused.contains(.gravity) {
                sink.ingest(.gravity, time: time,
                            values: [motion.gravity.x, motion.gravity.y, motion.gravity.z])
            }
            if fused.contains(.rotationRate) {
                sink.ingest(.rotationRate, time: time, values: [
                    motion.rotationRate.x, motion.rotationRate.y, motion.rotationRate.z
                ])
            }
            if fused.contains(.orientation) {
                let attitude = motion.attitude
                let q = attitude.quaternion
                sink.ingest(.orientation, time: time, values: [
                    attitude.roll.degrees, attitude.pitch.degrees, attitude.yaw.degrees,
                    q.x, q.y, q.z, q.w
                ])
            }
            if fused.contains(.magneticField) {
                let field = motion.magneticField
                sink.ingest(.magneticField, time: time, values: [
                    field.field.x, field.field.y, field.field.z,
                    Double(field.accuracy.rawValue)
                ])
            }
        }
    }
}

extension Double {
    var degrees: Double { self * 180 / .pi }
}
