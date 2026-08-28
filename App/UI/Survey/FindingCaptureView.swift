import AVFoundation
import SensorstormCore
import SwiftUI
import UIKit

/// Documenting one case: photos, clips, position, judgement, extent.
///
/// The order on screen is the order of the work. Point the phone at the damage and shoot —
/// as many times as it takes, an overview and a close-up are one case, not two. The
/// position freezes with the first shot, because the fix that counts is the one from where
/// the picture was taken and not from wherever the phone is by the time the note is typed.
struct FindingCaptureView: View {
    @Environment(SurveyModel.self) private var model
    @Environment(SensorHub.self) private var hub
    @Environment(\.dismiss) private var dismiss

    let surveyID: UUID
    /// When set, the screen only collects further photos and clips for a case that already
    /// exists — the second visit, or the close-up somebody forgot.
    var existingCaseID: UUID?

    /// Long enough for the receiver to settle, short enough that nobody walks off mid-way.
    private static let measureSeconds: TimeInterval = 10

    @State private var draft = FindingDraft()
    @State private var isCapturingPhoto = false
    @State private var clipStartedAt: Date?
    @State private var isFinishingClip = false
    @State private var isPositionFrozen = false
    @State private var isEditingArea = false
    @State private var isPlacingPin = false
    @State private var measureStartedAt: Date?
    @State private var cameraMessage: String?
    @State private var isSaving = false
    /// Mirrors the camera's own state, which lives behind a lock and is therefore invisible
    /// to `@Observable` — without this the view never learns that the session came up.
    @State private var isCameraReady = false
    @State private var supportsClips = false

