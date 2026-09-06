import SensorstormCore
import SwiftUI

/// The add-on's home: every walk that has been documented, newest first.
struct SurveyListView: View {
    @Environment(SurveyModel.self) private var model
    @Environment(SensorHub.self) private var hub
    @Environment(ProEntitlement.self) private var pro

    @State private var openedSurveyID: UUID?

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
                if !model.surveys.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Text(Format.bytes(model.totalBytes))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationDestination(item: $openedSurveyID) { id in
                SurveyDetailView(surveyID: id)
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
                    Text("Diese Route bleibt vollständig nutzbar: weitere Beobachtungen erfassen, bearbeiten und als CSV exportieren. Für mehrere Routen nebeneinander — pro Strasse, pro Auftrag, pro Tag — braucht es Pro.")
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
            Text("Eine Route sammelt Beobachtungen entlang eines Wegs. Pro Beobachtung: beliebig viele Fotos und Clips, die Position mit ihrer Abweichung, eine Bewertung von 1 bis 10 und der markierte Bereich.")
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
