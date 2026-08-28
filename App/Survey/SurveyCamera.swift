import AVFoundation
import Foundation
import SensorstormCore
import os

/// The camera behind the survey add-on: one still per finding, plus an optional clip.
///
/// Deliberately *not* the ``VideoRecorder`` path. That one exists to put a video frame on
/// the same clock as an accelerometer sample and pays for it with an `AVAssetWriter`, no
/// stills and no convenience. Documenting a spot on the ground needs the opposite trade:
/// a full-quality photo, a short clip with sound so the person walking can say what they
/// see, and nothing that has to be aligned to anything afterwards.
///
/// The two never run at the same time — the survey screen takes the camera only once the
/// record screen has given it up, and refuses it outright while a recording is running.
final class SurveyCamera: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()

    /// Longest clip per finding. A spot on a street is documented in seconds; a cap keeps a
    /// pocket-recorded hour from silently filling the phone.
    static let maximumClipSeconds: Double = 60

    /// Portrait. The app's UI is locked to portrait, so pinning the connection to the same
    /// angle means the file matches the preview the photo was framed in — no surprise
    /// rotation when the picture is opened somewhere else.
    private static let portraitRotationAngle: CGFloat = 90

    private let sessionQueue = DispatchQueue(label: "ch.sensorstorm.survey.camera")
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()

    private struct State: Sendable {
        var isConfigured = false
        var supportsClips = false
        var isRecordingClip = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// `AVCapturePhotoOutput` does not retain its delegate, so the capture would end up
    /// talking to a deallocated object. Held here until the photo comes back.
    private let photoDelegates = OSAllocatedUnfairLock(initialState: [Int64: PhotoDelegate]())
    private let clipWaiter = OSAllocatedUnfairLock<CheckedContinuation<URL?, Never>?>(initialState: nil)

    static var isAvailable: Bool { VideoRecorder.hasCamera }

    var isConfigured: Bool { state.withLock { $0.isConfigured } }
    var supportsClips: Bool { state.withLock { $0.supportsClips } }
    var isRecordingClip: Bool { state.withLock { $0.isRecordingClip } }

    // MARK: - Session lifecycle

    func configure() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                if state.withLock({ $0.isConfigured }) {
                    if !session.isRunning { session.startRunning() }
                    continuation.resume()
                    return
                }
                do {
                    try configureSession()
                    session.startRunning()
                    state.withLock { $0.isConfigured = true }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func teardown() {
        sessionQueue.async { [self] in
            if movieOutput.isRecording { movieOutput.stopRecording() }
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            session.commitConfiguration()
            state.withLock {
                $0.isConfigured = false
                $0.supportsClips = false
            }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        // `.photo` delivers full-sensor stills but refuses a movie output; `.high` gives
        // both from one session. A finding wants a photo *and* a clip, so `.high` wins.
        session.sessionPreset = session.canSetSessionPreset(.high) ? .high : .medium

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            throw SurveyCameraError.noCamera
        }
        session.addInput(input)

        guard session.canAddOutput(photoOutput) else { throw SurveyCameraError.cannotConfigure }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality
        if let dimensions = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
            Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height)
        }) {
            photoOutput.maxPhotoDimensions = dimensions
        }
        applyPortraitRotation(to: photoOutput.connection(with: .video))

        // Sound belongs to the clip: half of what a walker records is what they say about
        // the spot. Without permission the clip is silent rather than absent.
        if AudioSource.isMicrophoneAuthorized,
           let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        var supportsClips = false
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
            movieOutput.maxRecordedDuration = CMTime(seconds: Self.maximumClipSeconds,
                                                     preferredTimescale: 600)
            supportsClips = true
        }

        configureFocus(of: device)

        let clips = supportsClips
        state.withLock { $0.supportsClips = clips }
    }

    /// Ground photos are taken a metre from the subject with the phone pointing down —
    /// continuous autofocus and auto exposure are the difference between a usable picture
    /// and a grey blur.
    private func configureFocus(of device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        } catch {
            RecordingLog.warn("survey camera focus: \(error.localizedDescription)")
        }
    }

    private func applyPortraitRotation(to connection: AVCaptureConnection?) {
        guard let connection,
              connection.isVideoRotationAngleSupported(Self.portraitRotationAngle) else { return }
        connection.videoRotationAngle = Self.portraitRotationAngle
    }

    // MARK: - Photo

    func capturePhoto() async throws -> Data {
        guard isConfigured else { throw SurveyCameraError.notReady }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            sessionQueue.async { [self] in
                guard session.isRunning else {
                    continuation.resume(throwing: SurveyCameraError.notReady)
                    return
                }

                let settings = makePhotoSettings()
                let identifier = settings.uniqueID
                let delegate = PhotoDelegate { [weak self] result in
                    continuation.resume(with: result)
                    // Released on the next turn of the session queue rather than here: this
                    // closure runs inside the delegate's own method, and dropping the last
                    // reference to it mid-call is not something to rely on.
                    guard let self else { return }
                    sessionQueue.async { self.photoDelegates.withLock { $0[identifier] = nil } }
                }
                photoDelegates.withLock { $0[identifier] = delegate }
                photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    /// JPEG rather than the HEIF default: a finding travels to whatever software the office
    /// on the other end uses, and JPEG is the one every one of them opens.
    private func makePhotoSettings() -> AVCapturePhotoSettings {
        let settings = photoOutput.availablePhotoCodecTypes.contains(.jpeg)
            ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            : AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .quality
        // Only when the output actually carries a resolution: assigning an unsupported
        // dimension pair to the settings raises rather than falls back.
        if photoOutput.maxPhotoDimensions.width > 0, photoOutput.maxPhotoDimensions.height > 0 {
            settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        }
        if photoOutput.supportedFlashModes.contains(.auto) {
            settings.flashMode = .auto
        }
        return settings
    }

    // MARK: - Clip

    /// Starts a clip. Returns `false` when this device or this session cannot record one.
    @discardableResult
    func startClip(to url: URL) -> Bool {
        let started = state.withLock { current -> Bool in
            guard current.isConfigured, current.supportsClips, !current.isRecordingClip else {
                return false
            }
            current.isRecordingClip = true
            return true
        }
        guard started else { return false }

        sessionQueue.async { [self] in
            guard !movieOutput.isRecording else { return }
            try? FileManager.default.removeItem(at: url)
            applyPortraitRotation(to: movieOutput.connection(with: .video))
            movieOutput.startRecording(to: url, recordingDelegate: self)
        }
        return true
    }

    /// Stops the clip and waits for the file to be finalised. `nil` means the recording
    /// failed — an unfinalised `.mov` is not a video anyone can play.
    func stopClip() async -> URL? {
        guard isRecordingClip else { return nil }

        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            let previous = clipWaiter.withLock { waiter -> CheckedContinuation<URL?, Never>? in
                let existing = waiter
                waiter = continuation
                return existing
            }
            // Two callers waiting on one file would leave the first suspended forever.
            previous?.resume(returning: nil)

            sessionQueue.async { [self] in
                if movieOutput.isRecording {
                    movieOutput.stopRecording()
                } else {
                    finishClip(with: nil)
                }
            }
        }
    }

    private func finishClip(with url: URL?) {
        state.withLock { $0.isRecordingClip = false }
        let waiter = clipWaiter.withLock { waiter -> CheckedContinuation<URL?, Never>? in
            let current = waiter
            waiter = nil
            return current
        }
        waiter?.resume(returning: url)
    }
}

