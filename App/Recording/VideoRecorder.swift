import AVFoundation
import Foundation
import SensorstormCore
import os

/// Camera and microphone capture, written with `AVAssetWriter` rather than
/// `AVCaptureMovieFileOutput`.
///
/// The reason is the whole point of the app: a movie file output tells you *that* it
/// started, not *when*. Going through the writer means we see every sample buffer's
/// presentation timestamp, which sits on the capture session's synchronisation clock —
/// the host clock, the same one CoreMotion stamps its samples with. Storing the first
/// frame's timestamp therefore aligns video and sensors to well under one frame, with no
/// calibration step and no drift.
///
/// Video stabilisation is deliberately off: it decouples the image from the IMU and would
/// quietly invalidate any analysis that correlates the two.
final class VideoRecorder: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()

    private let sink: SampleSink
    private let sessionQueue = DispatchQueue(label: "ch.sensorstorm.capture.session")
    private let outputQueue = DispatchQueue(label: "ch.sensorstorm.capture.output")

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    // Writer state — only ever touched on `outputQueue`.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var hasStartedSession = false
    private var firstVideoHostTime: Double?
    private var lastVideoHostTime: Double?
    private var writesAudio = false

    /// Shared between the session queue, the output queue and `async` callers.
    /// `OSAllocatedUnfairLock` rather than `NSLock` because the latter is unavailable from
    /// asynchronous contexts.
    private struct State {
        var isConfigured = false
        var isFrontCamera = false
        var measuresLoudness = false
        var width = 0
        var height = 0
        var frameRate: Double = 30
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(sink: SampleSink) {
        self.sink = sink
        super.init()
    }

    // MARK: - Authorisation

    static var isCameraAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    static var cameraAuthorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    static func requestCameraAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    static var hasCamera: Bool {
        !AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        ).devices.isEmpty
    }

    var isConfigured: Bool {
        state.withLock { $0.isConfigured }
    }

    // MARK: - Session lifecycle

    func configure(mode: VideoMode, quality: VideoQuality,
                   includeAudio: Bool, measuresLoudness: Bool) async throws {
        guard mode != .off else { return }

        state.withLock {
            $0.isFrontCamera = mode.isFront
            $0.measuresLoudness = measuresLoudness
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                do {
                    try configureSession(mode: mode, quality: quality, includeAudio: includeAudio)
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
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            session.commitConfiguration()
            state.withLock { $0.isConfigured = false }
        }
    }

    private func configureSession(mode: VideoMode, quality: VideoQuality,
                                  includeAudio: Bool) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        let preset: AVCaptureSession.Preset = switch quality {
        case .hd720: .hd1280x720
        case .hd1080: .hd1920x1080
        case .uhd4k: .hd4K3840x2160
        }
        session.sessionPreset = session.canSetSessionPreset(preset) ? preset : .high

        let position: AVCaptureDevice.Position = mode.isFront ? .front : .back
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            throw VideoRecorderError.noCamera
        }
        session.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(videoOutput) else { throw VideoRecorderError.cannotAddOutput }
        session.addOutput(videoOutput)

        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
            // The recorded file is never mirrored: mirroring would flip the image's
            // relationship to the accelerometer axes.
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }

        if includeAudio,
           let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioDeviceInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioDeviceInput) {
            session.addInput(audioDeviceInput)
            audioOutput.setSampleBufferDelegate(self, queue: outputQueue)
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
            }
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let frameRate = device.activeVideoMinFrameDuration.timescale > 0
            ? Double(device.activeVideoMinFrameDuration.timescale)
                / Double(device.activeVideoMinFrameDuration.value)
            : 30

        state.withLock {
            $0.width = Int(dimensions.width)
            $0.height = Int(dimensions.height)
            $0.frameRate = frameRate
        }
    }

    // MARK: - Writing

    func startWriting(to url: URL) throws {
        var setupError: Error?
        outputQueue.sync {
            do {
                try? FileManager.default.removeItem(at: url)
                let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

                let videoSettings = videoOutput.recommendedVideoSettingsForAssetWriter(writingTo: .mov)
                let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                videoInput.expectsMediaDataInRealTime = true
                guard writer.canAdd(videoInput) else { throw VideoRecorderError.cannotAddOutput }
                writer.add(videoInput)

                var audioInput: AVAssetWriterInput?
                if session.outputs.contains(audioOutput) {
                    let audioSettings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov)
                    let input = AVAssetWriterInput(mediaType: .audio,
                                                   outputSettings: audioSettings)
                    input.expectsMediaDataInRealTime = true
                    if writer.canAdd(input) {
                        writer.add(input)
                        audioInput = input
                    }
                }

                self.writer = writer
                self.videoInput = videoInput
                self.audioInput = audioInput
                self.writesAudio = audioInput != nil
                self.hasStartedSession = false
                self.firstVideoHostTime = nil
                self.lastVideoHostTime = nil
            } catch {
                setupError = error
            }
        }
        if let setupError { throw setupError }
    }

    /// Finishes the movie and returns everything the metadata needs, including the exact
    /// host time of the first frame.
    func finishWriting() async -> VideoInfo? {
        let pending: (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInput?, Double, Double)? =
            outputQueue.sync {
                guard let writer, let videoInput, let start = firstVideoHostTime,
                      let last = lastVideoHostTime, writer.status == .writing else {
                    self.writer?.cancelWriting()
                    self.writer = nil
                    self.videoInput = nil
                    self.audioInput = nil
                    return nil
                }
                self.writer = nil
                self.videoInput = nil
                let audio = self.audioInput
                self.audioInput = nil
                self.hasStartedSession = false
                return (writer, videoInput, audio, start, last)
            }

        guard let (writer, videoInput, audioInput, start, last) = pending else { return nil }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else {
            RecordingLog.error("video writer failed: \(writer.error?.localizedDescription ?? "unknown")")
            return nil
        }

        let current = state.withLock { $0 }

        return VideoInfo(fileName: writer.outputURL.lastPathComponent,
                         startHostTime: start,
                         duration: max(last - start, 0),
                         width: current.width,
                         height: current.height,
                         nominalFrameRate: current.frameRate,
                         hasAudio: audioInput != nil,
                         isFrontCamera: current.isFrontCamera)
    }

    /// Converts a capture timestamp onto the host clock. In practice the capture session
    /// already runs on the host clock, but converting explicitly costs nothing and keeps
    /// the alignment correct if that ever changes.
    private func hostTime(for presentationTime: CMTime) -> Double {
        let hostClock = CMClockGetHostTimeClock()
        guard let clock = session.synchronizationClock, clock !== hostClock else {
            return presentationTime.seconds
        }
        return CMSyncConvertTime(presentationTime, from: clock, to: hostClock).seconds
    }
}

