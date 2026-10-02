import Foundation
import Testing
@testable import SensorstormCore

@Suite("NMEA")
struct NMEATests {
    static let gga = "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47"
    static let rmc = "$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A"
    static let gst = "$GNGST,172814.0,0.006,0.023,0.020,273.6,0.023,0.020,0.031*74"
    static let rtk = "$GNGGA,092750.000,5321.6802,N,00630.3372,W,4,8,1.03,61.7,M,55.2,M,1.5,0000*47"

    @Test func checksumAcceptsAndRejects() {
        #expect(NMEA.validatedBody(Self.gga) != nil)
        // One digit changed in the longitude: same checksum field, now wrong.
        let corrupted = Self.gga.replacingOccurrences(of: "01131.000", with: "01131.100")
        #expect(NMEA.validatedBody(corrupted) == nil)
        #expect(NMEA.validatedBody("GPGGA,no,dollar*00") == nil)
    }

    @Test func degreesFromDegreesAndMinutes() throws {
        let north = try #require(NMEA.degrees("4807.038", hemisphere: "N"))
        #expect(abs(north - 48.1173) < 1e-6)
        let west = try #require(NMEA.degrees("00630.3372", hemisphere: "W"))
        #expect(abs(west + 6.50562) < 1e-4)
        #expect(NMEA.degrees("4807.038", hemisphere: "X") == nil)
        #expect(NMEA.degrees("4899.000", hemisphere: "N") == nil)
    }

    @Test func positionSentence() throws {
        let parsed = try #require(NMEASentence.parse(Self.gga))
        guard case .fix(let latitude, let longitude, let altitude, let quality, let satellites, let hdop, _) = parsed else {
            Issue.record("not a fix")
            return
        }
        #expect(abs(latitude - 48.1173) < 1e-6)
        #expect(abs(longitude - 11.516667) < 1e-5)
        #expect(altitude == 545.4)
        #expect(quality == 1)
        #expect(satellites == 8)
        #expect(hdop == 0.9)
    }

    @Test func rtkCorrectionAge() throws {
        let parsed = try #require(NMEASentence.parse(Self.rtk))
        guard case .fix(_, _, _, let quality, _, _, let age) = parsed else {
            Issue.record("not a fix")
            return
        }
        #expect(quality == 4)
        #expect(age == 1.5)
    }

    @Test func speedIsMetresPerSecond() throws {
        let parsed = try #require(NMEASentence.parse(Self.rmc))
        guard case .motion(let speed, let course, let valid) = parsed else {
            Issue.record("not a motion sentence")
            return
        }
        // 22.4 knots
        #expect(abs(speed - 11.524) < 0.01)
        #expect(course == 84.4)
        #expect(valid)
    }

    @Test func piecesBecomeLines() {
        var assembler = NMEALineAssembler()
        let bytes = Array((Self.gga + "\r\n" + Self.rmc + "\r\n").utf8)
        var lines: [String] = []
        // The radio hands over three bytes at a time.
        var index = 0
        while index < bytes.count {
            let end = min(index + 3, bytes.count)
            lines += assembler.feed(Data(bytes[index..<end]))
            index = end
        }
        #expect(lines.count == 2)
        #expect(lines.first == Self.gga)
    }

    @Test func receiverMergesSentencesIntoRows() throws {
        var receiver = NMEAReceiver()
        let text = [Self.rmc, Self.gst, Self.gga].joined(separator: "\r\n") + "\r\n"
        let rows = receiver.feed(Data(text.utf8))
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.count == NMEAReceiver.channels.count)
        #expect(abs(row[0] - 48.1173) < 1e-6)
        #expect(abs(row[6] - 11.524) < 0.01)          // speed from the RMC before it
        #expect(abs(row[8] - 0.0305) < 0.001)         // sqrt(0.023² + 0.020²)
    }

    @Test func textIsToldFromBinary() {
        #expect(NMEA.looksLikeText(Data("$GPGGA,1,2\r\n".utf8)))
        #expect(!NMEA.looksLikeText(Data([0x01, 0x02, 0xFF])))
        #expect(!NMEA.looksLikeText(Data()))
    }

    @Test func noFixIsNotARow() {
        var receiver = NMEAReceiver()
        let body = "GPGGA,123519,4807.038,N,01131.000,E,0,00,99.9,,M,,M,,"
        var sum: UInt8 = 0
        for byte in body.utf8 { sum ^= byte }
        let line = "$\(body)*\(String(format: "%02X", sum))\r\n"
        #expect(receiver.feed(Data(line.utf8)).isEmpty)
    }
}

@Suite("Recording extender")
struct RecordingExtenderTests {
    private func makeStore() throws -> RecordingStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("extender-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return RecordingStore(root: root)
    }

    private func metadata(in store: RecordingStore) throws -> RecordingMetadata {
        let id = UUID()
        _ = try store.prepareDirectory(for: id)
        let metadata = RecordingMetadata(
            id: id, name: "x", startedAt: Date(timeIntervalSince1970: 1_000_000), startHostTime: 500,
            duration: 60, device: DeviceInfo(model: "t", systemName: "iOS", systemVersion: "1", appVersion: "1"),
            streams: [], requestedRateHz: 10)
        try store.save(metadata)
        return metadata
    }

    @Test func hostTimeFollowsTheWallClock() throws {
        let store = try makeStore()
        let recording = try metadata(in: store)
        let at = RecordingExtender.hostTime(for: Date(timeIntervalSince1970: 1_000_030), in: recording)
        #expect(at == 530)
    }

    @Test func streamsAreWrittenListedAndReplaced() throws {
        let store = try makeStore()
        let recording = try metadata(in: store)
        let info = ExternalStreamInfo(id: "health.heartrate", source: .derived, title: "Puls",
                                      channels: ["bpm"], channelUnits: ["1/min"])
        let first = ExtraStream(info: info, samples: [(time: 510, values: [70]), (time: 505, values: [68])])
        let once = try RecordingExtender.append([first], to: recording, in: store)
        #expect(once.externalStreams?.count == 1)
        #expect(once.externalStreams?.first?.sampleCount == 2)

        let second = ExtraStream(info: info, samples: [(time: 520, values: [72])])
        let twice = try RecordingExtender.append([second], to: once, in: store)
        #expect(twice.externalStreams?.count == 1)
        #expect(twice.externalStreams?.first?.sampleCount == 1)

        let reloaded = try store.loadMetadata(id: recording.id)
        #expect(reloaded.externalStreams?.first?.id == "health.heartrate")
        #expect(store.reader(for: info, recording: recording.id) != nil)
    }

    @Test func emptyStreamsAreSkipped() throws {
        let store = try makeStore()
        let recording = try metadata(in: store)
        let info = ExternalStreamInfo(id: "health.none", source: .derived, title: "–", channels: ["v"])
        let result = try RecordingExtender.append([ExtraStream(info: info, samples: [])], to: recording, in: store)
        #expect(result.externalStreams == nil)
    }
}
