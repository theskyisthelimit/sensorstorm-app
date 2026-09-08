import SensorstormCore
import SwiftUI

// What each lock says when it is tapped. Kept next to the UI rather than in the core for
// the same reason `SensorID.title` is: the core has no bundle to look strings up in, and
// the wording is presentation.

extension ProFeature {
    /// The headline on the paywall — names the thing the user just reached for.
    var title: LocalizedStringKey {
        switch self {
        case .highRate: "400 Hz Abtastrate"
        case .video4K: "Video in 4K"
        case .arkitPose: "Kamerapose für 3D"
        case .rawExport: "Rohdaten-Export"
        case .sceneExport: "Kamerafahrt für Blender"
        case .photoExport: "Bilder für Fotogrammetrie"
        case .interopExport: "Sensor Logger und Gyroflow"
        case .tableExport: "Eine Tabelle, JSON, SQLite"
        case .liveStreaming: "Live an einen Server senden"
        case .additionalSurveys: "Mehrere Routen"
        case .surveyGeoExport: "GeoJSON, GPX und KML"
        case .archiveExport: "Gesamtexport"
        }
    }

    /// One sentence on what it is good for. The paywall is where someone decides, so it
    /// says what the feature buys, not what it is called.
    var explanation: LocalizedStringKey {
        switch self {
        case .highRate:
            "Die Bewegungssensoren laufen mit 400 Hz statt 200 Hz. In dieser Auflösung sind Vibrationen und Stösse noch als Form erkennbar."
        case .video4K:
            "Video in 3840 × 2160, auf derselben Uhr wie jeder Messwert."
        case .arkitPose:
            "Zeichnet zu jedem Bild Position, Blickrichtung und Brennweite auf. Erst damit lassen sich Bilder in einer 3D-Szene an ihrem Ort platzieren."
        case .rawExport:
            "Die Aufnahme als .ssbin, verlustfrei und in voller Auflösung, statt gerundet in CSV."
        case .sceneExport:
            "Das Bündel enthält frames.csv, scene.json, das Video und den GPS-Track. Das Blender-Add-on macht daraus eine animierte Kamera, die der echten Aufnahme folgt."
        case .photoExport:
            "Der Export wählt scharfe, räumlich verteilte Einzelbilder und schreibt Brennweite, Position und Blickrichtung ins EXIF. Dazu kommen eine Kameratabelle und ein COLMAP-Modell. RealityScan, Metashape und Meshroom lesen das und rechnen daraus das Modell."
        case .interopExport:
            "Das Dateilayout von Sensor Logger, damit dessen Notebooks die Aufnahme unverändert lesen, und ein .gcsv-Log für die Stabilisierung in Gyroflow."
        case .tableExport:
            "Alle Sensoren stehen nebeneinander in einer Tabelle, auf einem gemeinsamen Zeitraster. Dazu kommt die ganze Aufnahme als JSON oder als SQLite-Datenbank mit einer Tabelle pro Sensor."
        case .liveStreaming:
            "Während der Aufnahme geht jede Messung als JSON an eine URL deiner Wahl, etwa an ein eigenes Dashboard, an Node-RED oder an Home Assistant. Das Format entspricht dem von Sensor Logger, ein bestehender Endpunkt funktioniert also unverändert."
        case .additionalSurveys:
            "Beliebig viele Routen nebeneinander: pro Strasse, pro Auftrag, pro Tag."
        case .surveyGeoExport:
            "Die Route als GeoJSON für QGIS, als KML für Google Earth, als GPX zum Wiederfinden, oder als Bündel mit jedem Foto und Clip."
        case .archiveExport:
            "Alles auf dem Gerät als ein Zip mit manifest.json: jede Datei mit SHA-256, jede Beobachtung mit Position und Bewertung."
        }
    }
}

/// A control that is either the real action or an invitation to buy.
///
/// Locked, it keeps its place and its wording and only swaps its symbol for a padlock. A
/// disabled row is a dead end; a padlock is a door, and it is the one place where someone
/// finds out the feature exists at all.
struct ProButton: View {
    @Environment(ProEntitlement.self) private var pro

    let feature: ProFeature
    let title: LocalizedStringKey
    let symbol: String
    let action: () -> Void

    init(_ feature: ProFeature,
         _ title: LocalizedStringKey,
         _ symbol: String,
         action: @escaping () -> Void) {
        self.feature = feature
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        let unlocked = pro.access.allows(feature)
        Button {
            if unlocked { action() } else { pro.requestUnlock(feature) }
        } label: {
            // A menu row renders text plus one symbol and nothing else, so the padlock has
            // to *be* the symbol rather than sit beside it.
            Label(title, systemImage: unlocked ? symbol : "lock.fill")
        }
    }
}

extension ProEntitlement {
    /// A binding that lets free values through and turns a gated one into the paywall.
    ///
    /// The gated option stays in the picker on purpose. Hiding 400 Hz would hide the reason
    /// to buy, and a user who never sees the option cannot want it.
    func gated<Value>(_ base: Binding<Value>,
                      feature: @escaping (Value) -> ProFeature?) -> Binding<Value> {
        Binding(
            get: { base.wrappedValue },
            set: { newValue in
                if let feature = feature(newValue), !self.access.allows(feature) {
                    self.requestUnlock(feature)
                } else {
                    base.wrappedValue = newValue
                }
            }
        )
    }
}

/// The padlock that marks a gated option inside a picker row.
struct ProTag: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Erfordert Pro"))
    }
}
