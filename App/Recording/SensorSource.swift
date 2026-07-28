import Foundation
import SensorstormCore

/// A group of sensors that share one underlying framework and are started and stopped
/// together. Sources are deliberately *not* main-actor isolated: their callbacks arrive on
/// background queues and must reach the ``SampleSink`` without an actor hop.
protocol SensorSource: AnyObject {
    /// Which of this source's sensors this device can actually deliver, right now.
    var availableSensors: Set<SensorID> { get }

    /// - Parameter offset: wall-clock → host-clock offset captured once at start, for
    ///   sources whose timestamps are `Date`s.
    func start(sensors: Set<SensorID>, rateHz: Double, wallToHostOffset: Double)
    func stop()
}
