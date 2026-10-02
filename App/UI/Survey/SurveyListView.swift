import SensorstormCore
import SwiftUI
import UniformTypeIdentifiers

/// The add-on's home: every walk that has been documented, newest first.
struct SurveyListView: View {
    @Environment(SurveyModel.self) private var model
    @Environment(SensorHub.self) private var hub
    @Environment(ProEntitlement.self) private var pro

    @State private var openedSurveyID: UUID?
    @State private var isImporting = false
    @State private var importResult: ArchiveImporter.Result?
    @State private var isCombining = false

    /// The first walk is free. A field tool cannot be judged from a settings screen, and
    /// the walk someone actually records is both the honest trial and the reason to buy.
    private var canStartSurvey: Bool {
        pro.access.allowsStartingSurvey(existingCount: model.surveys.count)
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.surveys.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Beobachtungen")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        startSurvey()
                    } label: {
                        Label("Neue Route", systemImage: canStartSurvey ? "plus" : "lock.fill")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            isImporting = true
                        } label: {
                            Label("Archiv einlesen", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            isCombining = true
                        } label: {
                            Label("Routen zusammenführen", systemImage: "arrow.triangle.merge")
                        }
                        .disabled(model.surveys.count < 2)
                        if !model.surveys.isEmpty {
                            Text(Format.bytes(model.totalBytes))
                        }
                    } label: {
                        Label("Mehr", systemImage: "ellipsis.circle")
                    }
                }
            }
            .navigationDestination(item: $openedSurveyID) { id in
                SurveyDetailView(surveyID: id)
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.zip]) { result in
                guard case .success(let url) = result else { return }
                Task {
                    importResult = await model.importArchive(from: url, recordings: hub.store)
                }
            }
            .sheet(isPresented: $isCombining) {
                CombineSurveysSheet()
            }
            .alert("Archiv eingelesen", isPresented: Binding(get: { importResult != nil },
                                                             set: { if !$0 { importResult = nil } })) {
                Button("OK", role: .cancel) { importResult = nil }
            } message: {
                if let result = importResult {
                    Text(Self.summary(result))
                }
            }
            .overlay {
                if model.isImporting {
                    ProgressView().padding(24).background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
                }
            }
        }
        .onAppear {
            model.refresh()
            // `SS_SCREEN=survey` shoots the walk itself — the map with its cases — rather
            // than the list, which is the shot that shows what the app is for.
            if ScreenshotFixture.screen == .survey {
                openedSurveyID = model.surveys.first?.id
            }
        }
        .surveyErrorAlert(model)
    }

    private static func summary(_ result: ArchiveImporter.Result) -> String {
        var lines: [String] = []
        if result.surveysAdded > 0 { lines.append(String(localized: "\(result.surveysAdded) neue Routen")) }
        if result.surveysMerged > 0 { lines.append(String(localized: "\(result.surveysMerged) Routen ergänzt")) }
        if result.surveysUnchanged > 0 { lines.append(String(localized: "\(result.surveysUnchanged) Routen waren schon da")) }
        if result.recordingsAdded > 0 { lines.append(String(localized: "\(result.recordingsAdded) Aufnahmen")) }
        if result.unreadable > 0 { lines.append(String(localized: "\(result.unreadable) Dateien nicht lesbar")) }
        return lines.joined(separator: "\n")
    }

    private var list: some View {
        List {
            Section {
                ForEach(model.surveys) { survey in
                    NavigationLink {
                        SurveyDetailView(surveyID: survey.id)
                    } label: {
                        SurveyRow(survey: survey, byteSize: model.byteSize(of: survey))
                    }
                    .listRowBackground(Theme.cardBackground)
                }
                .onDelete { model.delete(atOffsets: $0) }
            } footer: {
                if canStartSurvey {
                    Text("Eine Route ist ein Weg, eine Beobachtung eine Stelle darauf: beliebig viele Fotos und Clips, die Position samt Abweichung, eine Bewertung von 1 bis 10 und der markierte Bereich.")
                } else {
                    Text("Diese Route bleibt vollständig nutzbar: weitere Beobachtungen erfassen, bearbeiten und als CSV exportieren. Für mehrere Routen nebeneinander, pro Strasse, pro Auftrag oder pro Tag, braucht es Pro.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Keine Routen", systemImage: "mappin.and.ellipse")
        } description: {
            Text("Eine Route sammelt Beobachtungen entlang eines Wegs. Je Beobachtung: beliebig viele Fotos und Clips, die Position mit ihrer Abweichung, eine Bewertung von 1 bis 10 und der markierte Bereich.")
        } actions: {
            Button("Route starten") { startSurvey() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
    }

    /// A walk started while a recording runs remembers which one, so the findings and the
    /// sensor streams can be put back together afterwards.
    private func startSurvey() {
        guard canStartSurvey else {
            pro.requestUnlock(.additionalSurveys)
            return
        }
        guard let survey = model.createSurvey(recordingID: hub.activeRecordingID) else { return }
        openedSurveyID = survey.id
    }
}

/// Picks two or more walks and puts them together as a new one.
struct CombineSurveysSheet: View {
    @Environment(SurveyModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<UUID>()
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                Section {
                    TextField("Name der neuen Route", text: $name)
                } footer: {
                    Text("Die neue Route enthält alle Beobachtungen, Fotos und Wege der gewählten. Die ursprünglichen bleiben erhalten.")
                }
                Section {
                    ForEach(model.surveys) { survey in
                        SurveyRow(survey: survey, byteSize: model.byteSize(of: survey))
                            .tag(survey.id)
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .navigationTitle("Routen zusammenführen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Zusammenführen") {
                        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        model.combine(Array(selection), name: title.isEmpty ? String(localized: "Zusammengeführt") : title)
                        dismiss()
                    }
                    .disabled(selection.count < 2)
                }
            }
        }
    }
}

struct SurveyRow: View {
    let survey: Survey
    let byteSize: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(survey.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let worst = survey.worstSeverity {
                    SeverityBadge(severity: worst)
                }
            }

            Text(survey.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                metric("mappin", "\(survey.findings.count)")
                if survey.markedSquareMetres > 0 {
                    metric("square.dashed", "\(Int(survey.markedSquareMetres.rounded())) m²")
                }
                if let average = survey.averageSeverity {
                    metric("chart.bar", String(format: "⌀ %.1f", average))
                }
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
