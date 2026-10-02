import AVFoundation
import Foundation
import SensorstormCore

/// What the phone itself is doing that explains a gap in a recording: how much storage is
/// left, and where the audio goes — a microphone pulled out or a Bluetooth headset connecting
/// changes the input in the middle of a noise measurement.
final class SystemExtrasSource: @unchecked Sendable {
    static let storageStream = ExternalStreamInfo(
        id: "system.storage", source: .device,
        title: String(localized: "Freier Speicher"),
        channels: ["free"], channelUnits: ["GB"])
    static let audioStream = ExternalStreamInfo(
        id: "system.audio", source: .device,
        title: String(localized: "Audio-Route"),
        channels: ["volume", "inputs", "outputs"], channelUnits: ["", "", ""])

    private let sink: SampleSink
    private let queue = DispatchQueue(label: "ch.sensorstorm.systemextras")
    private var timer: DispatchSourceTimer?

    init(sink: SampleSink) {
        self.sink = sink
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 5)
            timer.setEventHandler { [weak self] in self?.sample() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    private func sample() {
        let time = HostClock.now
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let free = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage {
            sink.ingestExternal(Self.storageStream, time: time, values: [Double(free) / 1_000_000_000])
        }
        let session = AVAudioSession.sharedInstance()
        sink.ingestExternal(Self.audioStream, time: time, values: [
            Double(session.outputVolume),
            Double(session.currentRoute.inputs.count),
            Double(session.currentRoute.outputs.count)
        ])
    }
}
