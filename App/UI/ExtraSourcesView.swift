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

            EventRecordingSection()

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

/// The event recorder's three numbers.
struct EventRecordingSection: View {
    @Environment(SensorHub.self) private var hub

    private var isOn: Binding<Bool> {
        Binding(get: { hub.settings.eventThresholdG != nil },
                set: { hub.settings.eventThresholdG = $0 ? 2.5 : nil })
    }

    var body: some View {
        Section {
            Toggle(isOn: isOn) {
                Label("Ereignisaufnahme", systemImage: "waveform.badge.exclamationmark")
            }
            if let threshold = hub.settings.eventThresholdG {
                Stepper(value: Binding(get: { threshold }, set: { hub.settings.eventThresholdG = $0 }),
                        in: 0.5...8, step: 0.5) {
                    LabeledContent("Schwelle") { Text(verbatim: String(format: "%.1f g", threshold)).monospacedDigit() }
                }
                Stepper(value: Binding(get: { hub.settings.eventPreRoll ?? 30 },
                                       set: { hub.settings.eventPreRoll = $0 }), in: 5...120, step: 5) {
                    LabeledContent("Vorlauf") {
                        Text(verbatim: "\(Int(hub.settings.eventPreRoll ?? 30)) s").monospacedDigit()
                    }
                }
                Stepper(value: Binding(get: { hub.settings.eventPostRoll ?? 30 },
                                       set: { hub.settings.eventPostRoll = $0 }), in: 5...300, step: 5) {
                    LabeledContent("Nachlauf") {
                        Text(verbatim: "\(Int(hub.settings.eventPostRoll ?? 30)) s").monospacedDigit()
                    }
                }
                LabeledContent("Gespeicherte Ereignisse") {
                    Text(verbatim: "\(hub.eventsSaved)").monospacedDigit()
                }
                if hub.isCapturingEvent {
                    Label("Ereignis wird gespeichert …", systemImage: "record.circle")
                        .foregroundStyle(Theme.recording)
                }
            }
        } footer: {
            Text("Das Telefon hört mit, auch wenn niemand aufnimmt, und speichert nur dann eine Aufnahme, wenn ein Stoss die Schwelle überschreitet, mit den Sekunden davor und danach, ohne Video und Ton. Für ein Telefon im Fahrzeug, an einer Maschine, in einem Paket. Läuft nur, solange die App offen ist, der Aufnahme-Bildschirm läuft und keine Aufnahme aktiv ist.")
        }
    }
}
