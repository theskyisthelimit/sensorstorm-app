import AVFoundation
import CoreBluetooth
import CoreLocation
import CoreMotion
import Foundation
import SensorstormCore
import UIKit

/// Why a stream is not delivering — and, when there is one, the way out.
///
/// „nicht verfügbar" used to be the whole answer. A tester tapped the disabled heart-rate
/// row waiting for a permission prompt that was never going to come: the row was not
/// waiting for a permission at all, it was waiting for an Apple Watch. A dead toggle cannot
/// say that, so it says it here instead, and the row it belongs to becomes something that
/// can be tapped.
enum SensorStatus: Equatable {
    case ready
    /// Never asked. The app can still ask, so tapping the row asks.
    case permissionMissing(SensorPermission)
    /// Refused or restricted by policy. Only the Settings app can undo it.
    case permissionRefused(SensorPermission)
    /// Needs a paired Apple Watch running Sensorstorm.
    case needsWatch(WatchGap)
    /// This device has no such hardware. Nothing to offer.
    case unsupported
    /// The Simulator's stand-in signal, not the hardware.
    case simulated

    var isReady: Bool {
        switch self {
        case .ready, .simulated: true
        default: false
        }
    }

    /// Whether tapping the row leads anywhere. `unsupported` is the one dead end left, and
    /// it is a truthful one.
    var isActionable: Bool {
        switch self {
        case .permissionMissing, .permissionRefused, .needsWatch: true
        case .ready, .simulated, .unsupported: false
        }
    }
}

/// The four system permissions this app can be short of. Grouped the way iOS groups them,
/// not the way the sensor list does: one „Bewegung & Fitness" covers the pedometer, the
/// activity classifier and the barometer's altitude, and asking three times would be three
/// prompts for one switch.
enum SensorPermission: String, Equatable, CaseIterable {
    case motion
    case location
    case microphone
    case bluetooth

    /// Which permission a stream needs, or `nil` if it needs none.
    ///
    /// The raw IMU is deliberately absent: `CMMotionManager` delivers acceleration and
    /// rotation without any permission at all. Only the derived, historical streams —
    /// steps, activity, relative altitude — go through Core Motion's authorisation.
    static func required(for sensor: SensorID) -> SensorPermission? {
        switch sensor {
        case .pedometer, .activity, .barometer: .motion
        case .location, .compass: .location
        case .loudness: .microphone
        case .bluetooth: .bluetooth
        default: nil
        }
    }

    /// Shown under the sensor name once the permission was refused — what to turn on, and
    /// where. Naming the switch is the difference between a reason and an instruction.
    var refusedHint: String {
        switch self {
        case .motion: String(localized: "In den Einstellungen „Bewegung & Fitness“ erlauben.")
        case .location: String(localized: "In den Einstellungen „Ort“ erlauben.")
        case .microphone: String(localized: "In den Einstellungen „Mikrofon“ erlauben.")
        case .bluetooth: String(localized: "In den Einstellungen „Bluetooth“ erlauben.")
        }
    }

    var missingHint: String {
        switch self {
        case .motion: String(localized: "Braucht Bewegung & Fitness. Zum Erlauben tippen.")
        case .location: String(localized: "Braucht die Ortungsdienste. Zum Erlauben tippen.")
        case .microphone: String(localized: "Braucht das Mikrofon. Zum Erlauben tippen.")
        case .bluetooth: String(localized: "Braucht Bluetooth. Zum Erlauben tippen.")
        }
    }
}

/// What is missing between this phone and a watch that could be sending heart rate.
///
/// Two states rather than one, because they have two different remedies and a single
/// „keine Uhr" would send someone with a paired watch to the wrong place.
enum WatchGap: Equatable {
    case notSupported
    case notPaired
    case appNotInstalled

    var hint: String {
        switch self {
        case .notSupported: String(localized: "Dieses iPhone kann keine Apple Watch koppeln.")
        case .notPaired: String(localized: "Braucht eine gekoppelte Apple Watch.")
        case .appNotInstalled: String(localized: "Sensorstorm auf der Apple Watch installieren.")
        }
    }

    var explanation: String {
        switch self {
        case .notSupported:
            String(localized: "Herzfrequenz und Handgelenkbewegung kommen von einer Apple Watch. Dieses Gerät kann keine koppeln.")
        case .notPaired:
            String(localized: "Herzfrequenz und Handgelenkbewegung misst die Apple Watch, nicht das iPhone. Koppel eine Uhr in der Apple-Watch-App, dann erscheinen die beiden Ströme hier.")
        case .appNotInstalled:
            String(localized: "Die Uhr ist gekoppelt, aber Sensorstorm ist nicht darauf installiert. In der Apple-Watch-App unter „Verfügbare Apps“ installieren; die Uhr fragt beim ersten Start selbst nach dem Zugriff auf die Herzfrequenz.")
        }
    }
}

// MARK: - Reading the system's answer

enum SensorPermissionState {
    case missing
    case refused
    case granted
}

extension SensorPermission {
    /// One manager, kept alive. `authorizationStatus` is an instance property since iOS 14,
    /// and this is read once per row on every settings redraw — a fresh `CLLocationManager`
    /// each time would build and tear down a Core Location client for a string.
    @MainActor private static let locationManager = CLLocationManager()

    /// Main actor because `CLLocationManager` is not `Sendable` and this is only ever read
    /// while drawing a row.
    @MainActor
    var state: SensorPermissionState {
        switch self {
        case .motion:
            switch CMMotionActivityManager.authorizationStatus() {
            case .notDetermined: .missing
            case .authorized: .granted
            default: .refused
            }
        case .location:
            switch Self.locationManager.authorizationStatus {
            case .notDetermined: .missing
            case .authorizedWhenInUse, .authorizedAlways: .granted
            default: .refused
            }
        case .microphone:
            switch AVAudioApplication.shared.recordPermission {
            case .undetermined: .missing
            case .granted: .granted
            default: .refused
            }
        case .bluetooth:
            switch CBManager.authorization {
            case .notDetermined: .missing
            case .allowedAlways: .granted
            default: .refused
            }
        }
    }
}

/// The deep link into this app's own page in Settings. Apple guarantees only this one URL;
/// the per-switch URLs that circulate are private API and have been rejected before.
enum SystemSettings {
    @MainActor
    static func open() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
