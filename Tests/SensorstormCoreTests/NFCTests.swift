import Foundation
import Testing
@testable import SensorstormCore

@Suite("NFC: NDEF-Nachrichten, Karten, Wi-Fi, Bluetooth, Chip-Auskunft")
struct NFCTests {

    @Test("Eine URL wird mit Präfixbyte gekürzt und liest sich wieder")
    func uriPrefix() throws {
        let record = NDEFRecord.uri("https://www.example.com/a")
        #expect(record.payload.first == 0x02)
        #expect(String(decoding: record.payload.dropFirst(), as: UTF8.self) == "example.com/a")
        #expect(NDEFContent(record) == .uri("https://www.example.com/a"))
        // The longest prefix wins; an unknown scheme keeps byte 0.
        #expect(NDEFRecord.uri("https://example.com").payload.first == 0x04)
        #expect(NDEFRecord.uri("matter://x").payload.first == 0x00)
        #expect(NDEFRecord.uri("HTTPS://Example.com").payload.first == 0x04)
        #expect(NDEFContent(NDEFRecord.uri("tel:+41791234567")) == .uri("tel:+41791234567"))
    }

    @Test("Eine Nachricht aus mehreren Einträgen: Kopfbits, kurze und lange Nutzdaten")
    func messageRoundTrip() throws {
        let long = Data(repeating: 0x41, count: 300)
        let message = NDEFMessage(records: [
            .uri("https://example.com"), .text("Grüezi", language: "de"),
            .mime("application/octet-stream", payload: long),
        ])
        let data = message.serialized()
        #expect(data[0] == 0x91)          // MB, SR, well-known
        let parsed = try #require(NDEFMessage(data: data))
        #expect(parsed == message)
        #expect(parsed.records[2].payload.count == 300)
        #expect(message.byteCount == data.count)

        // A record with an identifier sets the IL bit and survives the trip.
        let tagged = NDEFMessage(records: [NDEFRecord(format: .media, type: Data("a/b".utf8),
                                                      identifier: Data("id".utf8), payload: Data([1, 2, 3]))])
        #expect(tagged.serialized()[0] == 0xDA)   // MB ME SR IL, media
        #expect(NDEFMessage(data: tagged.serialized()) == tagged)
    }

    @Test("Eine gelöschte Nachricht ist ein leerer Eintrag und gilt als leer")
    func erased() throws {
        #expect(NDEFMessage.erased.serialized() == Data([0xD0, 0x00, 0x00]))
        #expect(NDEFMessage.erased.isBlank)
        #expect(NDEFMessage(records: []).serialized() == Data([0xD0, 0x00, 0x00]))
        let parsed = try #require(NDEFMessage(data: Data([0xD0, 0x00, 0x00])))
        #expect(parsed.isBlank && parsed.records.count == 1)
        #expect(!NDEFMessage(records: [.text("x")]).isBlank)
    }

    @Test("Kaputte Nachrichten sind nil und kein Absturz")
    func malformed() {
        #expect(NDEFMessage(data: Data()) == nil)
        #expect(NDEFMessage(data: Data([0xD1, 0x01, 0x05, 0x55, 0x01])) == nil)       // payload runs past the end
        #expect(NDEFMessage(data: Data([0x91, 0x01, 0x01, 0x55, 0x01])) == nil)       // no end mark
        #expect(NDEFMessage(data: Data([0x51, 0x01, 0x01, 0x55, 0x01])) == nil)       // no begin mark
        #expect(NDEFMessage(data: Data([0xF1, 0x01, 0x01, 0x55, 0x01])) == nil)       // chunked
        #expect(NDEFMessage(data: Data([0xD1, 0x01, 0x01, 0x55, 0x01, 0xAA])) == nil) // trailing byte
        #expect(NDEFMessage(data: Data([0xD7, 0x00, 0x00])) == nil)                   // reserved format 7
    }

