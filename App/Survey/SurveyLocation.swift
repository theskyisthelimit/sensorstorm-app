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

/// A position built from several fixes.
///
/// One GPS fix is a guess with a claimed error bar. Ten fixes taken while standing still
/// are ten guesses around the same truth: their mean is closer to it, and — more usefully —
/// how far they lie apart is a *measured* error bar rather than a claimed one. On a street
/// the claimed accuracy is routinely optimistic next to what the scatter actually shows.
struct AveragedFix: Sendable, Hashable {
    var coordinate: Coordinate2D
    var altitude: Double?
    var ellipsoidalAltitude: Double?
    var sampleCount: Int
    /// Mean of the accuracies the device claimed for the fixes that went in.
    var claimedAccuracy: Double
    /// Root-mean-square distance of the fixes from their mean, in metres.
    var spread: Double
    var duration: TimeInterval

    func findingLocation(heading: Double?) -> FindingLocation {
        FindingLocation(latitude: coordinate.latitude,
                        longitude: coordinate.longitude,
                        altitude: altitude,
                        ellipsoidalAltitude: ellipsoidalAltitude,
                        // The spread is what was measured here; the claimed accuracy is
                        // kept only when there is nothing better to report.
                        horizontalAccuracy: spread > 0 ? spread : claimedAccuracy,
                        verticalAccuracy: -1,
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
    /// The last minute of fixes, so a position can be averaged over the seconds just gone
    /// without asking the user to stand still *again*.
    private var recent: [LiveFix] = []
    private static let bufferSeconds: TimeInterval = 60
    private static let bufferLimit = 300
    private let manager = CLLocationManager()
    private let forwarder = SurveyLocationForwarder()

    init() {
        authorization = manager.authorizationStatus
        manager.delegate = forwarder
        // The finding is a spot on the ground, not a track: best accuracy, no filtering.
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.headingFilter = kCLHeadingFilterNone

        forwarder.onFix = { [weak self] fix in
            Task { @MainActor in self?.record(fix) }
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

    private func record(_ fix: LiveFix) {
        self.fix = fix
        guard fix.isUsable else { return }
        recent.append(fix)

        let cutoff = Date().addingTimeInterval(-Self.bufferSeconds)
        recent.removeAll { $0.timestamp < cutoff }
        if recent.count > Self.bufferLimit {
            recent.removeFirst(recent.count - Self.bufferLimit)
        }
    }

    /// How many usable fixes arrived in the last `seconds`.
    func fixCount(inLast seconds: TimeInterval) -> Int {
        let cutoff = Date().addingTimeInterval(-seconds)
        return recent.count { $0.timestamp >= cutoff }
    }

    /// The mean of the fixes from the last `seconds`, or `nil` when there are too few to
    /// average — two points do not have a scatter worth reporting.
    ///
    /// The mean is weighted by 1/accuracy²: the first fixes after the phone wakes up are
    /// the worst ones, and letting them pull the result as hard as a good fix would throw
    /// away the reason for averaging in the first place.
    func averagedFix(seconds: TimeInterval = 10) -> AveragedFix? {
        let cutoff = Date().addingTimeInterval(-seconds)
        let samples = recent.filter { $0.timestamp >= cutoff && $0.isUsable }
        guard samples.count >= 3 else { return nil }

        var weightSum = 0.0
        var latitude = 0.0
        var longitude = 0.0
        var accuracySum = 0.0
        for sample in samples {
            let weight = 1 / max(sample.horizontalAccuracy, 1) / max(sample.horizontalAccuracy, 1)
            weightSum += weight
            latitude += sample.latitude * weight
            longitude += sample.longitude * weight
            accuracySum += sample.horizontalAccuracy
        }
        guard weightSum > 0 else { return nil }

        let mean = Coordinate2D(latitude: latitude / weightSum, longitude: longitude / weightSum)
        let squared = samples.reduce(0.0) { total, sample in
            let distance = mean.distance(to: sample.coordinate)
            return total + distance * distance
        }
        let spread = (squared / Double(samples.count)).squareRoot()

        let altitudes = samples.map(\.altitude).filter(\.isFinite)
        let ellipsoidal = samples.map(\.ellipsoidalAltitude).filter(\.isFinite)
        let span = (samples.last?.timestamp.timeIntervalSince(
            samples.first?.timestamp ?? Date())) ?? 0

        return AveragedFix(
            coordinate: mean,
            altitude: altitudes.isEmpty ? nil : altitudes.reduce(0, +) / Double(altitudes.count),
            ellipsoidalAltitude: ellipsoidal.isEmpty
                ? nil : ellipsoidal.reduce(0, +) / Double(ellipsoidal.count),
            sampleCount: samples.count,
            claimedAccuracy: accuracySum / Double(samples.count),
            spread: spread,
            duration: max(span, 0))
    }

    /// How good the current fix is, as something to put on screen next to a coordinate.
    var accuracyDescription: String {
        guard let fix, fix.isUsable else { return String(localized: "kein Fix") }
        return String(format: "±%.0f m", fix.horizontalAccuracy)
    }
}

/// Delegate callbacks arrive off the main actor, so they land here first and are forwarded
/// as plain values.
///
/// At file scope rather than nested inside the provider: this object is talked to from
/// CoreLocation's thread, and the enclosing type is main-actor isolated.
private final class SurveyLocationForwarder: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    var onFix: (@Sendable (LiveFix) -> Void)?
    var onHeading: (@Sendable (Double?) -> Void)?
    var onAuthorization: (@Sendable (CLAuthorizationStatus) -> Void)?

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        onFix?(LiveFix(location))
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateHeading heading: CLHeading) {
        // A negative accuracy means the reading is unusable — usually an uncalibrated
        // magnetometer. Reporting it as a direction would be worse than reporting none.
        let usable = heading.headingAccuracy >= 0 && heading.trueHeading >= 0
        onHeading?(usable ? heading.trueHeading : nil)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorization?(manager.authorizationStatus)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        RecordingLog.warn("survey location error: \(error.localizedDescription)")
    }
}
