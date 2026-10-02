import Darwin
import Foundation
import Network
import Security
import SensorstormCore

// The low-level probes of the network tools: one ICMP echo, one TCP connect, one UDP
// exchange. Each runs on its own queue and answers through a continuation, so a sweep of
// two hundred hosts is a task group and not two hundred blocked threads.
//
// Everything here is written against what iOS allows an ordinary app: ICMP over an
// unprivileged datagram socket, TCP and UDP through Network.framework. There is no raw
// socket and no promiscuous mode, and the ARP table only where the OS release shares it — see
// docs/ANALYSE.md, chapter 6.

// MARK: - ICMP

struct PingResult: Sendable, Equatable {
    /// Seconds. `nil` when nothing came back in time.
    var roundTrip: Double?
    /// Who answered — for an echo reply the target, for time-exceeded the router on the way.
    var responder: IPv4Addr?
    var kind: ICMPPacket.Reply.Kind?
    var ttl: Int?

    var answered: Bool { roundTrip != nil }
    var reachedTarget: Bool { kind == .echoReply }
}

enum ICMP {
    /// One echo request. With `ttl` set, the packet dies after that many hops and the router
    /// that kills it answers — the whole of traceroute.
    static func ping(_ address: IPv4Addr, ttl: Int? = nil, timeout: Double = 1.0,
                     payloadSize: Int = 32) async -> PingResult {
        await withCheckedContinuation { continuation in
            ICMPProbe(address: address, ttl: ttl, timeout: timeout, payloadSize: payloadSize)
                .start { continuation.resume(returning: $0) }
        }
    }
}

private final class ICMPProbe: @unchecked Sendable {
    private let address: IPv4Addr
    private let ttl: Int?
    private let timeout: Double
    private let payloadSize: Int
    private let queue = DispatchQueue(label: "ch.sensorstorm.icmp")
    private let identifier = UInt16.random(in: 1...UInt16.max)
    private let sequence = UInt16.random(in: 1...UInt16.max)

    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private var completion: (@Sendable (PingResult) -> Void)?
    private var startedAt = 0.0

    init(address: IPv4Addr, ttl: Int?, timeout: Double, payloadSize: Int) {
        self.address = address
        self.ttl = ttl
        self.timeout = timeout
        self.payloadSize = payloadSize
    }

    func start(_ completion: @escaping @Sendable (PingResult) -> Void) {
        queue.async { [self] in
            self.completion = completion
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
            guard fd >= 0 else { return finish(PingResult()) }
            descriptor = fd
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
            if let ttl {
                var value = Int32(ttl)
                setsockopt(fd, IPPROTO_IP, IP_TTL, &value, socklen_t(MemoryLayout<Int32>.size))
            }

            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            reader.setEventHandler { [self] in drain() }
            reader.setCancelHandler { close(fd) }
            source = reader
            reader.resume()

            startedAt = HostClock.now
            guard send() else { return finish(PingResult()) }
            queue.asyncAfter(deadline: .now() + timeout) { [self] in finish(PingResult()) }
        }
    }

    private func send() -> Bool {
        let packet = ICMPPacket.echoRequest(identifier: identifier, sequence: sequence,
                                            payload: Data(repeating: 0x5A, count: payloadSize))
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_addr.s_addr = address.value.bigEndian
        let sent = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &target) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    sendto(descriptor, bytes.baseAddress, bytes.count, 0, socketAddress,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == packet.count
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 1_500)
        while true {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            guard let reply = ICMPPacket.parseReply(Data(buffer[0..<count])) else { continue }
            // Matched by sequence, not by identifier: the kernel is free to rewrite the
            // identifier of a datagram ICMP socket, and a sequence number drawn at random
            // for this one probe is as good a key.
            if let received = reply.sequence, received != sequence { continue }
            if reply.kind == .echoReply, let from = reply.source, from != address { continue }
            finish(PingResult(roundTrip: HostClock.now - startedAt,
                              responder: reply.source ?? address,
                              kind: reply.kind, ttl: reply.ttl))
            return
        }
    }

    private func finish(_ result: PingResult) {
        guard let completion else { return }
        self.completion = nil
        if let source {
            source.cancel()          // closes the descriptor
        } else if descriptor >= 0 {
            close(descriptor)
        }
        source = nil
        completion(result)
    }
}

// MARK: - Run once

