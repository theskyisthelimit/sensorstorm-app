import SensorstormCore
import SwiftUI

/// The one place a sensor is armed or disarmed.
///
/// It appears twice — as sections of the settings screen, and as a sheet reached from the
/// sensor count on the record screen. Two copies would have drifted apart: the second one
/// would sooner or later have forgotten the engine-controlled streams, or the availability
/// check, or the guard below that keeps the armed set from being changed mid-recording.
///
/// Arming is not the same thing as showing. Hiding a tile
/// (``RecordingSettings/setVisible(_:for:)``) never touches the hardware — that separation
/// is enforced in ``RecordingSettings/affectsCapture(comparedTo:)`` and is worth keeping.
struct SensorArmingSections: View {
    @Environment(SensorHub.self) private var hub

    var body: some View {
        ForEach(SensorCategory.allCases, id: \.self) { category in
            section(category)
        }
    }

    @ViewBuilder
    private func section(_ category: SensorCategory) -> some View {
        @Bindable var hub = hub
        // Engine-controlled streams follow from the camera setting; showing them as toggles
        // would promise a choice that does not exist.
        let descriptors = SensorCatalog.descriptors(in: category)
            .filter { !SensorID.engineControlled.contains($0.id) }

        if !descriptors.isEmpty {
            Section(category.title) {
                ForEach(descriptors) { descriptor in
                    let available = hub.isAvailable(descriptor.id)
                    Toggle(isOn: Binding(
                        get: { hub.settings.isEnabled(descriptor.id) },
                        set: { hub.settings.setEnabled($0, for: descriptor.id) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(descriptor.id.title)
                            // One line. Spelled out, GPS alone lists ten channel names and
                            // pushed its row to three lines, which is most of why this
                            // screen felt like a wall. The full list lives in docs/UNITS.md.
                            Text(available
                                 ? descriptor.channels.joined(separator: ", ")
                                 : String(localized: "nicht verfügbar"))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    // The streams to write are frozen in `SensorHub.streamsToWrite(for:)`
                    // when the recording starts. A toggle that silently did nothing for the
                    // next twenty minutes would be worse than no toggle at all.
                    .disabled(!available || hub.phase != .idle)
                }
            }
        }
    }
}

/// The record screen's route to the same list: what is being recorded, changed where it is
/// being watched, without a detour through the settings tab.
struct SensorArmingSheet: View {
    @Environment(SensorHub.self) private var hub
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if hub.phase != .idle {
                    Section {
                        Label("Während einer Aufnahme lässt sich das nicht ändern.",
                              systemImage: "lock.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                SensorArmingSections()
            }
            .navigationTitle("Sensoren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}
