import SensorstormCore
import SwiftUI

/// One walk: the map of everything found on it, and the way to add the next finding.
struct SurveyDetailView: View {
    @Environment(SurveyModel.self) private var model
    @Environment(SensorHub.self) private var hub
    @Environment(\.dismiss) private var dismiss

    let surveyID: UUID

    @State private var isCapturing = false
    @State private var shareItem: ShareItem?
    @State private var selection: UUID?
    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var showsDeleteConfirmation = false

    private var survey: Survey? { model.survey(surveyID) }

    var body: some View {
        Group {
            if let survey {
                content(survey)
            } else {
                ContentUnavailableView("Begehung nicht gefunden", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle(survey?.name ?? String(localized: "Begehung"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom, spacing: 0) { capturePanel }
        .task {
            model.location.requestAuthorization()
            model.location.acquire()
        }
        .onDisappear { model.location.release() }
        .sheet(isPresented: $isCapturing) {
            FindingCaptureView(surveyID: surveyID)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .alert("Umbenennen", isPresented: $isRenaming) {
            TextField("Name", text: $draftName)
            Button("Sichern") {
                if let survey { model.rename(survey, to: draftName) }
            }
            Button("Abbrechen", role: .cancel) {}
        }
        .confirmationDialog("Begehung löschen?", isPresented: $showsDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                if let survey { model.delete(survey) }
                dismiss()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Alle Befunde, Fotos und Clips dieser Begehung werden entfernt.")
        }
        .overlay {
            if model.isExporting { exportOverlay }
        }
        .surveyErrorAlert(model)
    }

    // MARK: - Content

    private func content(_ survey: Survey) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                SurveyMapView(findings: survey.findings,
                              selection: selection,
                              onSelect: { selection = $0.id })
                    .frame(height: 320)
                    .clipShape(.rect(cornerRadius: 16))
                    .overlay(alignment: .bottomLeading) {
                        if survey.findings.isEmpty {
                            Text("Noch keine Befunde")
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: .capsule)
                                .padding(10)
                        }
                    }

                summaryCard(survey)
                positionCard

                if !survey.findings.isEmpty {
                    findingList(survey)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private func summaryCard(_ survey: Survey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            infoRow("Start", survey.startedAt.formatted(date: .abbreviated, time: .standard))
            infoRow("Befunde", "\(survey.findings.count)")
            if let worst = survey.worstSeverity, let average = survey.averageSeverity {
                infoRow("Schlimmster", "\(worst)/10")
                infoRow("Durchschnitt", String(format: "%.1f/10", average))
            }
            if survey.markedSquareMetres > 0 {
                infoRow("Markierte Fläche", "\(Int(survey.markedSquareMetres.rounded())) m²")
            }
            infoRow("Grösse", Format.bytes(model.byteSize(of: survey)))
            if let recordingID = survey.recordingID {
                Divider().overlay(Theme.cardBorder)
                Text("Zur Aufnahme \(String(recordingID.uuidString.prefix(8))) erfasst — die Befunde liegen auf derselben Uhr wie deren Sensordaten.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }

    /// Where the phone thinks it is right now — the number that decides whether the next
    /// finding is worth recording at all.
    private var positionCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "location.fill")
                .foregroundStyle(fixColor)
            VStack(alignment: .leading, spacing: 2) {
                if let fix = model.location.fix, fix.isUsable {
                    Text("\(Format.coordinate(fix.latitude)), \(Format.coordinate(fix.longitude))")
                        .font(.caption.monospacedDigit())
                    Text("GPS \(model.location.accuracyDescription)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if model.location.isAuthorized {
                    Text("Position wird gesucht …")
                        .font(.caption)
                    Text("Unter freiem Himmel dauert das ein paar Sekunden.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Kein Zugriff auf den Standort")
                        .font(.caption)
                    Text("Ohne Position kann ein Befund nicht wiedergefunden werden.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .card()
    }

    private var fixColor: Color {
        guard let fix = model.location.fix, fix.isUsable else { return .secondary }
        return fix.horizontalAccuracy <= 10 ? Theme.accent : .orange
    }

    private func findingList(_ survey: Survey) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Befunde")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(survey.findingsByTime) { finding in
                NavigationLink {
                    FindingDetailView(surveyID: surveyID, findingID: finding.id)
                } label: {
                    FindingRow(finding: finding,
                               thumbnail: model.photoURL(for: finding, in: surveyID))
                        .padding(.horizontal, 12)
                        .card()
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        model.deleteFinding(finding, from: surveyID)
                    } label: {
                        Label("Löschen", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func infoRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
        }
    }

    // MARK: - Capture

    private var capturePanel: some View {
        Button {
            isCapturing = true
        } label: {
            Label("Befund erfassen", systemImage: "camera.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.accent, in: .rect(cornerRadius: 14))
                .foregroundStyle(.black)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .disabled(survey == nil)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section("Exportieren") {
                    exportButton(.bundle, "Bündel mit Fotos", "shippingbox")
                    exportButton(.geoJSON, "GeoJSON", "globe")
                    exportButton(.csv, "CSV", "tablecells")
                    exportButton(.kml, "KML (Google Earth)", "globe.europe.africa")
                    exportButton(.gpx, "GPX-Wegpunkte", "point.topleft.down.to.point.bottomright.curvepath")
                }
                Divider()
                Button {
                    draftName = survey?.name ?? ""
                    isRenaming = true
                } label: {
                    Label("Umbenennen", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    showsDeleteConfirmation = true
                } label: {
                    Label("Löschen", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func exportButton(_ format: SurveyExporter.Format,
                              _ title: LocalizedStringKey,
                              _ symbol: String) -> some View {
        Button {
            guard let survey else { return }
            Task { shareItem = await model.export(survey, format: format).map(ShareItem.init) }
        } label: {
            Label(title, systemImage: symbol)
        }
        .disabled(survey?.findings.isEmpty ?? true)
    }

    private var exportOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text("Export läuft …")
                    .font(.footnote)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        }
    }
}