/// Lets whichever of a state callback and a timer gets there first finish an attempt.
final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire(_ body: () -> Void) {
        lock.lock()
        let first = !fired
        fired = true
        lock.unlock()
        if first { body() }
    }
}

// MARK: - TCP

struct TCPResult: Sendable, Equatable {
    enum Outcome: Sendable, Equatable {
        /// The handshake completed.
        case open
        /// The host answered with a reset: the port is closed, and the host is there.
        case refused
        case timedOut
        /// Anything else — no route, network down, the Local Network permission refused.
        case failed
    }

    var outcome: Outcome
    var roundTrip: Double?
    var banner: String?
    var error: String?
    /// iOS refused the connection because the person has not allowed local network access.
    var localNetworkDenied = false

    /// Open and refused both prove somebody is at that address.
    var hostAnswered: Bool { outcome == .open || outcome == .refused }
}

enum TCP {
    static func probe(host: String, port: Int, timeout: Double = 1.0,
                      banner: Bool = false) async -> TCPResult {
        await withCheckedContinuation { continuation in
            TCPAttempt(host: host, port: port, timeout: timeout, wantsBanner: banner)
                .start { continuation.resume(returning: $0) }
        }
    }

    /// What a service says on connecting, boiled down to something worth a line: the first
    /// printable line, and for HTTP the `Server` header instead of the status line alone.
    static func bannerSummary(_ data: Data) -> String? {
        let text = String(decoding: data.prefix(512), as: UTF8.self)
        let lines = text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).map(String.init)
        guard let first = lines.first else { return nil }
        func printable(_ line: String) -> String {
            String(line.unicodeScalars.map { $0.value >= 0x20 && $0.value < 0x7F ? Character($0) : "·" }
                .prefix(160))
        }
        if first.hasPrefix("HTTP/") {
            let server = lines.first { $0.lowercased().hasPrefix("server:") }
            return printable([first, server].compactMap { $0 }.joined(separator: " · "))
        }
        let cleaned = printable(first).trimmingCharacters(in: CharacterSet(charactersIn: "·"))
        return cleaned.count >= 3 ? cleaned : nil
    }

    static func greeting(for port: Int) -> Data? {
        [80, 81, 8000, 8008, 8080, 8081, 8888, 9000].contains(port)
            ? Data("HEAD / HTTP/1.0\r\nUser-Agent: Sensorstorm\r\n\r\n".utf8) : nil
    }
}

private final class TCPAttempt: @unchecked Sendable {
    private let connection: NWConnection?
    private let port: Int
    private let timeout: Double
    private let wantsBanner: Bool
    private let queue = DispatchQueue(label: "ch.sensorstorm.tcp")
    private var completion: (@Sendable (TCPResult) -> Void)?
    private var connected = false
    private var startedAt = 0.0

    init(host: String, port: Int, timeout: Double, wantsBanner: Bool) {
        self.port = port
        self.timeout = timeout
        self.wantsBanner = wantsBanner
        if let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 {
            let parameters = NWParameters.tcp
            // A scan that waits for a retry after every refusal would never finish.
            parameters.allowFastOpen = false
            connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        } else {
            connection = nil
        }
    }

    func start(_ completion: @escaping @Sendable (TCPResult) -> Void) {
        queue.async { [self] in
            guard let connection else {
                completion(TCPResult(outcome: .failed, error: "port"))
                return
            }
            self.completion = completion
            startedAt = HostClock.now
            connection.stateUpdateHandler = { [self] state in handle(state) }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [self] in
                if !connected { finish(TCPResult(outcome: .timedOut)) }
            }
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connected = true
            let roundTrip = HostClock.now - startedAt
            guard wantsBanner, let connection else {
                return finish(TCPResult(outcome: .open, roundTrip: roundTrip))
            }
            if let greeting = TCP.greeting(for: port) {
                connection.send(content: greeting, completion: .contentProcessed { _ in })
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 512) { [self] data, _, _, _ in
                finish(TCPResult(outcome: .open, roundTrip: roundTrip,
                                 banner: data.flatMap(TCP.bannerSummary)))
            }
            queue.asyncAfter(deadline: .now() + 1.2) { [self] in
                finish(TCPResult(outcome: .open, roundTrip: roundTrip))
            }
        case .failed(let error), .waiting(let error):
            finish(Self.classify(error))
        default:
            break
        }
    }

    /// Network.framework reports a refused connection as „waiting", not „failed" — the state
    /// it keeps while it would retry. Read the error rather than the state.
    private static func classify(_ error: NWError) -> TCPResult {
        switch error {
        case .posix(let code) where code == .ECONNREFUSED:
            return TCPResult(outcome: .refused, error: error.debugDescription)
        case .posix(let code) where code == .ETIMEDOUT:
            return TCPResult(outcome: .timedOut, error: error.debugDescription)
        case .dns(let code) where code == -65_570:
            // kDNSServiceErr_PolicyDenied: Settings → Privacy → Local Network is off.
            return TCPResult(outcome: .failed, error: error.debugDescription, localNetworkDenied: true)
        default:
            return TCPResult(outcome: .failed, error: error.debugDescription)
        }
    }

    private func finish(_ result: TCPResult) {
        guard let completion else { return }
        self.completion = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        completion(result)
    }
}

