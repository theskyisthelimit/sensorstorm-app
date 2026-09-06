import Foundation
import SensorstormCore

/// Pushes samples to a URL while the recording runs.
///
/// The payload shape deliberately matches Sensor Logger's, for the same reason
/// ``InteropExporter`` matches its CSV layout: there is already an ecosystem of scripts,
/// dashboards and home-automation bridges listening for that shape, and a second,
/// incompatible schema would help nobody. An endpoint written for one works for the other.
///
/// Nothing here reaches us. There is no default endpoint, no fallback host and no
/// telemetry — the URL is whatever the user typed, and if the field is empty nothing opens
/// a socket at all. That is why the privacy manifest can still declare no collected data:
/// data leaves the device only towards a server the user chose and controls.
final class LiveStreamer: @unchecked Sendable {

    /// What the settings screen shows after a push or a test.
    enum Status: Sendable, Equatable {
        case idle
        case sending
        case delivered(code: Int, samples: Int)
        case failed(String)
    }

    /// A dead endpoint must not turn into an out-of-memory. Beyond this the oldest samples
    /// are dropped and counted — the recording on disk stays complete either way, which is
    /// the whole reason dropping is the right answer here.
    private static let bufferLimit = 200_000

    private let lock = NSLock()
    private var buffer: [(sensor: SensorID, time: Double, values: [Double])] = []
    private var droppedSamples = 0
    private var messageId = 0
    private var isSending = false

    private var endpoint: URL?
    private var isMQTTRunning = false

    /// Whether anything is listening at all. Read only while the lock is held.
    private var isRunning: Bool { endpoint != nil || isMQTTRunning }
    private var sessionId = UUID().uuidString
    /// `epochSeconds = hostTime + hostToEpoch`, fixed at the start of a recording.
    private var hostToEpoch: Double = 0
    private var timer: DispatchSourceTimer?

    private let deviceId: String
    private let queue = DispatchQueue(label: "ch.sensorstorm.streaming")
    private let session: URLSession
    /// The same payload, on the protocol most home-automation setups already speak. Both
    /// transports can run at once; neither knows about the other.
    let mqtt = MQTTTransport()

    /// Latest outcome, for the settings screen. Read from the main actor.
    private var _status: Status = .idle
    var status: Status { lock.withLock { _status } }
    var dropped: Int { lock.withLock { droppedSamples } }

    init(deviceId: String) {
        self.deviceId = deviceId
        let configuration = URLSessionConfiguration.ephemeral
        // A push that is still queued when the next batch is ready is already stale; the
        // recording on disk is the archive, this is a live feed.
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Lifecycle

    func start(url: URL?, mqtt configuration: MQTTTransport.Configuration?,
               batchSeconds: Double, hostToEpoch: Double) {
        stop()
        if let configuration { mqtt.start(configuration) }
        lock.withLock {
            isMQTTRunning = configuration != nil
            endpoint = url
            sessionId = UUID().uuidString
            messageId = 0
            droppedSamples = 0
            self.hostToEpoch = hostToEpoch
            buffer.removeAll(keepingCapacity: true)
            _status = .idle
        }
        let period = max(batchSeconds, 0.05)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + period, repeating: period)
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        // One last flush so the tail of a recording is not silently swallowed.
        flush()
        lock.withLock {
            endpoint = nil
            isMQTTRunning = false
        }
        mqtt.stop()
    }

    /// Called from the sample hot path, on whichever queue the sensor fired on.
    func ingest(_ sensor: SensorID, time: Double, values: [Double]) {
        lock.withLock {
            guard isRunning else { return }
            if buffer.count >= Self.bufferLimit {
                let drop = buffer.count / 4
                buffer.removeFirst(drop)
                droppedSamples += drop
            }
            buffer.append((sensor, time, values))
        }
    }

    // MARK: - Sending

    /// Everything one POST needs, lifted out from under the lock in one go.
    private struct Job {
        let batch: [(sensor: SensorID, time: Double, values: [Double])]
        /// `nil` when only MQTT is configured — the payload is built and published either way.
        let url: URL?
        let messageId: Int
        let sessionId: String
        let hostToEpoch: Double
    }

