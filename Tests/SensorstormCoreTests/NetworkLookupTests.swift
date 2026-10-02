import Foundation
import Testing
@testable import SensorstormCore

@Suite("Hardware-Adressen, Hersteller, ARP, AS-Abfrage, Portzeilen")
struct NetworkLookupTests {

    @Test("Eine Hardware-Adresse in jeder üblichen Schreibweise")
    func macParsing() throws {
        let mac = try #require(MACAddress("AA-BB-CC-01-02-03"))
        #expect(mac.description == "aa:bb:cc:01:02:03")
        #expect(mac.formatted(uppercase: true, separator: "-") == "AA-BB-CC-01-02-03")
        #expect(mac.oui == 0xAABBCC)
        #expect(MACAddress("aabb.cc01.0203") == mac)
        #expect(MACAddress("aa:bb:cc:01:02") == nil)
        #expect(MACAddress("gg:bb:cc:01:02:03") == nil)
        #expect(MACAddress(bytes: [1, 2, 3]) == nil)
    }

    @Test("Zufällige und Gruppenadressen werden erkannt")
    func macFlags() throws {
        let random = try #require(MACAddress("02:00:00:00:00:01"))
        let privateWiFi = try #require(MACAddress("da:a1:19:00:00:00"))
        let burnedIn = try #require(MACAddress("00:1b:63:84:45:e6"))
        let group = try #require(MACAddress("01:00:5e:00:00:fb"))
        #expect(random.isLocallyAdministered && privateWiFi.isLocallyAdministered)
        #expect(!burnedIn.isLocallyAdministered && !burnedIn.isMulticast)
        #expect(group.isMulticast)
        let json = try JSONEncoder().encode(["mac": burnedIn])
        #expect(String(decoding: json, as: UTF8.self).contains("00:1b:63:84:45:e6"))
        #expect(try JSONDecoder().decode([String: MACAddress].self, from: json)["mac"]?.oui == 0x001B63)
    }

    private let list = Data("""
        000000\tXEROX CORPORATION
        001B63\tApple, Inc.
        3C2EF9\tApple, Inc.
        B827EB\tRaspberry Pi Foundation
        FCFC48\tApple, Inc.

        """.utf8)

    @Test("Der Hersteller wird im Text gesucht, ohne ein Wörterbuch aufzubauen")
    func ouiLookup() throws {
        let database = OUIDatabase(text: list)
        #expect(database.count == 5)
        #expect(database.vendor(of: try #require(MACAddress("00:1b:63:84:45:e6"))) == "Apple, Inc.")
        #expect(database.vendor(of: try #require(MACAddress("b8:27:eb:00:00:01"))) == "Raspberry Pi Foundation")
        #expect(database.vendor(of: try #require(MACAddress("00:00:00:00:00:01"))) == "XEROX CORPORATION")
        #expect(database.vendor(of: try #require(MACAddress("fc:fc:48:00:00:00"))) == "Apple, Inc.")
        #expect(database.vendor(of: try #require(MACAddress("00:11:22:00:00:00"))) == nil)
        // Locally administered: a lookup would only find a company by accident.
        #expect(database.vendor(of: try #require(MACAddress("02:1b:63:84:45:e6"))) == nil)
    }

    @Test("Die ausgelieferte Form: roh komprimiert, wieder lesbar")
    func ouiCompressed() throws {
        let packed = try (list as NSData).compressed(using: .zlib) as Data
        let database = try #require(OUIDatabase(compressed: packed))
        #expect(database.vendor(oui: 0x3C2EF9) == "Apple, Inc.")
        #expect(OUIDatabase(compressed: Data([1, 2, 3, 4])) == nil)
    }

    @Test("Herstellernamen für eine Listenzeile kürzen")
    func shortNames() {
        #expect(OUIDatabase.shortName("Apple, Inc.") == "Apple")
        #expect(OUIDatabase.shortName("Hon Hai Precision Ind. Co.,Ltd.") == "Hon Hai Precision Ind.")
        #expect(OUIDatabase.shortName("TP-LINK TECHNOLOGIES CO.,LTD.") == "TP-LINK")
        #expect(OUIDatabase.shortName("Raspberry Pi Foundation") == "Raspberry Pi Foundation")
        #expect(OUIDatabase.shortName("AVM GmbH") == "AVM")
    }

    /// A routing message the way the kernel writes it: a 92-byte header, then the address
    /// and the link-layer address, each padded to four bytes.
    private func message(ip: [UInt8], mac: [UInt8], nameLength: UInt8 = 0) -> [UInt8] {
        let inet: [UInt8] = [16, 2, 0, 0] + ip + [UInt8](repeating: 0, count: 8)
        var link: [UInt8] = [UInt8(8 + Int(nameLength) + mac.count), 18, 2, 0, 6, nameLength, UInt8(mac.count), 0]
            + [UInt8](repeating: 0x61, count: Int(nameLength)) + mac
        while link.count % 4 != 0 { link.append(0) }
        let length = 92 + inet.count + link.count
        var header = [UInt8](repeating: 0, count: 92)
        header[0] = UInt8(length & 0xFF); header[1] = UInt8(length >> 8)
        header[12] = 3   // RTA_DST | RTA_GATEWAY
        return header + inet + link
    }

