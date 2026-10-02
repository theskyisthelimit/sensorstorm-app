import Foundation
import Network
import NetworkExtension
import SensorstormCore

/// The quality of the network the phone is in, as streams of a recording: how long a ping to
/// the router and to the internet takes, whether it was lost, and how strong the Wi-Fi is.
///
/// Walked through a building with the position recording on, this is a coverage map made of
/// the same data as every other stream: the track says where, these say how good.
///
/// Armed only while a recording runs and only when the person switched it on — it sends a
/// packet a second, which is more than the app does otherwise.
final class NetworkQualitySource: @unchecked Sendable {
    static let routerStream = ExternalStreamInfo(
        id: "net.rtt.gateway", source: .network,
        title: String(localized: "Antwortzeit Router"),
        channels: ["rtt", "lost"], channelUnits: ["ms", ""])
    static let internetStream = ExternalStreamInfo(
        id: "net.rtt.internet", source: .network,
        title: String(localized: "Antwortzeit Internet (1.1.1.1)"),
        channels: ["rtt", "lost"], channelUnits: ["ms", ""])
    static let wifiStream = ExternalStreamInfo(
        id: "net.wifi.signal", source: .network,
        title: String(localized: "WLAN-Signal"),
        channels: ["signal"], channelUnits: ["%"])

    private let sink: SampleSink
    private let queue = DispatchQueue(label: "ch.sensorstorm.netquality")
    private var timer: DispatchSourceTimer?
    private var monitor: NWPathMonitor?
    private var gateway: IPv4Addr?
    private var tick = 0

    init(sink: SampleSink) {
        self.sink = sink
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            tick = 0
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                let gateway = path.gateways.compactMap { endpoint -> IPv4Addr? in
                    guard case .hostPort(let host, _) = endpoint, case .ipv4(let address) = host else { return nil }
                    return IPv4Addr(octets: Array(address.rawValue))
                }.first
                self?.queue.async { self?.gateway = gateway }
            }
            monitor.start(queue: queue)
            self.monitor = monitor

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.2, repeating: 1.0)
            timer.setEventHandler { [weak self] in self?.probe() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            monitor?.cancel()
            monitor = nil
            gateway = nil
        }
    }

    private func probe() {
        let time = HostClock.now
        tick += 1
        let sink = self.sink

        if let gateway {
            Task.detached {
                let result = await ICMP.ping(gateway, timeout: 0.9)
                Self.report(sink, Self.routerStream, time: time, result: result)
            }
        }
        Task.detached {
            let result = await ICMP.ping(IPv4Addr(octets: [1, 1, 1, 1]), timeout: 0.9)
            Self.report(sink, Self.internetStream, time: time, result: result)
        }
        // The Wi-Fi reading changes slowly and the call is not free.
        if tick % 2 == 0 {
            Task.detached {
                guard let network = await NEHotspotNetwork.fetchCurrent() else { return }
                sink.ingestExternal(Self.wifiStream, time: time, values: [network.signalStrength * 100])
            }
        }
    }

    /// A lost ping is a row too: `rtt` empty, `lost` 1. Without it a dead spot would be a
    /// gap in the file, indistinguishable from the stream not running.
    private static func report(_ sink: SampleSink, _ info: ExternalStreamInfo, time: Double, result: PingResult) {
        if result.reachedTarget, let roundTrip = result.roundTrip {
            sink.ingestExternal(info, time: time, values: [roundTrip * 1_000, 0])
        } else {
            sink.ingestExternal(info, time: time, values: [.nan, 1])
        }
    }
}
