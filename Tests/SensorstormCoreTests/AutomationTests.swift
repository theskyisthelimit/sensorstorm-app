import Foundation
import Testing
@testable import SensorstormCore

@Suite("Regeln, MQTT, Bluetooth-Decoder, Excel")
struct AutomationTests {

    // MARK: - MQTT

    @Test("SUBSCRIBE trägt Paketkennung und jeden Filter mit QoS 0")
    func subscribePacket() throws {
        let packet = try MQTTPacket.subscribe(packetID: 1, topics: ["a/b", "c"])
        #expect([UInt8](packet) == [0x82, 12, 0, 1, 0, 3, 0x61, 0x2F, 0x62, 0, 0, 1, 0x63, 0])
    }

    @Test("Ein Lesevorgang mit CONNACK, PUBLISH und einem halben Paket")
    func drainSplitsPackets() throws {
        var buffer = Data([0x20, 2, 0, 0])
        buffer.append(try MQTTPacket.publish(topic: "cmd", payload: Data("start".utf8)))
        buffer.append(contentsOf: [0x30, 10, 0])          // the next one, cut off
        let packets = MQTTPacket.drain(&buffer)
        #expect(packets.count == 2)
        #expect(packets.first.map { if case .connack(let d) = $0 { MQTTPacket.isAccepted(connack: d) } else { false } } == true)
        #expect(packets.last == .publish(topic: "cmd", payload: Data("start".utf8)))
        #expect(buffer == Data([0x30, 10, 0]))
    }

    @Test("Platzhalter und Wildcards")
    func topics() {
        #expect(MQTTTopic.expand("phones/${userId}/data", deviceID: "X") == "phones/X/data")
        #expect(MQTTTopic.expand("${deviceId}", deviceID: "X") == "X")
        #expect(MQTTTopic.list(" a, b\nc,, ") == ["a", "b", "c"])
        #expect(MQTTTopic.matches(filter: "home/+/temp", topic: "home/kitchen/temp"))
        #expect(!MQTTTopic.matches(filter: "home/+/temp", topic: "home/kitchen/hum"))
        #expect(MQTTTopic.matches(filter: "home/#", topic: "home/a/b/c"))
        #expect(!MQTTTopic.matches(filter: "home", topic: "home/a"))
    }

    // MARK: - Rules

    private func speedRule(_ mode: Rule.Mode) -> Rule {
        Rule(name: "schnell", mode: mode,
             conditions: [.value(sensor: .location, channel: 4, comparison: .above, threshold: 8)],
             actions: [.annotate(text: "schnell")])
    }

    private func context(speed: Double) -> RuleContext {
        RuleContext(values: [.location: [46.9, 7.4, 0, 0, speed]], elapsed: 0)
    }

    @Test("„Bei Änderung“ feuert auf der Flanke, nicht solange es gilt")
    func onChangeFiresOnEdge() {
        var engine = RuleEngine()
        let rule = speedRule(.onChange)
        #expect(engine.evaluate([rule], context: context(speed: 9), now: 0).count == 1)
        #expect(engine.evaluate([rule], context: context(speed: 9), now: 10).isEmpty)
        #expect(engine.evaluate([rule], context: context(speed: 2), now: 11).isEmpty)
        // A new edge inside the 5 s cooldown is swallowed …
        var fresh = RuleEngine()
        _ = fresh.evaluate([rule], context: context(speed: 9), now: 0)
        _ = fresh.evaluate([rule], context: context(speed: 2), now: 1)
        #expect(fresh.evaluate([rule], context: context(speed: 9), now: 3).isEmpty)
        // … one after it is not.
        _ = fresh.evaluate([rule], context: context(speed: 2), now: 4)
        #expect(fresh.evaluate([rule], context: context(speed: 9), now: 6).count == 1)
    }

    @Test("„Jedes Mal“ feuert weiter, aber höchstens einmal pro Minute")
    func everyTimeCooldown() {
        var engine = RuleEngine()
        let rule = speedRule(.everyTime)
        #expect(engine.evaluate([rule], context: context(speed: 9), now: 0).count == 1)
        #expect(engine.evaluate([rule], context: context(speed: 9), now: 59).isEmpty)
        #expect(engine.evaluate([rule], context: context(speed: 9), now: 60).count == 1)
    }

