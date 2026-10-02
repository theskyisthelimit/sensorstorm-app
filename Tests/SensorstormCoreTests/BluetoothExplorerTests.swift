import Foundation
import Testing
@testable import SensorstormCore

@Suite("Bluetooth: Wertformate, Verlauf der Funde, Namen")
struct BluetoothExplorerTests {

    @Test("Dieselben Bytes als Hex, Text, Zahl, Fliesskomma und Bits")
    func formats() {
        let hello = Data("Hello".utf8)
        #expect(GATTValueFormat.hex.render(hello) == "48 65 6C 6C 6F")
        #expect(GATTValueFormat.text.render(hello) == "Hello")
        #expect(GATTValueFormat.decimal.render(hello) == "72 101 108 108 111")
        #expect(GATTValueFormat.binary.render(Data([0x05, 0xFF])) == "00000101 11111111")

        #expect(GATTValueFormat.unsigned.render(Data([0x2A])) == "42")
        #expect(GATTValueFormat.unsigned.render(Data([0x01, 0x02])) == "513 (LE), 258 (BE)")
        #expect(GATTValueFormat.unsigned.render(Data([1, 2, 3])) == nil)
        #expect(GATTValueFormat.signed.render(Data([0xFF])) == "-1")
        #expect(GATTValueFormat.signed.render(Data([0xFE, 0xFF])) == "-2 (LE), -257 (BE)")
        #expect(GATTValueFormat.signed.render(Data([0x00, 0x00, 0x00, 0x80])) == "-2147483648 (LE), 128 (BE)")
        #expect(GATTValueFormat.unsigned.render(Data(repeating: 0xFF, count: 8)) == "18446744073709551615 (LE), 18446744073709551615 (BE)")

        let one = Data([0x00, 0x00, 0x80, 0x3F])        // 1.0 little endian
        #expect(GATTValueFormat.float.render(one)?.hasPrefix("1 (LE)") == true)
        #expect(GATTValueFormat.float.render(Data([1, 2, 3])) == nil)
        #expect(GATTValueFormat.float.render(Data([0x00, 0x00, 0xC0, 0x7F]))?.hasPrefix("NaN") == true)
    }

    @Test("Was kein Text ist, wird nicht als Text ausgegeben")
    func notText() {
        #expect(GATTValueFormat.text.render(Data([0x00, 0x01, 0x02])) == nil)
        #expect(GATTValueFormat.text.render(Data([0xFF, 0xFE])) == nil)
        #expect(GATTValueFormat.text.render(Data("Zeile 1\nZeile 2".utf8)) == "Zeile 1\nZeile 2")
        #expect(GATTValueFormat.text.render(Data("Grüezi".utf8)) == "Grüezi")
        for format in GATTValueFormat.allCases { #expect(format.render(Data()) == nil) }
    }

    private func device(_ id: UUID, name: String? = nil, rssi: Double, packets: Int, company: UInt16? = nil) -> ScannedDevice {
        var device = ScannedDevice(id: id, time: 0, rssi: rssi)
        for index in 0..<packets {
            var advertisement = ScannedAdvertisement(name: name, serviceUUIDs: ["180D"], isConnectable: true)
            if let company {
                advertisement.manufacturerData = Data([UInt8(company & 0xFF), UInt8(company >> 8), 1, 2])
            }
            device.record(time: Double(index), rssi: rssi, advertisement: advertisement)
        }
        return device
    }

    @Test("Der Verlauf zählt neue Pakete und merkt sich erste und letzte Zeit")
    func sightings() throws {
        let id = UUID()
        var log = SightingLog()
        let t0 = Date(timeIntervalSince1970: 1_000)
        log.merge([device(id, name: "Puls", rssi: -70, packets: 3, company: 0x004C)], now: t0)
        var entry = try #require(log.entries.first)
        #expect(entry.packets == 3 && entry.firstSeen == t0 && entry.lastSeen == t0)
        #expect(entry.name == "Puls" && entry.company == "Apple, Inc." && entry.isConnectable == true)
        #expect(entry.services == ["Heart Rate"] && entry.manufacturerData == "4C000102")

        // Nothing new heard: the last-seen time stays.
        log.merge([device(id, name: "Puls", rssi: -50, packets: 3, company: 0x004C)], now: t0 + 10)
        entry = try #require(log.entries.first)
        #expect(entry.lastSeen == t0 && entry.packets == 3 && entry.rssiMax == -70)

        // Two more packets, stronger: the span and the count move.
        log.merge([device(id, name: "Puls", rssi: -50, packets: 5, company: 0x004C)], now: t0 + 20)
        entry = try #require(log.entries.first)
        #expect(entry.lastSeen == t0 + 20 && entry.packets == 5 && entry.firstSeen == t0)
        #expect(entry.rssiMax == -50 && entry.rssiMin == -70 && entry.rssiLast == -50)

        // The scanner list was cleared and the device is back with a restarted counter.
        log.merge([device(id, name: "Puls", rssi: -60, packets: 1, company: 0x004C)], now: t0 + 30)
        #expect(log.entries.first?.packets == 6)
    }

    @Test("Verlauf: Speichern, Laden, Löschen, Begrenzung, Tabelle")
    func sightingStorage() throws {
        var log = SightingLog()
        let ids = (0..<3).map { _ in UUID() }
        log.merge(ids.enumerated().map { pair in device(pair.element, name: "Gerät, \(pair.offset)", rssi: -60, packets: 1) },
                  now: Date(timeIntervalSince1970: 2_000))
        let data = try JSONEncoder().encode(log)
        let loaded = try JSONDecoder().decode(SightingLog.self, from: data)
        #expect(loaded.entries.count == 3 && loaded.entries == log.entries)

        let lines = log.csv().split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix("id,name,company,services,first_seen"))
        #expect(lines[1].contains("\"Gerät, ") && lines[1].contains("1970-01-01T00:33:20Z"))

        log.remove(ids[0])
        #expect(log.entries.count == 2)
        log.removeAll()
        #expect(log.entries.isEmpty)

        var full = SightingLog()
        let many = (0..<(SightingLog.capacity + 5)).map { _ in device(UUID(), rssi: -60, packets: 1) }
        full.merge(many, now: Date())
        #expect(full.entries.count == SightingLog.capacity)
    }

    @Test("Namen: keine doppelten Schlüssel und die bekannten Dienste")
    func names() {
        #expect(BluetoothNames.service("1825") == "Object Transfer")
        #expect(BluetoothNames.service("0000180D-0000-1000-8000-00805F9B34FB") == "Heart Rate")
        #expect(BluetoothNames.service("1822") == "Pulse Oximeter")
        #expect(BluetoothNames.service("1815") == "Automation IO")
        #expect(BluetoothNames.characteristic("2A56") == "Digital")
        #expect(BluetoothNames.characteristic("2B2A") == "Database Hash")
        #expect(BluetoothNames.company(0x0075) == "Samsung Electronics Co. Ltd.")
        #expect(BluetoothNames.service("FFFF") == nil)
    }
}
