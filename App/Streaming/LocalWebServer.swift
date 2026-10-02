import Foundation
import Network

/// The phone as a server: anything on the same Wi-Fi can fetch the newest value of every
/// sensor with a plain `GET`, instead of the phone pushing to a server somebody has to run.
///
/// The answer is the push payload's shape — `{messageId, sessionId, deviceId, payload}` —
/// with one entry per sensor, so a script written against the HTTP push reads this too.
/// `Access-Control-Allow-Origin: *`, because the obvious client is a dashboard page opened
/// in a browser from somewhere else.
///
/// Read-only and on the local network only: there is no route that changes anything, and
/// nothing is announced over Bonjour — the address is on the settings screen for whoever
/// holds the phone.
final class LocalWebServer: @unchecked Sendable {
    static let port: UInt16 = 8080

    private let queue = DispatchQueue(label: "ch.sensorstorm.webserver")
    private let lock = NSLock()
    private var listener: NWListener?
    private let body: @Sendable () -> String

    /// - Parameter body: builds the JSON for one request, on the server's queue.
    init(body: @escaping @Sendable () -> String) {
        self.body = body
    }

    var isRunning: Bool { lock.withLock { listener != nil } }

    func start() {
        guard !isRunning,
              let listener = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
        else { return }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.stop() }
        }
        listener.start(queue: queue)
        lock.withLock { self.listener = listener }
    }

    func stop() {
        let listener = lock.withLock { () -> NWListener? in
            defer { self.listener = nil }
            return self.listener
        }
        listener?.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            // A browser asks for „/" and wants the page; a script asks for „/" and wants the
            // JSON it has always got. The Accept header tells them apart, and „/data" is
            // always the data.
            let wantsPage = request.lowercased().contains("accept: text/html") || request.lowercased().contains("accept:text/html")
            let route = String(path.split(separator: "?").first ?? "")
            let response: (status: String, type: String, body: String)
            switch route {
            case "/dashboard": response = ("200 OK", "text/html; charset=utf-8", DashboardPage.html)
            case "/" where wantsPage: response = ("200 OK", "text/html; charset=utf-8", DashboardPage.html)
            case "/", "/data": response = ("200 OK", "application/json", self.body())
            default: response = ("404 Not Found", "application/json", #"{"error":"not found"}"#)
            }
            let payload = Data(response.body.utf8)
            let head = "HTTP/1.1 \(response.status)\r\n"
                + "Content-Type: \(response.type)\r\n"
                + "Access-Control-Allow-Origin: *\r\n"
                + "Cache-Control: no-store\r\n"
                + "Content-Length: \(payload.count)\r\n"
                + "Connection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    /// The phone's IPv4 addresses on Wi-Fi and Ethernet — what someone types into a browser.
    static func addresses() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: interface.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.append(String(cString: host))
        }
        return result
    }
}
