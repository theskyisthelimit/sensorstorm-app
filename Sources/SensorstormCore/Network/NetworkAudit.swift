import Foundation

/// What a scan of a network says about its hygiene, in the terms an acceptance protocol uses:
/// which device offers a service it should not, and why that matters.
///
/// Only what a port answer can show. A phone cannot say a service is *vulnerable*; it can say
/// that a Telnet door is open on a printer, and that is a sentence a customer acts on.
public struct NetworkFinding: Sendable, Equatable, Identifiable {
    public enum Severity: Int, Sendable, Comparable, CaseIterable {
        case info = 0, warning = 1, critical = 2

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum Kind: String, Sendable, CaseIterable {
        /// Telnet, rsh, the Docker API, adb: remote control without a password prompt worth the name.
        case remoteShell
        case ftp
        case remoteDesktop
        case fileSharing
        case database
        case plainHTTPOnly
        case camera
        case messageBroker
    }

    public var address: String
    public var name: String
    public var port: Int
    public var kind: Kind
    public var severity: Severity

    public var id: String { "\(address):\(port):\(kind.rawValue)" }

    public init(address: String, name: String, port: Int, kind: Kind, severity: Severity) {
        self.address = address
        self.name = name
        self.port = port
        self.kind = kind
        self.severity = severity
    }
}

public enum NetworkAudit {
    private struct Rule {
        var kind: NetworkFinding.Kind
        var severity: NetworkFinding.Severity
    }

    private static let rules: [Int: Rule] = [
        23: Rule(kind: .remoteShell, severity: .critical),      // Telnet
        2323: Rule(kind: .remoteShell, severity: .critical),
        514: Rule(kind: .remoteShell, severity: .critical),     // rsh / syslog
        2375: Rule(kind: .remoteShell, severity: .critical),    // Docker API without TLS
        5555: Rule(kind: .remoteShell, severity: .critical),    // adb
        21: Rule(kind: .ftp, severity: .warning),
        3389: Rule(kind: .remoteDesktop, severity: .warning),
        5900: Rule(kind: .remoteDesktop, severity: .warning),
        445: Rule(kind: .fileSharing, severity: .info),
        139: Rule(kind: .fileSharing, severity: .info),
        548: Rule(kind: .fileSharing, severity: .info),
        3306: Rule(kind: .database, severity: .warning),
        5432: Rule(kind: .database, severity: .warning),
        1433: Rule(kind: .database, severity: .warning),
        27017: Rule(kind: .database, severity: .warning),
        6379: Rule(kind: .database, severity: .warning),
        9200: Rule(kind: .database, severity: .warning),
        554: Rule(kind: .camera, severity: .info),              // RTSP
        1883: Rule(kind: .messageBroker, severity: .info)       // MQTT without TLS
    ]

    /// The findings of a scan, worst first, then by address.
    public static func findings(for snapshot: NetworkSnapshot) -> [NetworkFinding] {
        var found: [NetworkFinding] = []
        for host in snapshot.hosts {
            let ports = Set(host.openPorts)
            for port in host.openPorts.sorted() {
                guard let rule = rules[port] else { continue }
                found.append(NetworkFinding(address: host.address, name: host.displayName, port: port,
                                            kind: rule.kind, severity: rule.severity))
            }
            // A web interface that answers on 80 and not on 443: the login travels in clear.
            if ports.contains(80), !ports.contains(443), !ports.contains(8443) {
                found.append(NetworkFinding(address: host.address, name: host.displayName, port: 80,
                                            kind: .plainHTTPOnly, severity: .info))
            }
        }
        return found.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            let left = IPv4Addr($0.address)?.value ?? 0, right = IPv4Addr($1.address)?.value ?? 0
            return left == right ? $0.port < $1.port : left < right
        }
    }
}