    private func flush() {
        let job: Job? = lock.withLock {
            // Still waiting on the previous POST: keep buffering rather than opening a
            // second connection. Backpressure beats a thundering herd against a Raspberry Pi.
            guard isRunning, !isSending, !buffer.isEmpty else { return nil }
            messageId += 1
            let job = Job(batch: buffer, url: endpoint, messageId: messageId,
                          sessionId: sessionId, hostToEpoch: hostToEpoch)
            buffer.removeAll(keepingCapacity: true)
            isSending = true
            _status = .sending
            return job
        }
        guard let job else { return }

        let text = Self.payload(job.batch, messageId: job.messageId,
                                sessionId: job.sessionId, deviceId: deviceId,
                                hostToEpoch: job.hostToEpoch)
        mqtt.publish(text)

        guard let url = job.url else {
            // MQTT only. `isSending` gates the HTTP write and would otherwise stay set, and
            // the status has to come from the transport that actually ran — leaving it at
            // `.sending` would show "sending…" for the rest of the recording.
            let outcome = mqtt.status
            lock.withLock {
                isSending = false
                _status = outcome
            }
            return
        }
        let body = Data(text.utf8)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let count = job.batch.count
        self.session.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            let outcome: Status
            if let error {
                outcome = .failed(error.localizedDescription)
            } else if let http = response as? HTTPURLResponse {
                outcome = (200..<300).contains(http.statusCode)
                    ? .delivered(code: http.statusCode, samples: count)
                    : .failed(String(localized: "Der Server antwortete mit \(http.statusCode)."))
            } else {
                outcome = .failed(String(localized: "Unerwartete Antwort vom Server."))
            }
            self.lock.withLock {
                self.isSending = false
                self._status = outcome
            }
        }.resume()
    }

    /// Sends one small message immediately, so the settings screen can say whether the
    /// endpoint is reachable *before* someone walks a street relying on it.
    func test(url: URL) async -> Status {
        let body = Data(Self.payload(
            [(sensor: .battery, time: HostClock.now, values: [1])],
            messageId: 0, sessionId: "test", deviceId: deviceId,
            hostToEpoch: Date().timeIntervalSince1970 - HostClock.now).utf8)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(String(localized: "Unerwartete Antwort vom Server."))
            }
            return (200..<300).contains(http.statusCode)
                ? .delivered(code: http.statusCode, samples: 1)
                : .failed(String(localized: "Der Server antwortete mit \(http.statusCode)."))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Payload

    /// `{messageId, sessionId, deviceId, payload: [{name, time, <channels>}]}` with `time`
    /// in epoch nanoseconds — Sensor Logger's shape.
    ///
    /// `messageId` matters more than it looks: batches are sent as they are ready and can
    /// arrive out of order, so a receiver that cares about ordering has to sort by it
    /// rather than by arrival.
    static func payload(_ batch: [(sensor: SensorID, time: Double, values: [Double])],
                        messageId: Int, sessionId: String, deviceId: String,
                        hostToEpoch: Double) -> String {
        var out = "{\"messageId\":\(messageId),"
        out += "\"sessionId\":\(JSONExporter.string(sessionId)),"
        out += "\"deviceId\":\(JSONExporter.string(deviceId)),"
        out += "\"payload\":["

        for (index, sample) in batch.enumerated() {
            if index > 0 { out += "," }
            let channels = sample.sensor.descriptor.channels
            let nanoseconds = (sample.time + hostToEpoch) * 1_000_000_000
            out += "{\"name\":\(JSONExporter.string(sample.sensor.rawValue)),"
            out += "\"time\":\(String(format: "%.0f", nanoseconds))"
            for (position, value) in sample.values.enumerated() {
                let name = position < channels.count ? channels[position] : "c\(position)"
                out += ",\(JSONExporter.string(name)):\(JSONExporter.number(value))"
            }
            out += "}"
        }
        return out + "]}"
    }
}