// MARK: - UDP

enum UDP {
    /// One datagram out, the first one back. `nil` for silence — which for UDP means a closed
    /// port, a filter and a host that is not there alike.
    static func exchange(host: String, port: UInt16, payload: Data, timeout: Double = 1.5) async -> Data? {
        await withCheckedContinuation { continuation in
            UDPAttempt(host: host, port: port, payload: payload, timeout: timeout, waitsForReply: true)
                .start { continuation.resume(returning: $0.data) }
        }
    }

    /// One datagram out. The error text if the system refused to send it.
    static func send(host: String, port: UInt16, payload: Data) async -> String? {
        await withCheckedContinuation { continuation in
            UDPAttempt(host: host, port: port, payload: payload, timeout: 2, waitsForReply: false)
                .start { continuation.resume(returning: $0.error) }
        }
    }
}

private final class UDPAttempt: @unchecked Sendable {
    struct Outcome: Sendable {
        var data: Data?
        var error: String?
    }

    private let connection: NWConnection?
    private let payload: Data
    private let timeout: Double
    private let waitsForReply: Bool
    private let queue = DispatchQueue(label: "ch.sensorstorm.udp")
    private var completion: (@Sendable (Outcome) -> Void)?

    init(host: String, port: UInt16, payload: Data, timeout: Double, waitsForReply: Bool) {
        self.payload = payload
        self.timeout = timeout
        self.waitsForReply = waitsForReply
        if let nwPort = NWEndpoint.Port(rawValue: port) {
            connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        } else {
            connection = nil
        }
    }

    func start(_ completion: @escaping @Sendable (Outcome) -> Void) {
        queue.async { [self] in
            guard let connection else { return completion(Outcome(error: "port")) }
            self.completion = completion
            connection.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    connection.send(content: payload, completion: .contentProcessed { [self] error in
                        if let error { return finish(Outcome(error: error.debugDescription)) }
                        if waitsForReply {
                            connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [self] data, _, _, error in
                                finish(Outcome(data: data, error: error?.debugDescription))
                            }
                        } else {
                            finish(Outcome())
                        }
                    })
                case .failed(let error), .waiting(let error):
                    finish(Outcome(error: error.debugDescription))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [self] in finish(Outcome()) }
        }
    }

    private func finish(_ outcome: Outcome) {
        guard let completion else { return }
        self.completion = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        completion(outcome)
    }
}

// MARK: - DNS

struct DNSLookup: Sendable, Equatable {
    var response: DNSResponse?
    /// Seconds from sending the question to reading the answer.
    var roundTrip: Double?
}

enum DNS {
    static func query(_ name: String, type: DNSRecordType, server: String,
                      timeout: Double = 3) async -> DNSLookup {
        let identifier = UInt16.random(in: 1...UInt16.max)
        guard let question = DNSMessage.query(id: identifier, name: name, type: type) else {
            return DNSLookup()
        }
        let started = HostClock.now
        guard let data = await UDP.exchange(host: server, port: 53, payload: question, timeout: timeout),
              let response = DNSMessage.parse(data), response.id == identifier else { return DNSLookup() }
        return DNSLookup(response: response, roundTrip: HostClock.now - started)
    }

