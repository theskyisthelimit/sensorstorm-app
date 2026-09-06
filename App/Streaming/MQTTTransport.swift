import Foundation
import Network
import SensorstormCore

/// Publishes the live payload to an MQTT broker.
///
/// The same bytes the HTTP push sends, on the protocol most home-automation and IoT setups
/// already speak. Both can run at once — a dashboard on one, Home Assistant on the other —
/// because the payload is identical and neither transport knows about the other.
///
/// The packet encoding is in ``MQTTPacket``, where it is unit-tested. What is left here is
/// the socket, the connect handshake, and the one rule that matters under load: never queue.
final class MQTTTransport: @unchecked Sendable {

    struct Configuration: Sendable, Hashable {
        var host: String
        var port: UInt16
        var usesTLS: Bool
        var topic: String
        var username: String?
        var password: String?
    }

    private let lock = NSLock()
    private var connection: NWConnection?
    private var isConnected = false
    private var isSending = false
    private var configuration: Configuration?
    private var _status: LiveStreamer.Status = .idle

    private let clientID = "sensorstorm-\(UUID().uuidString.prefix(8))"
    private let queue = DispatchQueue(label: "ch.sensorstorm.mqtt")

    var status: LiveStreamer.Status { lock.withLock { _status } }

    // MARK: - Lifecycle

    func start(_ configuration: Configuration) {
        stop()
        lock.withLock {
            self.configuration = configuration
            _status = .sending
        }
        connect(configuration)
    }

    func stop() {
        let connection = lock.withLock { () -> NWConnection? in
            let existing = self.connection
            self.connection = nil
            self.configuration = nil
            isConnected = false
            isSending = false
            return existing
        }
        guard let connection else { return }
        connection.send(content: MQTTPacket.disconnect, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func connect(_ configuration: Configuration) {
        let parameters: NWParameters = configuration.usesTLS ? .tls : .tcp
        let connection = NWConnection(host: NWEndpoint.Host(configuration.host),
                                      port: NWEndpoint.Port(rawValue: configuration.port) ?? 1883,
                                      using: parameters)
        lock.withLock { self.connection = connection }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendConnect(on: connection, configuration: configuration)
            case .failed(let error):
                self.lock.withLock {
                    self.isConnected = false
                    self._status = .failed(error.localizedDescription)
                }
            case .cancelled:
                self.lock.withLock { self.isConnected = false }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func sendConnect(on connection: NWConnection, configuration: Configuration) {
        guard let packet = try? MQTTPacket.connect(clientID: clientID,
                                                   username: configuration.username,
                                                   password: configuration.password) else {
            return
        }
        connection.send(content: packet, completion: .contentProcessed { _ in })
        // A CONNACK is four bytes and arrives before anything else.
        connection.receive(minimumIncompleteLength: 4, maximumLength: 8) { [weak self] data, _, _, _ in
            guard let self else { return }
            let accepted = data.map(MQTTPacket.isAccepted(connack:)) ?? false
            self.lock.withLock {
                self.isConnected = accepted
                self._status = accepted
                    ? .delivered(code: 0, samples: 0)
                    : .failed(data.map(MQTTPacket.connackMessage) ?? String(
                        localized: "Der Broker hat nicht geantwortet."))
            }
        }
    }

    // MARK: - Publishing

    /// Publishes one batch, or drops it.
    ///
    /// Dropping is deliberate and is the same rule the HTTP push follows: while one write is
    /// still in flight the next batch is discarded rather than queued. A broker slower than
    /// a 400 Hz stream would otherwise turn a backlog into an out-of-memory, and the
    /// recording on disk — the actual archive — is complete either way.
    func publish(_ payload: String) {
        let job = lock.withLock { () -> (NWConnection, String)? in
            guard let connection, isConnected, !isSending, let configuration else { return nil }
            isSending = true
            return (connection, configuration.topic)
        }
        guard let (connection, topic) = job else { return }
        guard let packet = try? MQTTPacket.publish(topic: topic, payload: Data(payload.utf8)) else {
            lock.withLock { isSending = false }
            return
        }
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.withLock {
                self.isSending = false
                if let error {
                    self._status = .failed(error.localizedDescription)
                }
            }
        })
    }
}
