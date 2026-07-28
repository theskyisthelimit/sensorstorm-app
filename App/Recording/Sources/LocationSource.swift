import CoreLocation
import Foundation
import SensorstormCore

/// GPS and compass.
///
/// `CLLocation` timestamps are wall-clock `Date`s, so they are mapped onto the host clock
/// with the offset captured when the recording started. Accuracy is pinned to
/// `bestForNavigation` with no distance filter — this app exists to capture the raw track,
/// not to save battery.
final class LocationSource: NSObject, SensorSource, CLLocationManagerDelegate, @unchecked Sendable {
    private let sink: SampleSink
    private let manager = CLLocationManager()
    private var wallToHostOffset: Double = 0
    private var active: Set<SensorID> = []

    /// Called on the main queue whenever authorisation changes.
    var onAuthorizationChange: (@Sendable (CLAuthorizationStatus) -> Void)?

    init(sink: SampleSink) {
        self.sink = sink
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.headingFilter = kCLHeadingFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    var isAuthorized: Bool {
        switch authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: true
        default: false
        }
    }

    var availableSensors: Set<SensorID> {
        var result: Set<SensorID> = [.location]
        if CLLocationManager.headingAvailable() { result.insert(.compass) }
        return result
    }

    func requestAuthorization() {
        guard authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    func start(sensors: Set<SensorID>, rateHz: Double, wallToHostOffset: Double) {
        self.wallToHostOffset = wallToHostOffset
        active = sensors.intersection(availableSensors)

        guard isAuthorized else {
            requestAuthorization()
            return
        }
        if active.contains(.location) {
            manager.startUpdatingLocation()
        }
        if active.contains(.compass), CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    /// Keeps GPS alive once the screen locks. Only legal — and only enabled — while a
    /// recording is actually running.
    func setBackgroundUpdates(_ enabled: Bool) {
        guard isAuthorized, active.contains(.location) else { return }
        manager.allowsBackgroundLocationUpdates = enabled
        manager.showsBackgroundLocationIndicator = enabled
    }

    func stop() {
        manager.allowsBackgroundLocationUpdates = false
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        active = []
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            let time = HostClock.hostSeconds(for: location.timestamp, offset: wallToHostOffset)
            sink.ingest(.location, time: time, values: [
                location.coordinate.latitude,
                location.coordinate.longitude,
                location.altitude,
                location.ellipsoidalAltitude,
                location.speed,
                location.speedAccuracy,
                location.course,
                location.courseAccuracy,
                location.horizontalAccuracy,
                location.verticalAccuracy
            ])
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateHeading heading: CLHeading) {
        let time = HostClock.hostSeconds(for: heading.timestamp, offset: wallToHostOffset)
        sink.ingest(.compass, time: time, values: [
            heading.trueHeading, heading.magneticHeading, heading.headingAccuracy
        ])
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        onAuthorizationChange?(status)

        // Authorisation can land after start() already ran — pick the updates up then.
        guard isAuthorized, !active.isEmpty else { return }
        if active.contains(.location) { manager.startUpdatingLocation() }
        if active.contains(.compass), CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        RecordingLog.warn("location error: \(error.localizedDescription)")
    }
}
