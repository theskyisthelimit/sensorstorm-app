import Foundation
import Network
import SensorstormCore

/// One SNTP exchange with a public time server.
///
/// **Nothing here moves the clock the app records on.** Samples stay on
/// `mach_absolute_time`, which is what makes a video frame and an acceleration value line
/// up with no calibration; a number fetched over Wi-Fi has no business touching that. The
/// measured offset is written into the recording's metadata and left there, so two phones
/// that each measured their own can be put on one timeline afterwards.
///
/// The packet format lives in ``NTPPacket``, where it is unit-tested. This is only the
/// socket around it.
enum NetworkTime {
    static let defaultServer = "time.apple.com"

    /// Takes several readings and keeps the one with the shortest round trip.
    ///
    /// The whole method assumes the packet took as long out as it did back. That assumption
    /// is least wrong on the fastest exchange, so the best of a few beats an average of
    /// them — a single slow reply would drag a mean sideways by half its own delay.
    static func measure(server: String = defaultServer, samples: Int = 4,
                        timeout: Duration = .seconds(2)) async -> TimeReference? {
        var best: NTPPacket.Reading?
        for _ in 0..<max(1, samples) {
            guard let reading = await exchange(server: server, timeout: timeout) else { continue }
            if best == nil || reading.roundTripSeconds < best!.roundTripSeconds {
                best = reading
            }
        }
        guard let best else { return nil }
        return TimeReference(server: server,
                             offsetSeconds: best.offsetSeconds,
                             roundTripSeconds: best.roundTripSeconds,
                             hostTime: HostClock.now)
    }

    private static func exchange(server: String, timeout: Duration) async -> NTPPacket.Reading? {
        let connection = NWConnection(
            host: NWEndpoint.Host(server), port: 123, using: .udp)

        return await withTaskGroup(of: NTPPacket.Reading?.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    let resumed = Resumed()
                    connection.stateUpdateHandler = { state in
                        guard case .ready = state else {
                            if case .failed = state, resumed.claim() {
                                continuation.resume(returning: nil)
                            }
                            return
                        }
                        let sentWall = Date().timeIntervalSince1970
                        let sentHost = HostClock.now
                        connection.send(content: NTPPacket.request(transmitTime: sentWall),
                                        completion: .contentProcessed { _ in })
                        connection.receiveMessage { data, _, _, _ in
                            guard resumed.claim() else { return }
                            // The round trip is measured on the monotonic clock: the wall
                            // clock is the thing under test and could step mid-exchange.
                            let elapsed = HostClock.now - sentHost
                            let reading = data.flatMap {
                                NTPPacket.reading(from: $0, sentAt: sentWall,
                                                  receivedAt: sentWall + elapsed)
                            }
                            continuation.resume(returning: reading)
                        }
                    }
                    connection.start(queue: .global(qos: .utility))
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            connection.cancel()
            return result
        }
    }

    /// A continuation may only be resumed once, and both the failure handler and the
    /// receive handler can fire.
    private final class Resumed: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false

        func claim() -> Bool {
            lock.withLock {
                guard !used else { return false }
                used = true
                return true
            }
        }
    }
}
