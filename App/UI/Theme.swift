import SensorstormCore
import SwiftUI

enum Theme {
    static let accent = Color(red: 0.29, green: 0.78, blue: 0.94)
    static let recording = Color(red: 0.98, green: 0.28, blue: 0.32)
    static let cardBackground = Color(white: 0.11)
    static let cardBorder = Color(white: 0.22)

    /// Axis colours follow the convention every IMU tool uses — x red, y green, z blue —
    /// so a curve is readable without hunting for the legend. Later channels continue in
    /// hues that stay distinguishable next to those three.
    static let channelColors: [Color] = [
        Color(red: 0.95, green: 0.36, blue: 0.36),
        Color(red: 0.40, green: 0.85, blue: 0.51),
        Color(red: 0.39, green: 0.60, blue: 0.98),
        Color(red: 0.96, green: 0.74, blue: 0.32),
        Color(red: 0.76, green: 0.52, blue: 0.95),
        Color(red: 0.36, green: 0.87, blue: 0.85),
        Color(red: 0.93, green: 0.51, blue: 0.71),
        Color(red: 0.62, green: 0.72, blue: 0.40),
        Color(red: 0.85, green: 0.61, blue: 0.45),
        Color(red: 0.55, green: 0.65, blue: 0.78)
    ]

    static func color(forChannel index: Int) -> Color {
        channelColors[index % channelColors.count]
    }
}

extension SensorCategory {
    var title: LocalizedStringKey {
        switch self {
        case .motion: "Bewegung"
        case .position: "Position"
        case .environment: "Umgebung"
        case .audio: "Audio"
        case .activity: "Aktivität"
        case .device: "Gerät"
        case .camera: "Kamera"
        }
    }

    var symbol: String {
        switch self {
        case .motion: "gyroscope"
        case .position: "location.fill"
        case .environment: "barometer"
        case .audio: "waveform"
        case .activity: "figure.walk"
        case .device: "iphone.gen3"
        case .camera: "camera.metering.matrix"
        }
    }
}

extension SensorID {
    var title: LocalizedStringKey {
        switch self {
        case .accelerometer: "Beschleunigung (roh)"
        case .gyroscope: "Drehrate (roh)"
        case .magnetometer: "Magnetfeld (roh)"
        case .userAcceleration: "Beschleunigung"
        case .gravity: "Gravitation"
        case .rotationRate: "Drehrate"
        case .orientation: "Orientierung"
        case .magneticField: "Magnetfeld"
        case .compass: "Kompass"
        case .barometer: "Barometer"
        case .location: "GPS"
        case .loudness: "Lautstärke"
        case .pedometer: "Schrittzähler"
        case .battery: "Batterie"
        case .brightness: "Helligkeit"
        case .network: "Netzwerk"
        case .headphoneOrientation: "AirPods-Orientierung"
        case .cameraPose: "Kamerapose"
        }
    }

    var symbol: String {
        switch self {
        case .accelerometer, .userAcceleration: "arrow.up.and.down.and.arrow.left.and.right"
        case .gyroscope, .rotationRate: "gyroscope"
        case .magnetometer, .magneticField: "dot.radiowaves.left.and.right"
        case .gravity: "arrow.down.to.line"
        case .orientation: "rotate.3d"
        case .compass: "safari"
        case .barometer: "barometer"
        case .location: "location.fill"
        case .loudness: "waveform"
        case .pedometer: "figure.walk"
        case .battery: "battery.75percent"
        case .brightness: "sun.max.fill"
        case .network: "antenna.radiowaves.left.and.right"
        case .headphoneOrientation: "airpods.pro"
        case .cameraPose: "camera.metering.matrix"
        }
    }

    /// Which channels the compact live tile shows. Streams like GPS have ten columns; a
    /// tile that lists all of them is unreadable.
    var highlightChannels: [Int] {
        switch self {
        case .location: [0, 1, 4]        // lat, lon, speed
        case .pedometer: [0, 1]          // steps, distance
        case .compass: [0]               // true heading
        case .magneticField: [0, 1, 2]   // drop the accuracy column
        case .orientation: [0, 1, 2]     // roll, pitch, yaw
        case .network: [0]
        case .battery: [0]
        case .cameraPose: [0, 1, 2]      // position; intrinsics belong in the detail view
        default: Array(0..<descriptor.channelCount)
        }
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.cardBackground, in: .rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
            }
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}
