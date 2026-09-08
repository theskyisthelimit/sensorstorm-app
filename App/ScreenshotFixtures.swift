import Foundation
import SensorstormCore
import SwiftUI
import UIKit

/// Deterministic contents for App Store screenshots.
///
/// Driven entirely by launch environment, so it costs a release build nothing: without
/// `SS_FIXTURE=1` every entry point below returns early and no fixture code runs.
/// `Tools/asc_capture_screenshots.py` sets the variables through `SIMCTL_CHILD_*`.
///
/// | variable | effect |
/// |---|---|
/// | `SS_FIXTURE=1` | replace the contents with the sample data on every launch |
/// | `SS_TAB=<case>` | open that tab of ``RootView/Screen`` |
/// | `SS_SCREEN=<case>` | open that deeper screen, see ``Screen`` |
///
/// The sample data is rebuilt from fixed UUIDs and a fixed date on every launch, so the
/// same shot on eight devices in two languages shows the same severities, the same
/// accuracy circles and the same byte counts. A screenshot set where the numbers drift
/// between devices looks like eight different apps.
enum ScreenshotFixture {

    static var isActive: Bool {
        ProcessInfo.processInfo.environment["SS_FIXTURE"] == "1"
    }

    /// A screen that is not one of the four tabs.
    enum Screen: String {
        case survey        // one walk, its cases on the map
        case export        // the device-wide archive sheet
        case paywall       // the purchase sheet — App Review wants to see where money changes hands
    }

    static var tab: RootView.Screen? {
        guard isActive, let raw = ProcessInfo.processInfo.environment["SS_TAB"] else { return nil }
        switch raw {
        case "record": return .record
        case "library": return .library
        case "survey": return .survey
        case "settings": return .settings
        default: return nil
        }
    }

    static var screen: Screen? {
        guard isActive, let raw = ProcessInfo.processInfo.environment["SS_SCREEN"] else { return nil }
        return Screen(rawValue: raw)
    }

    /// Which tab to start on. A deeper screen implies its tab, so the capture script never
    /// has to set both and get them out of step.
    static var initialTab: RootView.Screen? {
        if let tab { return tab }
        switch screen {
        case .survey: return .survey
        case .export, .paywall: return .settings
        case nil: return nil
        }
    }

    /// The price to show while the fixture runs.
    ///
    /// A simulator launched by `simctl` has no StoreKit configuration — that is bound to the
    /// scheme's run action, which only Xcode uses — so `Product.products(for:)` comes back
    /// empty and the purchase button would read „Pro freischalten" with no amount. The App
    /// Review screenshot of an in-app purchase has to show the purchase, price included.
    /// Same number as `Resources/Sensorstorm.storekit` and as App Store Connect.
    static var price: String? { isActive ? "CHF 19.00" : nil }

    // MARK: - Readiness

