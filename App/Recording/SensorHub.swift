import AVFoundation
import CoreLocation
import Foundation
import Observation
import SensorstormCore
import SwiftUI
import UIKit

/// The one object the UI talks to.
///
/// It owns every sensor source, the sink they all write into, and the recording lifecycle.
/// Sources run continuously while the record screen is up — that is what feeds the live
/// dashboard — and starting a recording simply hands the sink a set of writers. Nothing
/// has to be restarted, so the first sample of a recording is the very next sample the
/// hardware produces, not one settling period later.
@MainActor
@Observable
final class SensorHub {
    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case finishing
    }

    private(set) var phase: Phase = .idle
    private(set) var live: [SensorID: LiveSample] = [:]
    private(set) var availableSensors: Set<SensorID> = []
    private(set) var elapsed: TimeInterval = 0
    private(set) var writtenSampleCount = 0
    private(set) var isMonitoring = false
    private(set) var annotations: [Annotation] = []
    private(set) var lastFinishedRecording: RecordingMetadata?
    var errorMessage: String?

    var settings: RecordingSettings {
        didSet {
            guard settings != oldValue else { return }
            SettingsStore.save(settings)
            if isMonitoring, phase == .idle {
                restartMonitoring()
            }
        }
    }

    let sink = SampleSink()
    let store: RecordingStore
    let videoRecorder: VideoRecorder

    private let motionSource: MotionSource
    private let locationSource: LocationSource
    private let audioSource: AudioSource
    private let deviceStateSource: DeviceStateSource
    private let syntheticSource: SyntheticSource?

    private var displayTimer: Timer?
    private var activeRecording: ActiveRecording?
    /// Sensors the synthetic source is allowed to stand in for — empty on real hardware.
    private var syntheticSensors: Set<SensorID> = []

    private struct ActiveRecording {
        let id: UUID
        let directory: URL
        let startHostTime: Double
        let startedAt: Date
        let wallToHostOffset: Double
        let settings: RecordingSettings
        var writesAudioFile: Bool
    }

    init(store: RecordingStore) {
        self.store = store
        self.settings = SettingsStore.load()

        let sink = self.sink
        self.videoRecorder = VideoRecorder(sink: sink)
        self.motionSource = MotionSource(sink: sink)
        self.locationSource = LocationSource(sink: sink)
        self.audioSource = AudioSource(sink: sink)
        self.deviceStateSource = DeviceStateSource(sink: sink)

        #if targetEnvironment(simulator)
        self.syntheticSource = SyntheticSource(sink: sink)
        #else
        self.syntheticSource = nil
        #endif

        refreshAvailability()
    }

    // MARK: - Availability

    /// Sensors this device can deliver. On the Simulator the synthetic source stands in for
    /// the missing hardware — but only for sensors no real source provides. Two sources
    /// feeding one stream would interleave two different signals and, worse, produce
    /// non-monotonic timestamps, which the reader's binary search relies on.
    func refreshAvailability() {
        let real = motionSource.availableSensors
            .union(locationSource.availableSensors)
            .union(audioSource.availableSensors)
            .union(deviceStateSource.availableSensors)

        syntheticSensors = syntheticSource.map { $0.availableSensors.subtracting(real) } ?? []
        availableSensors = real.union(syntheticSensors)
    }

    func isAvailable(_ sensor: SensorID) -> Bool {
        availableSensors.contains(sensor)
    }

    var isCameraAvailable: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        VideoRecorder.hasCamera
        #endif
    }

    var locationAuthorization: CLAuthorizationStatus { locationSource.authorizationStatus }

    // MARK: - Permissions

    /// Asks for everything the current settings need, in one go, before the first recording.
    func requestPermissions() async {
        if settings.isEnabled(.location) || settings.isEnabled(.compass) {
            locationSource.requestAuthorization()
        }
        if settings.isEnabled(.loudness) || settings.recordsAudio {
            _ = await AudioSource.requestMicrophoneAccess()
        }
        if settings.isVideoEnabled, VideoRecorder.cameraAuthorizationStatus == .notDetermined {
            _ = await VideoRecorder.requestCameraAccess()
        }
        refreshAvailability()
    }

    // MARK: - Monitoring

    /// Starts every enabled source without writing anything — the live dashboard.
    func startMonitoring() async {
        guard !isMonitoring else { return }
        isMonitoring = true

        await startSources(for: settings)
        startDisplayTimer()
    }

    func stopMonitoring() {
        guard isMonitoring, phase == .idle else { return }
        isMonitoring = false
        stopSources()
        stopDisplayTimer()
        live = [:]
    }

    private func restartMonitoring() {
        guard phase == .idle else { return }
        stopSources()
        Task { await startSources(for: settings) }
    }

    private func startSources(for settings: RecordingSettings) async {
        let offset = HostClock.wallToHostOffset
        let wanted = settings.enabledSensors

        locationSource.onAuthorizationChange = { [weak self] _ in
            Task { @MainActor in self?.refreshAvailability() }
        }

        motionSource.usesTrueNorthReference = locationSource.isAuthorized
        motionSource.start(sensors: wanted, rateHz: settings.motionRateHz, wallToHostOffset: offset)
        locationSource.start(sensors: wanted, rateHz: settings.motionRateHz, wallToHostOffset: offset)
        deviceStateSource.start(sensors: wanted)
        syntheticSource?.start(sensors: wanted.intersection(syntheticSensors),
                               rateHz: settings.motionRateHz, wallToHostOffset: offset)

        if settings.isVideoEnabled, isCameraAvailable {
            await configureCamera(for: settings)
        } else if wanted.contains(.loudness) {
            startAudioMetering()
        }

        sink.clearLive(except: wanted)
    }

    private func configureCamera(for settings: RecordingSettings) async {
        do {
            try await videoRecorder.configure(
                mode: settings.videoMode,
                quality: settings.videoQuality,
                includeAudio: settings.recordsAudio || settings.isEnabled(.loudness),
                measuresLoudness: settings.isEnabled(.loudness)
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startAudioMetering() {
        do {
            try audioSource.start(fileURL: nil)
        } catch {
            RecordingLog.warn("audio metering unavailable: \(error.localizedDescription)")
        }
    }

    private func stopSources() {
        motionSource.stop()
        locationSource.stop()
        deviceStateSource.stop()
        syntheticSource?.stop()
        _ = audioSource.stop()
        videoRecorder.teardown()
    }

    // MARK: - Recording

    func startRecording() async {
        guard phase == .idle else { return }
        phase = .starting
        errorMessage = nil
        annotations = []

        await requestPermissions()
        if !isMonitoring {
            await startMonitoring()
        }

        let id = UUID()
        let recordingSettings = settings

        do {
            let directory = try store.prepareDirectory(for: id)
            let offset = HostClock.wallToHostOffset

            var writers: [SensorID: StreamWriter] = [:]
            for sensor in recordingSettings.enabledSensors.sorted(by: { $0.rawValue < $1.rawValue })
            where availableSensors.contains(sensor) {
                let descriptor = sensor.descriptor
                writers[sensor] = try StreamWriter(sensor: sensor,
                                                   channelCount: descriptor.channelCount,
                                                   directory: directory)
            }

            var writesAudioFile = false
            if recordingSettings.isVideoEnabled, isCameraAvailable {
                if !videoRecorder.isConfigured {
                    await configureCamera(for: recordingSettings)
                }
                try videoRecorder.startWriting(
                    to: directory.appendingPathComponent(RecordingStore.videoFileName))
            } else if recordingSettings.recordsAudio, recordingSettings.isEnabled(.loudness) {
                // Metering is already running; restart it so the same tap also writes a file.
                _ = audioSource.stop()
                try audioSource.start(fileURL: directory.appendingPathComponent("audio.m4a"))
                writesAudioFile = true
            }

            // Arm the writers last: from this instant on, every sample is part of the file.
            let startHostTime = HostClock.now
            sink.beginRecording(writers: writers)

            activeRecording = ActiveRecording(id: id, directory: directory,
                                              startHostTime: startHostTime,
                                              startedAt: Date(),
                                              wallToHostOffset: offset,
                                              settings: recordingSettings,
                                              writesAudioFile: writesAudioFile)

            locationSource.setBackgroundUpdates(true)
            UIApplication.shared.isIdleTimerDisabled = recordingSettings.keepsScreenAwake
            elapsed = 0
            phase = .recording
        } catch {
            errorMessage = error.localizedDescription
            _ = sink.endRecording()
            try? store.delete(id)
            phase = .idle
        }
    }

    @discardableResult
    func stopRecording() async -> RecordingMetadata? {
        guard phase == .recording, let active = activeRecording else { return nil }
        phase = .finishing

        let videoInfo: VideoInfo?
        if active.settings.isVideoEnabled, isCameraAvailable {
            videoInfo = await videoRecorder.finishWriting()
        } else {
            videoInfo = nil
        }

        var audioInfo: AudioInfo?
        if active.writesAudioFile {
            audioInfo = audioSource.stop()
            if active.settings.isEnabled(.loudness) {
                startAudioMetering()  // back to plain metering for the live view
            }
        }

        let streams = sink.endRecording()
        let duration = HostClock.now - active.startHostTime

        var metadata = RecordingMetadata(
            id: active.id,
            name: Self.defaultName(for: active.startedAt),
            startedAt: active.startedAt,
            startHostTime: active.startHostTime,
            duration: duration,
            device: Self.deviceInfo(),
            streams: streams.filter { $0.sampleCount > 0 },
            video: videoInfo,
            audio: audioInfo,
            requestedRateHz: active.settings.motionRateHz
        )

        locationSource.setBackgroundUpdates(false)
        UIApplication.shared.isIdleTimerDisabled = false

        do {
            try store.save(metadata)
            try store.saveAnnotations(annotations, for: active.id)
        } catch {
            errorMessage = error.localizedDescription
        }

        // A recording where nothing was captured is noise in the library.
        if metadata.streams.isEmpty, metadata.video == nil, metadata.audio == nil {
            try? store.delete(active.id)
            metadata.name = ""
            activeRecording = nil
            phase = .idle
            errorMessage = String(localized: "Es wurden keine Daten aufgezeichnet.")
            return nil
        }

        activeRecording = nil
        lastFinishedRecording = metadata
        elapsed = 0
        writtenSampleCount = 0
        phase = .idle
        return metadata
    }

    // MARK: - Annotations

    func addAnnotation(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        annotations.append(Annotation(hostTime: HostClock.now, text: trimmed))
    }

    // MARK: - Display refresh

    /// The UI reads the sink at 10 Hz. Pushing every sample into `@Observable` state would
    /// mean thousands of view invalidations per second for no visible gain.
    private func startDisplayTimer() {
        stopDisplayTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLiveValues() }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func refreshLiveValues() {
        live = sink.snapshot()
        if let active = activeRecording, phase == .recording {
            elapsed = HostClock.now - active.startHostTime
            writtenSampleCount = sink.writtenSampleCount
        }
    }

    // MARK: - Helpers

    static func defaultName(for date: Date) -> String {
        date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    static func deviceInfo() -> DeviceInfo {
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return DeviceInfo(model: UIDevice.current.modelIdentifier,
                          systemName: UIDevice.current.systemName,
                          systemVersion: UIDevice.current.systemVersion,
                          appVersion: "\(version) (\(build))")
    }
}

extension UIDevice {
    /// `iPhone17,1` rather than "iPhone" — the marketing name is useless for reproducing a
    /// measurement.
    var modelIdentifier: String {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "Simulator"
        #else
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        #endif
    }
}
