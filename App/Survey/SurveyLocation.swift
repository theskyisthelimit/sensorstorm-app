import CoreLocation
import Foundation
import Observation
import SensorstormCore

/// One GPS fix, reduced to plain numbers.
///
/// `CLLocation` is a reference type that arrives on the delegate's thread; carrying the
/// values across instead of the object keeps the whole survey path free of shared mutable
/// state, which is what `SWIFT_STRICT_CONCURRENCY: complete` asks for anyway.
struct LiveFix: Sendable, Hashable {
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var ellipsoidalAltitude: Double
    var horizontalAccuracy: Double
    var verticalAccuracy: Double
    var speed: Double
    var course: Double
    var timestamp: Date

    init(_ location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        altitude = location.altitude
        ellipsoidalAltitude = location.ellipsoidalAltitude
        horizontalAccuracy = location.horizontalAccuracy
        verticalAccuracy = location.verticalAccuracy
        speed = location.speed
        course = location.course
        timestamp = location.timestamp
    }

    /// CoreLocation reports (0, 0) with a negative accuracy while it has nothing.
    var isUsable: Bool { horizontalAccuracy > 0 }

    var coordinate: Coordinate2D {
        Coordinate2D(latitude: latitude, longitude: longitude)
    }

    func findingLocation(heading: Double?) -> FindingLocation {
        FindingLocation(latitude: latitude,
                        longitude: longitude,
                        altitude: altitude,
                        ellipsoidalAltitude: ellipsoidalAltitude,
                        horizontalAccuracy: horizontalAccuracy,
                        verticalAccuracy: verticalAccuracy,
                        heading: heading)
    }
}

/// The live position for the survey screens.
///
/// Separate from ``LocationSource``, which exists to write GPS samples into a recording.
/// This one only ever answers "where am I standing right now", runs whenever a survey
/// screen is open, and stops the moment it closes — a walk down a street is minutes of
/// work, and a location manager left running afterwards is a battery bill for nothing.
@MainActor
@Observable
final class SurveyLocationProvider {
    private(set) var fix: LiveFix?
    /// Degrees from true north, or `nil` when the compass has nothing usable.
    private(set) var heading: Double?
    private(set) var authorization: CLAuthorizationStatus
    private(set) var isRunning = false

    /// How many screens currently want the live position.
    private var holders = 0
    private let manager = CLLocationManager()
    private let forwarder = Forwarder()

    init() {
        authorization = manager.authorizationStatus
        manager.delegate = forwarder
        // The finding is a spot on the ground, not a track: best accuracy, no filtering.
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.headingFilter = kCLHeadingFilterNone

        forwarder.onFix = { [weak self] fix in
            Task { @MainActor in self?.fix = fix }
        }
        forwarder.onHeading = { [weak self] heading in
            Task { @MainActor in self?.heading = heading }
        }
        forwarder.onAuthorization = { [weak self] status in
            Task { @MainActor in
                self?.authorization = status
                // Authorisation can land after start() already ran — pick the updates up then.
                if self?.isRunning == true { self?.start() }
            }
        }
    }

    var isAuthorized: Bool {
        switch authorization {
        case .authorizedWhenInUse, .authorizedAlways: true
        default: false
        }
    }

    func requestAuthorization() {
        guard authorization == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    /// Screens hold the position while they are on screen, counted rather than switched.
    /// The capture sheet and the area editor sit on top of the map screen, and the innermost
    /// one closing must not turn GPS off underneath the ones still open.
    func acquire() {
        holders += 1
        guard holders == 1 else { return }
        start()
    }

    func release() {
        holders = max(holders - 1, 0)
        guard holders == 0 else { return }
        stop()
    }

    private func start() {
        isRunning = true
        guard isAuthorized else {
            requestAuthorization()
            return
        }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    private func stop() {
        isRunning = false
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    /// How good the current fix is, as something to put on screen next to a coordinate.
    var accuracyDescription: String {
        guard let fix, fix.isUsable else { return String(localized: "kein Fix") }
        return String(format: "±%.0f m", fix.horizontalAccuracy)
    }

    /// Delegate callbacks arrive off the main actor, so they land here first and are
    /// forwarded as plain values.
    private final class Forwarder: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
        var onFix: (@Sendable (LiveFix) -> Void)?
        var onHeading: (@Sendable (Double?) -> Void)?
        var onAuthorization: (@Sendable (CLAuthorizationStatus) -> Void)?

        func locationManager(_ manager: CLLocationManager,
                             didUpdateLocations locations: [CLLocation]) {
            guard let location = locations.last else { return }
            onFix?(LiveFix(location))
        }

        func locationManager(_ manager: CLLocationManager, didUpdateHeading heading: CLHeading) {
            // A negative accuracy means the reading is unusable — usually an uncalibrated
            // magnetometer. Reporting it as a direction would be worse than reporting none.
            let usable = heading.headingAccuracy >= 0 && heading.trueHeading >= 0
            onHeading?(usable ? heading.trueHeading : nil)
        }

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            onAuthorization?(manager.authorizationStatus)
        }

        func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
            RecordingLog.warn("survey location error: \(error.localizedDescription)")
        }
    }
}
