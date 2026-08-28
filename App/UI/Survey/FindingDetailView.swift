import AVKit
import SensorstormCore
import SwiftUI

/// One finding, in full: the photo, the clip, where it is, how bad it is, how far it reaches.
///
/// Edits are kept locally and written back when the screen closes as well as on demand —
/// nobody walking a street should lose a note because they swiped back.
struct FindingDetailView: View {
    @Environment(SurveyModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let surveyID: UUID
    let findingID: UUID

    @State private var severity = 5
    @State private var label = ""
    @State private var note = ""
    @State private var area: FindingArea?
    @State private var hasLoaded = false
    @State private var isEditingArea = false
    @State private var showsDeleteConfirmation = false
    @State private var player: AVPlayer?
    @State private var shareItem: ShareItem?

    private var finding: GroundFinding? {
        model.survey(surveyID)?.finding(findingID)
    }

    var body: some View {
        Group {
            if let finding {
                content(finding)
            } else {
                ContentUnavailableView("Befund nicht gefunden", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle(label.isEmpty ? String(localized: "Befund") : label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task { load() }
        .onDisappear {
            player?.pause()
            applyEdits()
        }
        .sheet(isPresented: $isEditingArea) {
            if let finding {
                AreaEditorView(center: finding.location.coordinate, area: $area)
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .confirmationDialog("Befund löschen?", isPresented: $showsDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                if let finding { model.deleteFinding(finding, from: surveyID) }
                dismiss()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Foto und Clip dieses Befunds werden mitgelöscht.")
        }
        .surveyErrorAlert(model)
    }

    private func content(_ finding: GroundFinding) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                photo(finding)

                if let player {
                    VideoPlayer(player: player)
                        .frame(height: 240)
                        .clipShape(.rect(cornerRadius: 16))
                }

                SurveyMapView(findings: [previewFinding(finding)], selection: finding.id)
                    .frame(height: 240)
                    .clipShape(.rect(cornerRadius: 16))

                SeverityPicker(severity: $severity)
                    .padding(14)
                    .card()

                describeCard
                areaCard
                infoCard(finding)

                Button(role: .destructive) {
                    showsDeleteConfirmation = true
                } label: {
                    Label("Befund löschen", systemImage: "trash")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
    }

    @ViewBuilder
    private func photo(_ finding: GroundFinding) -> some View {
        if let url = model.photoURL(for: finding, in: surveyID) {
            FindingPhotoView(url: url, severity: finding.severity)
        } else {
            Label("Ohne Foto erfasst", systemImage: "camera.badge.ellipsis")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .card()
        }
    }

    private var describeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Was ist es?", text: $label)
                .textFieldStyle(.plain)
                .font(.subheadline)
            Divider().overlay(Theme.cardBorder)
            TextField("Notiz", text: $note, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .lineLimit(2...6)
        }
        .padding(14)
        .card()
    }

    private var areaCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Bereich")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                if let area, area.isValid {
                    Text("\(Int(area.squareMetres.rounded())) m²")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
            }
            if let area, area.isValid {
                if area.kind == .circle {
                    Text("Kreis mit \(Int(area.radius.rounded())) m Radius")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Polygon mit \(area.points.count) Punkten")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Kein Bereich markiert.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                isEditingArea = true
            } label: {
                Label(area == nil ? "Bereich markieren" : "Bereich bearbeiten",
                      systemImage: "square.dashed")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
        }
        .padding(14)
        .card()
    }

    private func infoCard(_ finding: GroundFinding) -> some View {
        let location = finding.location
        let lv95 = location.lv95
        return VStack(alignment: .leading, spacing: 8) {
            infoRow("Zeit", finding.capturedAt.formatted(date: .abbreviated, time: .standard))
            infoRow("WGS84", "\(Format.coordinate(location.latitude)), \(Format.coordinate(location.longitude))")
            infoRow("LV95", String(format: "%.1f / %.1f", lv95.east, lv95.north))
            if location.horizontalAccuracy > 0 {
                infoRow("Genauigkeit", String(format: "±%.1f m", location.horizontalAccuracy))
            }
            if let altitude = location.altitude {
                infoRow("Höhe", String(format: "%.1f m ü. M.", altitude))
            }
            if let heading = location.heading {
                infoRow("Blickrichtung", String(format: "%.0f°", heading))
            }
            if finding.recordingID != nil {
                infoRow("Aufnahmezeit", String(format: "%.3f s", finding.hostTime))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }

    private func infoRow(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    applyEdits()
                } label: {
                    Label("Sichern", systemImage: "checkmark")
                }
                if let finding, let url = model.photoURL(for: finding, in: surveyID) {
                    Button {
                        shareItem = ShareItem(url: url)
                    } label: {
                        Label("Foto teilen", systemImage: "square.and.arrow.up")
                    }
                }
                if let finding, let url = model.videoURL(for: finding, in: surveyID) {
                    Button {
                        shareItem = ShareItem(url: url)
                    } label: {
                        Label("Clip teilen", systemImage: "video")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - State

    /// The map wants the *edited* area, not the stored one, so a freshly drawn polygon shows
    /// up before it has been written back.
    private func previewFinding(_ finding: GroundFinding) -> GroundFinding {
        var preview = finding
        preview.severity = GroundFinding.clamp(severity)
        preview.area = area
        return preview
    }

    private func load() {
        guard !hasLoaded, let finding else { return }
        hasLoaded = true
        severity = finding.severity
        label = finding.label
        note = finding.note
        area = finding.area
        if let url = model.videoURL(for: finding, in: surveyID) {
            player = AVPlayer(url: url)
        }
    }

    private func applyEdits() {
        guard hasLoaded, var current = finding else { return }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let clamped = GroundFinding.clamp(severity)

        guard current.severity != clamped || current.label != trimmedLabel
                || current.note != trimmedNote || current.area != area else { return }

        current.severity = clamped
        current.label = trimmedLabel
        current.note = trimmedNote
        current.area = area
        model.update(current, in: surveyID)
    }
}