    private var isAddingToExistingCase: Bool { existingCaseID != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    viewfinder
                    captureControls
                    if !draft.media.isEmpty {
                        mediaCard
                    }
                    if !isAddingToExistingCase {
                        positionCard
                        SeverityPicker(severity: $draft.severity)
                            .padding(14)
                            .card()
                        describeCard
                        areaCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .navigationTitle(isAddingToExistingCase ? "Aufnahmen hinzufügen" : "Fall erfassen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", role: .cancel) {
                        Task { await cancel() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        Task { await save() }
                    }
                    .disabled(isSaving || !canSave)
                }
            }
        }
        .task { await prepareCamera() }
        .onDisappear {
            model.camera.teardown()
            model.location.release()
            isCameraReady = false
        }
        .onChange(of: model.location.fix) { _, fix in
            // Until the first shot the draft simply follows the phone.
            guard !isPositionFrozen, let fix else { return }
            draft.follow(fix, heading: model.location.heading)
        }
        .sheet(isPresented: $isEditingArea) {
            AreaEditorView(center: areaCenter, area: $draft.area)
        }
        .sheet(isPresented: $isPlacingPin) {
            PinEditorView(measured: measuredForPin,
                          initial: draft.location?.coordinate ?? areaCenter,
                          onApply: { coordinate in
                              draft.placePin(at: coordinate)
                              isPositionFrozen = true
                          },
                          onReset: draft.positionSource == .manual
                              ? { draft.resetToMeasured() } : nil)
        }
        .alert("Kamera", isPresented: .init(
            get: { cameraMessage != nil },
            set: { if !$0 { cameraMessage = nil } }
        )) {
            Button("OK", role: .cancel) { cameraMessage = nil }
        } message: {
            Text(cameraMessage ?? "")
        }
    }

    // MARK: - Viewfinder

    @ViewBuilder
    private var viewfinder: some View {
        ZStack {
            if canUseCamera {
                CameraPreviewView(session: model.camera.session, isMirrored: false)
            } else {
                Theme.cardBackground
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "camera.fill")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text(cameraUnavailableReason)
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 24)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 320)
        .clipShape(.rect(cornerRadius: 16))
        .overlay(alignment: .topLeading) {
            if let clipStartedAt {
                clipTimer(from: clipStartedAt)
                    .padding(10)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !draft.media.isEmpty {
                Label("\(draft.photoCount)/\(draft.videoCount)", systemImage: "photo.on.rectangle")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: .capsule)
                    .padding(10)
                    .accessibilityLabel(Text("\(draft.photoCount) Fotos, \(draft.videoCount) Clips"))
            }
        }
    }

    private func clipTimer(from start: Date) -> some View {
        TimelineView(.periodic(from: start, by: 0.1)) { context in
            Label(Format.timecode(max(context.date.timeIntervalSince(start), 0)),
                  systemImage: "record.circle")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(Theme.recording)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: .capsule)
        }
    }

    // MARK: - Controls

    private var captureControls: some View {
        HStack(spacing: 14) {
            Button {
                Task { await capturePhoto() }
            } label: {
                Label(draft.photoCount == 0 ? "Foto" : "Foto \(draft.photoCount + 1)",
                      systemImage: "camera.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accent, in: .rect(cornerRadius: 12))
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .disabled(!canUseCamera || isCapturingPhoto || clipStartedAt != nil)

            Button {
                Task { await toggleClip() }
            } label: {
                Label(clipStartedAt == nil ? String(localized: "Clip") : String(localized: "Stopp"),
                      systemImage: clipStartedAt == nil ? "video.fill" : "stop.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(clipStartedAt == nil ? Theme.cardBackground : Theme.recording,
                                in: .rect(cornerRadius: 12))
                    .foregroundStyle(clipStartedAt == nil ? Color.primary : .white)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .disabled(!canUseCamera || !supportsClips || isFinishingClip)
        }
    }

    // MARK: - Media

    private var mediaCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Aufnahmen")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Text("\(draft.media.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            PendingMediaStrip(media: draft.media) { item in
                remove(item)
            }
        }
        .padding(14)
        .card()
    }

    // MARK: - Position

    private var positionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Position")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                AccuracyBadge(metres: draftUncertainty, source: draft.positionSource)
            }

            if let location = draft.location, location.coordinate.isValid {
                Text("\(Format.coordinate(location.latitude)), \(Format.coordinate(location.longitude))")
                    .font(.caption.monospacedDigit())
                Text(positionExplanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if model.location.isAuthorized {
                Text("Position wird gesucht … Ohne Fix oder gesetzte Nadel lässt sich der Fall nicht sichern.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Kein Zugriff auf den Standort. Ohne ihn bleibt nur die Nadel von Hand.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let measureStartedAt {
                measuringRow(from: measureStartedAt)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await measurePosition() }
                } label: {
                    Label("Messen", systemImage: "scope")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .disabled(measureStartedAt != nil || model.location.fix?.isUsable != true)

                Button {
                    isPlacingPin = true
                } label: {
                    Label("Nadel", systemImage: "mappin.and.ellipse")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .disabled(areaCenterCoordinate == nil)

                Button {
                    isPositionFrozen = false
                    draft.resetToMeasured()
                    if let fix = model.location.fix {
                        draft.follow(fix, heading: model.location.heading)
                    }
                } label: {
                    Label("GPS", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .disabled(model.location.fix?.isUsable != true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }

    /// The scatter of the fixes arriving right now, while they are being collected — the
    /// number that says whether standing still another five seconds is worth it.
    private func measuringRow(from start: Date) -> some View {
        TimelineView(.periodic(from: start, by: 0.25)) { context in
            let elapsed = min(max(context.date.timeIntervalSince(start), 0), Self.measureSeconds)
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: elapsed, total: Self.measureSeconds)
                    .tint(Theme.accent)
                Text("\(model.location.fixCount(inLast: max(elapsed, 1))) Fixes gesammelt — ruhig stehen bleiben")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var positionExplanation: LocalizedStringKey {
        switch draft.positionSource {
        case .gps:
            isPositionFrozen
                ? "Einzelner GPS-Fix, festgehalten bei der ersten Aufnahme."
                : "Einzelner GPS-Fix, folgt dem Gerät bis zur ersten Aufnahme."
        case .averaged:
            "Gemittelt aus \(draft.positionSampleCount ?? 0) Fixes, gemessene Streuung ±\(spreadText) m."
        case .manual:
            draft.measuredLocation == nil
                ? "Nadel von Hand gesetzt."
                : "Nadel von Hand gesetzt, \(offsetText) m vom GPS-Fix. Beide Positionen werden gespeichert."
        }
    }

    private var spreadText: String {
        String(format: "%.1f", draft.positionSpread ?? 0)
    }

    private var offsetText: String {
        guard let measured = draft.measuredLocation?.coordinate,
              let current = draft.location?.coordinate else { return "0" }
        return String(format: "%.0f", measured.distance(to: current))
    }

    private var draftUncertainty: Double? {
        switch draft.positionSource {
        case .manual: nil
        case .averaged: draft.positionSpread ?? draft.location?.horizontalAccuracy
        case .gps: draft.location?.horizontalAccuracy
        }
    }

    /// What the pin editor should draw as "this is what GPS said": the measurement kept
    /// aside once a pin was placed, or the current position while it is still a fix.
    private var measuredForPin: FindingLocation? {
        draft.positionSource == .manual ? draft.measuredLocation : draft.location
    }

    // MARK: - Description

    private var describeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Was ist es? z. B. Schlagloch", text: $draft.label)
                .textFieldStyle(.plain)
                .font(.subheadline)
            Divider().overlay(Theme.cardBorder)
            TextField("Notiz", text: $draft.note, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .lineLimit(2...5)
        }
        .padding(14)
        .card()
    }

    // MARK: - Area

    private var areaCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Bereich")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                if let area = draft.area, area.isValid {
                    Text("\(Int(area.squareMetres.rounded())) m²")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
            }

            if let area = draft.area, area.isValid {
                Group {
                    if area.kind == .circle {
                        Text("Kreis mit \(Int(area.radius.rounded())) m Radius")
                    } else {
                        Text("Polygon mit \(area.points.count) Punkten")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("Optional: markiere, wie weit der Schaden reicht — als Kreis um dich herum oder als Polygon entlang des Rands.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                isEditingArea = true
            } label: {
                Label(draft.area == nil ? "Bereich markieren" : "Bereich bearbeiten",
                      systemImage: "square.dashed")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .disabled(areaCenterCoordinate == nil)
        }
        .padding(14)
        .card()
    }

    // MARK: - State

    /// A case needs a position; photos and clips are what make it useful, not what make it
    /// valid. Adding to an existing case is the other way round: there the media are the
    /// whole point.
    private var canSave: Bool {
        if isAddingToExistingCase { return !draft.media.isEmpty }
        return draft.isSaveable
    }

    private var canUseCamera: Bool {
        SurveyCamera.isAvailable
            && VideoRecorder.cameraAuthorizationStatus == .authorized
            && !recordingHoldsCamera
            && isCameraReady
    }

    /// A running Sensorstorm recording owns the camera hardware; a second capture session
    /// would take it away mid-measurement. Saying so beats a black rectangle.
    private var recordingHoldsCamera: Bool {
        hub.phase != .idle && hub.settings.isVideoEnabled
    }

    private var cameraUnavailableReason: LocalizedStringKey {
        if recordingHoldsCamera {
            "Die laufende Aufnahme benutzt die Kamera. Fall ohne Foto erfassen oder die Aufnahme stoppen."
        } else if !SurveyCamera.isAvailable {
            "Auf diesem Gerät ist keine Kamera verfügbar."
        } else if VideoRecorder.cameraAuthorizationStatus != .authorized {
            "Kein Zugriff auf die Kamera. In den Einstellungen von iOS freigeben."
        } else {
            "Kamera wird gestartet …"
        }
    }

    private var areaCenterCoordinate: Coordinate2D? {
        if let location = draft.location, location.coordinate.isValid { return location.coordinate }
        if let fix = model.location.fix, fix.isUsable { return fix.coordinate }
        return nil
    }

    private var areaCenter: Coordinate2D {
        areaCenterCoordinate ?? Coordinate2D(latitude: 0, longitude: 0)
    }

    // MARK: - Actions

    private func prepareCamera() async {
        model.location.requestAuthorization()
        model.location.acquire()
        if let fix = model.location.fix, !isPositionFrozen {
            draft.follow(fix, heading: model.location.heading)
        }

        guard SurveyCamera.isAvailable, !recordingHoldsCamera else { return }

        // The live dashboard holds the camera while the record screen is up; it has to let
        // go before a second session can have it. Its teardown runs on its own queue, so
        // taking the device in the same breath is a race — wait it out rather than fight it.
        if hub.isMonitoring {
            hub.stopMonitoring()
            try? await Task.sleep(for: .milliseconds(200))
        }

        if VideoRecorder.cameraAuthorizationStatus == .notDetermined {
            _ = await VideoRecorder.requestCameraAccess()
        }
        guard VideoRecorder.cameraAuthorizationStatus == .authorized else { return }
        // Asked before the session is built: the microphone input can only be added while
        // configuring, so a clip recorded later would otherwise be silent.
        if !AudioSource.isMicrophoneAuthorized {
            _ = await AudioSource.requestMicrophoneAccess()
        }

        do {
            try await model.camera.configure()
            isCameraReady = model.camera.isConfigured
            supportsClips = model.camera.supportsClips
        } catch {
            cameraMessage = error.localizedDescription
        }
    }

    private func capturePhoto() async {
        isCapturingPhoto = true
        defer { isCapturingPhoto = false }
        do {
            let data = try await model.camera.capturePhoto()
            let thumbnail = await ThumbnailCache.shared.thumbnail(from: data, maxPixel: 300)
            draft.media.append(PendingMedia(photo: data, thumbnail: thumbnail))
            freezePosition()
        } catch {
            cameraMessage = error.localizedDescription
        }
    }

    private func toggleClip() async {
        if let start = clipStartedAt {
            isFinishingClip = true
            defer { isFinishingClip = false }
            let url = await model.camera.stopClip()
            clipStartedAt = nil
            if let url {
                draft.media.append(PendingMedia(clip: url,
                                                duration: Date().timeIntervalSince(start)))
            }
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("case-\(UUID().uuidString).mov")
        guard model.camera.startClip(to: url) else {
            cameraMessage = String(localized: "Für dieses Gerät ist keine Videoaufnahme möglich.")
            return
        }
        clipStartedAt = Date()
        freezePosition()
    }

    /// Holds the position where it was when the first picture was taken. A hand-placed pin
    /// or an averaged position is never overwritten by a later fix.
    private func freezePosition() {
        guard !isPositionFrozen else { return }
        if draft.positionSource == .gps, let fix = model.location.fix, fix.isUsable {
            draft.follow(fix, heading: model.location.heading)
        }
        // The case is stamped with the moment it was actually documented, not with the
        // moment the screen happened to open.
        draft.capturedAt = Date()
        draft.hostTime = HostClock.now
        isPositionFrozen = true
    }

    private func measurePosition() async {
        measureStartedAt = Date()
        defer { measureStartedAt = nil }

        try? await Task.sleep(for: .seconds(Self.measureSeconds))
        guard let averaged = model.location.averagedFix(seconds: Self.measureSeconds) else {
            cameraMessage = String(localized: "Zu wenige Fixes für eine Mittelung — unter freiem Himmel nochmals versuchen.")
            return
        }
        draft.apply(averaged, heading: model.location.heading)
        isPositionFrozen = true
    }

    private func remove(_ item: PendingMedia) {
        if let url = item.clipURL { try? FileManager.default.removeItem(at: url) }
        draft.media.removeAll { $0.id == item.id }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        if let start = clipStartedAt {
            let url = await model.camera.stopClip()
            clipStartedAt = nil
            if let url {
                draft.media.append(PendingMedia(clip: url,
                                                duration: Date().timeIntervalSince(start)))
            }
        }

        if let existingCaseID {
            guard model.addMedia(draft.media, to: existingCaseID, in: surveyID) else { return }
            dismiss()
            return
        }

        if draft.location == nil, let fix = model.location.fix {
            draft.follow(fix, heading: model.location.heading)
        }
        draft.recordingID = hub.activeRecordingID
        guard model.addFinding(draft, to: surveyID) != nil else { return }
        dismiss()
    }

    private func cancel() async {
        if clipStartedAt != nil {
            let url = await model.camera.stopClip()
            clipStartedAt = nil
            if let url { try? FileManager.default.removeItem(at: url) }
        }
        // Nothing was saved, so nothing may stay behind in the temporary directory.
        for item in draft.media {
            if let url = item.clipURL { try? FileManager.default.removeItem(at: url) }
        }
        dismiss()
    }
}