    @Test("Die Abkühlzeit gilt je Regel, nicht für alle")
    func cooldownIsPerRule() {
        var engine = RuleEngine()
        let fast = speedRule(.everyTime)
        let other = Rule(name: "Zeit", mode: .everyTime, conditions: [.elapsed(seconds: 0)],
                         actions: [.stopRecording])
        #expect(engine.evaluate([fast], context: context(speed: 9), now: 0).count == 1)
        #expect(engine.evaluate([fast, other], context: context(speed: 9), now: 1).map(\.name) == ["Zeit"])
    }

    @Test("Geofence ohne GPS-Fix ist weder drinnen noch draussen")
    func geofence() {
        let home = Rule.Condition.geofence(latitude: 46.9, longitude: 7.4, radius: 100, inside: false)
        #expect(!RuleEngine.holds(home, in: RuleContext(values: [:], elapsed: 0)))
        #expect(!RuleEngine.holds(home, in: RuleContext(values: [.location: [46.9005, 7.4]], elapsed: 0)))
        #expect(RuleEngine.holds(home, in: RuleContext(values: [.location: [46.902, 7.4]], elapsed: 0)))
    }

    @Test("MQTT-Bedingung mit Wildcard und Textsuche")
    func mqttCondition() {
        let condition = Rule.Condition.mqtt(topic: "cmd/#", contains: "mark")
        #expect(RuleEngine.holds(condition, in: RuleContext(values: [:], elapsed: 0,
                                                           messages: [("cmd/x", "please MARK")])))
        #expect(!RuleEngine.holds(condition, in: RuleContext(values: [:], elapsed: 0,
                                                            messages: [("other", "mark")])))
    }

    @Test("Regeln überstehen JSON")
    func rulesRoundTrip() throws {
        let rule = Rule(name: "x", conditions: [.mqtt(topic: "a", contains: "")],
                        actions: [.notify(title: "T", message: "M", emoji: "🚨")])
        let decoded = try JSONDecoder().decode(Rule.self, from: JSONEncoder().encode(rule))
        #expect(decoded == rule)
    }

    // MARK: - Bluetooth

    private func hex(_ text: String) -> Data {
        var data = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            data.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    @Test("RuuviTag RAWv2, das Beispiel aus Ruuvis Spezifikation")
    func ruuvi() throws {
        let reading = try #require(BLEDecoders.decode(BLEAdvertisement(
            manufacturerData: hex("99040512FC5394C37C0004FFFC040CAC364200CDCBB8334C884F"))))
        #expect(abs(reading.value("temperature")! - 24.3) < 1e-9)
        #expect(abs(reading.value("humidity")! - 53.49) < 1e-9)
        #expect(abs(reading.value("pressure")! - 1000.44) < 1e-9)
        #expect(abs(reading.value("accelerationZ")! - 1.036) < 1e-9)
        #expect(abs(reading.value("batteryVoltage")! - 2.977) < 1e-9)
        #expect(reading.value("movementCounter") == 66)
    }

    @Test("BTHome v2, unverschlüsselt")
    func bthome() throws {
        let reading = try #require(BLEDecoders.decode(BLEAdvertisement(
            serviceData: ["FCD2": hex("4002CA0903BF13")])))
        #expect(abs(reading.value("temperature")! - 25.06) < 1e-9)
        #expect(abs(reading.value("humidity")! - 50.55) < 1e-9)
        // Encrypted: not ours to read.
        #expect(BLEDecoders.decode(BLEAdvertisement(serviceData: ["FCD2": hex("4102CA09")])) == nil)
    }

    @Test("pvvx-Firmware auf einem Xiaomi-Thermometer")
    func pvvx() throws {
        let reading = try #require(BLEDecoders.decode(BLEAdvertisement(
            serviceData: ["181A": hex("112233445566" + "6009" + "8813" + "B80B" + "5A" + "01" + "04")])))
        #expect(reading.value("temperature") == 24)
        #expect(reading.value("humidity") == 50)
        #expect(reading.value("batteryVoltage") == 3)
        #expect(reading.value("battery") == 90)
    }

    @Test("Herzfrequenzgurt mit RR-Intervall")
    func heartRate() {
        #expect(BLEDecoders.decode(.heartRate, Data([0x00, 72]))?.value("heartRate") == 72)
        let reading = BLEDecoders.decode(.heartRate, Data([0x10, 60, 0x00, 0x04]))
        #expect(reading?.value("rrInterval") == 1)
    }

    @Test("Trittfrequenz aus zwei kumulativen CSC-Paketen")
    func cadence() throws {
        var tracker = CSCTracker()
        _ = tracker.update(try #require(BLEDecoders.decode(.cyclingSpeedCadence, Data([0x02, 10, 0, 0x00, 0x00]))))
        // One crank revolution in 1024/1024 s = 60 rpm.
        let second = tracker.update(try #require(BLEDecoders.decode(.cyclingSpeedCadence, Data([0x02, 11, 0, 0x00, 0x04]))))
        #expect(second.value("cadence") == 60)
    }

    @Test("Mehrere Decoder in einer Datei")
    func scriptDecoders() throws {
        let decoders = try ScriptDecoders(source: """
            decoder({ name: "Eins", manufacturerId: 0x0590,
                      decode: function (b) { return { value: b[2] * 2 }; } });
            decoder({ name: "Zwei", serviceUuid: "0000abcd-0000-1000-8000-00805f9b34fb",
                      decode: function (b, ad) { return { first: b[0], label: "ignored" }; } });
            """)
        #expect(decoders.names == ["Eins", "Zwei"])
        let one = decoders.decode(BLEAdvertisement(manufacturerData: Data([0x90, 0x05, 21])))
        #expect(one == BLEReading(decoder: "Eins", fields: [.init("value", 42)]))
        let two = decoders.decode(BLEAdvertisement(serviceData: ["ABCD": Data([7])]))
        #expect(two == BLEReading(decoder: "Zwei", fields: [.init("first", 7)]))
        #expect(decoders.decode(BLEAdvertisement(manufacturerData: Data([0x00, 0x01, 1]))) == nil)
    }

    @Test("Ein Decoder ohne Kriterium und ein Syntaxfehler werden abgewiesen")
    func scriptDecoderErrors() {
        #expect(throws: ScriptDecoders.LoadError.self) {
            try ScriptDecoders(source: "decoder({ name: 'alles', decode: function () { return {}; } });")
        }
        #expect(throws: ScriptDecoders.LoadError.self) { try ScriptDecoders(source: "decoder({") }
    }

    // MARK: - Excel

    @Test("Das Workbook ist ein gültiges Zip mit einem Blatt pro Sensor")
    func excelWorkbook() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensorstorm-xlsx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(root: root)
        var metadata = RecordingMetadata(
            name: "Excel", startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            startHostTime: 1000, duration: 1,
            device: DeviceInfo(model: "iPhone17,1", systemName: "iOS",
                               systemVersion: "26.0", appVersion: "1.0.0"),
            requestedRateHz: 10)
        let directory = try store.prepareDirectory(for: metadata.id)
        let writer = try StreamWriter(sensor: .barometer, channelCount: 2, directory: directory)
        writer.append(time: 1000.5, values: [97.1, .nan])
        writer.flush()
        metadata.streams = [writer.close()]
        try store.save(metadata)

        let url = root.appendingPathComponent("r.xlsx")
        try XLSXExporter(store: store).write(metadata, to: url)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-p", url.path, "xl/worksheets/sheet1.xml"]
        let pipe = Pipe()
        unzip.standardOutput = pipe
        try unzip.run()
        unzip.waitUntilExit()
        let sheet = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(unzip.terminationStatus == 0)
        #expect(sheet.contains("<t>relativeAltitude</t>"))
        #expect(sheet.contains("<c><v>0.5</v></c><c><v>1700000000.5</v></c><c><v>97.1</v></c><c/>"))
    }
}
