import Foundation

/// The ports worth asking about, with the name a service usually answers to.
///
/// A port scan of 65 535 ports takes minutes and tells a person nothing they cannot learn
/// from the hundred that matter. The first list is nmap's hundred most frequently open TCP
/// ports; the second adds the rest of the well-known range and the services that live in
/// networks full of small devices — MQTT, Home Assistant, Node-RED, ESPHome, Modbus.
public enum PortCatalog {

    public static let top100: [Int] = [
        7, 9, 13, 21, 22, 23, 25, 26, 37, 53, 79, 80, 81, 88, 106, 110, 111, 113, 119, 135,
        139, 143, 144, 179, 199, 389, 427, 443, 444, 445, 465, 513, 514, 515, 543, 544, 548,
        554, 587, 631, 646, 873, 990, 993, 995, 1025, 1026, 1027, 1028, 1029, 1110, 1433,
        1720, 1723, 1755, 1900, 2000, 2001, 2049, 2121, 3000, 3128, 3306, 3389, 3986, 4899,
        5000, 5009, 5051, 5060, 5101, 5190, 5357, 5432, 5631, 5666, 5800, 5900, 6000, 6001,
        6646, 7070, 8000, 8008, 8009, 8080, 8081, 8443, 8888, 9100, 9999, 10000, 32768,
        49152, 49153, 49154, 49155, 49156, 49157,
    ]

    /// Services of the small-device world, beyond nmap's list.
    public static let devices: [Int] = [
        502, 1880, 1883, 4840, 5353, 5683, 6053, 6668, 8086, 8123, 8883, 9090, 62078,
    ]

    /// 1–1024 and the device ports.
    public static var wellKnown: [Int] {
        Array(Set(Array(1...1_024) + top100 + devices)).sorted()
    }

    public static func services(_ preset: Preset, custom: [Int] = []) -> [Int] {
        switch preset {
        case .top100: top100 + devices
        case .wellKnown: wellKnown
        case .custom: Array(Set(custom.filter { (1...65_535).contains($0) })).sorted()
        }
    }

    public enum Preset: String, Sendable, CaseIterable {
        case top100, wellKnown, custom
    }

    /// „22, 80, 8000-8100" → the ports. A range runs at most 4096 ports and a list at most
    /// 4096 in all, so a typo cannot start a scan that never ends. `nil` for text that is not
    /// a list of ports.
    public static func parse(_ text: String) -> [Int]? {
        var ports = Set<Int>()
        for part in text.split(whereSeparator: { ", ;\n".contains($0) }) {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
            switch bounds.count {
            case 1:
                guard let port = Int(bounds[0]), (1...65_535).contains(port) else { return nil }
                ports.insert(port)
            case 2:
                guard let low = Int(bounds[0]), let high = Int(bounds[1]),
                      (1...65_535).contains(low), (1...65_535).contains(high),
                      low <= high, high - low < 4_096 else { return nil }
                ports.formUnion(low...high)
            default:
                return nil
            }
            guard ports.count <= 4_096 else { return nil }
        }
        return ports.sorted()
    }

    /// What a service on this port is usually called. Empty for a port without a well-known use.
    public static func name(_ port: Int) -> String {
        names[port] ?? ""
    }

    private static let names: [Int: String] = [
        7: "echo", 9: "discard", 13: "daytime", 21: "ftp", 22: "ssh", 23: "telnet", 25: "smtp",
        37: "time", 53: "dns", 79: "finger", 80: "http", 81: "http-alt", 88: "kerberos",
        110: "pop3", 111: "rpcbind", 113: "ident", 119: "nntp", 135: "msrpc",
        139: "netbios-ssn", 143: "imap", 179: "bgp", 389: "ldap", 427: "slp", 443: "https",
        445: "smb", 465: "smtps", 502: "modbus", 514: "syslog", 515: "printer", 548: "afp",
        554: "rtsp", 587: "submission", 631: "ipp", 646: "ldp", 873: "rsync", 990: "ftps",
        993: "imaps", 995: "pop3s", 1433: "mssql", 1720: "h323", 1723: "pptp", 1880: "node-red",
        1883: "mqtt", 1900: "upnp", 2049: "nfs", 3128: "squid", 3306: "mysql", 3389: "rdp",
        4840: "opc-ua", 4899: "radmin", 5000: "upnp", 5060: "sip", 5353: "mdns",
        5357: "wsdapi", 5432: "postgresql", 5683: "coap", 5900: "vnc", 6000: "x11",
        6053: "esphome", 6668: "tuya", 7070: "realserver", 8000: "http-alt", 8008: "http-alt",
        8009: "ajp13", 8080: "http-proxy", 8081: "http-alt", 8086: "influxdb",
        8123: "home-assistant", 8443: "https-alt", 8883: "mqtts", 8888: "http-alt",
        9090: "http-alt", 9100: "jetdirect", 62078: "iphone-sync",
    ]
}