// MARK: - Sample delivery

extension VideoRecorder: AVCaptureVideoDataOutputSampleBufferDelegate,
                         AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if output === audioOutput {
            let measures = state.withLock { $0.measuresLoudness }
            if measures, let level = AudioLevelMeter.level(from: sampleBuffer) {
                sink.ingest(.loudness, time: hostTime(for: presentationTime),
                            values: [level.average, level.peak])
            }
        }

        guard let writer else { return }

        if writer.status == .unknown {
            guard output === videoOutput else { return }  // start the file on a video frame
            guard writer.startWriting() else {
                RecordingLog.error("video writer refused to start: \(writer.error?.localizedDescription ?? "?")")
                self.writer = nil
                return
            }
            writer.startSession(atSourceTime: presentationTime)
            hasStartedSession = true
            firstVideoHostTime = hostTime(for: presentationTime)
        }

        guard writer.status == .writing, hasStartedSession else { return }

        if output === videoOutput {
            guard let videoInput, videoInput.isReadyForMoreMediaData else { return }
            videoInput.append(sampleBuffer)
            lastVideoHostTime = hostTime(for: presentationTime)
        } else if output === audioOutput {
            guard let audioInput, audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sampleBuffer)
        }
    }
}

enum VideoRecorderError: Error, LocalizedError {
    case noCamera
    case cannotAddOutput
    case notAuthorized

    var errorDescription: String? {
        switch self {
        case .noCamera: String(localized: "Keine Kamera verfügbar.")
        case .cannotAddOutput: String(localized: "Die Kamera konnte nicht konfiguriert werden.")
        case .notAuthorized: String(localized: "Kein Zugriff auf die Kamera.")
        }
    }
}
