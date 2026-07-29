import Foundation
import SensorstormCore

/// Deliberately small. Sensor Logger drowns you in toggles; here there are three knobs
/// that actually change the result — which sensors, how fast, and what the camera does.
struct RecordingSettings: Codable, Sendable, Equatable {
    var enabledSensors: Set<SensorID>
    var motionRateHz: Double
    var videoMode: VideoMode
    var videoQuality: VideoQuality
    var recordsAudio: Bool
    var keepsScreenAwake: Bool
    /// Which camera stack records the video. Optional so a settings blob written by an
    /// earlier build still decodes; ``captureEngine`` resolves the default.
    var preferredCaptureEngine: CaptureEngine?

    /// Streams hidden from the live tiles and the playback charts.
    ///
    /// Deliberately independent of ``enabledSensors``: a measurement not taken cannot be
    /// taken again afterwards, whereas a view can always be changed back. Tidying the screen
    /// must therefore never cost data.
    ///
    /// Stores what is *hidden* rather than what is shown, so a sensor added in a later
    /// version appears by default instead of silently staying invisible.
    var hiddenSensors: Set<SensorID>?
    var collapsedCategories: Set<SensorCategory>?

    static let availableRates: [Double] = [10, 25, 50, 100, 200, 400]

    static let `default` = RecordingSettings(
        enabledSensors: Set(SensorCatalog.all.filter(\.defaultEnabled).map(\.id)),
        motionRateHz: 100,
        videoMode: .off,
        videoQuality: .hd1080,
        recordsAudio: true,
        keepsScreenAwake: true,
        preferredCaptureEngine: .classic
    )

    var captureEngine: CaptureEngine {
        get { preferredCaptureEngine ?? .classic }
        set { preferredCaptureEngine = newValue }
    }

    /// ARKit owns the camera outright, so the front camera and the classic quality presets
    /// do not apply — and it only makes sense with a camera running at all.
    var usesARKit: Bool { captureEngine == .arkit && isVideoEnabled }

    // MARK: - Display

    func isVisible(_ sensor: SensorID) -> Bool {
        !(hiddenSensors ?? []).contains(sensor)
    }

    mutating func setVisible(_ visible: Bool, for sensor: SensorID) {
        var hidden = hiddenSensors ?? []
        if visible { hidden.remove(sensor) } else { hidden.insert(sensor) }
        hiddenSensors = hidden.isEmpty ? nil : hidden
    }

    func isCollapsed(_ category: SensorCategory) -> Bool {
        (collapsedCategories ?? []).contains(category)
    }

    mutating func setCollapsed(_ collapsed: Bool, for category: SensorCategory) {
        var categories = collapsedCategories ?? []
        if collapsed { categories.insert(category) } else { categories.remove(category) }
        collapsedCategories = categories.isEmpty ? nil : categories
    }

    /// Only counts streams that are actually being recorded — a hidden sensor that is also
    /// switched off is not something the user is missing from the screen.
    func hiddenCount(among available: Set<SensorID>) -> Int {
        (hiddenSensors ?? []).count { enabledSensors.contains($0) && available.contains($0) }
    }

    mutating func showAllSensors() {
        hiddenSensors = nil
        collapsedCategories = nil
    }

    /// Whether the difference to `other` changes what the hardware does, rather than only
    /// what the screen draws.
    ///
    /// Without this, hiding a tile would tear down and restart every sensor source — resetting
    /// all live values and interrupting a 400 Hz stream to change a view.
    func affectsCapture(comparedTo other: RecordingSettings) -> Bool {
        var mine = self
        var theirs = other
        mine.hiddenSensors = nil
        mine.collapsedCategories = nil
        theirs.hiddenSensors = nil
        theirs.collapsedCategories = nil
        return mine != theirs
    }

    func isEnabled(_ sensor: SensorID) -> Bool {
        enabledSensors.contains(sensor)
    }

    mutating func setEnabled(_ enabled: Bool, for sensor: SensorID) {
        if enabled { enabledSensors.insert(sensor) } else { enabledSensors.remove(sensor) }
    }

    var isVideoEnabled: Bool { videoMode != .off }
}

enum VideoMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case off
    case back
    case front

    var id: String { rawValue }
    var isFront: Bool { self == .front }
}

enum VideoQuality: String, Codable, Sendable, CaseIterable, Identifiable {
    case hd720
    case hd1080
    case uhd4k

    var id: String { rawValue }

    var pixelSize: (width: Int, height: Int) {
        switch self {
        case .hd720: (1280, 720)
        case .hd1080: (1920, 1080)
        case .uhd4k: (3840, 2160)
        }
    }
}

/// Settings live in `UserDefaults` as one JSON blob — a single decode on launch, a single
/// encode on change, and adding a field later can't leave stale keys behind.
@MainActor
final class SettingsStore {
    private static let key = "recordingSettings"

    static func load() -> RecordingSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(RecordingSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    static func save(_ settings: RecordingSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
