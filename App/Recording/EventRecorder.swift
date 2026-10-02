import Foundation
import SensorstormCore

/// A recorder that is always listening and saves only when something happens: a shock above
/// the threshold writes the seconds before it and the seconds after it as a recording.
///
/// For a phone in a vehicle, on a machine, on a package: nobody watches it, nobody presses
/// record, and the one thing worth keeping is the moment of the bang. A recording of the whole
/// journey would be hours of nothing.
///
/// Sensors only — no video, no audio. A pre-roll of video would mean holding minutes of
/// frames in memory, and a recorder that gets killed for memory is not a recorder.
///
/// Armed only while the app is open on the record screen and nothing else is recording: iOS
/// does not keep the motion sensors running for an app in the background, apart from the
/// location mode, and that is not something to hold open for an event that may never come.
final class EventRecorder: @unchecked Sendable {
    struct Configuration: Equatable, Sendable {
        var thresholdG: Double
        var preRoll: Double
        var postRoll: Double
        var requestedRateHz: Double
    }

    private struct Capture {
        var id: UUID
        var directory: URL
        var writers: [SensorID: StreamWriter]
        var startHostTime: Double
        var triggerHostTime: Double
        var endHostTime: Double
        var startedAt: Date
        var magnitude: Double
    }

    private let store: RecordingStore
    private let lock = NSLock()
    private var configuration: Configuration?
    private var rings: [SensorID: SampleRing] = [:]
    private var trigger = ShockTrigger(threshold: 2, holdOff: 20)
    private var capture: Capture?

    /// Called on an arbitrary queue with the saved recording.
    var onSaved: (@Sendable (RecordingMetadata) -> Void)?
    /// Called when the armed state changes, for the screen.
    var onCapturing: (@Sendable (Bool) -> Void)?

    init(store: RecordingStore) {
        self.store = store
    }

    /// `nil` disarms: the buffer is dropped and the observer does nothing.
    func configure(_ configuration: Configuration?) {
        lock.lock()
        defer { lock.unlock() }
        guard self.configuration != configuration else { return }
        self.configuration = configuration
        rings = [:]
        if let configuration {
            // Held off for the length of a capture: the next event after this one is another
            // recording, not this one's tail.
            trigger = ShockTrigger(threshold: configuration.thresholdG,
                                   holdOff: configuration.preRoll + configuration.postRoll)
        }
    }

    var isArmed: Bool {
        lock.lock(); defer { lock.unlock() }
        return configuration != nil
    }

    /// Every sample of every sensor, from whichever queue it arrived on.
    func observe(_ sensor: SensorID, time: Double, values: [Double]) {
        lock.lock()
        guard let configuration else { lock.unlock(); return }

        var ring = rings[sensor] ?? SampleRing(maxSeconds: configuration.preRoll)
        ring.append(time: time, values: values)
        rings[sensor] = ring

        var finished: Capture?
        if var current = capture {
            if let writer = current.writers[sensor] {
                writer.append(time: time, values: values)
            } else if let writer = try? StreamWriter(sensor: sensor, channelCount: values.count,
                                                     directory: current.directory) {
                // A sensor that had no sample in the pre-roll but has one now.
                writer.append(time: time, values: values)
                current.writers[sensor] = writer
                capture = current
            }
            if time >= current.endHostTime {
                finished = current
                capture = nil
            }
        } else if sensor == .userAcceleration, let magnitude = trigger.check(time: time, values: values) {
            beginCapture(at: time, magnitude: magnitude, configuration: configuration)
        }
        lock.unlock()

        if let finished { finish(finished, configuration: configuration) }
    }

    /// Caller holds the lock.
    private func beginCapture(at time: Double, magnitude: Double, configuration: Configuration) {
        let id = UUID()
        guard let directory = try? store.prepareDirectory(for: id) else { return }
        let start = time - configuration.preRoll
        var writers: [SensorID: StreamWriter] = [:]
        for (sensor, ring) in rings {
            let samples = ring.samples(since: start)
            guard let first = samples.first,
                  let writer = try? StreamWriter(sensor: sensor, channelCount: first.values.count,
                                                 directory: directory) else { continue }
            for sample in samples { writer.append(time: sample.time, values: sample.values) }
            writers[sensor] = writer
        }
        let startedAt = Date().addingTimeInterval(-(HostClock.now - start))
        capture = Capture(id: id, directory: directory, writers: writers, startHostTime: start,
                          triggerHostTime: time, endHostTime: time + configuration.postRoll,
                          startedAt: startedAt, magnitude: magnitude)
        onCapturing?(true)
        // The sensors normally keep time moving; if they stop, the timer closes the file.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + configuration.postRoll + 2) { [weak self] in
            self?.forceFinish(id: id)
        }
    }

    private func forceFinish(id: UUID) {
        lock.lock()
        guard let current = capture, current.id == id, let configuration else { lock.unlock(); return }
        capture = nil
        lock.unlock()
        finish(current, configuration: configuration)
    }

    private func finish(_ capture: Capture, configuration: Configuration) {
        let streams = capture.writers.values.map { $0.close() }
            .filter { $0.sampleCount > 0 }
            .sorted { $0.sensor.rawValue < $1.sensor.rawValue }
        onCapturing?(false)
        guard !streams.isEmpty else {
            try? store.delete(capture.id)
            return
        }

        let name = String(localized: "Ereignis") + " " + capture.startedAt.formatted(
            .dateTime.year().month(.twoDigits).day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        let magnitudeText = String(format: "%.1f", capture.magnitude)
        let metadata = RecordingMetadata(
            id: capture.id, name: name, startedAt: capture.startedAt, startHostTime: capture.startHostTime,
            duration: capture.endHostTime - capture.startHostTime, device: SensorHub.deviceInfo(),
            streams: streams, requestedRateHz: configuration.requestedRateHz,
            notes: String(localized: "Ausgelöst durch einen Stoss von \(magnitudeText) g."))
        do {
            try store.save(metadata)
            try store.saveAnnotations([
                Annotation(hostTime: capture.triggerHostTime,
                           text: String(localized: "Stoss \(magnitudeText) g"))
            ], for: capture.id)
            onSaved?(metadata)
        } catch {
            RecordingLog.warn("event recording not saved: \(error.localizedDescription)")
        }
    }
}
