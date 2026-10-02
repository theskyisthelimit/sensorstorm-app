import Foundation

/// One line of a port scan's result: an open port, or a run of ports that stayed shut.
///
/// A scan of 1 024 ports with three open ones is a list of three lines and four grey ranges
/// between them, not a thousand rows of nothing. The ranges say what was looked at, which is
/// the part a bare list of the open ports leaves out.
public enum PortRow: Sendable, Equatable, Hashable {
    case open(port: Int)
    /// `count` ports between `first` and `last` were tried and refused or stayed silent. Fewer
    /// than `last - first + 1` when the scan skipped some, as the list of common ports does.
    case closed(first: Int, last: Int, count: Int)

    /// The rows for a scan of `scanned` in which `open` answered.
    public static func rows(scanned: [Int], open: [Int]) -> [PortRow] {
        let openSet = Set(open)
        var rows: [PortRow] = []
        var runFirst: Int?
        var runLast = 0
        var runCount = 0
        func flush() {
            if let first = runFirst { rows.append(.closed(first: first, last: runLast, count: runCount)) }
            runFirst = nil
            runCount = 0
        }
        for port in Set(scanned).union(openSet).sorted() {
            if openSet.contains(port) {
                flush()
                rows.append(.open(port: port))
            } else {
                if runFirst == nil { runFirst = port }
                runLast = port
                runCount += 1
            }
        }
        flush()
        return rows
    }
}

extension PortCatalog {
    /// What a port is for, spelled out the way a person would look it up. Empty for a port with
    /// no well-known use. Technical names, deliberately not translated: they are what the
    /// protocol is called everywhere.
    public static func title(_ port: Int) -> String {
        titles[port] ?? ""
    }

    private static let titles: [Int: String] = [
        7: "Echo", 9: "Discard", 13: "Daytime", 19: "Character Generator", 20: "FTP data",
        21: "File Transfer Protocol (FTP)", 22: "Secure Shell (SSH)", 23: "Telnet",
        25: "Simple Mail Transfer Protocol (SMTP)", 37: "Time", 53: "Domain Name System (DNS)",
        67: "DHCP server", 68: "DHCP client", 69: "Trivial FTP (TFTP)", 79: "Finger",
        80: "Hypertext Transfer Protocol (HTTP)", 81: "HTTP alternate", 88: "Kerberos",
        110: "Post Office Protocol (POP3)", 111: "Remote Procedure Call (rpcbind)",
        113: "Identification Protocol (ident)", 119: "Network News Transfer Protocol (NNTP)",
        123: "Network Time Protocol (NTP)", 135: "Microsoft RPC", 137: "NetBIOS name service",
        138: "NetBIOS datagram service", 139: "NetBIOS session service",
        143: "Internet Message Access Protocol (IMAP)", 161: "Simple Network Management Protocol (SNMP)",
        162: "SNMP trap", 179: "Border Gateway Protocol (BGP)", 389: "Lightweight Directory Access Protocol (LDAP)",
        427: "Service Location Protocol (SLP)", 443: "HTTP over TLS (HTTPS)", 445: "Microsoft Directory Services (SMB)",
        465: "SMTP over TLS (SMTPS)", 500: "Internet Key Exchange (IKE)", 502: "Modbus TCP",
        513: "Remote login (rlogin)", 514: "Syslog", 515: "Line Printer Daemon (LPD)",
        543: "Kerberos login", 544: "Remote shell (kshell)", 548: "Apple Filing Protocol (AFP)",
        554: "Real Time Streaming Protocol (RTSP)", 587: "Mail submission (SMTP)", 631: "Internet Printing Protocol (IPP)",
        636: "LDAP over TLS (LDAPS)", 646: "Label Distribution Protocol (LDP)", 873: "rsync",
        990: "FTP over TLS (FTPS)", 993: "IMAP over TLS (IMAPS)", 995: "POP3 over TLS (POP3S)",
        1080: "SOCKS proxy", 1194: "OpenVPN", 1433: "Microsoft SQL Server", 1521: "Oracle database",
        1701: "L2TP", 1720: "H.323", 1723: "Point-to-Point Tunneling Protocol (PPTP)",
        1812: "RADIUS authentication", 1813: "RADIUS accounting", 1880: "Node-RED", 1883: "MQTT",
        1900: "Universal Plug and Play (UPnP)", 2049: "Network File System (NFS)", 2181: "Apache ZooKeeper",
        2375: "Docker API", 3000: "Development server", 3128: "Squid proxy", 3306: "MySQL",
        3389: "Remote Desktop Protocol (RDP)", 3478: "STUN/TURN", 4840: "OPC UA", 4899: "Radmin",
        5000: "UPnP / development server", 5060: "Session Initiation Protocol (SIP)", 5061: "SIP over TLS",
        5222: "XMPP client", 5353: "Multicast DNS (Bonjour)", 5357: "Web Services for Devices (WSD)",
        5432: "PostgreSQL", 5601: "Kibana", 5683: "Constrained Application Protocol (CoAP)",
        5900: "Virtual Network Computing (VNC)", 5984: "CouchDB", 6000: "X Window System",
        6053: "ESPHome native API", 6379: "Redis", 6668: "Tuya local", 7070: "RealServer",
        8000: "HTTP alternate", 8008: "HTTP alternate (Chromecast)", 8009: "Apache JServ (AJP13)",
        8080: "HTTP proxy / alternate", 8081: "HTTP alternate", 8086: "InfluxDB", 8123: "Home Assistant",
        8443: "HTTPS alternate", 8883: "MQTT over TLS", 8888: "HTTP alternate", 9000: "Portainer / SonarQube",
        9090: "HTTP alternate", 9100: "Raw printing (JetDirect)", 9200: "Elasticsearch", 11211: "Memcached",
        27017: "MongoDB", 32400: "Plex Media Server", 51820: "WireGuard", 62078: "iPhone sync (lockdownd)",
    ]
}
