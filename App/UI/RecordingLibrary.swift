import Foundation
import Observation
import SensorstormCore
import SwiftUI

/// The list of recordings on disk, plus the operations the library screen offers.
@MainActor
@Observable
final class RecordingLibrary {
    private(set) var recordings: [RecordingMetadata] = []
    private(set) var totalBytes: Int64 = 0
    /// Folders a crash mid-recording left without metadata — invisible in `recordings`.
    private(set) var orphans: [RecordingStore.OrphanedRecording] = []
    private(set) var orphanBytes: Int64 = 0
    private(set) var isExporting = false
    private(set) var exportProgress: Double = 0
    var errorMessage: String?

    let store: RecordingStore

    init(store: RecordingStore) {
        self.store = store
        refresh()
    }

    func refresh() {
        recordings = store.allRecordings()
        totalBytes = recordings.reduce(0) { $0 + store.byteSize(of: $1.id) }
        orphans = store.orphanedRecordings()
        orphanBytes = orphans.reduce(0) { $0 + $1.byteSize }
    }

    func byteSize(of recording: RecordingMetadata) -> Int64 {
        store.byteSize(of: recording.id)
    }

    func delete(_ recording: RecordingMetadata) {
        do {
            try store.delete(recording.id)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(atOffsets offsets: IndexSet) {
        for index in offsets {
            guard recordings.indices.contains(index) else { continue }
            try? store.delete(recordings[index].id)
        }
        refresh()
    }

    /// Reclaims every orphaned folder. Nothing there can be opened or repaired — the
    /// metadata that would say what the samples are was never written — so the only
    /// thing to give back is the space.
    func deleteOrphans() {
        for orphan in orphans {
            do {
                try store.delete(orphan.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        refresh()
    }

    func rename(_ recording: RecordingMetadata, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = recording
        updated.name = trimmed
        do {
            try store.save(updated)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateNotes(_ recording: RecordingMetadata, notes: String) {
        var updated = recording
        updated.notes = notes
        try? store.save(updated)
        refresh()
    }

    /// Exports off the main actor and returns the zip for the share sheet.
    func export(_ recording: RecordingMetadata,
                format: RecordingExporter.Format) async -> URL? {
        isExporting = true
        exportProgress = 0
        defer { isExporting = false }

        let store = self.store
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        do {
            return try await Task.detached(priority: .userInitiated) {
                try RecordingExporter(store: store)
                    .export(recording, format: format, into: destination)
            }.value
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}

extension View {
    /// Surfaces ``RecordingLibrary/errorMessage``.
    ///
    /// The model has always recorded why a delete, rename or export failed; until this
    /// existed nothing displayed it, so a failed export looked exactly like a successful one
    /// that produced no share sheet.
    func libraryErrorAlert(_ library: RecordingLibrary) -> some View {
        alert("Fehler", isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
    }
}