    /// The name a resolver — typically the router — has for an address.
    static func reverse(_ address: IPv4Addr, server: String, timeout: Double = 0.8) async -> String? {
        let lookup = await query(address.reverseName, type: .ptr, server: server, timeout: timeout)
        guard let record = lookup.response?.answers.first(where: { $0.type == DNSRecordType.ptr.rawValue }) else { return nil }
        let name = record.value.hasSuffix(".") ? String(record.value.dropLast()) : record.value
        return name.isEmpty ? nil : name
    }

    /// The name the system's resolver has for an address — what a traceroute hop is called.
    static func systemReverse(_ address: IPv4Addr) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var target = sockaddr_in()
                target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                target.sin_family = sa_family_t(AF_INET)
                target.sin_addr.s_addr = address.value.bigEndian
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let status = withUnsafePointer(to: &target) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &buffer,
                                    socklen_t(buffer.count), nil, 0, NI_NAMEREQD)
                    }
                }
                continuation.resume(returning: status == 0 ? String(cString: buffer) : nil)
            }
        }
    }

    /// What the system's own resolver makes of a name — the answer the app's other
    /// connections get, which is not always the one a chosen server gives.
    static func system(_ host: String) async -> (addresses: [String], seconds: Double) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let started = HostClock.now
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                var result: UnsafeMutablePointer<addrinfo>?
                var addresses: [String] = []
                if getaddrinfo(host, nil, &hints, &result) == 0 {
                    var cursor = result
                    while let entry = cursor {
                        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen,
                                       &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                            let text = String(cString: buffer)
                            if !addresses.contains(text) { addresses.append(text) }
                        }
                        cursor = entry.pointee.ai_next
                    }
                    freeaddrinfo(result)
                }
                continuation.resume(returning: (addresses, HostClock.now - started))
            }
        }
    }
}

// MARK: - TLS

struct TLSReport: Sendable {
    var chain: [CertificateSummary]
    /// "TLS 1.3"
    var protocolVersion: String
    var applicationProtocol: String?
    /// Seconds from the first packet to a finished handshake.
    var handshake: Double
    /// Whether the system would trust this chain for this name.
    var trusted: Bool
    var trustError: String?
}

enum TLSInspector {
    /// Connects, takes whatever certificate chain the server shows — trusted or not — and
    /// says what the system makes of it. Nothing is sent beyond the handshake.
    static func inspect(host: String, port: Int = 443, timeout: Double = 6) async -> TLSReport? {
        await withCheckedContinuation { continuation in
            TLSAttempt(host: host, port: port, timeout: timeout).start { continuation.resume(returning: $0) }
        }
    }
}

private final class TLSAttempt: @unchecked Sendable {
    private let host: String
    private let port: Int
    private let timeout: Double
    private let queue = DispatchQueue(label: "ch.sensorstorm.tls")
    private var connection: NWConnection?
    private var completion: (@Sendable (TLSReport?) -> Void)?
    private var chain: [CertificateSummary] = []
    private var trusted = false
    private var trustError: String?
    private var startedAt = 0.0

    init(host: String, port: Int, timeout: Double) {
        self.host = host
        self.port = port
        self.timeout = timeout
    }

    func start(_ completion: @escaping @Sendable (TLSReport?) -> Void) {
        queue.async { [self] in
            self.completion = completion
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return finish(nil) }

            let tls = NWProtocolTLS.Options()
            let host = self.host
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [self] _, trust, complete in
                let reference = sec_trust_copy_ref(trust).takeRetainedValue()
                var error: CFError?
                // Evaluated against the name asked for, so a certificate for another host is
                // reported as not trusted rather than as fine.
                SecTrustSetPolicies(reference, SecPolicyCreateSSL(true, host as CFString))
                trusted = SecTrustEvaluateWithError(reference, &error)
                trustError = error.map { ($0 as Error).localizedDescription }
                let certificates = (SecTrustCopyCertificateChain(reference) as? [SecCertificate]) ?? []
                chain = certificates.compactMap {
                    CertificateSummary.parse(der: SecCertificateCopyData($0) as Data)
                }
                // Looking at a certificate is not accepting it: the person wants to read what
                // a self-signed or expired one says, so the handshake is allowed to finish.
                complete(true)
            }, queue)

            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort,
                                          using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
            self.connection = connection
            startedAt = HostClock.now
            connection.stateUpdateHandler = { [self] state in
                switch state {
                case .ready: report()
                case .failed, .waiting: finish(nil)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [self] in finish(nil) }
        }
    }

    private func report() {
        let handshake = HostClock.now - startedAt
        var version = "TLS"
        var application: String?
        if let metadata = connection?.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
            let security = metadata.securityProtocolMetadata
            switch sec_protocol_metadata_get_negotiated_tls_protocol_version(security) {
            case .TLSv13: version = "TLS 1.3"
            case .TLSv12: version = "TLS 1.2"
            case .TLSv11: version = "TLS 1.1"
            case .TLSv10: version = "TLS 1.0"
            default: version = "TLS"
            }
            if let pointer = sec_protocol_metadata_get_negotiated_protocol(security) {
                application = String(cString: pointer)
            }
        }
        finish(TLSReport(chain: chain, protocolVersion: version, applicationProtocol: application,
                         handshake: handshake, trusted: trusted, trustError: trustError))
    }

    private func finish(_ report: TLSReport?) {
        guard let completion else { return }
        self.completion = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        completion(report)
    }
}

