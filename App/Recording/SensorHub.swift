import AVFoundation
import CoreLocation
import Foundation
import Observation
import SensorstormCore
import SwiftUI
import UIKit
import UserNotifications

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

    private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { updateEventRecorder() } }
    }
    /// Result of the network-time measurement for the running recording, if one was asked
    /// for and finished in time. Stored, never applied.
    private var timeReference: TimeReference?
    private(set) var live: [SensorID: LiveSample] = [:]
    /// Streams that are not the device's own sensors, newest reading each — Bluetooth
    /// devices, network measurements. Sorted by title so the tiles do not jump around.
    private(set) var externalLive: [LiveExternalSample] = []
    private(set) var availableSensors: Set<SensorID> = []
    /// Only the approximate location is allowed. Refreshed with the availability, which is
    /// what an authorisation change triggers.
    private(set) var isLocationAccuracyReduced = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var writtenSampleCount = 0
    private(set) var isMonitoring = false {
        didSet { if isMonitoring != oldValue { updateEventRecorder() } }
    }
    private(set) var annotations: [Annotation] = []
    private(set) var lastFinishedRecording: RecordingMetadata?
    var errorMessage: String?

    /// Events the event recorder saved since launch, and whether it is writing one now.
    private(set) var eventsSaved = 0
    private(set) var isCapturingEvent = false

    /// The phone as a Bluetooth sensor, and a second phone seen from this one. Both are
    /// switched on in the settings and do nothing until then.
    private(set) var bluetoothServiceSubscribers = 0
    private(set) var peers: [PeerLink.Peer] = []
    private(set) var peerStatus: PeerLink.Status = .idle
    private(set) var peerConnection: PeerLink.Connection? {
        didSet {
            // A phone just connected: swap ultra-wideband tokens if that was asked for.
            guard peerConnection != nil, oldValue == nil, settings.isOn(.uwb),
                  let token = nearbyLink.prepare() else { return }
            peerLink.exchangeNearbyToken(token)
        }
    }

    var settings: RecordingSettings {
        didSet {
            guard settings != oldValue else { return }
            SettingsStore.save(settings)
            // Show/hide and collapse are display state and must not disturb the hardware.
            if isMonitoring, phase == .idle, settings.affectsCapture(comparedTo: oldValue) {
                restartMonitoring()
            } else if !settings.hasSameBluetoothSubscriptions(as: oldValue) {
                // No restart: choosing a characteristic in the explorer must not tear down the
                // very connection it is looking at.
                configureBluetoothDecoding(for: settings)
            }
            updateWebServer()
            updatePeripheral()
            updateEventRecorder()
        }
    }

    /// Evaluated ten times a second while a recording runs. See ``RuleEngine``.
    var rules: [Rule] {
        didSet { RuleStore.save(rules) }
    }
    /// What the rules did and which messages arrived, newest first, for the running or
    /// last recording.
    private(set) var ruleLog: [RuleLogEntry] = []
    private var ruleEngine = RuleEngine()
    /// MQTT messages since the last evaluation.
    private var inbox: [(topic: String, payload: String)] = []

    let sink = SampleSink()
    let store: RecordingStore
    let videoRecorder: VideoRecorder
    let poseRecorder: ARPoseRecorder

    private let motionSource: MotionSource
    private let locationSource: LocationSource
    private let audioSource: AudioSource
    private let deviceStateSource: DeviceStateSource
    private let activitySource: ActivitySource
    let bluetoothSource: BluetoothSource
    private let networkQualitySource: NetworkQualitySource
    private let extraSources: ExtraSourcesController
    private let peripheralService = BLEPeripheralService()
    private let eventRecorder: EventRecorder
    private let nearbyLink: NearbyLink
    let peerLink: PeerLink
    private let watchLink: WatchLink
    let streamer: LiveStreamer
    let webServer: LocalWebServer
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
        /// Frozen at start: the engine that owns the camera for this run must not change
        /// underneath `stopRecording()` if the setting is toggled mid-recording.
        let engine: CaptureEngine
    }

    init(store: RecordingStore) {
        self.store = store
        self.settings = SettingsStore.load()
        self.rules = RuleStore.load()

        let sink = self.sink
        self.videoRecorder = VideoRecorder(sink: sink)
        self.poseRecorder = ARPoseRecorder(sink: sink)
        self.motionSource = MotionSource(sink: sink)
        self.locationSource = LocationSource(sink: sink)
        self.audioSource = AudioSource(sink: sink)
        self.deviceStateSource = DeviceStateSource(sink: sink)
        self.activitySource = ActivitySource(sink: sink)
        self.bluetoothSource = BluetoothSource(sink: sink)
        self.networkQualitySource = NetworkQualitySource(sink: sink)
        self.extraSources = ExtraSourcesController(sink: sink)
        self.peerLink = PeerLink(sink: sink)
        self.eventRecorder = EventRecorder(store: store, device: Self.deviceInfo())
        self.nearbyLink = NearbyLink(sink: sink)
        self.watchLink = WatchLink(sink: sink)
        // Identifies this phone to the user's own endpoint, nothing else. `identifierForVendor`
        // is scoped to this vendor and resets when the last of their apps is uninstalled —
        // which is exactly as much identity as a live feed needs.
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        self.streamer = LiveStreamer(deviceId: deviceId)
        // The newest value of every running stream, in the push payload's shape.
        self.webServer = LocalWebServer {
            let now = HostClock.now
            let batch = sink.snapshot()
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { (sensor: $0.key, time: $0.value.hostTime, values: $0.value.values) }
            return LiveStreamer.payload(batch, messageId: 0, sessionId: "live", deviceId: deviceId,
                                        hostToEpoch: Date().timeIntervalSince1970 - now)
        }

        #if targetEnvironment(simulator)
        self.syntheticSource = SyntheticSource(sink: sink)
        #else
        self.syntheticSource = nil
        #endif

        watchLink.onReachabilityChange = { [weak self] in
            Task { @MainActor in self?.refreshAvailability() }
        }
        watchLink.onCommand = { [weak self] command in
            Task { @MainActor in await self?.handleWatchCommand(command) }
        }
        watchLink.activate()
        eventRecorder.onSaved = { [weak self] _ in
            Task { @MainActor in self?.eventsSaved += 1 }
        }
        eventRecorder.onCapturing = { [weak self] capturing in
            Task { @MainActor in self?.isCapturingEvent = capturing }
        }
        let recorder = eventRecorder
        sink.setObserver { sensor, time, values in recorder.observe(sensor, time: time, values: values) }
        peripheralService.onControl = { [weak self] command in
            Task { @MainActor in await self?.handleRemoteCommand(command) }
        }
        peripheralService.onSubscribers = { [weak self] count in
            Task { @MainActor in self?.bluetoothServiceSubscribers = count }
        }
        peerLink.onPeers = { [weak self] peers in
            Task { @MainActor in self?.peers = peers }
        }
        peerLink.onStatus = { [weak self] status in
            Task { @MainActor in self?.peerStatus = status }
        }
        peerLink.onConnection = { [weak self] connection in
            Task { @MainActor in self?.peerConnection = connection }
        }
        peerLink.onNearbyToken = { [weak self] token in
            Task { @MainActor in self?.startNearby(with: token) }
        }
        peripheralService.onNearbyToken = { [weak self] token in
            Task { @MainActor in self?.startNearby(with: token) }
        }
        streamer.mqtt.onMessage = { [weak self] topic, payload in
            Task { @MainActor in self?.receive(topic: topic, payload: payload) }
        }
        refreshAvailability()
        updateWebServer()
        updatePeripheral()
        updateEventRecorder()
    }

    // MARK: - Web server

    /// Tells the watch and anyone subscribed over Bluetooth whether this phone is recording.
    private func announce(isRecording: Bool, since: Date? = nil, hostTime: Double = 0) {
        watchLink.publishStatus(isRecording: isRecording, since: since)
        peripheralService.publishState(isRecording: isRecording, since: hostTime)
    }

    /// Armed while the sensors are running for the dashboard and nothing is being recorded;
    /// during a recording the recording is the record.
    private func updateEventRecorder() {
        let active = isMonitoring && phase == .idle
        eventRecorder.configure(active ? settings.eventConfiguration : nil)
    }

    private func startNearby(with token: Data) {
        guard settings.isOn(.uwb) else { return }
        nearbyLink.start(peerToken: token, name: peerConnection?.name ?? "iPhone")
    }

    private func updatePeripheral() {
        watchLink.setFastRate(settings.isOn(.watchFast))
        peripheralService.setNearbyToken(settings.offersBluetoothService && settings.isOn(.uwb)
                                         ? nearbyLink.prepare() : nil)
        if settings.offersBluetoothService {
            peripheralService.start(allowsControl: settings.allowsBluetoothControl)
        } else {
            peripheralService.stop()
        }
    }

    private func handleRemoteCommand(_ command: BLEPeripheralService.Command) async {
        switch command {
        case .start: await handleWatchCommand("start")
        case .stop: await handleWatchCommand("stop")
        case .mark: await handleWatchCommand("mark")
        }
    }

    private func updateWebServer() {
        if settings.isWebServerEnabled == true { webServer.start() } else { webServer.stop() }
    }

    // MARK: - Bluetooth sensors

    var bluetoothReadings: [BluetoothSource.DeviceReading] { bluetoothSource.latestReadings }
    var connectableBluetoothDevices: [BluetoothSource.Connectable] { bluetoothSource.connectableDevices }

    /// After a decoder file was added or removed. Takes effect on the next advertisement,
    /// without restarting the scan.
    func reloadBluetoothDecoders() {
        configureBluetoothDecoding(for: settings)
    }

    private func configureBluetoothDecoding(for settings: RecordingSettings) {
        bluetoothSource.configureDecoding(enabled: settings.decodesBluetoothSensors,
                                          decoders: settings.decodesBluetoothSensors ? DecoderLibrary.load() : [],
                                          paired: settings.pairedBluetoothDevices ?? [],
                                          subscriptions: settings.gattSubscriptions ?? [])
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
            .union(activitySource.availableSensors)
            .union(bluetoothSource.availableSensors)
            .union(watchLink.availableSensors)

        syntheticSensors = syntheticSource.map { $0.availableSensors.subtracting(real) } ?? []
        var all = real.union(syntheticSensors)
        // Written by the camera path rather than by a sensor source, so it is available
        // exactly when there is a camera to write it.
        if isCameraAvailable { all.insert(.cameraPose) }
        availableSensors = all
        isLocationAccuracyReduced = locationSource.isAccuracyReduced
    }

    /// The streams a recording should write: what the user armed, minus the ones the user
    /// does not control, plus whatever the active capture engine contributes itself.
    private func streamsToWrite(for settings: RecordingSettings) -> Set<SensorID> {
        var wanted = settings.enabledSensors.subtracting(SensorID.engineControlled)
        if settings.isVideoEnabled, isCameraAvailable || usesARKit(for: settings) {
            wanted.insert(.cameraPose)
        }
        return wanted.intersection(availableSensors)
    }

    func isAvailable(_ sensor: SensorID) -> Bool {
        availableSensors.contains(sensor)
    }

    /// Why a stream is silent, and what can be done about it — the long form of
    /// ``isAvailable(_:)``.
    ///
    /// Order matters. The watch streams are absent for a reason the hardware check cannot
    /// express, and a permission that was refused leaves the hardware perfectly present, so
    /// „unsupported" has to be the last answer rather than the first.
    func status(for sensor: SensorID) -> SensorStatus {
        if SensorID.watchProvided.contains(sensor) {
            if let gap = watchLink.gap { return .needsWatch(gap) }
            return .ready
        }
        if syntheticSensors.contains(sensor) { return .simulated }

        let permission = SensorPermission.required(for: sensor)
        let permissionState = permission?.state

        // A refused permission is never a missing sensor, whatever the hardware probe says.
        if case .refused = permissionState, let permission { return .permissionRefused(permission) }

        // Core Motion answers its capability questions *through* the permission:
        // `CMPedometer.isStepCountingAvailable()` and `CMAltimeter.isRelativeAltitudeAvailable()`
        // both go false once „Bewegung & Fitness" is off. Asking the hardware first would
        // therefore tell a phone with a perfectly good barometer that it has no barometer —
        // the exact wrong sentence this whole type exists to stop.
        if case .missing = permissionState, permission == .motion { return .permissionMissing(.motion) }

        guard availableSensors.contains(sensor) else { return .unsupported }

        if case .missing = permissionState, let permission { return .permissionMissing(permission) }
        return .ready
    }

    /// Asks for one permission and redraws against the answer.
    ///
    /// Only ever called from a row the user tapped, which is the difference between this
    /// and ``requestPermissions()``: that one asks for everything a recording is about to
    /// need, this one asks for the single thing someone just pointed at.
    func requestPermission(_ permission: SensorPermission) async {
        switch permission {
        case .motion: await activitySource.requestAuthorization()
        case .location: locationSource.requestAuthorization()
        case .microphone: _ = await AudioSource.requestMicrophoneAccess()
        case .bluetooth: await bluetoothSource.requestAuthorization()
        }
        refreshAvailability()
    }

    var isCameraAvailable: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        VideoRecorder.hasCamera
        #endif
    }

    var isARKitAvailable: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        ARPoseRecorder.isSupported
        #endif
    }

    /// ARKit without a compass reading produces a world rotated by an unknown amount instead
    /// of one rotated by a few degrees — worth saying out loud before a recording, not after.
    var canAlignARKitToNorth: Bool {
        isARKitAvailable && ARPoseRecorder.canAlignToHeading && locationSource.isAuthorized
    }

    var locationAuthorization: CLAuthorizationStatus { locationSource.authorizationStatus }

    /// Makes the here-and-now the barometer's zero. The stream keeps running; only the
    /// `relativeAltitude` column shifts, and what was subtracted is written into the
    /// recording's metadata so an absolute pressure stays recoverable.
    func zeroBarometer() {
        motionSource.resetBarometerReference()
    }

    /// The recording currently being written, if any. The survey add-on stamps it onto every
    /// finding, which is what lets a photo of a pothole be lined up with the accelerometer
    /// trace of driving over it.
    var activeRecordingID: UUID? {
        phase == .recording ? activeRecording?.id : nil
    }

    // MARK: - Permissions

    /// Asks for everything the current settings need, in one go, before the first recording.
    func requestPermissions() async {
        if settings.isEnabled(.location) || settings.isEnabled(.compass) {
            locationSource.requestAuthorization()
        }
        if settings.isEnabled(.loudness) || settings.isEnabled(.loudnessA) || settings.recordsAudio {
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
        activitySource.start(sensors: wanted)
        configureBluetoothDecoding(for: settings)
        bluetoothSource.start(sensors: wanted)
        watchLink.start(sensors: wanted, wallToHostOffset: offset)
        syntheticSource?.start(sensors: wanted.intersection(syntheticSensors),
                               rateHz: settings.motionRateHz, wallToHostOffset: offset)

        if usesARKit(for: settings) {
            poseRecorder.recordsLight = settings.isOn(.cameraLight)
            poseRecorder.recordsDepth = settings.isOn(.depth)
            poseRecorder.start(quality: settings.videoQuality)
            // ARKit owns the camera and delivers no audio, so metering has to come from the
            // microphone tap rather than from a capture session's audio output.
            if wanted.contains(.loudness) || wanted.contains(.loudnessA) || settings.recordsAudio || settings.needsMicrophoneExtras {
                startAudioMetering()
            }
        } else if settings.isVideoEnabled, isCameraAvailable {
            await configureCamera(for: settings)
        } else {
            // No camera in play — either it was never wanted or this device has none. Either
            // way the microphone is the only thing left that can meter, and skipping it here
            // used to leave the loudness tile permanently blank with no explanation.
            if settings.isVideoEnabled {
                errorMessage = String(localized: "Keine Kamera verfügbar. Es werden nur Sensordaten aufgezeichnet.")
            }
            if wanted.contains(.loudness) || wanted.contains(.loudnessA) || settings.recordsAudio || settings.needsMicrophoneExtras {
                startAudioMetering()
            }
        }

        sink.clearLive(except: wanted)
    }

    /// Whether this run should use ARKit, taking availability into account rather than just
    /// the setting.
    func usesARKit(for settings: RecordingSettings) -> Bool {
        settings.usesARKit && isARKitAvailable
    }

    private func configureCamera(for settings: RecordingSettings) async {
        do {
            try await videoRecorder.configure(
                mode: settings.videoMode,
                quality: settings.videoQuality,
                includeAudio: settings.recordsAudio || settings.isEnabled(.loudness) || settings.isEnabled(.loudnessA),
                measuresLoudness: settings.isEnabled(.loudness),
                measuresWeighted: settings.isEnabled(.loudnessA)
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// What the microphone tap does besides the level, from the settings in force. Set before
    /// every `start`, because the tap is rebuilt whenever a recording begins or ends.
    private func configureAudioExtras(_ settings: RecordingSettings) {
        audioSource.computesWeighted = settings.isEnabled(.loudnessA)
        audioSource.computesSpectrum = settings.isOn(.spectrum)
        // An `if`, not a ternary: a closure on one side and `nil` on the other makes the
        // compiler give up on the type.
        if settings.isOn(.soundClasses) {
            audioSource.onSoundClass = { [weak self] time, label, confidence in
                Task { @MainActor in self?.noteSound(time: time, label: label, confidence: confidence) }
            }
        } else {
            audioSource.onSoundClass = nil
        }
    }

    /// A heard sound becomes a note on the recording's timeline, at the moment it was heard.
    private func noteSound(time: Double, label: String, confidence: Double) {
        guard phase == .recording else { return }
        let percent = Int((confidence * 100).rounded())
        annotations.append(Annotation(hostTime: time,
                                      text: String(localized: "Geräusch: \(label) (\(percent) %)")))
    }

    private func startAudioMetering() {
        configureAudioExtras(settings)
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
        activitySource.stop()
        bluetoothSource.stop()
        watchLink.stop()
        syntheticSource?.stop()
        _ = audioSource.stop()
        videoRecorder.teardown()
        poseRecorder.stop()
    }

    // MARK: - Recording

    func startRecording() async {
        guard phase == .idle else { return }
        phase = .starting
        errorMessage = nil
        annotations = []
        ruleLog = []
        ruleEngine = RuleEngine()
        inbox = []
        // Spikes from the minutes the dashboard was open before the start are not this
        // recording's business.
        _ = sink.drainExtremes()
        _ = sink.drainExternalExtremes()
        await requestNotificationPermissionIfNeeded()

        await requestPermissions()
        if !isMonitoring {
            await startMonitoring()
        }

        // 4K video plus 400 Hz across a dozen streams fills a device faster than anyone
        // expects. Refusing up front beats a truncated recording discovered afterwards.
        if let free = Self.freeDiskBytes, free < Self.minimumFreeBytes {
            errorMessage = String(localized: "Zu wenig freier Speicher für eine Aufnahme.")
            phase = .idle
            return
        }

        let id = UUID()
        let recordingSettings = settings

        do {
            let directory = try store.prepareDirectory(for: id)
            let offset = HostClock.wallToHostOffset

            locationSource.resetAnchor()
            motionSource.resetBarometerReference()
            timeReference = nil

            var writers: [SensorID: StreamWriter] = [:]
            for sensor in streamsToWrite(for: recordingSettings).sorted(by: { $0.rawValue < $1.rawValue }) {
                let descriptor = sensor.descriptor
                writers[sensor] = try StreamWriter(sensor: sensor,
                                                   channelCount: descriptor.channelCount,
                                                   directory: directory)
            }

            let engine: CaptureEngine = usesARKit(for: recordingSettings) ? .arkit : .classic
            let videoURL = directory.appendingPathComponent(RecordingStore.videoFileName)

            // Only the classic path's movie carries its own audio track. ARKit delivers no
            // audio at all, and a sensor-only recording obviously has no movie — in both of
            // those cases "Ton aufnehmen" has to mean a separate file, which it silently did
            // not before.
            //
            // Audio goes first on purpose. Starting an `AVAudioEngine` takes a few hundred
            // milliseconds, and doing it *between* arming the movie and arming the writers
            // meant the movie collected a quarter second of frames that no camera pose
            // covered. The exporter still matches poses to frames by time, but there is no
            // reason to hand it a gap to clean up.
            var writesAudioFile = false
            let carriesAudioInMovie = engine == .classic
                && recordingSettings.isVideoEnabled && isCameraAvailable
            if recordingSettings.recordsAudio, !carriesAudioInMovie {
                // Metering is already running; restart it so the same tap also writes a file.
                _ = audioSource.stop()
                configureAudioExtras(recordingSettings)
                try audioSource.start(fileURL: directory.appendingPathComponent("audio.m4a"))
                writesAudioFile = true
            }

            switch engine {
            case .arkit:
                try poseRecorder.startWriting(to: videoURL)
            case .classic where recordingSettings.isVideoEnabled && isCameraAvailable:
                if !videoRecorder.isConfigured {
                    await configureCamera(for: recordingSettings)
                }
                try videoRecorder.startWriting(to: videoURL)
            case .classic:
                break
            }

            // Arm the writers last: from this instant on, every sample is part of the file.
            let startHostTime = HostClock.now
            sink.beginRecording(writers: writers, externalDirectory: directory)

            // Only while something is actually being recorded, and only when asked for: the
            // scan runs whenever the record screen is open, but writing down which devices
            // were in the room is a separate decision.
            //
            // Created here rather than with the writers so it shares the recording's
            // `startHostTime`. Taking its own would put its `seconds_elapsed` column on a
            // different origin than every other stream — by however long creating the
            // writers took, which is exactly the kind of quiet offset this app exists to
            // not have.
            if recordingSettings.logsBluetoothAdvertisements,
               recordingSettings.isEnabled(.bluetooth) {
                bluetoothSource.beginLogging(
                    try? AdvertisementLog(directory: directory, startHostTime: startHostTime))
            }
            if recordingSettings.isEnabled(.bluetooth),
               recordingSettings.decodesBluetoothSensors
                || !(recordingSettings.pairedBluetoothDevices ?? []).isEmpty {
                bluetoothSource.beginReadingLog(
                    try? BLEReadingLog(directory: directory, startHostTime: startHostTime))
            }

            if recordingSettings.recordsNetworkQuality {
                networkQualitySource.start()
            }
            extraSources.start(recordingSettings)
            if peerConnection != nil {
                // Measured again at the start, so the offset stored with the recording is
                // seconds old, not as old as the connection.
                peerLink.resync()
                if recordingSettings.startsPeersTogether { peerLink.send(.start) }
            }

            // Streaming rides along with the recording rather than running on its own: a
            // feed without a file behind it is a feed nobody can check afterwards.
            let endpoint = recordingSettings.streamingEndpoint
            let broker = recordingSettings.mqttConfiguration
            if endpoint != nil || broker != nil {
                let streamer = self.streamer
                streamer.start(url: endpoint, mqtt: broker,
                               batchSeconds: recordingSettings.streamingBatch,
                               hostToEpoch: Date().timeIntervalSince1970 - startHostTime)
                sink.setTap { sensor, time, values in
                    streamer.ingest(sensor, time: time, values: values)
                }
            }

            // Measured in the background and written into the metadata when the recording
            // ends. It never touches a sample — see NTPPacket — so there is nothing to wait
            // for, and a slow or blocked server must not delay the record button.
            if recordingSettings.measuresNetworkTime {
                Task { [weak self] in
                    let reference = await NetworkTime.measure()
                    await MainActor.run { self?.timeReference = reference }
                }
            }

            activeRecording = ActiveRecording(id: id, directory: directory,
                                              startHostTime: startHostTime,
                                              startedAt: Date(),
                                              wallToHostOffset: offset,
                                              settings: recordingSettings,
                                              writesAudioFile: writesAudioFile,
                                              engine: engine)

            locationSource.setBackgroundUpdates(true)
            UIApplication.shared.isIdleTimerDisabled = recordingSettings.keepsScreenAwake
            elapsed = 0
            phase = .recording
            announce(isRecording: true, since: activeRecording?.startedAt, hostTime: startHostTime)
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

        sink.setTap(nil)
        streamer.stop()

        let videoInfo: VideoInfo? = switch active.engine {
        case .arkit:
            await poseRecorder.finishWriting()
        case .classic where active.settings.isVideoEnabled && isCameraAvailable:
            await videoRecorder.finishWriting()
        case .classic:
            nil
        }

        var audioInfo: AudioInfo?
        if active.writesAudioFile {
            audioInfo = audioSource.stop()
            if active.settings.isEnabled(.loudness) || active.settings.isEnabled(.loudnessA) {
                startAudioMetering()  // back to plain metering for the live view
            }
        }

        bluetoothSource.endLogging()
        networkQualitySource.stop()
        extraSources.stop()
        if peerConnection != nil, active.settings.startsPeersTogether { peerLink.send(.stop) }

        let ended = sink.endRecordingWithExternals()
        let streams = ended.streams
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
            requestedRateHz: active.settings.motionRateHz,
            captureEngine: active.engine,
            attitudeReferenceFrame: motionSource.activeReferenceFrame,
            geodeticAnchor: locationSource.geodeticAnchor,
            barometerReference: motionSource.barometerReference,
            timeReference: timeReference,
            reducedLocationAccuracy: isLocationAccuracyReduced && active.settings.isEnabled(.location)
                ? true : nil,
            externalStreams: ended.external.filter { $0.sampleCount > 0 }.nilIfEmpty,
            audioCalibrationDecibels: active.settings.isEnabled(.loudnessA) ? active.settings.audioCalibrationDecibels : nil,
            peerDevices: peerConnection.map {
                [PeerDevice(name: $0.name, identifier: $0.identifier.uuidString, clock: $0.clock)]
            }
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
        if metadata.streams.isEmpty, metadata.externalStreams == nil,
           metadata.video == nil, metadata.audio == nil {
            try? store.delete(active.id)
            metadata.name = ""
            activeRecording = nil
            phase = .idle
            announce(isRecording: false)
            errorMessage = String(localized: "Es wurden keine Daten aufgezeichnet.")
            return nil
        }

        activeRecording = nil
        lastFinishedRecording = metadata
        elapsed = 0
        writtenSampleCount = 0
        phase = .idle
        announce(isRecording: false)
        return metadata
    }

    /// The wrist's three buttons. The phone is the one that records, so a command that does not
    /// fit its state — a second start, a stop while idle — is simply ignored; the status the hub
    /// publishes afterwards is what the watch believes.
    private func handleWatchCommand(_ command: String) async {
        switch command {
        case "start": await startRecording()
        case "stop": _ = await stopRecording()
        case "mark":
            if phase == .recording { addAnnotation(String(localized: "Markierung (Uhr)")) }
        default: break
        }
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
        if settings.offersBluetoothService { peripheralService.publish(live) }
        sink.dropExternal(olderThan: 30, now: HostClock.now)
        externalLive = sink.externalSnapshot().values.sorted {
            $0.info.title == $1.info.title ? $0.id < $1.id : $0.info.title < $1.info.title
        }
        if let active = activeRecording, phase == .recording {
            elapsed = HostClock.now - active.startHostTime
            writtenSampleCount = sink.writtenSampleCount
            evaluateRules()
        }
    }

    // MARK: - Rules

    private func evaluateRules() {
        let messages = inbox
        inbox.removeAll()
        // Drained even when no rule is on, so switching one on mid-recording starts from the
        // next interval rather than from everything since the recording began.
        let extremes = sink.drainExtremes()
        let externalExtremes = sink.drainExternalExtremes()
        guard rules.contains(where: \.isEnabled) else { return }
        let context = RuleContext(values: live.mapValues(\.values), elapsed: elapsed,
                                  messages: messages,
                                  minimum: extremes.mapValues(\.minimum),
                                  maximum: extremes.mapValues(\.maximum),
                                  externalValues: Dictionary(uniqueKeysWithValues: externalLive.map { ($0.id, $0.values) }),
                                  externalMinimum: externalExtremes.mapValues(\.minimum),
                                  externalMaximum: externalExtremes.mapValues(\.maximum))
        for rule in ruleEngine.evaluate(rules, context: context, now: HostClock.now) {
            for action in rule.actions {
                perform(action, of: rule)
            }
        }
    }

    private func perform(_ action: Rule.Action, of rule: Rule) {
        switch action {
        case let .notify(title, message, emoji):
            let heading = [emoji, title.isEmpty ? rule.name : title]
                .filter { !$0.isEmpty }.joined(separator: " ")
            NotificationPresenter.post(title: heading, body: message)
            log(.notification, heading, message)
        case .annotate(let text):
            let note = text.isEmpty ? rule.name : text
            addAnnotation(note)
            log(.annotation, rule.name, note)
        case .stopRecording:
            log(.stop, rule.name, String(localized: "Aufnahme beendet"))
            Task { await stopRecording() }
        }
    }

    /// Only during a recording: rules run then, and a console filling up between recordings
    /// would bury the one that matters.
    private func receive(topic: String, payload: String) {
        guard phase == .recording else { return }
        inbox.append((topic, payload))
        log(.message, topic, String(payload.prefix(200)))
    }

    private func log(_ kind: RuleLogEntry.Kind, _ title: String, _ detail: String) {
        ruleLog.insert(RuleLogEntry(date: Date(), kind: kind, title: title, detail: detail), at: 0)
        if ruleLog.count > 200 { ruleLog.removeLast() }
    }

    /// Asked when the first recording with a notifying rule starts — the moment the
    /// question makes sense — rather than on first launch.
    private func requestNotificationPermissionIfNeeded() async {
        let notifies = rules.contains { rule in
            rule.isEnabled && rule.actions.contains { if case .notify = $0 { true } else { false } }
        }
        guard notifies else { return }
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    // MARK: - Helpers

    static func defaultName(for date: Date) -> String {
        date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    /// Enough headroom for a couple of minutes of 4K plus the streams around it. A hard
    /// floor rather than an estimate: predicting the size of a recording whose length nobody
    /// knows yet would be guesswork dressed up as a check.
    static let minimumFreeBytes: Int64 = 500 * 1024 * 1024

    static var freeDiskBytes: Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        return try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
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
