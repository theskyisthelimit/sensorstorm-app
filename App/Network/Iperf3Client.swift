import Foundation
import Network
import SensorstormCore

/// A TCP connection with `async` send and exact-length receive — the shape a protocol with
/// one-byte states and length-prefixed JSON wants.
final class NWStream: @unchecked Sendable {
    enum StreamError: Error, LocalizedError {
        case network(String)
        case timeout
        case closed

        var errorDescription: String? {
            switch self {
            case .network(let text): text
            case .timeout: String(localized: "Keine Antwort innerhalb der Frist.")
            case .closed: String(localized: "Die Gegenstelle hat die Verbindung geschlossen.")
            }
        }
    }

    let connection: NWConnection
    let queue = DispatchQueue(label: "ch.sensorstorm.nwstream")

    init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        connection = NWConnection(host: NWEndpoint.Host(host),
                                  port: NWEndpoint.Port(rawValue: port) ?? 5_201,
                                  using: NWParameters(tls: nil, tcp: tcp))
    }

    func connect(timeout: Double = 5) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OneShot()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.fire { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    once.fire { continuation.resume(throwing: StreamError.network(error.debugDescription)) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                once.fire { continuation.resume(throwing: StreamError.timeout) }
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: StreamError.network(error.debugDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receive(exactly count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: StreamError.network(error.debugDescription))
                } else if let data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: StreamError.closed)
                }
            }
        }
    }

    /// Whatever has arrived, up to `maximum` bytes; `nil` once the other side closed.
    func receiveSome(maximum: Int) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, _, error in
                continuation.resume(returning: error == nil ? data : nil)
            }
        }
    }

    func cancel() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}

/// Keeps `block` going out on a connection until `deadline`, two sends deep so the pipe never
/// idles between a send finishing and the next starting.
private final class SendPump: @unchecked Sendable {
    private let stream: NWStream
    private let block: Data
    private let deadline: Double
    private let counter: ByteCounter
    private var outstanding = 0
    private var failed = false
    private var finished = false
    private var completion: (@Sendable () -> Void)?

    init(stream: NWStream, block: Data, deadline: Double, counter: ByteCounter) {
        self.stream = stream
        self.block = block
        self.deadline = deadline
        self.counter = counter
    }

    func run() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stream.queue.async { [self] in
                completion = { continuation.resume() }
                for _ in 0..<2 { issue() }
            }
        }
    }

    private func issue() {
        guard !finished else { return }
        if failed || HostClock.now >= deadline {
            if outstanding == 0 { finish() }
            return
        }
        outstanding += 1
        stream.connection.send(content: block, completion: .contentProcessed { [self] error in
            outstanding -= 1
            if error != nil { failed = true } else { counter.add(block.count) }
            issue()
        })
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        completion?()
        completion = nil
    }
}

/// What an iperf3 test measured.
struct Iperf3Result: Sendable, Equatable {
    var duration: Double
    var streams: Int
    var reverse: Bool
    /// Megabits per second as the sending side counted them.
    var senderMegabits: Double
    /// As the receiving side counted them — the figure iperf3 prints as „receiver", and the one
    /// that says what actually arrived.
    var receiverMegabits: Double
}

enum Iperf3Error: Error, LocalizedError {
    case refused
    case serverError
    case terminated
    case unexpected(Int8)
    case resultsMissing

    var errorDescription: String? {
        switch self {
        case .refused: String(localized: "Der Server hat den Test abgelehnt (er ist vermutlich beschäftigt).")
        case .serverError: String(localized: "Der Server meldet einen Fehler.")
        case .terminated: String(localized: "Der Server hat den Test abgebrochen.")
        case .unexpected(let state): String(localized: "Unerwarteter Zustand \(Int(state)) vom Server.")
        case .resultsMissing: String(localized: "Der Server hat keine Ergebnisse geschickt.")
        }
    }
}