// MARK: - HTTP

/// One HTTP request, timed phase by phase.
struct HTTPReport: Sendable {
    var statusCode: Int?
    var finalURL: String
    var redirects: Int
    var headers: [(name: String, value: String)]
    /// Seconds. `nil` where the phase did not happen — a reused connection has no DNS lookup.
    var dns: Double?
    var connect: Double?
    var tls: Double?
    var timeToFirstByte: Double?
    var total: Double
    var bytes: Int64
    var networkProtocol: String?
    var tlsVersion: String?
    var remoteAddress: String?
    var usedProxy: Bool
    /// The first 4 KB of the body as text, for the tools that read what comes back.
    var bodyPreview: String?
    var error: String?
}

enum HTTPProbe {
    static func request(_ url: URL, method: String = "GET", timeout: Double = 15) async -> HTTPReport {
        let collector = MetricsCollector()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Sensorstorm", forHTTPHeaderField: "User-Agent")

        let started = HostClock.now
        var response: HTTPURLResponse?
        var failure: String?
        var received: Int64 = 0
        var preview: String?
        do {
            let (data, urlResponse) = try await session.data(for: request)
            response = urlResponse as? HTTPURLResponse
            received = Int64(data.count)
            preview = String(data: data.prefix(4_096), encoding: .utf8)
        } catch {
            failure = error.localizedDescription
        }
        let total = HostClock.now - started
        return collector.report(response: response, total: total, bytes: received,
                                preview: preview, fallbackURL: url, error: failure)
    }
}

private final class MetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var metrics: URLSessionTaskMetrics?

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock(); self.metrics = metrics; lock.unlock()
    }

    func report(response: HTTPURLResponse?, total: Double, bytes: Int64, preview: String?,
                fallbackURL: URL, error: String?) -> HTTPReport {
        lock.lock(); let metrics = self.metrics; lock.unlock()
        let last = metrics?.transactionMetrics.last

        func span(_ start: Date?, _ end: Date?) -> Double? {
            guard let start, let end, end >= start else { return nil }
            return end.timeIntervalSince(start)
        }
        let headers = (response?.allHeaderFields ?? [:]).compactMap { key, value -> (name: String, value: String)? in
            guard let name = key as? String, let text = value as? String else { return nil }
            return (name, text)
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }

        var version: String?
        if let raw = last?.negotiatedTLSProtocolVersion {
            switch raw {
            case .TLSv13: version = "TLS 1.3"
            case .TLSv12: version = "TLS 1.2"
            default: version = "TLS"
            }
        }
        return HTTPReport(
            statusCode: response?.statusCode,
            finalURL: (response?.url ?? fallbackURL).absoluteString,
            redirects: metrics?.redirectCount ?? 0,
            headers: headers,
            dns: span(last?.domainLookupStartDate, last?.domainLookupEndDate),
            connect: span(last?.connectStartDate, last?.secureConnectionStartDate ?? last?.connectEndDate),
            tls: span(last?.secureConnectionStartDate, last?.secureConnectionEndDate),
            timeToFirstByte: span(last?.requestEndDate ?? last?.requestStartDate, last?.responseStartDate),
            total: total,
            bytes: bytes,
            networkProtocol: last?.networkProtocolName,
            tlsVersion: version,
            remoteAddress: last?.remoteAddress,
            usedProxy: last?.isProxyConnection ?? false,
            bodyPreview: preview,
            error: error)
    }
}
