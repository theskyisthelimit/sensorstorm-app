import Foundation
import Network
import SensorstormCore

/// Publishes the live payload to an MQTT broker.
///
/// The same bytes the HTTP push sends, on the protocol most home-automation and IoT setups
/// already speak. Both can run at once — a dashboard on one, Home Assistant on the other —
/// because the payload is identical and neither transport knows about the other.
///
/// It also listens. Topics in ``Configuration/subscriptions`` are subscribed after the
/// handshake, and what arrives goes to ``onMessage`` — which is how a rule can react to a
/// command sent from Home Assistant or Node-RED.
///
/// The packet encoding is in ``MQTTPacket``, where it is unit-tested. What is left here is
/// the socket, the connect handshake, and the one rule that matters under load: never queue.
final class MQTTTransport: @unchecked Sendable {

    struct Configuration: Sendable, Hashable {
        var host: String
        var port: UInt16
        var usesTLS: Bool
        var topic: String
        var subscriptions: [String] = []
        var username: String?
        var password: String?
    }

    /// Called on the transport's own queue with every message on a subscribed topic.
    var onMessage: (@Sendable (_ topic: String, _ payload: String) -> Void)? {
        get { lock.withLock { _onMessage } }
        set { lock.withLock { _onMessage = newValue } }
    }
    private var _onMessage: (@Sendable (String, String) -> Void)?

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
        receive(on: connection, configuration: configuration, buffer: Data())
    }

    /// One read loop for the life of the connection: the CONNACK first, then whatever the
    /// subscriptions bring. Ends when the connection does.
    private func receive(on connection: NWConnection, configuration: Configuration, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            for packet in MQTTPacket.drain(&buffer) {
                switch packet {
                case .connack(let connack):
                    self.handleConnack(connack, on: connection, configuration: configuration)
                case .publish(let topic, let payload):
                    self.onMessage?(topic, String(decoding: payload, as: UTF8.self))
                case .other:
                    break
                }
            }
            guard !isComplete, error == nil, connection.state == .ready else {
                if buffer.isEmpty, data == nil, self.status == .sending {
                    self.lock.withLock {
                        self._status = .failed(String(localized: "Der Broker hat nicht geantwortet."))
                    }
                }
                return
            }
            self.receive(on: connection, configuration: configuration, buffer: buffer)
        }
    }

    private func handleConnack(_ connack: Data, on connection: NWConnection,
                               configuration: Configuration) {
        let accepted = MQTTPacket.isAccepted(connack: connack)
        lock.withLock {
            isConnected = accepted
            _status = accepted ? .delivered(code: 0, samples: 0)
                               : .failed(MQTTPacket.connackMessage(connack))
        }
        guard accepted, !configuration.subscriptions.isEmpty,
              let subscribe = try? MQTTPacket.subscribe(packetID: 1, topics: configuration.subscriptions)
        else { return }
        connection.send(content: subscribe, completion: .contentProcessed { _ in })
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
