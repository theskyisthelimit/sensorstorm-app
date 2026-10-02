import Foundation
import Testing
@testable import SensorstormCore

@Suite("Netzwerk: Adressen, ICMP, DNS, Zertifikate, Bestand")
struct NetworkCoreTests {

    // MARK: - IPv4

    @Test("Adressen werden streng gelesen und gedruckt")
    func addresses() throws {
        let address = try #require(IPv4Addr("192.168.1.10"))
        #expect(address.value == 0xC0A8010A)
        #expect(address.description == "192.168.1.10")
        #expect(address.reverseName == "10.1.168.192.in-addr.arpa")
        #expect(address.isPrivate && !address.isLinkLocal && !address.isLoopback)
        #expect(IPv4Addr("172.16.0.1")?.isPrivate == true)
        #expect(IPv4Addr("172.32.0.1")?.isPrivate == false)
        #expect(IPv4Addr("169.254.3.4")?.isLinkLocal == true)
        #expect(IPv4Addr("100.100.1.1")?.isSharedAddressSpace == true)
        for bad in ["", "1.2.3", "1.2.3.4.5", "256.1.1.1", "1.2.3.-4", "+1.2.3.4", "1..3.4", "a.b.c.d", "1.2.3.4 "] {
            #expect(IPv4Addr(bad) == nil, "\(bad)")
        }
        #expect(IPv4Addr("0.0.0.0")?.value == 0)
    }

    @Test("Teilnetze: Maske, Rechnen, Hosts und das Fenster um das eigene Gerät")
    func subnets() throws {
        let own = try #require(IPv4Addr("192.168.1.20"))
        let subnet = try #require(IPv4Subnet(address: own, netmask: IPv4Addr("255.255.255.0")!))
        #expect(subnet.prefix == 24)
        #expect(subnet.network.description == "192.168.1.0")
        #expect(subnet.broadcast.description == "192.168.1.255")
        #expect(subnet.hostCount == 254)
        #expect(subnet.contains(IPv4Addr("192.168.1.99")!))
        #expect(!subnet.contains(IPv4Addr("192.168.2.1")!))
        let hosts = subnet.hosts(excluding: [own])
        #expect(hosts.count == 253)
        #expect(hosts.first?.description == "192.168.1.1" && hosts.last?.description == "192.168.1.254")
        #expect(!hosts.contains(own))

        // A mask that is not a run of ones is refused.
        #expect(IPv4Subnet(address: own, netmask: IPv4Addr("255.0.255.0")!) == nil)
        #expect(IPv4Subnet(address: own, netmask: IPv4Addr("0.0.0.0")!)?.prefix == 0)

        #expect(IPv4Subnet(address: own, prefix: 30)?.hostCount == 2)
        #expect(IPv4Subnet(address: own, prefix: 31)?.hostCount == 2)
        #expect(IPv4Subnet(address: own, prefix: 32)?.hostCount == 1)
        #expect(IPv4Subnet(address: own, prefix: 33) == nil)

        // A /16 is cut to a window of the requested size around the phone's own address.
        let large = try #require(IPv4Subnet(address: IPv4Addr("10.0.77.5")!, prefix: 16))
        let window = large.hosts(limit: 100)
        #expect(window.count == 100)
        #expect(window.first! <= IPv4Addr("10.0.77.5")! && IPv4Addr("10.0.77.5")! <= window.last!)
        #expect(window.map(\.value) == Array(window.first!.value..<(window.first!.value + 100)))
        // At the edge of the subnet the window is pushed back inside it.
        let edge = try #require(IPv4Subnet(address: IPv4Addr("10.0.0.2")!, prefix: 16))
        #expect(edge.hosts(limit: 100).first?.description == "10.0.0.1")
        let top = try #require(IPv4Subnet(address: IPv4Addr("10.0.255.250")!, prefix: 16))
        #expect(top.hosts(limit: 100).last?.description == "10.0.255.254")
        #expect(top.hosts(limit: 100).count == 100)
    }

