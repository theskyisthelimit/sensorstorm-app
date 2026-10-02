import Foundation

/// Sources that cost something — a permission, a packet, a battery percentage — and that most
/// recordings do not want. Each is its own switch; none runs unless it was switched on, and
/// none is asked for before then.
///
/// They write external streams (see ``ExternalStreamInfo``), so they appear in the recording,
/// in the playback and in every export without any of those knowing they exist.
enum ExtraSource: String, CaseIterable, Identifiable, Sendable {
    case absoluteAltitude
    case systemState
    case beacons
    case homeKit
    case spectrum
    case soundClasses
    case cameraLight
    case depth
    case uwb
    case watchFast

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .absoluteAltitude: "arrow.up.to.line.compact"
        case .systemState: "internaldrive"
        case .beacons: "antenna.radiowaves.left.and.right.circle"
        case .homeKit: "homekit"
        case .spectrum: "waveform.path"
        case .soundClasses: "ear.and.waveform"
        case .cameraLight: "sun.max"
        case .depth: "ruler"
        case .uwb: "wave.3.right.circle"
        case .watchFast: "applewatch.radiowaves.left.and.right"
        }
    }

    var title: String {
        switch self {
        case .absoluteAltitude: String(localized: "Absolute Höhe")
        case .systemState: String(localized: "Speicher und Audio-Route")
        case .beacons: String(localized: "iBeacons")
        case .homeKit: String(localized: "HomeKit-Sensoren")
        case .spectrum: String(localized: "Frequenzbänder")
        case .soundClasses: String(localized: "Geräuschklassen")
        case .cameraLight: String(localized: "Helligkeit über die Kamera")
        case .depth: String(localized: "LiDAR-Abstand")
        case .uwb: String(localized: "UWB-Abstand zum zweiten iPhone")
        case .watchFast: String(localized: "Uhr mit hoher Rate")
        }
    }

    var detail: String {
        switch self {
        case .absoluteAltitude:
            String(localized: "Höhe über Meer aus GPS und Barometer zusammen, genauer als jede der beiden allein. Für Stockwerke und Gefälle.")
        case .systemState:
            String(localized: "Freier Speicher und Lautstärke der Audio-Route. Erklärt Aussetzer, wenn der Speicher voll läuft oder ein Mikrofon abgezogen wird.")
        case .beacons:
            String(localized: "Misst Signal und Entfernung zu iBeacons mit den eingetragenen Kennungen. Nur im Vordergrund.")
        case .homeKit:
            String(localized: "Liest Temperatur, Feuchte, CO₂, Licht, Kontakt und Bewegung aus dem eigenen Zuhause, solange die Aufnahme läuft.")
        case .spectrum:
            String(localized: "Schreibt zum Schallpegel zehn Oktavbänder und die vorherrschende Frequenz mit. Zeigt, ob ein Brummen tief oder ein Quietschen hoch ist.")
        case .soundClasses:
            String(localized: "Erkennt Geräusche wie Sirene, Motor, Bohrer oder Hund mit Apples eingebautem Klassifikator und setzt sie als Notiz in die Aufnahme. Läuft auf dem Gerät.")
        case .cameraLight:
            String(localized: "Schätzt die Helligkeit der Umgebung aus dem Kamerabild, in Lumen. Eine Schätzung, kein Luxmeter. Braucht die Aufnahme mit ARKit.")
        case .depth:
            String(localized: "Misst mit dem LiDAR den Abstand zur Bildmitte, bis etwa fünf Meter. Braucht ein Gerät mit LiDAR und die Aufnahme mit ARKit.")
        case .watchFast:
            String(localized: "Die Uhr misst die Beschleunigung des Handgelenks mit 800 Hz statt mit 50 Hz und schickt sie als Strom mit. Braucht eine Apple Watch ab Series 8 oder Ultra und eine Uhr-Aufnahme.")
        case .uwb:
            String(localized: "Misst mit Ultrabreitband Abstand und Richtung zu einem zweiten iPhone, auf Zentimeter genau. Beide Telefone brauchen Ultrabreitband und die Verbindung unter „Bluetooth-Dienst und zweites iPhone“.")
        }
    }
}
