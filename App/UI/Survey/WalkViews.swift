import Charts
import SensorstormCore
import SwiftUI
import UniformTypeIdentifiers

/// Whether the walk's path is being recorded, how far it is, and how to end the walk.
struct WalkCard: View {
    @Environment(SurveyModel.self) private var model
    let survey: Survey
    @State private var isScanning = false
    @State private var scanMessage: String?

    private var isTracking: Bool { model.trackingSurveyID == survey.id }
    private var tracksElsewhere: Bool { model.isTracking && !isTracking }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: isTracking ? "figure.walk.motion" : "figure.walk")
                    .foregroundStyle(isTracking ? Theme.recording : Theme.accent)
                    .accessibilityHidden(true)
                if isTracking {
                    Text("Der Weg wird aufgezeichnet")
                        .font(.subheadline.weight(.semibold))
                } else if survey.track.count >= 2 {
                    Text("Weg aufgezeichnet")
                        .font(.subheadline.weight(.semibold))
                } else {
                    Text("Weg")
                        .font(.subheadline.weight(.semibold))
                }
                Spacer(minLength: 0)
            }

            if survey.track.count >= 2 {
                HStack(spacing: 14) {
                    metric("Länge", Self.length(survey.trackLength))
                    metric("Dauer", Self.duration(survey.trackDuration))
                    metric("Punkte", "\(survey.track.count)")
                }
            }

            HStack(spacing: 10) {
                Button {
                    if isTracking { model.stopTracking() } else { model.startTracking(survey.id) }
                } label: {
                    if isTracking {
                        Label("Weg anhalten", systemImage: "stop.fill")
                    } else {
                        Label("Weg aufzeichnen", systemImage: "record.circle")
                    }
                }
                .buttonStyle(.bordered)
                .tint(isTracking ? Theme.recording : Theme.accent)
                .disabled(tracksElsewhere)

                if survey.endedAt == nil {
                    Button {
                        model.finish(survey.id)
                    } label: {
                        Label("Abschliessen", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        model.reopen(survey.id)
                    } label: {
                        Label("Wieder öffnen", systemImage: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .font(.footnote)

            if survey.endedAt == nil, NFCCheckpointReader.isAvailable {
                Button {
                    Task { await scanCheckpoint() }
                } label: {
                    Label("Kontrollpunkt scannen", systemImage: "wave.3.right")
                }
                .buttonStyle(.bordered)
                .font(.footnote)
                .disabled(isScanning)
            }
            if let scanMessage {
                Text(verbatim: scanMessage).font(.caption2).foregroundStyle(.secondary)
            }

            if isTracking {
                Text("Alle paar Meter ein Punkt, auch bei gesperrtem Bildschirm. iOS zeigt dafür den blauen Streifen an.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if tracksElsewhere {
                Text("Der Weg einer anderen Route wird gerade aufgezeichnet.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if let ended = survey.endedAt {
                Text("Abgeschlossen am \(ended.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }

    private func scanCheckpoint() async {
        isScanning = true
        scanMessage = nil
        defer { isScanning = false }
        do {
            let code = try await NFCCheckpointReader().scan(prompt: String(localized: "Halte das iPhone an den Aufkleber."))
            if await model.addCheckpoint(code: code, to: survey.id) != nil {
                scanMessage = String(localized: "Kontrollpunkt \(code) gesichert.")
            }
        } catch NFCCheckpointReader.Failure.cancelled {
            // The person closed the sheet; nothing to say.
        } catch {
            scanMessage = error.localizedDescription
        }
    }

    private func metric(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(verbatim: value).font(.callout.monospacedDigit())
        }
    }

    static func length(_ metres: Double) -> String {
        metres >= 1_000 ? String(format: "%.2f km", metres / 1_000) : String(format: "%.0f m", metres)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 3_600
            ? String(format: "%d:%02d h", total / 3_600, total % 3_600 / 60)
            : String(format: "%d:%02d min", total / 60, total % 60)
    }
}

/// What a repeat walk found compared with the one it repeats.
struct RepeatComparisonCard: View {
    @Environment(SurveyModel.self) private var model
    let survey: Survey

    var body: some View {
        if let previousID = survey.repeatsSurveyID, let previous = model.survey(previousID) {
            let result = FindingHistory.compare(older: previous, newer: survey)
            VStack(alignment: .leading, spacing: 8) {
                Label("Gegenüber „\(previous.name)“", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        figure("Neu", result.new, .orange)
                        figure("Erledigt", result.resolved, .green)
                        figure("Schlimmer", result.worse, Theme.recording)
                    }
                    GridRow {
                        figure("Besser", result.better, .mint)
                        figure("Gleich", result.unchanged, .secondary)
                        figure("Noch nicht geprüft", result.notYetChecked, Theme.accent)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .card()
        }
    }

    private func figure(_ title: LocalizedStringKey, _ value: Int, _ colour: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: "\(value)").font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(colour)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Which catalog the walk uses.
struct CatalogMenu: View {
    @Environment(SurveyModel.self) private var model
    let survey: Survey

    var body: some View {
        Menu {
            Button {
                set(nil)
            } label: {
                if survey.catalogID == nil {
                    Label("Freitext", systemImage: "checkmark")
                } else {
                    Text("Freitext")
                }
            }
            ForEach(model.catalogs.all) { catalog in
                Button {
                    set(catalog.id)
                } label: {
                    if survey.catalogID == catalog.id {
                        Label { Text(verbatim: catalog.name.resolve(CatalogStore.language)) } icon: { Image(systemName: "checkmark") }
                    } else {
                        Text(verbatim: catalog.name.resolve(CatalogStore.language))
                    }
                }
            }
        } label: {
            Label("Katalog", systemImage: "list.bullet.rectangle")
        }
    }

    private func set(_ id: String?) {
        var updated = survey
        updated.catalogID = id
        model.save(updated)
    }
}

/// Loads the swisstopo tiles of a walk's area onto the phone.
struct OfflineMapSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = OfflineMapStore()
    let bounds: GeoBounds?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let bounds {
                        let plan = TileMath.plan(bounds: bounds, zooms: OfflineMapStore.zooms, limit: OfflineMapStore.tileLimit)
                        LabeledContent("Kacheln") { Text(verbatim: "\(plan.tiles.count)").monospacedDigit() }
                        LabeledContent("Tiefste Stufe") { Text(verbatim: "\(plan.deepest)").monospacedDigit() }
                        LabeledContent("Etwa") {
                            Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(plan.tiles.count) * 20_000, countStyle: .file))
                        }
                        if store.progress.isRunning {
                            ProgressView(value: store.progress.fraction)
                            Button("Abbrechen", role: .cancel) { store.cancel() }
                        } else {
                            Button {
                                store.download(layer: SwisstopoTileOverlay.mapLayer, bounds: bounds)
                            } label: {
                                Label("Karte laden", systemImage: "arrow.down.circle")
                            }
                            Button {
                                store.download(layer: SwisstopoTileOverlay.aerialLayer, bounds: bounds)
                            } label: {
                                Label("Luftbild laden", systemImage: "arrow.down.circle")
                            }
                        }
                        if store.progress.failed > 0 {
                            Text("\(store.progress.failed) Kacheln liessen sich nicht laden.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Die Route hat noch keine Beobachtung und keinen Weg, für die sich ein Gebiet bestimmen liesse.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Gebiet der Route")
                } footer: {
                    Text("Lädt die swisstopo-Karte für das Gebiet in den Zoomstufen 12 bis 17 auf das Telefon. Ohne Netz zeigt die Karte dann genau diese Kacheln. Quelle: © swisstopo.")
                }

                Section {
                    LabeledContent("Auf dem Telefon") {
                        Text(verbatim: ByteCountFormatter.string(fromByteCount: store.bytes, countStyle: .file))
                    }
                    Button("Alle Kacheln löschen", role: .destructive) { store.removeAll() }
                        .disabled(store.bytes == 0)
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Karte offline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The result of importing an archive, in words.
struct ImportResultView: View {
    let result: ArchiveImporter.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if result.surveysAdded > 0 {
                Label("\(result.surveysAdded) neue Routen", systemImage: "plus.circle")
            }
            if result.surveysMerged > 0 {
                Label("\(result.surveysMerged) Routen ergänzt", systemImage: "arrow.triangle.merge")
            }
            if result.surveysUnchanged > 0 {
                Label("\(result.surveysUnchanged) Routen waren schon da", systemImage: "equal.circle")
            }
            if result.findings.added + result.findings.updated > 0 {
                Label("\(result.findings.added) neue und \(result.findings.updated) geänderte Beobachtungen", systemImage: "mappin")
            }
            if result.recordingsAdded > 0 {
                Label("\(result.recordingsAdded) Aufnahmen", systemImage: "waveform")
            }
            if result.unreadable > 0 {
                Label("\(result.unreadable) Dateien nicht lesbar", systemImage: "exclamationmark.triangle")
            }
        }
    }
}