    // MARK: - ICMP

    @Test("Die Prüfsumme einer Echo-Anfrage ist gültig und hängt vom Inhalt ab")
    func icmpChecksum() {
        let packet = ICMPPacket.echoRequest(identifier: 0x1234, sequence: 7, payload: Data("abcde".utf8))
        #expect(packet.count == 8 + 5)
        #expect([UInt8](packet.prefix(8)).prefix(2) == [8, 0])
        // Summing a packet that carries its own checksum comes out as zero.
        #expect(ICMPPacket.checksum(packet) == 0)
        let other = ICMPPacket.echoRequest(identifier: 0x1234, sequence: 8, payload: Data("abcde".utf8))
        #expect(packet != other)
        #expect(ICMPPacket.checksum(other) == 0)
    }

    private func ipHeader(source: [UInt8], ttl: UInt8, length: Int) -> [UInt8] {
        [0x45, 0, UInt8(length >> 8), UInt8(length & 0xFF), 0, 0, 0, 0, ttl, 1, 0, 0]
            + source + [192, 168, 1, 50]
    }

    @Test("Eine Echo-Antwort samt IP-Kopf wird gelesen")
    func echoReply() throws {
        let icmp: [UInt8] = [0, 0, 0, 0, 0x12, 0x34, 0x00, 0x07] + Array("abcd".utf8)
        let reply = try #require(ICMPPacket.parseReply(
            Data(ipHeader(source: [192, 168, 1, 1], ttl: 64, length: 20 + icmp.count) + icmp)))
        #expect(reply.kind == .echoReply)
        #expect(reply.source?.description == "192.168.1.1")
        #expect(reply.identifier == 0x1234 && reply.sequence == 7)
        #expect(reply.ttl == 64)
        // The same reply without an IP header — the kernel does not always keep it.
        #expect(ICMPPacket.parseReply(Data(icmp))?.sequence == 7)
        #expect(ICMPPacket.parseReply(Data([0, 0, 0])) == nil)
    }

    @Test("Time Exceeded trägt Kennung und Folgenummer der Sonde, die ihn ausgelöst hat")
    func timeExceeded() throws {
        let inner = ipHeader(source: [192, 168, 1, 50], ttl: 1, length: 28)
            + [8, 0, 0, 0, 0x12, 0x34, 0x00, 0x03]
        let icmp: [UInt8] = [11, 0, 0, 0, 0, 0, 0, 0] + inner
        let reply = try #require(ICMPPacket.parseReply(
            Data(ipHeader(source: [10, 0, 0, 1], ttl: 250, length: 20 + icmp.count) + icmp)))
        #expect(reply.kind == .timeExceeded)
        #expect(reply.source?.description == "10.0.0.1")
        #expect(reply.identifier == 0x1234 && reply.sequence == 3)

        var unreachable = icmp
        unreachable[0] = 3
        unreachable[1] = 1
        let host = try #require(ICMPPacket.parseReply(
            Data(ipHeader(source: [10, 0, 0, 1], ttl: 250, length: 20 + unreachable.count) + unreachable)))
        #expect(host.kind == .destinationUnreachable(code: 1))
    }

    @Test("Ping-Statistik: Verlust, Mittel, Streuung als mittlere Differenz")
    func pingStatistics() {
        var statistics = PingStatistics()
        #expect(statistics.average == nil && statistics.jitter == nil && statistics.lossPercent == 0)
        for sample in [0.010, 0.020, nil, 0.015] as [Double?] { statistics.record(sample) }
        #expect(statistics.sent == 4 && statistics.received == 3)
        #expect(abs(statistics.lossPercent - 25) < 1e-9)
        #expect(abs((statistics.average ?? 0) - 0.015) < 1e-12)
        #expect(statistics.minimum == 0.010 && statistics.maximum == 0.020)
        // |20−10| = 10 ms and |15−20| = 5 ms; the lost probe is not a round trip.
        #expect(abs((statistics.jitter ?? 0) - 0.0075) < 1e-12)
    }

    // MARK: - DNS

    @Test("Die Anfrage hat den Aufbau aus RFC 1035")
    func dnsQuery() throws {
        let query = try #require(DNSMessage.query(id: 0x1234, name: "a.bc.", type: .a))
        #expect([UInt8](query) == [0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0,
                                   1, 0x61, 2, 0x62, 0x63, 0, 0, 1, 0, 1])
        #expect(DNSMessage.query(id: 1, name: "a..b", type: .a) == nil)
        #expect(DNSMessage.query(id: 1, name: String(repeating: "a", count: 64) + ".com", type: .a) == nil)
        #expect(DNSMessage.query(id: 1, name: "ok.example", type: .mx)?.suffix(4) == Data([0, 15, 0, 1]))
        #expect(DNSMessage.ptrName(for: IPv4Addr("1.2.3.4")!) == "4.3.2.1.in-addr.arpa")
    }

    private func label(_ text: String) -> [UInt8] { [UInt8(text.utf8.count)] + Array(text.utf8) }

    private func question() -> [UInt8] {
        label("www") + label("example") + label("com") + [0, 0, 1, 0, 1]
    }

    @Test("Eine Antwort mit CNAME, A und komprimierten Namen")
    func dnsResponse() throws {
        // Offsets: 12 www, 16 example, 24 com, 28 end of name; the question ends at 33.
        let header: [UInt8] = [0xBE, 0xEF, 0x81, 0x80, 0, 1, 0, 2, 0, 0, 0, 0]
        let cname: [UInt8] = [0xC0, 0x0C, 0, 5, 0, 1, 0, 0, 0x01, 0x2C, 0, 6] + label("web") + [0xC0, 0x10]
        let address: [UInt8] = label("web") + [0xC0, 0x10, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 93, 184, 216, 34]
        let response = try #require(DNSMessage.parse(Data(header + question() + cname + address)))
        #expect(response.id == 0xBEEF && response.isResponse && response.rcode == 0)
        #expect(response.rcodeLabel == "NOERROR")
        #expect(response.answers.count == 2)
        #expect(response.answers[0] == DNSRecord(name: "www.example.com", type: 5, ttl: 300,
                                                 value: "web.example.com"))
        #expect(response.answers[1].name == "web.example.com")
        #expect(response.answers[1].value == "93.184.216.34" && response.answers[1].typeLabel == "A")
        #expect(response.answers[1].ttl == 60)
    }

    @Test("MX, TXT, AAAA, SRV und SOA werden lesbar")
    func dnsRecordTypes() throws {
        func answer(type: UInt16, rdata: [UInt8]) -> [UInt8] {
            [0xC0, 0x10, UInt8(type >> 8), UInt8(type & 0xFF), 0, 1, 0, 0, 0, 30,
             UInt8(rdata.count >> 8), UInt8(rdata.count & 0xFF)] + rdata
        }
        let records: [[UInt8]] = [
            answer(type: 15, rdata: [0, 10] + label("mail") + [0xC0, 0x10]),
            answer(type: 16, rdata: label("hello") + label("foo")),
            answer(type: 28, rdata: [0x20, 0x01, 0x0D, 0xB8] + [UInt8](repeating: 0, count: 10) + [0, 1]),
            answer(type: 33, rdata: [0, 1, 0, 5, 0x1F, 0x90] + label("srv") + [0xC0, 0x10]),
            answer(type: 6, rdata: label("ns") + [0xC0, 0x10] + label("admin") + [0xC0, 0x10] + [0, 0, 0, 42, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
            answer(type: 99, rdata: [0xAB, 0xCD]),
        ]
        let header: [UInt8] = [0, 1, 0x81, 0x80, 0, 1, 0, UInt8(records.count), 0, 0, 0, 0]
        let response = try #require(DNSMessage.parse(Data(header + question() + records.flatMap { $0 })))
        let values = response.answers.map(\.value)
        #expect(values[0] == "10 mail.example.com")
        #expect(values[1] == "hellofoo")
        #expect(values[2] == "2001:db8::1")
        #expect(values[3] == "1 5 8080 srv.example.com")
        #expect(values[4] == "ns.example.com admin.example.com 42")
        #expect(values[5] == "abcd")
        #expect(response.answers[5].typeLabel == "TYPE99")

        #expect(DNSMessage.ipv6([UInt8](repeating: 0, count: 16)) == "::")
        #expect(DNSMessage.ipv6([UInt8](repeating: 0, count: 15) + [1]) == "::1")
        #expect(DNSMessage.ipv6([0, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 4, 0, 5]) == "1:0:2:0:3:0:4:5")
    }

    @Test("Eine Schleife in den Zeigern und abgeschnittene Pakete sind Fehler, kein Absturz")
    func dnsMalformed() {
        let loop: [UInt8] = [0, 1, 0x81, 0x80, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 0x0C, 0, 1, 0, 1]
        #expect(DNSMessage.parse(Data(loop)) == nil)
        #expect(DNSMessage.parse(Data([1, 2, 3])) == nil)
        let header: [UInt8] = [0, 1, 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0]
        let cut = Data(header + question() + [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 1, 0, 4, 1, 2])
        #expect(DNSMessage.parse(cut) == nil)
        let nxdomain: [UInt8] = [0, 1, 0x81, 0x83, 0, 1, 0, 0, 0, 0, 0, 0]
        let parsed = DNSMessage.parse(Data(nxdomain + question()))
        #expect(parsed?.rcode == 3 && parsed?.rcodeLabel == "NXDOMAIN" && parsed?.answers.isEmpty == true)
        let truncated: [UInt8] = [0, 1, 0x83, 0x80, 0, 1, 0, 0, 0, 0, 0, 0]
        #expect(DNSMessage.parse(Data(truncated + question()))?.isTruncated == true)
    }

    // MARK: - NetBIOS

    @Test("Statusabfrage und -antwort des NetBIOS-Namensdienstes")
    func netBIOS() throws {
        let request = NetBIOSName.statusRequest(id: 0x1234)
        #expect(request.count == 50)
        #expect([UInt8](request.suffix(4)) == [0, 0x21, 0, 1])

        func entry(_ name: String, suffix: UInt8, flags: UInt16) -> [UInt8] {
            Array(name.padding(toLength: 15, withPad: " ", startingAt: 0).utf8) + [suffix, UInt8(flags >> 8), UInt8(flags & 0xFF)]
        }
        let names = entry("WORKSTATION", suffix: 0x00, flags: 0x0400)
            + entry("WORKGROUP", suffix: 0x00, flags: 0x8400)
            + entry("WORKSTATION", suffix: 0x20, flags: 0x0400)
        let rdata: [UInt8] = [3] + names + [UInt8](repeating: 0, count: 46)
        let name = [0x20] + Array("CKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".utf8) + [0]
        let packet: [UInt8] = [0x12, 0x34, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 0] + name
            + [0, 0x21, 0, 1, 0, 0, 0, 0, UInt8(rdata.count >> 8), UInt8(rdata.count & 0xFF)] + rdata
        let entries = try #require(NetBIOSName.parse(Data(packet)))
        #expect(entries.count == 3)
        #expect(NetBIOSName.hostName(entries) == "WORKSTATION")
        #expect(NetBIOSName.workgroup(entries) == "WORKGROUP")
        #expect(entries[2].suffix == 0x20)
        #expect(NetBIOSName.parse(request) == nil)
    }

    // MARK: - Ports

    @Test("Portlisten: Bereiche, Obergrenzen und Namen")
    func ports() {
        #expect(PortCatalog.parse("22, 80,8000-8003") == [22, 80, 8000, 8001, 8002, 8003])
        #expect(PortCatalog.parse("80 80 80") == [80])
        #expect(PortCatalog.parse("") == [])
        #expect(PortCatalog.parse("0") == nil)
        #expect(PortCatalog.parse("65536") == nil)
        #expect(PortCatalog.parse("90-80") == nil)
        #expect(PortCatalog.parse("1-5000") == nil)
        #expect(PortCatalog.parse("a") == nil)
        #expect(PortCatalog.parse("1-2-3") == nil)
        #expect(PortCatalog.top100.count == Set(PortCatalog.top100).count)
        #expect((95...105).contains(PortCatalog.top100.count))
        #expect(PortCatalog.wellKnown.first == 1 && PortCatalog.wellKnown.contains(8123))
        #expect(PortCatalog.name(443) == "https" && PortCatalog.name(1883) == "mqtt" && PortCatalog.name(4) == "")
        #expect(PortCatalog.services(.custom, custom: [80, 99_999, 22, 80]) == [22, 80])
    }

    // MARK: - Certificates

    private static let certificate: Data = {
        let hex =
        "308201e93082018ea003020102021472301fae58aef78f5f069fcd13f5804b80" +
        "41f798300a06082a8648ce3d04030230323115301306035504030c0c726f7574" +
        "65722e6c6f63616c31193017060355040a0c1053656e736f7273746f726d2054" +
        "657374301e170d3236313030323037323535375a170d32363132333130373235" +
        "35375a30323115301306035504030c0c726f757465722e6c6f63616c31193017" +
        "060355040a0c1053656e736f7273746f726d20546573743059301306072a8648" +
        "ce3d020106082a8648ce3d03010703420004705ac843ba790cf267b21c6bcb9e" +
        "d779304cc46275032398675291b682d38c1c38f53cb5f81856c669282ae81bef" +
        "89fd49824198caa8a5fc265a3e3d96345567a38181307f301d0603551d0e0416" +
        "04140f838867da296327d9ec0aaf6c02be70d4f1de6c301f0603551d23041830" +
        "1680140f838867da296327d9ec0aaf6c02be70d4f1de6c300f0603551d130101" +
        "ff040530030101ff302c0603551d1104253023820c726f757465722e6c6f6361" +
        "6c820d2a2e6578616d706c652e636f6d8704c0a80101300a06082a8648ce3d04" +
        "03020349003046022100b8dc319244af88dc0ff4d9082dc6f2bb459d0d301057" +
        "b36f5a4ffe667aab505c022100fa1ebb3e9c0b4281a666b1d363f0588e532a82" +
        "d76d03a48723c186ef4faa9fac"
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }()

    @Test("Ein Zertifikat sagt, für wen es gilt, wer es ausgestellt hat und bis wann")
    func certificate() throws {
        let summary = try #require(CertificateSummary.parse(der: Self.certificate))
        #expect(summary.subjectCommonName == "router.local")
        #expect(summary.subjectOrganization == "Sensorstorm Test")
        #expect(summary.issuerCommonName == "router.local")
        #expect(summary.isSelfSigned)
        #expect(summary.alternativeNames == ["router.local", "*.example.com", "192.168.1.1"])
        #expect(abs(summary.notBefore.timeIntervalSince1970 - 1_790_925_957) < 1)
        #expect(abs(summary.notAfter.timeIntervalSince1970 - 1_798_701_957) < 1)
        #expect(!summary.serialNumber.isEmpty)

        let inside = Date(timeIntervalSince1970: 1_792_000_000)
        #expect(summary.isValid(at: inside))
        #expect(!summary.isValid(at: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(!summary.isValid(at: Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(summary.daysRemaining(at: Date(timeIntervalSince1970: 1_798_701_957 - 86_400 * 30 - 100)) == 30)

        #expect(summary.covers(host: "router.local"))
        #expect(summary.covers(host: "ROUTER.local"))
        #expect(summary.covers(host: "www.example.com"))
        // A wildcard stands for exactly one label.
        #expect(!summary.covers(host: "example.com"))
        #expect(!summary.covers(host: "a.b.example.com"))
        #expect(summary.covers(host: "192.168.1.1"))
        #expect(!summary.covers(host: "other.local"))

        #expect(CertificateSummary.parse(der: Data()) == nil)
        #expect(CertificateSummary.parse(der: Self.certificate.prefix(100)) == nil)
    }

    // MARK: - Inventory

    @Test("Was ein Gerät ist, aus dem, worauf es antwortet")
    func classifier() {
        func guess(_ address: String = "192.168.1.50", ports: [Int] = [], services: [String] = [],
                   names: [String] = []) -> DeviceGuess {
            DeviceClassifier.guess(address: address, gateway: "192.168.1.1", openPorts: ports,
                                   services: services, names: names)
        }
        #expect(guess("192.168.1.1", ports: [80, 443]) == .router)
        #expect(guess(ports: [9100]) == .printer)
        #expect(guess(services: ["_ipp._tcp"]) == .printer)
        #expect(guess(ports: [445], names: ["DiskStation"]) == .nas)
        #expect(guess(ports: [554]) == .camera)
        #expect(guess(services: ["_hap._tcp"]) == .smartHome)
        #expect(guess(ports: [1883]) == .smartHome)
        #expect(guess(services: ["_googlecast._tcp"]) == .mediaPlayer)
        #expect(guess(ports: [62078]) == .apple)
        #expect(guess(ports: [3389]) == .computer)
        #expect(guess(ports: [22]) == .server)
        #expect(guess() == .unknown)
    }

    @Test("Zusammenführen lässt Listen wachsen, der Vergleich nennt neue Hosts und Ports")
    func inventory() {
        var host = HostRecord(address: "192.168.1.20", hostNames: ["nas"], openPorts: [445],
                              roundTrip: 0.004, sources: ["ping"])
        host.merge(HostRecord(address: "192.168.1.20", hostNames: ["nas", "nas.local"],
                              services: ["_smb._tcp"], openPorts: [22, 445], roundTrip: 0.002,
                              sources: ["bonjour", "ping"]))
        #expect(host.hostNames == ["nas", "nas.local"])
        #expect(host.openPorts == [22, 445] && host.roundTrip == 0.002)
        #expect(host.sources == ["ping", "bonjour"] && host.displayName == "nas")
        #expect(HostRecord(address: "10.0.0.9").displayName == "10.0.0.9")

        let old = NetworkSnapshot(networkName: "Büro", subnet: "192.168.1.0/24", hosts: [
            HostRecord(address: "192.168.1.1", openPorts: [80]),
            HostRecord(address: "192.168.1.20", hostNames: ["nas"], openPorts: [445]),
            HostRecord(address: "192.168.1.30"),
        ])
        let new = NetworkSnapshot(networkName: "Büro", subnet: "192.168.1.0/24", hosts: [
            HostRecord(address: "192.168.1.1", openPorts: [80]),
            HostRecord(address: "192.168.1.20", hostNames: ["nas"], openPorts: [23, 445]),
            HostRecord(address: "192.168.1.77", openPorts: [80]),
        ])
        let diff = InventoryDiff.between(old, new)
        #expect(diff.added.map(\.address) == ["192.168.1.77"])
        #expect(diff.removed.map(\.address) == ["192.168.1.30"])
        #expect(diff.changed == [InventoryDiff.Change(address: "192.168.1.20", name: "nas",
                                                       openedPorts: [23], closedPorts: [])])
        #expect(!diff.isEmpty)
        #expect(InventoryDiff.between(old, old).isEmpty)

        let data = try? JSONEncoder().encode(new)
        #expect(data.flatMap { try? JSONDecoder().decode(NetworkSnapshot.self, from: $0) } == new)
    }

    // MARK: - iperf3

    @Test("iperf3: Cookie, Rahmen und Durchsatz")
    func iperf() throws {
        var counter: UInt8 = 0
        let cookie = Iperf3.cookie { counter &+= 7; return counter }
        #expect(cookie.count == 37 && cookie.last == 0)
        #expect(cookie.dropLast().allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x32 && $0 <= 0x37) })

        let parameters = Iperf3.parameters(duration: 10, reverse: true)
        let object = try #require(try JSONSerialization.jsonObject(with: parameters) as? [String: Any])
        #expect(object["tcp"] as? Bool == true && object["time"] as? Int == 10 && object["reverse"] as? Bool == true)
        #expect(object["parallel"] as? Int == 1 && object["len"] as? Int == 131_072)

        var buffer = Iperf3.frame(parameters)
        buffer.append(Iperf3.frame(Data("{}".utf8)))
        #expect(buffer.prefix(4) == Data([0, 0, UInt8(parameters.count >> 8), UInt8(parameters.count & 0xFF)]))
        #expect(Iperf3.readFrame(&buffer) == parameters)
        #expect(Iperf3.readFrame(&buffer) == Data("{}".utf8))
        #expect(buffer.isEmpty && Iperf3.readFrame(&buffer) == nil)

        // The rest of a message has not arrived: nothing is taken, nothing is lost.
        var partial = Iperf3.frame(Data("hello".utf8)).dropLast(2)
        let before = Data(partial)
        #expect(Iperf3.readFrame(&partial) == nil && partial == before)
        // A length nobody sends means the stream is out of step.
        var broken = Data([0xFF, 0xFF, 0xFF, 0xFF, 1, 2])
        #expect(Iperf3.readFrame(&broken) == nil && broken.isEmpty)

        #expect(abs(Iperf3.megabits(bytes: 125_000_000, seconds: 10) - 100) < 1e-9)
        #expect(Iperf3.megabits(bytes: 1, seconds: 0) == 0)
        #expect(Iperf3.State.exchangeResults.rawValue == 13 && Iperf3.State.accessDenied.rawValue == -1)
    }

    @Test("Wake-on-LAN: Hardware-Adresse lesen und das Paket bauen")
    func wakeOnLAN() throws {
        let mac = try #require(WakeOnLAN.parseMAC("AA-bb:cc.dd ee:0f"))
        #expect(mac == [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x0F])
        #expect(WakeOnLAN.format(mac) == "aa:bb:cc:dd:ee:0f")
        #expect(WakeOnLAN.parseMAC("aa:bb:cc:dd:ee") == nil)
        #expect(WakeOnLAN.parseMAC("gg:bb:cc:dd:ee:ff") == nil)
        let packet = try #require(WakeOnLAN.magicPacket(mac: mac))
        #expect(packet.count == 102)
        #expect(packet.prefix(6).allSatisfy { $0 == 0xFF })
        #expect(Array(packet.suffix(6)) == mac)
        #expect(WakeOnLAN.magicPacket(mac: [1, 2, 3]) == nil)
    }

    @Test("Der Bestand als Tabelle: eine Zeile je Gerät, Namen maskiert")
    func snapshotCSV() {
        let snapshot = NetworkSnapshot(
            networkName: "Büro", subnet: "10.0.0.0/24", gateway: "10.0.0.1",
            hosts: [
                HostRecord(address: "10.0.0.1", hostNames: ["router, oben"], services: ["_http._tcp"],
                           openPorts: [53, 80], roundTrip: 0.0012, sources: ["ping", "dns"], guess: .router),
                HostRecord(address: "10.0.0.7"),
            ])
        let lines = snapshot.csv().split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0] == "address,name,guess,open_ports,services,round_trip_ms,sources")
        #expect(lines[1] == "10.0.0.1,\"router, oben\",router,53 80,_http._tcp,1.20,ping dns")
        #expect(lines[2] == "10.0.0.7,,unknown,,,,")
    }
}
