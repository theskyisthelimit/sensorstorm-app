import AVFoundation
import Foundation
import SensorstormCore

/// Microphone loudness, and — when no video is running — the audio track itself.
///
/// The session runs in `.measurement` mode, which switches off the input processing chain
/// (AGC, noise suppression). That costs a bit of perceived quality and buys a level reading
/// that actually means something across recordings.
final class AudioSource: @unchecked Sendable {
    private let sink: SampleSink
    private let engine = AVAudioEngine()

    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private var firstFrameHostTime: Double?
    private var writtenFrames: AVAudioFramePosition = 0
    private var fileFormat: AVAudioFormat?
    private var isRunning = false

    init(sink: SampleSink) {
        self.sink = sink
    }

    var availableSensors: Set<SensorID> { [.loudness] }

    static var isMicrophoneAuthorized: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    static func requestMicrophoneAccess() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// - Parameter fileURL: where to write the audio track, or `nil` to only meter.
    func start(fileURL: URL?) throws {
        guard !isRunning else { return }

        try configureSession()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioSourceError.noInput
        }

        if let fileURL {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            audioFile = try AVAudioFile(forWriting: fileURL, settings: settings)
        }
        fileFormat = format
        firstFrameHostTime = nil
        writtenFrames = 0

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            self?.handle(buffer: buffer, when: when)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() -> AudioInfo? {
        guard isRunning else { return nil }
        isRunning = false

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        lock.lock()
        let file = audioFile
        let start = firstFrameHostTime
        let frames = writtenFrames
        let format = fileFormat
        audioFile = nil
        firstFrameHostTime = nil
        writtenFrames = 0
        lock.unlock()

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard let file, let start, let format, frames > 0 else { return nil }
        return AudioInfo(fileName: file.url.lastPathComponent,
                         startHostTime: start,
                         duration: Double(frames) / format.sampleRate,
                         sampleRate: format.sampleRate,
                         channelCount: Int(format.channelCount))
    }

    // MARK: - Private

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true)
    }

    private func handle(buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        // `hostTime` is mach ticks — the same clock every other stream is on.
        let time = when.isHostTimeValid
            ? HostClock.seconds(fromTicks: when.hostTime)
            : HostClock.now

        if let level = AudioLevelMeter.level(from: buffer) {
            sink.ingest(.loudness, time: time, values: [level.average, level.peak])
        }

        lock.lock()
        if firstFrameHostTime == nil { firstFrameHostTime = time }
        let file = audioFile
        lock.unlock()

        guard let file else { return }
        do {
            try file.write(from: buffer)
            lock.lock()
            writtenFrames += AVAudioFramePosition(buffer.frameLength)
            lock.unlock()
        } catch {
            RecordingLog.warn("audio write failed: \(error.localizedDescription)")
        }
    }
}

enum AudioSourceError: Error, LocalizedError {
    case noInput

    var errorDescription: String? {
        switch self {
        case .noInput: String(localized: "Kein Mikrofon verfügbar.")
        }
    }
}