    @Test("Die Nachbartabelle des Kernels, mit unvollständigen Einträgen und Namen im Link-Teil")
    func arpTable() throws {
        let buffer = message(ip: [192, 168, 1, 10], mac: [0x00, 0x1B, 0x63, 0x84, 0x45, 0xE6])
            + message(ip: [192, 168, 1, 11], mac: [])
            + message(ip: [192, 168, 1, 255], mac: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
            + message(ip: [192, 168, 1, 12], mac: [0xB8, 0x27, 0xEB, 0x01, 0x02, 0x03], nameLength: 3)
        let entries = ARPTable.parse(buffer)
        #expect(entries.count == 2)
        #expect(entries[0].address.description == "192.168.1.10" && entries[0].mac.description == "00:1b:63:84:45:e6")
        #expect(entries[1].address.description == "192.168.1.12" && entries[1].mac.oui == 0xB827EB)
    }

    @Test("Beschädigte Puffer geben leer oder das Lesbare zurück, keinen Absturz")
    func arpMalformed() {
        #expect(ARPTable.parse([]).isEmpty)
        #expect(ARPTable.parse([UInt8](repeating: 0, count: 200)).isEmpty)
        let good = message(ip: [10, 0, 0, 2], mac: [0x00, 0x1B, 0x63, 4, 5, 6])
        #expect(ARPTable.parse(good + [0xFF, 0xFF] + [UInt8](repeating: 0, count: 100)).count == 1)
        #expect(ARPTable.parse(Array(good.dropLast(5))).isEmpty)
    }

    @Test("Die Fragen und Antworten der AS-Abfrage")
    func asnLookup() throws {
        let address = try #require(IPv4Addr("8.8.4.4"))
        #expect(ASNLookup.originQuery(for: address) == "4.4.8.8.origin.asn.cymru.com")
        #expect(ASNLookup.nameQuery(asn: 15169) == "AS15169.asn.cymru.com")

        let origin = try #require(ASNLookup.parseOrigin("15169 | 8.8.4.0/24 | US | arin | 2014-03-14"))
        #expect(origin.asn == 15169 && origin.prefix == "8.8.4.0/24" && origin.countryCode == "US")
        #expect(origin.registry == "arin" && origin.flag == "🇺🇸")
        let named = ASNLookup.parseName("15169 | US | arin | 2000-03-30 | GOOGLE, US", into: origin)
        #expect(named.name == "GOOGLE" && named.label == "AS15169 GOOGLE")
        let long = ASNLookup.parseName("3320 | DE | ripencc | 1994-01-01 | DTAG Internet service provider operations, DE", into: ASNInfo(asn: 3320))
        #expect(long.name == "DTAG Internet service provider operations" && long.countryCode == "DE")

        #expect(ASNLookup.parseOrigin("15169 23456 | 8.8.8.0/24 | US | arin | 2023-12-28")?.asn == 15169)
        #expect(ASNLookup.parseOrigin("\"NA | | | |\"") == nil)
        #expect(ASNLookup.parseOrigin("") == nil)
    }

    @Test("Nur Adressen, die ein fremdes Netz besitzen kann, werden nachgeschlagen")
    func asnLookupable() throws {
        for text in ["8.8.8.8", "93.184.216.34", "1.1.1.1"] {
            #expect(ASNLookup.isLookupable(try #require(IPv4Addr(text))), "\(text)")
        }
        for text in ["192.168.1.1", "10.0.0.1", "172.16.5.5", "100.64.0.1", "127.0.0.1", "169.254.1.1",
                     "0.0.0.0", "224.0.0.251", "255.255.255.255"] {
            #expect(!ASNLookup.isLookupable(try #require(IPv4Addr(text))), "\(text)")
        }
    }

    @Test("Flaggen aus Ländercodes")
    func flags() {
        #expect(CountryFlag.emoji("ch") == "🇨🇭")
        #expect(CountryFlag.emoji("DE") == "🇩🇪")
        #expect(CountryFlag.emoji("EU") == "🇪🇺")
        #expect(CountryFlag.emoji("") == nil)
        #expect(CountryFlag.emoji("USA") == nil)
        #expect(CountryFlag.emoji("1A") == nil)
    }

    @Test("Ports: offene Zeilen und zusammengefasste geschlossene Bereiche")
    func portRows() {
        let rows = PortRow.rows(scanned: Array(1...100), open: [22, 80])
        #expect(rows == [.closed(first: 1, last: 21, count: 21), .open(port: 22),
                         .closed(first: 23, last: 79, count: 57), .open(port: 80),
                         .closed(first: 81, last: 100, count: 20)])
        // A scan of the common ports: the run counts what was tried, not what lies between.
        let common = PortRow.rows(scanned: [7, 9, 21, 22, 443, 8080], open: [443])
        #expect(common == [.closed(first: 7, last: 22, count: 4), .open(port: 443),
                           .closed(first: 8080, last: 8080, count: 1)])
        #expect(PortRow.rows(scanned: [1, 2, 3], open: []) == [.closed(first: 1, last: 3, count: 3)])
        #expect(PortRow.rows(scanned: [], open: []).isEmpty)
        // An open port the scan did not list (a banner probe found it) still gets a row.
        #expect(PortRow.rows(scanned: [1], open: [5]) == [.closed(first: 1, last: 1, count: 1), .open(port: 5)])
    }

    @Test("Ports haben Namen und ausgeschriebene Bezeichnungen")
    func portTitles() {
        #expect(PortCatalog.title(22) == "Secure Shell (SSH)")
        #expect(PortCatalog.title(443) == "HTTP over TLS (HTTPS)")
        #expect(PortCatalog.title(1) == "")
        for port in PortCatalog.top100 + PortCatalog.devices where !PortCatalog.name(port).isEmpty {
            #expect(!PortCatalog.title(port).isEmpty,
                    "Port \(port) hat einen Namen, aber keine Bezeichnung")
        }
    }

    @Test("Die Kürzel eines Geräts folgen aus dem, was der Scan fand")
    func hostBadges() {
        let router = HostRecord(address: "192.168.1.1", services: ["_http._tcp"], openPorts: [53, 80, 443],
                                sources: ["ping", "ssdp"])
        #expect(HostBadge.badges(for: router, isGateway: true) == [.gateway, .web, .upnp, .bonjour, .dns])
        let printer = HostRecord(address: "192.168.1.30", services: ["_ipp._tcp"], openPorts: [631, 9100],
                                 sources: ["bonjour"])
        #expect(HostBadge.badges(for: printer, isGateway: false) == [.printer, .bonjour])
        let server = HostRecord(address: "192.168.1.40", openPorts: [22, 445, 3306, 25], sources: ["tcp", "netbios"])
        #expect(HostBadge.badges(for: server, isGateway: false) == [.ssh, .files, .netbios, .mail, .database])
        #expect(HostBadge.badges(for: HostRecord(address: "192.168.1.50"), isGateway: false).isEmpty)
        #expect(Set(HostBadge.allCases.map(\.letter)).count == HostBadge.allCases.count)
    }

    @Test("Die Hardware-Adresse eines Geräts wandert in den Bestand und in die Tabelle")
    func hostMAC() {
        var host = HostRecord(address: "10.0.0.5")
        host.merge(HostRecord(address: "10.0.0.5", mac: "00:1b:63:84:45:e6"))
        #expect(host.mac == "00:1b:63:84:45:e6")
        host.merge(HostRecord(address: "10.0.0.5"))
        #expect(host.mac == "00:1b:63:84:45:e6")
        let snapshot = NetworkSnapshot(networkName: "x", subnet: "10.0.0.0/24", hosts: [host])
        let line = snapshot.csv { $0.oui == 0x001B63 ? "Apple, Inc." : nil }.split(separator: "\n")[1]
        #expect(line.hasSuffix(",00:1b:63:84:45:e6,\"Apple, Inc.\""))
        // An older saved scan has no such field and must still load.
        let old = Data(#"{"address":"10.0.0.9","hostNames":[],"services":[],"openPorts":[],"sources":[],"guess":"unknown"}"#.utf8)
        #expect((try? JSONDecoder().decode(HostRecord.self, from: old))?.mac == nil)
    }

    @Test("Der Herstellername gibt einen Hinweis, wenn nichts anderes die Art verrät")
    func vendorGuess() {
        #expect(DeviceClassifier.guess(vendor: "Apple, Inc.") == .apple)
        #expect(DeviceClassifier.guess(vendor: "Espressif Inc.") == .smartHome)
        #expect(DeviceClassifier.guess(vendor: "Hangzhou Hikvision Digital Technology Co.,Ltd.") == .camera)
        #expect(DeviceClassifier.guess(vendor: "Seiko Epson Corporation") == .printer)
        #expect(DeviceClassifier.guess(vendor: "Synology Incorporated") == .nas)
        #expect(DeviceClassifier.guess(vendor: "Raspberry Pi Foundation") == .computer)
        // A company that makes routers and plugs and phones says nothing about this device.
        #expect(DeviceClassifier.guess(vendor: "TP-LINK TECHNOLOGIES CO.,LTD.") == nil)
        #expect(DeviceClassifier.guess(vendor: "Samsung Electronics Co.,Ltd") == nil)
    }
}
