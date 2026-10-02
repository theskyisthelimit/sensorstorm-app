import SensorstormCore
import SwiftUI

extension WorkProfile {
    var title: LocalizedStringKey {
        switch self {
        case .general: "Allgemein"
        case .roads: "Strassen und Wege"
        case .building: "Gebäude und Fassaden"
        case .elevator: "Aufzug"
        case .transit: "Bahn, Tram und Bus"
        case .construction: "Baustelle und Erschütterung"
        case .network: "Netz und Funk"
        case .sound: "Schall"
        case .research: "Forschung und Datensätze"
        }
    }

    var summary: LocalizedStringKey {
        switch self {
        case .general: "Die Voreinstellung: Bewegung, Position, Höhe und Umgebung."
        case .roads: "Beschleunigung und Position für den Zustand einer Strasse, dazu der Katalog für Schäden."
        case .building: "Position, Kompass und Höhe für Begehungen von Gebäuden, mit dem Katalog für Mängel."
        case .elevator: "Vertikalbeschleunigung und Höhe für Fahrten im Aufzug."
        case .transit: "Beschleunigung, Drehung und Position für den Fahrkomfort."
        case .construction: "Beschleunigung mit 200 Hz und Schallpegel, für Erschütterungen und Lärm."
        case .network: "Netzqualität und Bluetooth entlang eines Wegs, für die Abdeckung im Gebäude."
        case .sound: "Schallpegel in dB(A), mit Position."
        case .research: "Alle Bewegungssensoren, beschriftbar mit Notizen, für Datensätze."
        }
    }

    var symbol: String {
        switch self {
        case .general: "square.grid.2x2"
        case .roads: "road.lanes"
        case .building: "building.2"
        case .elevator: "arrow.up.arrow.down.square"
        case .transit: "tram"
        case .construction: "hammer"
        case .network: "wifi"
        case .sound: "ear"
        case .research: "brain"
        }
    }
}

/// „Wofür nutzt du Sensorstorm?" — one choice that sets the sensors, the rate and the catalog.
struct ProfilePickerView: View {
    @Environment(SensorHub.self) private var hub
    @Environment(SurveyModel.self) private var surveys
    @Environment(\.dismiss) private var dismiss
    @AppStorage("workProfileChosen") private var chosen = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(WorkProfile.allCases) { profile in
                        Button {
                            hub.settings.apply(profile)
                            chosen = true
                            dismiss()
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: profile.symbol)
                                    .frame(minWidth: 30)
                                    .font(.title3)
                                    .foregroundStyle(Theme.accent)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(profile.title).font(.headline)
                                        if hub.settings.workProfile == profile {
                                            Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                        }
                                    }
                                    Text(profile.summary).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Ein Profil stellt Sensoren, Rate und Katalog ein. Alles lässt sich danach einzeln ändern, und das Profil wechseln geht jederzeit unter Einstellungen.")
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Wofür nutzt du Sensorstorm?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Später") {
                        chosen = true
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled(false)
    }
}