/// An iperf3 client: the control conversation, the data streams, the results exchange.
///
/// Written from the protocol as the reference implementation behaves, not run against one —
/// that is what the first hardware test is for. The framing (cookie, state bytes, length
/// prefix, parameters) is tested in `Iperf3Tests`; what only a real server can confirm is
/// the order in which it sends its states.
enum Iperf3Client {
    static func run(host: String, port: UInt16 = 5_201, duration: Int = 10, parallel: Int = 1,
                    reverse: Bool = false,
                    onSample: @escaping @Sendable (ThroughputEngine.Sample) -> Void) async throws -> Iperf3Result {
        let control = NWStream(host: host, port: port)
        try await control.connect()
        defer { control.cancel() }

        let cookie = Iperf3.cookie()
        try await control.send(cookie)

        var dataStreams: [NWStream] = []
        defer { for stream in dataStreams { stream.cancel() } }
        let counter = ByteCounter()
        var pumpTask: Task<Void, Never>?
        var clientBytes: Int64 = 0
        var started = 0.0
        var serverBytes: Int64?

        while true {
            let raw = try await control.receive(exactly: 1)
            let value = Int8(bitPattern: raw[0])
            guard let state = Iperf3.State(rawValue: value) else { throw Iperf3Error.unexpected(value) }

            switch state {
            case .paramExchange:
                let json = Iperf3.parameters(duration: duration, parallelStreams: parallel, reverse: reverse)
                try await control.send(Iperf3.frame(json))

            case .createStreams:
                for _ in 0..<parallel {
                    let stream = NWStream(host: host, port: port)
                    try await stream.connect()
                    try await stream.send(cookie)
                    dataStreams.append(stream)
                }

            case .testStart:
                break

            case .testRunning:
                started = HostClock.now
                let startTime = started
                let deadline = startTime + Double(duration)
                let streams = dataStreams
                let block = Data(repeating: 0x5A, count: 131_072)
                pumpTask = Task {
                    await withTaskGroup(of: Void.self) { group in
                        for stream in streams {
                            if reverse {
                                group.addTask {
                                    while HostClock.now < deadline + 1, let data = await stream.receiveSome(maximum: 262_144) {
                                        counter.add(data.count)
                                    }
                                }
                            } else {
                                group.addTask {
                                    await SendPump(stream: stream, block: block, deadline: deadline,
                                                   counter: counter).run()
                                }
                            }
                        }
                        // The sampler and the end of the test share the group's lifetime.
                        group.addTask {
                            var previous: (Double, Int64) = (0, 0)
                            while HostClock.now < deadline {
                                try? await Task.sleep(for: .milliseconds(500))
                                let elapsed = HostClock.now - startTime
                                let bytes = counter.total
                                let rate = Iperf3.megabits(bytes: bytes - previous.1, seconds: elapsed - previous.0)
                                onSample(ThroughputEngine.Sample(time: elapsed, megabits: rate))
                                previous = (elapsed, bytes)
                            }
                        }
                        await group.waitForAll()
                    }
                    // The client ends the test, whichever way the data flowed.
                    try? await control.send(Data([UInt8(bitPattern: Iperf3.State.testEnd.rawValue)]))
                }

            case .exchangeResults:
                await pumpTask?.value
                clientBytes = counter.total
                let elapsed = max(HostClock.now - started, 0.001)
                let streamsReport: [[String: Any]] = dataStreams.indices.map { index in
                    [
                        "id": index + 1,
                        "bytes": Int(clientBytes / Int64(max(dataStreams.count, 1))),
                        "retransmits": -1,
                        "jitter": 0,
                        "errors": 0,
                        "omitted_errors": 0,
                        "packets": 0,
                        "omitted_packets": 0,
                        "start_time": 0,
                        "end_time": elapsed,
                    ]
                }
                let results: [String: Any] = [
                    "cpu_util_total": 0, "cpu_util_user": 0, "cpu_util_system": 0,
                    "sender_has_retransmits": -1, "streams": streamsReport,
                ]
                let body = try JSONSerialization.data(withJSONObject: results)
                try await control.send(Iperf3.frame(body))

                // The server's side of the exchange: four bytes of length, then the JSON.
                let header = try await control.receive(exactly: 4)
                let length = header.reduce(0) { $0 << 8 | Int($1) }
                guard length > 0, length <= 1 << 20 else { throw Iperf3Error.resultsMissing }
                let payload = try await control.receive(exactly: length)
                if let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                   let list = object["streams"] as? [[String: Any]] {
                    serverBytes = list.reduce(Int64(0)) { $0 + Int64(($1["bytes"] as? NSNumber)?.int64Value ?? 0) }
                }

            case .displayResults:
                try? await control.send(Data([UInt8(bitPattern: Iperf3.State.iperfDone.rawValue)]))
                let seconds = max(Double(duration), 0.001)
                let local = Iperf3.megabits(bytes: clientBytes, seconds: seconds)
                let remote = serverBytes.map { Iperf3.megabits(bytes: $0, seconds: seconds) } ?? local
                return Iperf3Result(duration: seconds, streams: parallel, reverse: reverse,
                                    senderMegabits: reverse ? remote : local,
                                    receiverMegabits: reverse ? local : remote)

            case .accessDenied: throw Iperf3Error.refused
            case .serverError: throw Iperf3Error.serverError
            case .serverTerminate, .clientTerminate: throw Iperf3Error.terminated
            default: break
            }
        }
    }
}
