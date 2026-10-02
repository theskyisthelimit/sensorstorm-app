import SensorstormCore
import SwiftUI

/// "Add the Health data of this hour" — asked for in the recording, when the person is looking
/// at it and the watch has had time to sync.
struct HealthImportCard: View {
    let recording: RecordingMetadata
    let store: RecordingStore
    let onImported: (RecordingMetadata) -> Void

    private enum State: Equatable {
        case idle, working, done(Int), failed(String)
    }

    @State private var state: State = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await importNow() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "heart.text.square").font(.title3).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gesundheitsdaten holen").font(.subheadline.weight(.semibold))
                        Text("Puls, Atmung, Sauerstoff, Schritte und Laufmetriken aus der Zeit dieser Aufnahme")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if state == .working { ProgressView() }
                }
                .padding(14)
                .card()
            }
            .buttonStyle(.plain)
            .disabled(state == .working)

            switch state {
            case .done(let count):
                Text("\(count) Verläufe hinzugefügt.").font(.footnote).foregroundStyle(.secondary)
            case .failed(let message):
                Text(verbatim: message).font(.footnote).foregroundStyle(Theme.recording)
            case .idle, .working:
                EmptyView()
            }
        }
    }

    private func importNow() async {
        guard HealthImporter.isAvailable else {
            state = .failed(String(localized: "Auf diesem Gerät gibt es keine Gesundheitsdaten."))
            return
        }
        state = .working
        let importer = HealthImporter()
        do {
            try await importer.requestAccess()
            let streams = try await importer.streams(for: recording)
            if streams.isEmpty {
                state = .failed(String(localized: "Für diese Zeit liegen keine Gesundheitsdaten vor. Die Uhr überträgt sie erst nach einigen Minuten, und Sensorstorm braucht die Freigabe in der Health-App."))
                return
            }
            let updated = try RecordingExtender.append(streams, to: recording, in: store)
            state = .done(streams.count)
            onImported(updated)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
