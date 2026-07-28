import SensorstormCore
import SwiftUI

struct LibraryView: View {
    @Environment(RecordingLibrary.self) private var library

    var body: some View {
        NavigationStack {
            Group {
                if library.recordings.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Aufnahmen")
            .toolbar {
                if !library.recordings.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Text(Format.bytes(library.totalBytes))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear { library.refresh() }
    }

    private var list: some View {
        List {
            ForEach(library.recordings) { recording in
                NavigationLink {
                    RecordingDetailView(recording: recording, store: library.store)
                } label: {
                    RecordingRow(recording: recording,
                                 byteSize: library.byteSize(of: recording))
                }
                .listRowBackground(Theme.cardBackground)
            }
            .onDelete { library.delete(atOffsets: $0) }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Keine Aufnahmen", systemImage: "square.stack.3d.down.right")
        } description: {
            Text("Starte auf dem Tab „Aufnehmen“ deine erste Messung.")
        }
    }
}

struct RecordingRow: View {
    let recording: RecordingMetadata
    let byteSize: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(recording.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if recording.video != nil {
                    Image(systemName: "video.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.accent)
                }
                if recording.audio != nil {
                    Image(systemName: "mic.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.accent)
                }
            }

            Text(recording.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                metric("clock", Format.duration(recording.duration))
                metric("chart.dots.scatter", "\(recording.streams.count)")
                metric("number", Format.sampleCount(recording.totalSampleCount))
                metric("internaldrive", Format.bytes(byteSize))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func metric(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(text)
        }
    }
}
