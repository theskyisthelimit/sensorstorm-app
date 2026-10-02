import SensorstormCore
import SwiftUI

/// Numbers and names the network screens share.
enum NetFormat {
    /// „12.3 ms". A reading below a tenth of a millisecond is not a measurement on a phone.
    static func milliseconds(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "—" }
        let value = seconds * 1_000
        return value < 10 ? String(format: "%.2f ms", value) : String(format: "%.1f ms", value)
    }

    static func megabits(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return value < 100 ? String(format: "%.1f Mbit/s", value) : String(format: "%.0f Mbit/s", value)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f %%", value)
    }

    static func ports(_ ports: [Int]) -> String {
        ports.map(String.init).joined(separator: ", ")
    }
}

extension DeviceGuess {
    var title: LocalizedStringKey {
        switch self {
        case .router: "Router"
        case .printer: "Drucker"
        case .nas: "Netzwerkspeicher"
        case .camera: "Kamera"
        case .mediaPlayer: "Mediengerät"
        case .smartHome: "Smart Home"
        case .apple: "Apple-Gerät"
        case .computer: "Computer"
        case .server: "Server"
        case .unknown: "Unbekannt"
        }
    }

    var symbol: String {
        switch self {
        case .router: "wifi.router"
        case .printer: "printer"
        case .nas: "externaldrive.connected.to.line.below"
        case .camera: "web.camera"
        case .mediaPlayer: "tv"
        case .smartHome: "homekit"
        case .apple: "apple.logo"
        case .computer: "desktopcomputer"
        case .server: "server.rack"
        case .unknown: "questionmark.circle"
        }
    }
}

extension NetworkInterface.Kind {
    var title: LocalizedStringKey {
        switch self {
        case .wifi: "WLAN"
        case .cellular: "Mobilfunk"
        case .wired: "Kabel oder Adapter"
        case .vpn: "VPN"
        case .hotspot: "Persönlicher Hotspot"
        case .peerToPeer: "Direktverbindung"
        case .loopback: "Loopback"
        case .other: "Sonstige"
        }
    }

    var symbol: String {
        switch self {
        case .wifi: "wifi"
        case .cellular: "antenna.radiowaves.left.and.right"
        case .wired: "cable.connector"
        case .vpn: "lock.shield"
        case .hotspot: "personalhotspot"
        case .peerToPeer: "dot.radiowaves.left.and.right"
        case .loopback: "arrow.triangle.2.circlepath"
        case .other: "network"
        }
    }
}

/// The notice shown wherever the Local Network permission is the reason nothing answers.
struct LocalNetworkNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Zugriff auf das lokale Netz fehlt", systemImage: "exclamationmark.triangle")
                .font(.callout.weight(.semibold))
            Text("Ohne diese Freigabe antwortet im eigenen Netz nichts. In den Einstellungen unter „Datenschutz & Sicherheit“ → „Lokales Netzwerk“ einschalten.")
                .font(.callout)
            Button("Einstellungen öffnen") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
    }
}

/// „ja" or „nein". An `if`, not a ternary: `Text(flag ? "ja" : "nein")` picks between two
/// plain strings and never reaches the String Catalog.
struct YesNo: View {
    let value: Bool

    var body: some View {
        if value {
            Text("ja")
        } else {
            Text("nein")
        }
    }
}
