import Foundation
import Testing
@testable import SensorstormCore

@Suite("Netzwerkprotokolle")
struct ProtocolTests {

    // MARK: - SNTP

    /// The formula, with numbers chosen so the answer is obvious: the device is one second
    /// behind, and the round trip took 200 ms split evenly.
    @Test("Der Zeitversatz kommt mit dem richtigen Vorzeichen heraus")
    func ntpOffsetSign() throws {
        let t1 = 1000.0                    // client sends
        let t2 = 1001.1                    // server receives  (device is 1 s behind)
        let t3 = 1001.1                    // server replies immediately
        let t4 = 1000.2                    // client receives

        var reply = Data(repeating: 0, count: NTPPacket.size)
        reply[0] = 0b00_100_100             // mode 4, server
        reply[1] = 2                        // stratum
        NTPPacket.writeTimestamp(t2 + NTPPacket.epochDelta, into: &reply, at: 32)
        NTPPacket.writeTimestamp(t3 + NTPPacket.epochDelta, into: &reply, at: 40)

        let reading = try #require(NTPPacket.reading(from: reply, sentAt: t1, receivedAt: t4))
        // ((1001.1 − 1000) + (1001.1 − 1000.2)) / 2 = 1.0
        #expect(abs(reading.offsetSeconds - 1.0) < 1e-6)
        #expect(abs(reading.roundTripSeconds - 0.2) < 1e-6)
    }

    @Test("Der 64-Bit-Zeitstempel übersteht Schreiben und Lesen")
    func ntpTimestampRoundTrip() {
        var packet = Data(repeating: 0, count: NTPPacket.size)
        let value = 3_926_000_123.456789
        NTPPacket.writeTimestamp(value, into: &packet, at: 40)
        // The fraction is 32 bits, so ~0.23 ns of resolution — far below anything that
        // matters here, but the whole seconds must be exact.
        #expect(abs(NTPPacket.timestamp(in: packet, at: 40) - value) < 1e-6)
    }

    /// A stratum of 0 is a "kiss-o'-death": a refusal dressed as a packet. Reading a time
    /// out of it would look like a working sync and be nonsense.
    @Test("Eine Absage wird nicht als Zeit gelesen")
    func ntpRejectsKissOfDeath() {
        var reply = Data(repeating: 0, count: NTPPacket.size)
        reply[0] = 0b00_100_100
        reply[1] = 0
        NTPPacket.writeTimestamp(1000 + NTPPacket.epochDelta, into: &reply, at: 32)
        NTPPacket.writeTimestamp(1000 + NTPPacket.epochDelta, into: &reply, at: 40)
        #expect(NTPPacket.reading(from: reply, sentAt: 1000, receivedAt: 1000.2) == nil)
    }

    @Test("Eine zu kurze Antwort wird abgelehnt")
    func ntpRejectsShortReply() {
        #expect(NTPPacket.reading(from: Data(repeating: 0, count: 10),
                                 sentAt: 0, receivedAt: 1) == nil)
    }

    @Test("Die Anfrage ist ein gültiges Client-Paket")
    func ntpRequestShape() {
        let packet = NTPPacket.request(transmitTime: 1000)
        #expect(packet.count == NTPPacket.size)
        #expect(packet[0] & 0b111 == 3)               // mode 3: client
        #expect((packet[0] >> 3) & 0b111 == 4)        // version 4
        #expect(abs(NTPPacket.timestamp(in: packet, at: 40)
                    - (1000 + NTPPacket.epochDelta)) < 1e-6)
    }

    // MARK: - MQTT

    /// The seven-bits-per-byte length. 127 still fits in one byte, 128 needs two — that
    /// boundary is where a hand-written encoder goes wrong.
    @Test("Die variable Länge wird nach MQTT-Regeln kodiert")
    func mqttRemainingLength() throws {
        #expect(try MQTTPacket.remainingLength(0) == Data([0x00]))
        #expect(try MQTTPacket.remainingLength(127) == Data([0x7F]))
        #expect(try MQTTPacket.remainingLength(128) == Data([0x80, 0x01]))
        #expect(try MQTTPacket.remainingLength(16_383) == Data([0xFF, 0x7F]))
        #expect(try MQTTPacket.remainingLength(16_384) == Data([0x80, 0x80, 0x01]))
        #expect(try MQTTPacket.remainingLength(268_435_455) == Data([0xFF, 0xFF, 0xFF, 0x7F]))
    }

    @Test("Eine zu grosse Nachricht wird abgelehnt, nicht abgeschnitten")
    func mqttRejectsOversizePayload() {
        #expect(throws: MQTTPacket.PacketError.self) {
            _ = try MQTTPacket.remainingLength(268_435_456)
        }
    }

    @Test("CONNECT trägt Protokollname, Version und die gesetzten Flags")
    func mqttConnect() throws {
        let packet = try MQTTPacket.connect(clientID: "sensorstorm-1",
                                            username: "u", password: "p")
        #expect(packet[0] == 0x10)
        // After the fixed header and its one length byte: 00 04 "MQTT" 04 <flags>
        #expect(Array(packet[2..<8]) == [0x00, 0x04, 0x4D, 0x51, 0x54, 0x54])
        #expect(packet[8] == 4)
        let flags = packet[9]
        #expect(flags & 0b1000_0000 != 0)   // username present
        #expect(flags & 0b0100_0000 != 0)   // password present
        #expect(flags & 0b0000_0010 != 0)   // clean session
    }

    @Test("CONNECT ohne Zugangsdaten setzt die Flags nicht")
    func mqttConnectWithoutCredentials() throws {
        let packet = try MQTTPacket.connect(clientID: "x", username: nil, password: nil)
        #expect(packet[9] & 0b1100_0000 == 0)
    }

    @Test("PUBLISH ist QoS 0 und trägt Thema und Nutzlast")
    func mqttPublish() throws {
        let payload = Data(#"{"messageId":1}"#.utf8)
        let packet = try MQTTPacket.publish(topic: "sensorstorm", payload: payload)
        #expect(packet[0] == 0x30)                     // PUBLISH, QoS 0, no dup, no retain
        let remaining = Int(packet[1])
        #expect(remaining == 2 + 11 + payload.count)   // length prefix + topic + payload
        #expect(packet.suffix(payload.count) == payload)
    }

    @Test("Nur der Rückgabecode 0 gilt als angenommen")
    func mqttConnack() {
        #expect(MQTTPacket.isAccepted(connack: Data([0x20, 0x02, 0x00, 0x00])))
        #expect(!MQTTPacket.isAccepted(connack: Data([0x20, 0x02, 0x00, 0x05])))
        #expect(!MQTTPacket.isAccepted(connack: Data([0x30, 0x02, 0x00, 0x00])))
        #expect(!MQTTPacket.isAccepted(connack: Data([0x20, 0x02])))
    }
}
