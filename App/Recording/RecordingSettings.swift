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

    static let availableRates: [Double] = [10, 25, 50, 100, 200, 400]

    static let `default` = RecordingSettings(
        enabledSensors: Set(SensorCatalog.all.filter(\.defaultEnabled).map(\.id)),
        motionRateHz: 100,
        videoMode: .off,
        videoQuality: .hd1080,
        recordsAudio: true,
        keepsScreenAwake: true
    )

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
