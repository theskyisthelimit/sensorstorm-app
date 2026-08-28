import AVFoundation
import SensorstormCore
import SwiftUI
import UIKit

/// Documenting one spot: photo, clip, position, judgement, extent.
///
/// The order on screen is the order of the work. Point the phone at the ground and shoot;
/// the position is frozen at that instant, because the fix that matters is the one from
/// where the picture was taken, not from wherever the phone happens to be by the time the
/// note is typed.
struct FindingCaptureView: View {
    @Environment(SurveyModel.self) private var model
    @Environment(SensorHub.self) private var hub
    @Environment(\.dismiss) private var dismiss

    let surveyID: UUID

    @State private var draft = FindingDraft()
    @State private var photoImage: UIImage?
    @State private var isCapturingPhoto = false
    @State private var clipStartedAt: Date?
    @State private var isFinishingClip = false
    @State private var isLocationPinned = false
    @State private var isEditingArea = false
    @State private var cameraMessage: String?
    @State private var isSaving = false
    /// Mirrors the camera's own state, which lives behind a lock and is therefore invisible
    /// to `@Observable` — without this the view never learns that the session came up.
    @State private var isCameraReady = false
    @State private var supportsClips = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    viewfinder
                    captureControls
                    positionCard
                    SeverityPicker(severity: $draft.severity)
                        .padding(14)
                        .card()
                    describeCard
                    areaCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .navigationTitle("Befund")
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
            // Until the shutter is pressed the draft simply follows the phone.
            guard !isLocationPinned, let fix, fix.isUsable else { return }
            draft.location = fix.findingLocation(heading: model.location.heading)
        }
        .sheet(isPresented: $isEditingArea) {
            AreaEditorView(center: areaCenter, area: $draft.area)
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
            // While a clip runs the live image wins: the point of the clip is to see what
            // is being filmed, not the still that was taken a moment earlier.
            if let photoImage, clipStartedAt == nil {
                Image(uiImage: photoImage)
                    .resizable()
                    .scaledToFill()
            } else if canUseCamera {
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
        .frame(height: 340)
        .clipShape(.rect(cornerRadius: 16))
        .overlay(alignment: .topTrailing) {
            if photoImage != nil, clipStartedAt == nil {
                Button {
                    photoImage = nil
                    draft.photo = nil
                } label: {
                    Label("Neu aufnehmen", systemImage: "arrow.counterclockwise")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: .capsule)
                }
                .buttonStyle(.plain)
                .padding(10)
            }
        }
        .overlay(alignment: .topLeading) {
            if let clipStartedAt {
                clipTimer(from: clipStartedAt)
                    .padding(10)
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
                Label(draft.photo == nil ? "Foto" : "Foto ersetzen", systemImage: "camera.fill")
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
                Label(clipStartedAt == nil ? clipButtonTitle : String(localized: "Stopp"),
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

    private var clipButtonTitle: String {
        draft.clipURL == nil
            ? String(localized: "Clip")
            : String(localized: "Clip neu")
    }

    // MARK: - Position

    private var positionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: isLocationPinned ? "mappin.circle.fill" : "location.fill")
                    .foregroundStyle(Theme.accent)
                Text(isLocationPinned ? "Position festgehalten" : "Aktuelle Position")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                if isLocationPinned {
                    Button("Neu setzen") { pinLocation(force: true) }
                        .font(.caption)
                }
            }

            if let location = draft.location, location.isUsable {
                Text("\(Format.coordinate(location.latitude)), \(Format.coordinate(location.longitude))")
                    .font(.caption.monospacedDigit())
                HStack(spacing: 10) {
                    Text(String(format: "±%.0f m", location.horizontalAccuracy))
                    if let heading = location.heading {
                        Text(String(format: "Blickrichtung %.0f°", heading))
                    }
                    if let altitude = location.altitude {
                        Text(String(format: "%.0f m ü. M.", altitude))
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            } else if model.location.isAuthorized {
                Text("Position wird gesucht … Ohne Fix lässt sich der Befund nicht sichern.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Kein Zugriff auf den Standort. Sensorstorm braucht ihn, damit ein Befund wiedergefunden werden kann.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
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
                Text("Optional: markiere, wie weit die Stelle reicht — als Kreis um dich herum oder als Polygon entlang des Rands.")
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

    /// A finding needs a position; photo and clip are what make it useful, not what make it
    /// valid. A note written at a spot with no camera still beats no record of the spot.
    private var canSave: Bool {
        draft.isSaveable || currentFix()?.isUsable == true
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
            "Die laufende Aufnahme benutzt die Kamera. Befund ohne Foto erfassen oder die Aufnahme stoppen."
        } else if !SurveyCamera.isAvailable {
            "Auf diesem Gerät ist keine Kamera verfügbar."
        } else if VideoRecorder.cameraAuthorizationStatus != .authorized {
            "Kein Zugriff auf die Kamera. In den Einstellungen von iOS freigeben."
        } else {
            "Kamera wird gestartet …"
        }
    }

    private var areaCenterCoordinate: Coordinate2D? {
        if let location = draft.location, location.isUsable { return location.coordinate }
        if let fix = currentFix(), fix.isUsable { return fix.coordinate }
        return nil
    }

    private var areaCenter: Coordinate2D {
        areaCenterCoordinate ?? Coordinate2D(latitude: 0, longitude: 0)
    }

    private func currentFix() -> LiveFix? { model.location.fix }

    // MARK: - Actions

    private func prepareCamera() async {
        model.location.requestAuthorization()
        model.location.acquire()
        if let fix = currentFix(), fix.isUsable, !isLocationPinned {
            draft.location = fix.findingLocation(heading: model.location.heading)
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
            draft.photo = data
            photoImage = UIImage(data: data)
            draft.capturedAt = Date()
            draft.hostTime = HostClock.now
            pinLocation()
        } catch {
            cameraMessage = error.localizedDescription
        }
    }

    private func toggleClip() async {
        if clipStartedAt != nil {
            isFinishingClip = true
            defer { isFinishingClip = false }
            let url = await model.camera.stopClip()
            clipStartedAt = nil
            if let url {
                removeClipFile()
                draft.clipURL = url
            }
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("finding-\(draft.id.uuidString)-\(Int(Date().timeIntervalSince1970)).mov")
        guard model.camera.startClip(to: url) else {
            cameraMessage = String(localized: "Für dieses Gerät ist keine Videoaufnahme möglich.")
            return
        }
        clipStartedAt = Date()
        pinLocation()
    }

    /// Freezes the draft's position. Called when the shutter goes, because that is the
    /// moment the finding is standing in front of you.
    private func pinLocation(force: Bool = false) {
        guard let fix = currentFix(), fix.isUsable else { return }
        guard force || !isLocationPinned else { return }
        draft.location = fix.findingLocation(heading: model.location.heading)
        isLocationPinned = true
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        if clipStartedAt != nil {
            let url = await model.camera.stopClip()
            clipStartedAt = nil
            if let url {
                removeClipFile()
                draft.clipURL = url
            }
        }
        if draft.location == nil || draft.location?.isUsable != true {
            if let fix = currentFix(), fix.isUsable {
                draft.location = fix.findingLocation(heading: model.location.heading)
            }
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
        removeClipFile()
        dismiss()
    }

    /// A clip that has been replaced or abandoned is deleted right away — the temporary
    /// directory is not a place to leave 200 MB behind.
    private func removeClipFile() {
        guard let url = draft.clipURL else { return }
        try? FileManager.default.removeItem(at: url)
        draft.clipURL = nil
    }
}
