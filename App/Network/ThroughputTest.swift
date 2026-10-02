import Foundation
import Network
import SensorstormCore

/// A lock-guarded byte count several tasks add to and one reads.
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0

    func add(_ count: Int) {
        lock.lock(); bytes += Int64(count); lock.unlock()
    }

    var total: Int64 {
        lock.lock(); defer { lock.unlock() }
        return bytes
    }
}

/// Counts what a URL session moves: bytes received for a download, bytes sent for an upload.
private final class TransferMeter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let counter = ByteCounter()

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        counter.add(data.count)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        counter.add(Int(bytesSent))
    }
}

/// Throughput over plain HTTPS: several connections pulling or pushing for a fixed time, and
/// the rate read off every quarter second.
///
/// By default against Cloudflare's public speed-test endpoints; any server that hands out a
/// large body and swallows a POST will do, which is how a switch in the next room gets tested
/// without the internet in the way.
enum ThroughputEngine {
    enum Direction: Sendable {
        case download, upload
    }

    struct Sample: Sendable, Equatable {
        /// Seconds into the test.
        var time: Double
        var megabits: Double
    }

    struct Result: Sendable, Equatable {
        /// The mean over everything after the first second, when the connections have found
        /// their speed; the ramp-up would drag the figure down for a short test.
        var megabits: Double
        var peak: Double
        var samples: [Sample]
    }

    static let defaultDownload = URL(string: "https://speed.cloudflare.com/__down?bytes=250000000")!
    static let defaultUpload = URL(string: "https://speed.cloudflare.com/__up")!

    static func run(_ direction: Direction, url: URL, parallel: Int = 4, duration: Double = 8,
                    onSample: @escaping @Sendable (Sample) -> Void) async -> Result? {
        let meter = TransferMeter()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = parallel
        configuration.timeoutIntervalForRequest = duration + 5
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration, delegate: meter, delegateQueue: nil)

        let started = HostClock.now
        var request = URLRequest(url: url)
        request.setValue("Sensorstorm", forHTTPHeaderField: "User-Agent")
        var workers: Task<Void, Never>?
        switch direction {
        case .download:
            // Plain data tasks with the delegate counting: `session.data(for:)` would keep
            // a quarter of a gigabyte per connection in memory until it finished.
            for _ in 0..<parallel { session.dataTask(with: request).resume() }
        case .upload:
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let upload = request
            workers = Task {
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<parallel {
                        group.addTask {
                            let body = Data(count: 8_000_000)
                            // A fast link finishes one body inside the window; keep pushing.
                            while HostClock.now - started < duration, !Task.isCancelled {
                                if (try? await session.upload(for: upload, from: body)) == nil { break }
                            }
                        }
                    }
                }
            }
        }

        var samples: [Sample] = []
        var previous: (time: Double, bytes: Int64) = (0, 0)
        var atOneSecond: Int64 = 0
        while true {
            try? await Task.sleep(for: .milliseconds(250))
            let elapsed = HostClock.now - started
            let bytes = meter.counter.total
            if elapsed - previous.time >= 0.2 {
                let rate = Iperf3.megabits(bytes: bytes - previous.bytes, seconds: elapsed - previous.time)
                let sample = Sample(time: elapsed, megabits: rate)
                samples.append(sample)
                onSample(sample)
                previous = (elapsed, bytes)
            }
            if atOneSecond == 0, elapsed >= 1 { atOneSecond = bytes }
            if elapsed >= duration || Task.isCancelled { break }
        }
        workers?.cancel()
        session.invalidateAndCancel()
        await workers?.value

        let elapsed = HostClock.now - started
        let total = meter.counter.total
        guard total > 0, elapsed > 1.5 else { return nil }
        let mean = Iperf3.megabits(bytes: total - atOneSecond, seconds: elapsed - 1)
        return Result(megabits: mean, peak: samples.map(\.megabits).max() ?? mean, samples: samples)
    }

    /// Connect time to a host's TLS port over several tries — round trips without needing ICMP,
    /// which is what a captive or filtered network lets through.
    static func latency(host: String = "1.1.1.1", port: Int = 443, tries: Int = 8) async -> [Double] {
        var values: [Double] = []
        for _ in 0..<tries {
            let result = await TCP.probe(host: host, port: port, timeout: 1.5)
            if let roundTrip = result.roundTrip { values.append(roundTrip) }
            try? await Task.sleep(for: .milliseconds(120))
        }
        return values
    }
}
