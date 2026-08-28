import SensorstormCore
import SwiftUI

/// „Alles, was auf dem Gerät ist, als eine Datei" — the screen behind that sentence.
///
/// Separate from the per-item exports on purpose. Those answer „diese eine Begehung für
/// QGIS"; this one produces a zip with a `manifest.json` at its root that names every file
/// and every case, for a script on the other end that has to read the lot without a human
/// pointing at folders.
struct ArchiveExportView: View {
    @Environment(SurveyModel.self) private var surveys
    @Environment(RecordingLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var includesSurveys = true
    @State private var includesSurveyMedia = true
    @State private var includesRecordings = false
    @State private var recordingFormat: RecordingExporter.Format = .csvBundle

    @State private var progress: Double?
    @State private var result: ShareItem?
    @State private var errorMessage: String?

    private var surveyCount: Int { surveys.surveys.count }
    private var recordingCount: Int { library.recordings.count }

    /// The bytes already on disk. The archive lands near this: media dominate, and CSV
    /// costs more than the binary streams it is written from — so it is announced as an
    /// order of magnitude, not as a promise.
    private var estimatedBytes: Int64 {
        var total: Int64 = 0
        if includesSurveys {
            total += includesSurveyMedia ? surveys.totalBytes : Int64(surveyCount) * 8_192
        }
        if includesRecordings { total += library.totalBytes }
        return total
    }

    private var hasSomethingToExport: Bool {
        (includesSurveys && surveyCount > 0) || (includesRecordings && recordingCount > 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                contentSection
                if includesRecordings { recordingFormatSection }
                actionSection
            }
            .navigationTitle("Gesamtexport")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schliessen") { dismiss() }
                        .disabled(progress != nil)
                }
            }
            .sheet(item: $result) { item in
                ShareSheet(items: [item.url])
            }
            .alert("Export fehlgeschlagen", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var contentSection: some View {
        Section {
            Toggle(isOn: $includesSurveys) {
                LabeledContent("Begehungen") {
                    Text("\(surveyCount)").monospacedDigit()
                }
            }
            Toggle("Fotos und Clips", isOn: $includesSurveyMedia)
                .disabled(!includesSurveys)
            Toggle(isOn: $includesRecordings) {
                LabeledContent("Messaufnahmen") {
                    Text("\(recordingCount)").monospacedDigit()
                }
            }
        } header: {
            Text("Inhalt")
        } footer: {
            Text("Im Archiv liegt \(ArchiveExporter.manifestFileName): jede Datei mit Grösse und SHA-256, jeder Fall mit Position, Genauigkeit, Bewertung und den Pfaden seiner Aufnahmen. Ein Skript liest diese eine Datei und braucht sonst nichts über die Ordner zu wissen.")
        }
    }

    private var recordingFormatSection: some View {
        Section {
            Picker("Format", selection: $recordingFormat) {
                Text("CSV je Sensor").tag(RecordingExporter.Format.csvBundle)
                Text("Rohdaten (.ssbin)").tag(RecordingExporter.Format.rawBundle)
            }
        } header: {
            Text("Messaufnahmen")
        } footer: {
            Text("CSV liest jede Tabelle und jedes Skript direkt. Rohdaten sind kleiner und verlustfrei, brauchen aber einen Leser für das .ssbin-Format — der Aufbau steht im README des Archivs.")
        }
    }

    private var actionSection: some View {
        Section {
            if let progress {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress)
                        .tint(Theme.accent)
                    Text("Archiv wird geschrieben … \(Int(progress * 100)) %")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Task { await run() }
                } label: {
                    Label("Archiv erstellen", systemImage: "shippingbox")
                }
                .disabled(!hasSomethingToExport)
            }
        } footer: {
            if hasSomethingToExport {
                Text("Ungefähr \(Format.bytes(estimatedBytes)). Das Archiv wird danach zum Teilen angeboten — Dateien, AirDrop, Mail.")
            } else {
                Text("Nichts ausgewählt, was es zu exportieren gäbe.")
            }
        }
    }

    private func run() async {
        progress = 0
        defer { progress = nil }

        let options = ArchiveExporter.Options(
            includesSurveys: includesSurveys,
            includesSurveyMedia: includesSurveyMedia,
            includesRecordings: includesRecordings,
            recordingFormat: recordingFormat
        )
        let surveyStore = surveys.store
        let recordingStore = library.store
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("exports", isDirectory: true)

        // Reported from a detached task, so the bar moves while a bundle full of video is
        // being hashed instead of freezing at zero until the whole thing is done.
        let reporter = ProgressReporter { value in
            Task { @MainActor in progress = value }
        }

        do {
            let url = try await Task.detached(priority: .userInitiated) {
                try ArchiveExporter(surveyStore: surveyStore, recordingStore: recordingStore,
                                    appVersion: version, build: build)
                    .export(into: destination, options: options, progress: reporter.report)
            }.value
            result = ShareItem(url: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Bridges the exporter's `@Sendable` progress closure back to the main actor.
private final class ProgressReporter: Sendable {
    private let handler: @Sendable (Double) -> Void

    init(_ handler: @escaping @Sendable (Double) -> Void) {
        self.handler = handler
    }

    var report: @Sendable (Double) -> Void { handler }
}
