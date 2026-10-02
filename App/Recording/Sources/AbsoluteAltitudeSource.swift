import CoreMotion
import Foundation
import SensorstormCore

/// Height above sea level from the barometer and the GPS fused by the system: better than the
/// GPS altitude, which wanders by ten metres, and better than the barometer alone, which has
/// no zero. Roughly once a second.
final class AbsoluteAltitudeSource: @unchecked Sendable {
    static let stream = ExternalStreamInfo(
        id: "motion.altitude.absolute", source: .device,
        title: String(localized: "Absolute Höhe (GPS und Barometer)"),
        channels: ["altitude", "accuracy", "precision"], channelUnits: ["m", "m", "m"])

    private let sink: SampleSink
    private let altimeter = CMAltimeter()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "ch.sensorstorm.absolutealtitude"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    init(sink: SampleSink) {
        self.sink = sink
    }

    static var isAvailable: Bool { CMAltimeter.isAbsoluteAltitudeAvailable() }

    func start() {
        guard Self.isAvailable else { return }
        let sink = self.sink
        altimeter.startAbsoluteAltitudeUpdates(to: queue) { data, _ in
            guard let data else { return }
            sink.ingestExternal(Self.stream, time: data.timestamp,
                                values: [data.altitude, data.accuracy, data.precision])
        }
    }

    func stop() {
        altimeter.stopAbsoluteAltitudeUpdates()
    }
}
