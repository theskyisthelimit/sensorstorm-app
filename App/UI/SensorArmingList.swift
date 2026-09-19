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
        // Engine-controlled streams follow from the camera setting; showing them as toggles
        // would promise a choice that does not exist.
        let descriptors = SensorCatalog.descriptors(in: category)
            .filter { !SensorID.engineControlled.contains($0.id) }

        if !descriptors.isEmpty {
            Section(category.title) {
                ForEach(descriptors) { descriptor in
                    SensorArmingRow(descriptor: descriptor)
                }
            }
        }
    }
}

/// One sensor: a switch when it can be switched, and otherwise the reason it cannot plus
/// the way out.
///
/// The previous version put „nicht verfügbar" under every unavailable sensor and disabled
/// the row. That reads as a system fault for the two thirds of cases where it is nothing of
/// the sort — a permission never asked for, a permission refused once months ago, a watch
/// that is not paired. A tester sat on the heart-rate row waiting for a prompt that a
/// disabled toggle can never produce. Now the row itself is the prompt.
private struct SensorArmingRow: View {
    let descriptor: SensorDescriptor

    @Environment(SensorHub.self) private var hub
    @State private var watchGap: WatchGap?
    @State private var isRequesting = false

    var body: some View {
        let status = hub.status(for: descriptor.id)

        Group {
            if status.isReady {
                armingToggle(status)
            } else if status.isActionable {
                actionRow(status)
            } else {
                unsupportedRow
            }
        }
        .alert(descriptor.id.title, isPresented: Binding(
            get: { watchGap != nil },
            set: { if !$0 { watchGap = nil } }
        ), presenting: watchGap) { _ in
            Button("OK", role: .cancel) { watchGap = nil }
        } message: { gap in
            Text(gap.explanation)
        }
    }

    // MARK: - The three shapes a row can take

    @ViewBuilder
    private func armingToggle(_ status: SensorStatus) -> some View {
        @Bindable var hub = hub
        Toggle(isOn: Binding(
            get: { hub.settings.isEnabled(descriptor.id) },
            set: { hub.settings.setEnabled($0, for: descriptor.id) }
        )) {
            label(subtitle: subtitle(for: status), tint: .tertiary, lines: 1)
        }
        // The streams to write are frozen in `SensorHub.streamsToWrite(for:)` when the
        // recording starts. A toggle that silently did nothing for the next twenty minutes
        // would be worse than no toggle at all.
        .disabled(hub.phase != .idle)
    }

    @ViewBuilder
    private func actionRow(_ status: SensorStatus) -> some View {
        Button {
            perform(status)
        } label: {
            HStack {
                label(subtitle: subtitle(for: status), tint: .secondary, lines: 2)
                Spacer(minLength: 12)
                if isRequesting {
                    ProgressView()
                } else {
                    Text(actionTitle(for: status))
                        .font(.footnote.weight(.semibold))
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        // Nothing here changes what is being captured, so unlike the toggle it stays live
        // during a recording — reading why the heart rate is missing is not a capture change.
        .disabled(isRequesting)
    }

    private var unsupportedRow: some View {
        label(subtitle: String(localized: "Dieses Gerät hat keinen solchen Sensor."), tint: .tertiary, lines: 2)
            .foregroundStyle(.secondary)
    }

    // MARK: -

    /// - Parameter lines: one for the channel list, two for a reason.
    ///
    /// The channel list is decorative — GPS alone names ten columns, and spelled out it
    /// pushed the row to three lines, which is most of why this screen felt like a wall. It
    /// is documented in full in docs/UNITS.md and may be cut. A reason may not: „In den
    /// Einstellungen „Bewegung & Fit…“ is an instruction with the instruction removed.
    private func label(subtitle: String, tint: HierarchicalShapeStyle, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(descriptor.id.title)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(tint)
                .lineLimit(lines)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func subtitle(for status: SensorStatus) -> String {
        switch status {
        case .ready, .simulated:
            descriptor.channels.joined(separator: ", ")
        case .permissionMissing(let permission):
            permission.missingHint
        case .permissionRefused(let permission):
            permission.refusedHint
        case .needsWatch(let gap):
            gap.hint
        case .unsupported:
            String(localized: "Dieses Gerät hat keinen solchen Sensor.")
        }
    }

    private func actionTitle(for status: SensorStatus) -> String {
        switch status {
        case .permissionMissing: String(localized: "Erlauben")
        case .permissionRefused: String(localized: "Einstellungen")
        default: String(localized: "Warum?")
        }
    }

    private func perform(_ status: SensorStatus) {
        switch status {
        case .permissionMissing(let permission):
            isRequesting = true
            Task {
                await hub.requestPermission(permission)
                isRequesting = false
            }
        case .permissionRefused:
            SystemSettings.open()
        case .needsWatch(let gap):
            watchGap = gap
        case .ready, .simulated, .unsupported:
            break
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