    /// The capture script polls for this instead of sleeping a fixed amount: a cold start
    /// plus seeding varies by an order of magnitude across devices and machine load, and a
    /// blind sleep either catches the launch screen or wastes minutes over a full run.
    static func markReady() {
        guard isActive else { return }
        guard let documents = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return }
        try? Data().write(to: documents.appendingPathComponent("screenshot-ready"))
    }

    // MARK: - Seeding

    /// Fixed identity, so a second launch overwrites the first rather than piling up.
    ///
    /// Built with a format string rather than written out: a hand-typed literal with one
    /// digit substituted stops being a valid UUID at the tenth case, and the failure would
    /// be a force-unwrap trap in a fixture nobody runs outside a release week.
    private static func fixtureID(group: Int, index: Int) -> UUID {
        UUID(uuidString: String(format: "5E1F%04X-0000-4000-A000-%012X", group, index))!
    }

    private static let surveyID = fixtureID(group: 0, index: 1)
    private static let recordingID = fixtureID(group: 0, index: 2)

    /// A stretch of Bern. A real anchor keeps the LV95 conversion inside its validity
    /// range, which is also what the exports in the same shot will show.
    private static let anchor = Coordinate2D(latitude: 46.9480, longitude: 7.4474)
    private static let day = Date(timeIntervalSince1970: 1_780_000_000)

    /// Fixed rather than read from the running simulator.
    ///
    /// The recording detail screen prints both of these, and `UIDevice.current` would
    /// report a different iOS version on the iPhone runtime than on the iPad one — the
    /// same drift between shots that the fixed UUIDs and the fixed date exist to prevent.
    /// It is also the reason this compiles at all: `UIDevice` is `@MainActor`, and seeding
    /// runs from `App.init` before any view exists.
    private static let fixtureDevice = DeviceInfo(
        model: "iPhone", systemName: "iOS", systemVersion: "18.0",
        appVersion: bundleVersion)

    /// The same string `SettingsView.appVersion` builds, read straight from the bundle so
    /// it needs no actor — the info dictionary is not isolated to anything.
    private static var bundleVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    static func seed(recordings: RecordingStore, surveys: SurveyStore) {
        guard isActive else { return }
        try? surveys.delete(surveyID)
        try? recordings.delete(recordingID)
        seedSurvey(into: surveys)
        seedRecording(into: recordings)
    }

    // MARK: Survey

    private static func seedSurvey(into store: SurveyStore) {
        var findings: [GroundFinding] = []
        for (index, spec) in caseSpecs.enumerated() {
            let coordinate = offset(anchor, east: spec.east, north: spec.north)
            let media = photo(for: spec, index: index, in: store)
            findings.append(GroundFinding(
                id: fixtureID(group: 1, index: index),
                capturedAt: day.addingTimeInterval(Double(index) * 240),
                hostTime: Double(index) * 240,
                location: location(coordinate, accuracy: spec.accuracy),
                positionSource: spec.source,
                // A pin keeps what GPS said, so the detail screen can show both the fix
                // and the offset — the whole point of the screen.
                measuredLocation: spec.source == .manual
                    ? location(offset(coordinate, east: 6.5, north: -3.0), accuracy: 12)
                    : nil,
                positionSampleCount: spec.source == .averaged ? 47 : nil,
                positionSpread: spec.source == .averaged ? 1.8 : nil,
                severity: spec.severity,
                label: spec.label,
                note: spec.note,
                media: media,
                // A circle carries its centre in `points`; built here rather than in the
                // spec because the centre is the case's own coordinate.
                area: spec.radius.map { FindingArea.circle(center: coordinate, radius: $0) }))
        }

        let survey = Survey(id: surveyID,
                            name: "Murtenstrasse",
                            startedAt: day,
                            notes: String(localized: "Zustandserfassung Abschnitt West"),
                            findings: findings)
        try? store.save(survey)
    }

    private struct CaseSpec {
        let east: Double, north: Double
        let severity: Int
        let label: String
        let note: String
        let accuracy: Double
        let source: PositionSource
        let radius: Double?
    }

    // Four cases spanning the three position sources, so one screenshot of the map shows
    // a 4.5 m circle, an 8 m circle and a hand-set pin next to each other — which is the
    // argument the app makes, made visible.
    //
    // Labels and notes go through `String(localized:)` even though a real case's label is
    // free text a user typed: the English store listing needs screenshots with English
    // labels in them, and the simulator's launch language is what decides. Resolved lazily
    // on first access, which is after `AppleLanguages` has taken effect.
    private static let caseSpecs: [CaseSpec] = [
        CaseSpec(east: 0, north: 0, severity: 8,
                 label: String(localized: "Schlagloch"),
                 note: String(localized: "Rechte Fahrspur, Tiefe rund 6 cm."),
                 accuracy: 4.5, source: .averaged, radius: 3),
        CaseSpec(east: 62, north: 14, severity: 5,
                 label: String(localized: "Längsriss"),
                 note: String(localized: "Über etwa 12 m, noch ohne Ausbruch."),
                 accuracy: 8, source: .gps, radius: nil),
        CaseSpec(east: 128, north: -9, severity: 9,
                 label: String(localized: "Belagsausbruch"),
                 note: String(localized: "Vor der Einmündung, Kante scharf."),
                 accuracy: 0, source: .manual, radius: 5),
        CaseSpec(east: 205, north: 31, severity: 3,
                 label: String(localized: "Setzung"),
                 note: String(localized: "Um den Schacht, flach."),
                 accuracy: 6.5, source: .gps, radius: nil),
    ]

    private static func photo(for spec: CaseSpec, index: Int, in store: SurveyStore) -> [CaseMedia] {
        guard let data = placeholderPhoto(spec.label) else { return [] }
        guard let media = try? store.writePhoto(
            data,
            id: fixtureID(group: 2, index: index),
            capturedAt: day.addingTimeInterval(Double(index) * 240),
            in: surveyID)
        else { return [] }
        return [media]
    }

    /// A drawn stand-in rather than a bundled asset: a photo of a real pothole would be
    /// several megabytes in every download, and this only ever exists in the simulator.
    private static func placeholderPhoto(_ label: String) -> Data? {
        let size = CGSize(width: 1200, height: 900)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(white: 0.28, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.17, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 380, y: 300, width: 440, height: 300))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 54, weight: .semibold),
                .foregroundColor: UIColor(white: 0.85, alpha: 1),
            ]
            let text = label as NSString
            let bounds = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: 700),
                      withAttributes: attributes)
        }
        return image.jpegData(compressionQuality: 0.8)
    }

    // MARK: Recording

    /// Ninety seconds of plausible curves, so the playback screen has something with shape
    /// in it rather than a flat line. Same generator idea as `SyntheticSource`, but written
    /// straight to disk — the fixture has to exist before any view appears.
    private static func seedRecording(into store: RecordingStore) {
        guard let directory = try? store.prepareDirectory(for: recordingID) else { return }

        let rate = 100.0
        let duration = 90.0
        let count = Int(rate * duration)
        var streams: [StreamInfo] = []

        for sensor in [SensorID.userAcceleration, .rotationRate, .orientation, .location] {
            let descriptor = SensorCatalog.descriptor(for: sensor)
            guard let writer = try? StreamWriter(sensor: sensor,
                                                 channelCount: descriptor.channelCount,
                                                 directory: directory) else { continue }
            let step = sensor == .location ? Int(rate) : 1     // GPS runs at 1 Hz
            for index in stride(from: 0, to: count, by: step) {
                let t = Double(index) / rate
                writer.append(time: t, values: samples(sensor, t: t,
                                                       channels: descriptor.channelCount))
            }
            writer.flush()
            streams.append(writer.close())
        }

        let metadata = RecordingMetadata(
            id: recordingID,
            name: "Murtenstrasse West",
            startedAt: day,
            startHostTime: 0,
            duration: duration,
            device: fixtureDevice,
            streams: streams,
            requestedRateHz: rate)
        try? store.save(metadata)
    }

    /// Deterministic on purpose — no randomness anywhere, or the charts differ between the
    /// iPhone and the iPad shot of the same screen.
    private static func samples(_ sensor: SensorID, t: Double, channels: Int) -> [Double] {
        switch sensor {
        case .userAcceleration:
            return [0.18 * sin(2.1 * t) + 0.05 * sin(11 * t),
                    0.12 * cos(1.7 * t) + 0.04 * sin(9 * t),
                    0.30 * sin(0.9 * t) + 0.09 * sin(14 * t)]
        case .rotationRate:
            return [0.25 * sin(1.3 * t), 0.18 * cos(0.8 * t), 0.40 * sin(0.4 * t)]
        case .orientation:
            var values = [3.0 * sin(0.5 * t), 2.0 * cos(0.3 * t), 40 * sin(0.12 * t)]
            while values.count < channels { values.append(0) }
            return Array(values.prefix(channels))
        case .location:
            let point = offset(anchor, east: t * 2.4, north: t * 0.4)
            var values = [point.latitude, point.longitude, 542.0, 4.5,
                          2.4, 78.0, 3.0, 6.0, 0.0, 0.0]
            while values.count < channels { values.append(0) }
            return Array(values.prefix(channels))
        default:
            return Array(repeating: 0, count: channels)
        }
    }

    // MARK: - Geometry helpers

    private static func location(_ coordinate: Coordinate2D, accuracy: Double) -> FindingLocation {
        FindingLocation(latitude: coordinate.latitude, longitude: coordinate.longitude,
                        altitude: 542, ellipsoidalAltitude: 591,
                        horizontalAccuracy: accuracy, verticalAccuracy: 8, heading: 96)
    }

    /// Metres east and north of an anchor, via the same local frame the app measures areas
    /// in — degrees would be off by a third of the distance at this latitude.
    ///
    /// `Coordinate2D.geodetic` is internal to the core, so the anchor is built here.
    private static func offset(_ base: Coordinate2D, east: Double, north: Double) -> Coordinate2D {
        let anchor = Geodetic(latitude: base.latitude, longitude: base.longitude, height: 0)
        let moved = Geodesy.geodetic(fromENU: ENU(east: east, north: north, up: 0),
                                     anchor: anchor)
        return Coordinate2D(latitude: moved.latitude, longitude: moved.longitude)
    }
}
