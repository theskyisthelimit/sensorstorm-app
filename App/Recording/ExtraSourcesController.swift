import Foundation
import SensorstormCore

/// Owns the extra sources and starts the ones the recording's settings ask for.
///
/// Started when a recording begins and stopped when it ends — unlike the sensors on the
/// dashboard, which run whenever the screen is open. Nothing here is worth a permission prompt
/// or a battery percentage for a person who only looked at the record screen.
@MainActor
final class ExtraSourcesController {
    private let altitude: AbsoluteAltitudeSource
    private let system: SystemExtrasSource
    private let beacons: BeaconSource
    private let homeKit: HomeKitSource

    init(sink: SampleSink) {
        altitude = AbsoluteAltitudeSource(sink: sink)
        system = SystemExtrasSource(sink: sink)
        beacons = BeaconSource(sink: sink)
        homeKit = HomeKitSource(sink: sink)
    }

    func start(_ settings: RecordingSettings) {
        if settings.isOn(.absoluteAltitude) { altitude.start() }
        if settings.isOn(.systemState) { system.start() }
        if settings.isOn(.beacons) {
            beacons.start(uuids: BeaconSource.parse(settings.beaconUUIDs ?? []))
        }
        if settings.isOn(.homeKit) { homeKit.start() }
    }

    func stop() {
        altitude.stop()
        system.stop()
        beacons.stop()
        homeKit.stop()
    }
}
