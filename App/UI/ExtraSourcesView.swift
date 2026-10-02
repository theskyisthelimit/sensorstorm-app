import SensorstormCore
import SwiftUI

/// The sources that cost a permission or a battery percentage, each its own switch.
struct ExtraSourcesView: View {
    @Environment(SensorHub.self) private var hub

    private var beaconText: Binding<String> {
        Binding(
            get: { (hub.settings.beaconUUIDs ?? []).joined(separator: "\n") },
            set: { text in
                let lines = text.split(whereSeparator: \.isNewline).map(String.init)
                hub.settings.beaconUUIDs = lines.isEmpty ? nil : lines
            })
    }

    var body: some View {
        Form {
            Section {
                ForEach(ExtraSource.allCases) { source in
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: Binding(get: { hub.settings.isOn(source) },
                                             set: { hub.settings.setOn($0, for: source) })) {
                            Label(source.title, systemImage: source.symbol)
                        }
                        Text(source.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Alles hier läuft nur während einer Aufnahme und schreibt eigene Ströme: sie stehen in der Wiedergabe und in jedem Export neben den übrigen Sensoren. Frequenzbänder und Geräuschklassen brauchen das Mikrofon und laufen nicht zusammen mit einer Videoaufnahme ohne ARKit.")
            }

            if hub.settings.isOn(.beacons) {
                Section {
                    TextEditor(text: beaconText)
                        .font(.callout.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .frame(minHeight: 90)
                } header: {
                    Text("iBeacon-Kennungen")
                } footer: {
                    Text("Eine UUID pro Zeile. iOS misst nur Beacons, deren UUID es kennt, und nur im Vordergrund.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Weitere Quellen")
        .navigationBarTitleDisplayMode(.inline)
    }
}