    @Test("Text mit Sprachkennung, UTF-8 und UTF-16")
    func text() throws {
        let record = NDEFRecord.text("Hallo Welt", language: "de")
        #expect(record.payload == Data([2]) + Data("de".utf8) + Data("Hallo Welt".utf8))
        #expect(NDEFContent(record) == .text("Hallo Welt", language: "de"))
        var utf16 = Data([UInt8(0x82)]) + Data("en".utf8)
        utf16.append(contentsOf: [0xFE, 0xFF, 0x00, 0x48, 0x00, 0x69])
        #expect(NDEFContent(NDEFRecord(format: .wellKnown, type: Data("T".utf8), payload: utf16))
                == .text("Hi", language: "en"))
        #expect(NDEFContent(NDEFRecord(format: .wellKnown, type: Data("T".utf8), payload: Data([5, 0x41])))
                == .unknown(byteCount: 2))
    }

    @Test("Telefon, Mail, SMS und Ort sind URIs mit maskierten Werten")
    func schemes() {
        #expect(NDEFContent(.phone("+41 79 123 45-67")) == .uri("tel:+41791234567"))
        #expect(NDEFContent(.mail("a@b.ch", subject: "Hallo & Tschüss", body: "x=1")).summary
                == "mailto:a@b.ch?subject=Hallo%20%26%20Tsch%C3%BCss&body=x%3D1")
        #expect(NDEFContent(.mail("a@b.ch")).summary == "mailto:a@b.ch")
        #expect(NDEFContent(.sms("079 123", body: "Hi")).summary == "sms:079123?body=Hi")
        #expect(NDEFContent(.geo(latitude: 47.3769, longitude: 8.5417)).summary == "geo:47.376900,8.541700")
    }

    @Test("Wi-Fi: der Eintrag trägt SSID, Verschlüsselung und Schlüssel, und liest sich zurück")
    func wifi() throws {
        let credential = WiFiCredential(ssid: "Büro", password: "geheim123", security: .wpa2)
        let record = credential.record
        #expect(record.typeString == "application/vnd.wfa.wsc" && record.format == .media)
        let payload = [UInt8](record.payload)
        #expect(Array(payload.prefix(5)) == [0x10, 0x4A, 0x00, 0x01, 0x10])
        let parsed = try #require(WiFiCredential(wsc: record.payload))
        #expect(parsed.ssid == "Büro" && parsed.password == "geheim123" && parsed.security == .wpa2)
        #expect(NDEFContent(record) == .wifi(credential))
        for security in WiFiCredential.Security.allCases {
            let round = try #require(WiFiCredential(wsc: WiFiCredential(ssid: "x", password: "pw", security: security).wscPayload()))
            #expect(round.security == security, "\(security)")
        }
        // An open network keeps no password.
        #expect(WiFiCredential(ssid: "Cafe", password: "ignored", security: .open).password == "")
        #expect(WiFiCredential(wsc: Data([1, 2, 3])) == nil)
    }

    @Test("Visitenkarte als vCard 3.0, mit Maskierung, und zurück")
    func vcard() throws {
        let card = VCard(firstName: "Ana", lastName: "Meier", organization: "Büro, Mitte", title: "CTO",
                         phone: "+41791234567", email: "ana@example.com", website: "https://example.com",
                         address: "Hauptstrasse 1; 8000 Zürich")
        let text = card.text()
        #expect(text.hasPrefix("BEGIN:VCARD\r\nVERSION:3.0\r\nN:Meier;Ana;;;\r\nFN:Ana Meier"))
        #expect(text.contains("ORG:Büro\\, Mitte") && text.hasSuffix("END:VCARD\r\n"))
        let parsed = try #require(VCard(text: text))
        #expect(parsed.firstName == "Ana" && parsed.lastName == "Meier" && parsed.title == "CTO")
        #expect(parsed.phone == "+41791234567" && parsed.email == "ana@example.com")
        #expect(parsed.organization == "Büro, Mitte")
        #expect(NDEFContent(card.record) == .contact(parsed))
        #expect(parsed.displayName == "Ana Meier")
        // Cards from phones: vCard 2.1, FN only.
        let simple = try #require(VCard(text: "BEGIN:VCARD\nVERSION:2.1\nFN:Bo Li\nTEL;CELL:123\nEND:VCARD"))
        #expect(simple.firstName == "Bo" && simple.lastName == "Li" && simple.phone == "123")
        #expect(VCard(text: "hello") == nil)
    }

    @Test("Bluetooth: Adresse mit dem letzten Byte zuerst, Name und Klasse")
    func bluetooth() throws {
        let address = try #require(MACAddress("AA:BB:CC:11:22:33"))
        let classic = BluetoothOOB.classic(address: address, name: "Boxen", deviceClass: 0x240404)
        let payload = [UInt8](classic.payload)
        #expect(Int(payload[0]) | Int(payload[1]) << 8 == payload.count)
        #expect(Array(payload[2..<8]) == [0x33, 0x22, 0x11, 0xCC, 0xBB, 0xAA])
        #expect(NDEFContent(classic) == .bluetooth(address: "AA:BB:CC:11:22:33", name: "Boxen", lowEnergy: false))

        let le = BluetoothOOB.lowEnergy(address: address, isRandom: true, name: "Sensor")
        #expect(NDEFContent(le) == .bluetooth(address: "AA:BB:CC:11:22:33", name: "Sensor", lowEnergy: true))
        #expect(NDEFContent(BluetoothOOB.lowEnergy(address: address, isRandom: false, name: nil))
                == .bluetooth(address: "AA:BB:CC:11:22:33", name: nil, lowEnergy: true))
    }

    @Test("Ein Smart Poster trägt Titel und Adresse")
    func smartPoster() throws {
        let inner = NDEFMessage(records: [.text("Rathaus", language: "de"), .uri("https://example.org")])
        let poster = NDEFRecord(format: .wellKnown, type: Data("Sp".utf8), payload: inner.serialized())
        #expect(NDEFContent(poster) == .smartPoster(uri: "https://example.org", title: "Rathaus"))
        #expect(NDEFContent(poster).summary == "Rathaus https://example.org")
        #expect(NDEFContent(NDEFRecord(format: .absoluteURI, type: Data("https://a.b".utf8))) == .uri("https://a.b"))
        #expect(NDEFContent(.external("example.com:x", payload: Data([1, 2]))) == .external(type: "example.com:x", byteCount: 2))
        #expect(NDEFContent(.mime("image/png", payload: Data([1]))) == .mime(type: "image/png", byteCount: 1))
        #expect(NDEFContent(.empty) == .empty)
    }

    @Test("GET_VERSION nennt den Chip und seinen Speicher")
    func version() throws {
        let ntag213 = try #require(NTAGVersion(response: Data([0x00, 0x04, 0x04, 0x02, 0x01, 0x00, 0x0F, 0x03])))
        #expect(ntag213.model == "NTAG213" && ntag213.userBytes == 144 && ntag213.totalPages == 45)
        let ntag215 = try #require(NTAGVersion(response: Data([0x00, 0x04, 0x04, 0x02, 0x01, 0x00, 0x11, 0x03])))
        #expect(ntag215.model == "NTAG215" && ntag215.userBytes == 504 && ntag215.totalPages == 135)
        let ntag216 = try #require(NTAGVersion(response: Data([0x00, 0x04, 0x04, 0x02, 0x01, 0x00, 0x13, 0x03])))
        #expect(ntag216.totalPages == 231)
        let ultralight = try #require(NTAGVersion(response: Data([0x00, 0x04, 0x03, 0x01, 0x01, 0x00, 0x0B, 0x03])))
        #expect(ultralight.model == "MIFARE Ultralight EV1 (MF0UL11)" && ultralight.userBytes == 48)
        let unknown = try #require(NTAGVersion(response: Data([0x00, 0x04, 0x04, 0x05, 0x01, 0x00, 0x33, 0x03])))
        #expect(unknown.model == nil && unknown.totalPages == nil)
        #expect(NTAGVersion(response: Data([0x00, 0x04])) == nil)
        #expect(NTAGVersion(response: Data([0x01, 0x04, 0x04, 0x02, 0x01, 0x00, 0x0F, 0x03])) == nil)
    }

    @Test("Chip-Auskunft: Hersteller, Zufalls-ID, Belegung")
    func tagInfo() {
        var info = NFCTagInfo(technology: .miFareUltralight, uid: Data([0x04, 0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6]),
                              ndefStatus: .readWrite, ndefCapacity: 137,
                              message: NDEFMessage(records: [.uri("https://example.com")]))
        #expect(info.manufacturer == "NXP" && !info.usesRandomID && info.isWritable)
        #expect(info.serialHex == "04:A1:B2:C3:D4:E5:F6")
        #expect(info.usedBytes == info.message?.byteCount)
        info.message = .erased
        #expect(info.usedBytes == 0)
        info.uid = Data([0x08, 1, 2, 3])
        #expect(info.manufacturer == nil && info.usesRandomID)
        info.ndefStatus = .readOnly
        #expect(!info.isWritable)
        let vicinity = NFCTagInfo(technology: .iso15693, uid: Data([0xE0, 0x02, 1, 2, 3, 4, 5, 6]), manufacturerCode: 0x02)
        #expect(vicinity.manufacturer == "STMicroelectronics")
        #expect(NFCTagInfo(technology: .felica, uid: Data([1, 2])).manufacturer == "Sony")
    }

    @Test("Hexdump mit Versatz und Textspalte")
    func dump() {
        let text = HexCoding.dump(Data("Hello world!XY".utf8), width: 8, firstOffset: 0x10)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines == ["0010  48 65 6C 6C 6F 20 77 6F  Hello wo",
                          "0018  72 6C 64 21 58 59" + String(repeating: " ", count: 8) + "rld!XY"])
        #expect(HexCoding.dump(Data()) == "")
    }

    @Test("Aus den Eingaben des Formulars wird ein Eintrag, oder nichts")
    func draft() throws {
        var draft = NFCDraft(kind: .url)
        #expect(draft.record() == nil && !draft.isComplete)
        draft.url = "  example.com/a "
        #expect(NDEFContent(try #require(draft.record())) == .uri("https://example.com/a"))
        draft.url = "mailto:x@y.ch"
        #expect(NDEFContent(try #require(draft.record())) == .uri("mailto:x@y.ch"))

        draft = NFCDraft(kind: .text)
        draft.text = "Grüezi"
        #expect(NDEFContent(try #require(draft.record())) == .text("Grüezi", language: "de"))

        draft = NFCDraft(kind: .phone)
        draft.phone = "abc"
        #expect(draft.record() == nil)
        draft.phone = "+41 79 1"
        #expect(NDEFContent(try #require(draft.record())).summary == "tel:+41791")

        draft = NFCDraft(kind: .mail)
        draft.mailAddress = "nope"
        #expect(draft.record() == nil)
        draft.mailAddress = "a@b.ch"
        #expect(draft.record() != nil)

        draft = NFCDraft(kind: .location)
        draft.latitude = "47,3769"
        draft.longitude = "8.5417"
        #expect(NDEFContent(try #require(draft.record())).summary == "geo:47.376900,8.541700")
        draft.latitude = "91"
        #expect(draft.record() == nil)

        draft = NFCDraft(kind: .wifi)
        draft.wifiSSID = "Büro"
        #expect(draft.record() == nil)                 // a protected network needs its key
        draft.wifiPassword = "geheim123"
        #expect(draft.record() != nil)
        draft.wifiSecurity = .open
        draft.wifiPassword = ""
        #expect(draft.record() != nil)
        draft.wifiSSID = String(repeating: "x", count: 33)
        #expect(draft.record() == nil)                 // an SSID is at most 32 bytes

        draft = NFCDraft(kind: .contact)
        #expect(draft.record() == nil)
        draft.contact.lastName = "Meier"
        #expect(NDEFContent(try #require(draft.record())).summary == "Meier")

        draft = NFCDraft(kind: .bluetooth)
        draft.bluetoothAddress = "AA:BB:CC:11:22:33"
        draft.bluetoothName = "Boxen"
        #expect(NDEFContent(try #require(draft.record())) == .bluetooth(address: "AA:BB:CC:11:22:33", name: "Boxen", lowEnergy: false))
        draft.bluetoothLowEnergy = true
        #expect(NDEFContent(try #require(draft.record())) == .bluetooth(address: "AA:BB:CC:11:22:33", name: "Boxen", lowEnergy: true))
        draft.bluetoothAddress = "zz"
        #expect(draft.record() == nil)

        draft = NFCDraft(kind: .custom)
        draft.mimeType = "application/x-demo"
        draft.customPayload = "hello"
        #expect(try #require(draft.record()).payload == Data("hello".utf8))
        draft.customIsHex = true
        draft.customPayload = "0A ff"
        #expect(try #require(draft.record()).payload == Data([0x0A, 0xFF]))
        draft.customPayload = "0A f"
        #expect(draft.record() == nil)
        draft.mimeType = "demo"
        draft.customPayload = "00"
        #expect(draft.record() == nil)
    }
}