// MARK: - Delegates

extension SurveyCamera: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        var isUsable = error == nil
        // Hitting the duration cap is reported as an error even though the file is complete;
        // `AVErrorRecordingSuccessfullyFinishedKey` is the flag that tells the two apart.
        if let error = error as NSError?,
           let finished = error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool {
            isUsable = finished
        }
        if !isUsable {
            RecordingLog.warn("survey clip failed: \(error?.localizedDescription ?? "unbekannt")")
            try? FileManager.default.removeItem(at: outputFileURL)
        }
        finishClip(with: isUsable ? outputFileURL : nil)
    }
}

/// Retained by ``SurveyCamera`` for exactly as long as one capture is in flight.
private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: @Sendable (Result<Data, Error>) -> Void
    private let hasFinished = OSAllocatedUnfairLock(initialState: false)

    init(completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        self.completion = completion
        super.init()
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            finish(with: .failure(error))
        } else if let data = photo.fileDataRepresentation() {
            finish(with: .success(data))
        } else {
            finish(with: .failure(SurveyCameraError.noImageData))
        }
    }

    /// The last callback of every capture, successful or not. It is the safety net that
    /// keeps a caller from awaiting a photo that will never arrive; once the photo has been
    /// delivered it does nothing.
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        finish(with: .failure(error ?? SurveyCameraError.noImageData))
    }

    private func finish(with result: Result<Data, Error>) {
        let wasFinished = hasFinished.withLock { finished -> Bool in
            let previous = finished
            finished = true
            return previous
        }
        guard !wasFinished else { return }
        completion(result)
    }
}

enum SurveyCameraError: Error, LocalizedError {
    case noCamera
    case cannotConfigure
    case notReady
    case noImageData

    var errorDescription: String? {
        switch self {
        case .noCamera: String(localized: "Keine Kamera verfügbar.")
        case .cannotConfigure: String(localized: "Die Kamera konnte nicht konfiguriert werden.")
        case .notReady: String(localized: "Die Kamera ist noch nicht bereit.")
        case .noImageData: String(localized: "Das Foto konnte nicht gesichert werden.")
        }
    }
}
