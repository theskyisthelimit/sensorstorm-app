import AVKit
import SensorstormCore
import SwiftUI

/// One case, in full: every photo and clip, where it is, how well that is known, how bad it
/// is, how far it reaches.
///
/// Text edits are kept locally and written back when the screen closes as well as on
/// demand — nobody walking a street should lose a note because they swiped back. Position
/// changes are written immediately: they are single deliberate acts, not typing.
struct FindingDetailView: View {
    @Environment(SurveyModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let surveyID: UUID
    let findingID: UUID

    @State private var severity = 5
    @State private var label = ""
    @State private var note = ""
    @State private var area: FindingArea?
    @State private var hasLoaded = false
    @State private var isEditingArea = false
    @State private var isPlacingPin = false
    @State private var isAddingMedia = false
    @State private var showsDeleteConfirmation = false
    @State private var viewerItem: CaseMedia?
    @State private var shareItem: ShareItem?

    private var finding: GroundFinding? {
        model.survey(surveyID)?.finding(findingID)
    }

    var body: some View {
        Group {
            if let finding {
                content(finding)
            } else {
                ContentUnavailableView("Fall nicht gefunden", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle(label.isEmpty ? String(localized: "Fall") : label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task { load() }
        .onDisappear { applyEdits() }
        // Leaving the screen is not the only way this view ends: the phone goes into a
        // pocket, iOS suspends the app, and a rating typed in front of the damage would be
        // gone. Write on the way out of `.active`, not only on the way off the screen.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { applyEdits() }
        }
        .sheet(isPresented: $isEditingArea) {
            if let finding {
                AreaEditorView(center: finding.location.coordinate, area: $area)
            }
        }
        .sheet(isPresented: $isPlacingPin) {
            if let finding {
                PinEditorView(measured: finding.measuredLocation ?? finding.location,
                              initial: finding.location.coordinate,
                              onApply: { placePin(at: $0) },
                              onReset: finding.measuredLocation != nil ? { resetPosition() } : nil)
            }
        }
        .sheet(isPresented: $isAddingMedia) {
            FindingCaptureView(surveyID: surveyID, existingCaseID: findingID)
        }
        .sheet(item: $viewerItem) { item in
            MediaViewerView(url: model.url(for: item, in: surveyID), media: item)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .confirmationDialog("Fall löschen?", isPresented: $showsDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                if let finding { model.deleteFinding(finding, from: surveyID) }
                dismiss()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Alle Fotos und Clips dieses Falls werden mitgelöscht.")
        }
        .surveyErrorAlert(model)
    }

    private func content(_ finding: GroundFinding) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                mediaSection(finding)

                SurveyMapView(findings: [previewFinding(finding)], selection: finding.id)
                    .frame(height: 260)
                    .clipShape(.rect(cornerRadius: 16))

                positionCard(finding)

                SeverityPicker(severity: $severity)
                    .padding(14)
                    .card()

                describeCard
                areaCard
                infoCard(finding)

                Button(role: .destructive) {
                    showsDeleteConfirmation = true
                } label: {
                    Label("Fall löschen", systemImage: "trash")
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

    // MARK: - Media

    @ViewBuilder
    private func mediaSection(_ finding: GroundFinding) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let cover = finding.coverPhoto {
                FindingPhotoView(url: model.url(for: cover, in: surveyID),
                                 severity: finding.severity)
                    .onTapGesture { viewerItem = cover }
            }

            if !finding.media.isEmpty {
                CaseMediaStrip(media: finding.media,
                               urlFor: { model.url(for: $0, in: surveyID) },
                               onSelect: { viewerItem = $0 },
                               onDelete: { model.deleteMedia($0, from: findingID, in: surveyID) })
            }

            Button {
                isAddingMedia = true
            } label: {
                Label(finding.media.isEmpty ? "Aufnahmen machen" : "Weitere Aufnahmen",
                      systemImage: "camera.fill")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
        }
        .padding(.vertical, finding.coverPhoto == nil ? 8 : 0)
    }

    // MARK: - Position

    private func positionCard(_ finding: GroundFinding) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Position")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                AccuracyBadge(metres: finding.uncertaintyRadius, source: finding.positionSource)
            }

            Text(SurveyExporter.positionDescription(of: finding))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let measured = finding.measuredLocation, measured.coordinate.isValid {
                Text("GPS hatte \(Format.coordinate(measured.latitude)), \(Format.coordinate(measured.longitude)) gemeldet — beides ist gespeichert.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 12) {
                Button {
                    isPlacingPin = true
                } label: {
                    Label(finding.positionSource == .manual ? "Nadel verschieben" : "Nadel setzen",
                          systemImage: "mappin.and.ellipse")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)

                if finding.measuredLocation != nil {
                    Button {
                        resetPosition()
                    } label: {
                        Label("Zurück auf GPS", systemImage: "location.fill")
                            .font(.caption.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
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
            infoRow("Quelle", positionSourceName(finding.positionSource))
            if let radius = finding.uncertaintyRadius {
                infoRow(finding.positionSource == .averaged ? "Streuung" : "Genauigkeit",
                        String(format: "±%.1f m", radius))
            }
            if let samples = finding.positionSampleCount {
                infoRow("Fixes", "\(samples)")
            }
            if let offset = finding.manualOffsetMetres {
                infoRow("Versatz zum GPS-Fix", String(format: "%.1f m", offset))
            }
            if let altitude = location.altitude {
                infoRow("Höhe", String(format: "%.1f m ü. M.", altitude))
            }
            if let heading = location.heading {
                infoRow("Blickrichtung", String(format: "%.0f°", heading))
            }
            infoRow("Aufnahmen", "\(Format.photos(finding.photos.count)), \(Format.clips(finding.videos.count))")
            if finding.recordingID != nil {
                infoRow("Aufnahmezeit", String(format: "%.3f s", finding.hostTime))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }

    private func positionSourceName(_ source: PositionSource) -> String {
        switch source {
        case .gps: String(localized: "einzelner GPS-Fix")
        case .averaged: String(localized: "gemittelt")
        case .manual: String(localized: "Nadel von Hand")
        }
    }

    private func infoRow(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .multilineTextAlignment(.trailing)
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
                if let finding {
                    ForEach(finding.media) { item in
                        if let url = model.url(for: item, in: surveyID) {
                            Button {
                                shareItem = ShareItem(url: url)
                            } label: {
                                Label(item.kind == .photo ? "Foto teilen" : "Clip teilen",
                                      systemImage: item.kind == .photo ? "photo" : "video")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - State

    /// The map wants the *edited* case, not the stored one, so a freshly drawn polygon shows
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

    private func placePin(at coordinate: Coordinate2D) {
        guard var current = finding else { return }
        current.placePin(at: coordinate)
        model.update(current, in: surveyID)
    }

    private func resetPosition() {
        guard var current = finding else { return }
        current.resetPositionToMeasured()
        model.update(current, in: surveyID)
    }
}

/// One photo or clip, full screen.
struct MediaViewerView: View {
    let url: URL?
    let media: CaseMedia

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if media.kind == .video, let player {
                    VideoPlayer(player: player)
                } else if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(media.capturedAt.formatted(date: .omitted, time: .standard))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .task {
            guard let url else { return }
            if media.kind == .video {
                player = AVPlayer(url: url)
            } else {
                // Full width of a modern screen, not the full eight megapixels.
                image = await ThumbnailCache.shared.thumbnail(for: url, maxPixel: 2400)
            }
        }
        .onDisappear { player?.pause() }
    }
}
