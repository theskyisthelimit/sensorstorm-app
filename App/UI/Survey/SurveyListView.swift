import SensorstormCore
import SwiftUI

/// The add-on's home: every walk that has been documented, newest first.
struct SurveyListView: View {
    @Environment(SurveyModel.self) private var model
    @Environment(SensorHub.self) private var hub

    @State private var openedSurveyID: UUID?

    var body: some View {
        NavigationStack {
            Group {
                if model.surveys.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Fälle")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        startSurvey()
                    } label: {
                        Label("Neue Begehung", systemImage: "plus")
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
        .onAppear { model.refresh() }
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
                Text("Eine Begehung ist ein Weg, ein Fall eine Schadenstelle darauf: beliebig viele Fotos und Clips, die Position samt Abweichung, eine Bewertung von 1 bis 10 und der markierte Bereich.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Keine Begehungen", systemImage: "mappin.and.ellipse")
        } description: {
            Text("Eine Begehung sammelt Fälle entlang eines Wegs. Pro Fall: beliebig viele Fotos und Clips, die Position mit ihrer Abweichung, eine Bewertung von 1 bis 10 und der markierte Bereich.")
        } actions: {
            Button("Begehung starten") { startSurvey() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
    }

    /// A walk started while a recording runs remembers which one, so the findings and the
    /// sensor streams can be put back together afterwards.
    private func startSurvey() {
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
