import Foundation
import SensorstormCore

/// Plausible fake sensor data for the Simulator, which has no IMU, no barometer and no
/// camera.
///
/// Without this the whole app is a grid of "nicht verfügbar" on a Mac, so neither the live
/// dashboard nor the playback charts nor the App Store screenshots can be checked without
/// a device in hand. It never runs on real hardware.
final class SyntheticSource: SensorSource, @unchecked Sendable {
    private let sink: SampleSink
    private let queue = DispatchQueue(label: "ch.sensorstorm.synthetic")
    private var timer: DispatchSourceTimer?
    private var active: Set<SensorID> = []
    private var phase: Double = 0

    init(sink: SampleSink) {
        self.sink = sink
    }

    var availableSensors: Set<SensorID> {
        [.accelerometer, .gyroscope, .magnetometer, .userAcceleration, .gravity,
         .rotationRate, .orientation, .magneticField, .compass, .barometer,
         .location, .loudness, .pedometer]
    }

    func start(sensors: Set<SensorID>, rateHz: Double, wallToHostOffset: Double) {
        stop()
        active = sensors.intersection(availableSensors)
        guard !active.isEmpty else { return }

        let interval = 1.0 / max(rateHz, 1)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick(interval: interval) }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        active = []
    }

    private func tick(interval: Double) {
        let time = HostClock.now
        phase += interval

        // A slow walk with a bit of hand-shake on top — recognisable curves rather than noise.
        let slow = sin(phase * 0.6)
        let fast = sin(phase * 7.3)
        let jitter = Double.random(in: -0.02...0.02)

        if active.contains(.accelerometer) {
            sink.ingest(.accelerometer, time: time,
                        values: [slow * 0.15 + jitter, fast * 0.08 + jitter, -1 + slow * 0.05])
        }
        if active.contains(.userAcceleration) {
            sink.ingest(.userAcceleration, time: time,
                        values: [slow * 0.15 + jitter, fast * 0.08 + jitter, slow * 0.05])
        }
        if active.contains(.gravity) {
            sink.ingest(.gravity, time: time,
                        values: [sin(phase * 0.3) * 0.2, cos(phase * 0.3) * 0.2, -0.96])
        }
        if active.contains(.gyroscope) {
            sink.ingest(.gyroscope, time: time,
                        values: [fast * 0.3, slow * 0.5, sin(phase * 2.1) * 0.2])
        }
        if active.contains(.rotationRate) {
            sink.ingest(.rotationRate, time: time,
                        values: [fast * 0.3, slow * 0.5, sin(phase * 2.1) * 0.2])
        }
        if active.contains(.orientation) {
            let roll = sin(phase * 0.3) * 18
            let pitch = cos(phase * 0.22) * 12
            let yaw = (phase * 6).truncatingRemainder(dividingBy: 360) - 180
            sink.ingest(.orientation, time: time,
                        values: [roll, pitch, yaw,
                                 sin(phase * 0.15), cos(phase * 0.11), sin(phase * 0.09), 1])
        }
        if active.contains(.magnetometer) {
            sink.ingest(.magnetometer, time: time,
                        values: [21 + slow * 3, -8 + fast, 41 + slow * 2])
        }
        if active.contains(.magneticField) {
            sink.ingest(.magneticField, time: time,
                        values: [21 + slow * 3, -8 + fast, 41 + slow * 2, 2])
        }

        // The slow streams keep their own, realistic cadence.
        tickSlowStreams(time: time)
    }

    private var lastSlowTick: Double = 0

    private func tickSlowStreams(time: Double) {
        guard time - lastSlowTick >= 1 else { return }
        lastSlowTick = time

        if active.contains(.compass) {
            let heading = (phase * 6).truncatingRemainder(dividingBy: 360)
            sink.ingest(.compass, time: time, values: [heading, heading - 2.1, 5])
        }
        if active.contains(.barometer) {
            sink.ingest(.barometer, time: time,
                        values: [97.8 + sin(phase * 0.05) * 0.05, sin(phase * 0.05) * 4])
        }
        if active.contains(.location) {
            // A slow drift around Zürich Hauptbahnhof.
            let latitude = 47.378177 + sin(phase * 0.02) * 0.0009
            let longitude = 8.540192 + cos(phase * 0.02) * 0.0012
            sink.ingest(.location, time: time,
                        values: [latitude, longitude, 408 + sin(phase * 0.05) * 3, 455,
                                 1.4 + sin(phase * 0.3) * 0.6, 1.2,
                                 (phase * 6).truncatingRemainder(dividingBy: 360), 4.0,
                                 4.5, 6.0])
        }
        if active.contains(.pedometer) {
            sink.ingest(.pedometer, time: time,
                        values: [(phase * 1.8).rounded(), phase * 1.35, 1.8, 0.55, 0, 0])
        }
        if active.contains(.loudness) {
            sink.ingest(.loudness, time: time,
                        values: [-42 + sin(phase * 1.7) * 8, -28 + sin(phase * 2.3) * 6])
        }
    }
}
