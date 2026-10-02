import Foundation

/// The unit of a field a Bluetooth decoder named, so a stream made from it has a unit on
/// its axis and in its exports instead of an empty column.
///
/// The names are the decoders' own (`BLEDecoders`), and the units follow what those decoders
/// compute — Ruuvi's pressure is hectopascal because the decoder divides by 100, not because
/// that is what the datasheet says. A field this does not know has no unit, which is the
/// honest answer for the decoder files users write themselves.
public enum BLEUnits {
    public static func unit(for field: String, decoder: String = "") -> String {
        // BTHome repeats names with a counter: `temperature2`, `voltage3`.
        let base = field.reversed().drop(while: \.isNumber).reversed().map(String.init).joined()
        switch base {
        case "temperature", "dewPoint": return "°C"
        case "humidity", "moisture", "battery", "pedalBalance": return "%"
        case "pressure": return "hPa"
        case "accelerationX", "accelerationY", "accelerationZ": return "g"
        case "batteryVoltage", "voltage": return "V"
        case "illuminance": return "lx"
        case "mass": return "kg"
        case "massLb": return "lb"
        case "energy": return "kWh"
        case "power": return "W"
        case "current": return "A"
        case "pm25", "pm10", "tvoc": return "µg/m³"
        case "co2": return "ppm"
        case "rotation": return "°"
        case "distanceMm": return "mm"
        case "distance", "strideLength", "totalDistance": return "m"
        case "duration": return "s"
        case "speed": return "m/s"
        case "volume", "water": return "L"
        case "volumeMl": return "mL"
        case "volumeFlowRate": return "m³/h"
        case "gas": return "m³"
        case "acceleration": return "m/s²"
        case "gyroscope": return "°/s"
        case "heartRate": return "bpm"
        case "rrInterval", "rr": return "s"
        case "cadence": return decoder.localizedCaseInsensitiveContains("running") ? "spm" : "rpm"
        case "rssi": return "dBm"
        default: return ""
        }
    }
}
