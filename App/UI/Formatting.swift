import Foundation
import SensorstormCore

enum Format {
    /// Sensor values span eleven orders of magnitude — 0.0004 g of noise and 8.54 degrees
    /// of longitude want different precision, and neither wants scientific notation on a
    /// dashboard. Decimals are picked from the magnitude.
    static func value(_ value: Double, unit: String = "") -> String {
        guard value.isFinite else { return "—" }

        let magnitude = abs(value)
        let decimals: Int
        switch magnitude {
        case 0: decimals = 2
        case ..<0.01: decimals = 5
        case ..<1: decimals = 4
        case ..<100: decimals = 3
        case ..<10_000: decimals = 2
        default: decimals = 1
        }

        let text = String(format: "%.\(decimals)f", value)
        return unit.isEmpty ? text : "\(text) \(unit)"
    }

    /// Coordinates need six decimals to be worth anything (≈10 cm).
    static func coordinate(_ value: Double) -> String {
        value.isFinite ? String(format: "%.6f", value) : "—"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// Recording clock: tenths matter when you are timing a drop test.
    static func timecode(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00,0" }
        let total = Int(seconds)
        let tenths = Int((seconds - Double(total)) * 10)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d,%d", hours, minutes, secs, tenths)
            : String(format: "%d:%02d,%d", minutes, secs, tenths)
    }

    static func rate(_ hertz: Double) -> String {
        guard hertz.isFinite, hertz > 0 else { return "—" }
        return hertz >= 10
            ? String(format: "%.0f Hz", hertz)
            : String(format: "%.1f Hz", hertz)
    }

    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: count)
    }

    static func sampleCount(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic))
    }

    /// Renders one channel of one sensor for the live tile, applying the per-sensor
    /// special cases (coordinates, enum-coded columns).
    static func channelValue(sensor: SensorID, channel: Int, value: Double) -> String {
        switch (sensor, channel) {
        case (.location, 0), (.location, 1):
            return coordinate(value)
        case (.network, 0):
            return NetworkKind(rawValue: Int(value))?.label ?? "—"
        case (.battery, 1):
            return BatteryStateLabel.label(for: Int(value))
        case (.pedometer, 0):
            return value.isFinite ? String(format: "%.0f", value) : "—"
        default:
            return Self.value(value, unit: sensor.descriptor.unit(forChannel: channel))
        }
    }
}

enum BatteryStateLabel {
    static func label(for raw: Int) -> String {
        switch raw {
        case 1: String(localized: "Entladen")
        case 2: String(localized: "Lädt")
        case 3: String(localized: "Voll")
        default: String(localized: "Unbekannt")
        }
    }
}
