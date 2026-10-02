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

@Suite("Peer clock")
struct PeerClockTests {
    @Test func symmetricExchangeGivesTheOffset() throws {
        // The remote clock is 5 s ahead; the answer took 20 ms each way.
        let samples = (0..<10).map { i -> PeerClockSample in
            let asked = 100 + Double(i)
            return PeerClockSample(asked: asked, remote: asked + 0.02 + 5, answered: asked + 0.04)
        }
        let estimate = try #require(PeerClock.estimate(samples))
        #expect(abs(estimate.offset - 5) < 1e-9)
        #expect(abs(estimate.uncertainty - 0.02) < 1e-9)
        #expect(abs(PeerClock.local(from: 105.02, using: estimate) - 100.02) < 1e-9)
    }

    @Test func slowExchangesAreOutvoted() throws {
        // Eight clean exchanges and two where the answer sat in a queue for 300 ms.
        var samples = (0..<8).map { i -> PeerClockSample in
            let asked = 10 + Double(i)
            return PeerClockSample(asked: asked, remote: asked + 0.01 - 2, answered: asked + 0.02)
        }
        samples.append(PeerClockSample(asked: 30, remote: 30.01 - 2, answered: 30.32))
        samples.append(PeerClockSample(asked: 40, remote: 40.01 - 2, answered: 40.32))
        let estimate = try #require(PeerClock.estimate(samples))
        #expect(abs(estimate.offset + 2) < 0.001)
        #expect(estimate.bestRoundTrip < 0.03)
    }

    @Test func tooFewSamplesAreNoEstimate() {
        let two = [PeerClockSample(asked: 1, remote: 2, answered: 1.1),
                   PeerClockSample(asked: 2, remote: 3, answered: 2.1)]
        #expect(PeerClock.estimate(two) == nil)
    }
}

@Suite("Peer payload")
struct PeerPayloadTests {
    @Test func roundTrip() throws {
        let data = PeerPayload.encode(time: 123_456.789, values: [1.5, -2.25, 0, 9.81])
        #expect(data.count == 8 + 4 * 4)
        let decoded = try #require(PeerPayload.decode(data))
        #expect(decoded.time == 123_456.789)
        #expect(decoded.values == [1.5, -2.25, 0, 9.81].map { Double(Float($0)) })
    }

    @Test func clockRoundTrip() {
        #expect(PeerPayload.decodeClock(PeerPayload.clock(98_765.4321)) == 98_765.4321)
        #expect(PeerPayload.decodeClock(Data([1, 2, 3])) == nil)
    }

    @Test func malformedPacketsAreRefused() {
        #expect(PeerPayload.decode(Data(count: 5)) == nil)
        #expect(PeerPayload.decode(Data(count: 10)) == nil)   // 8 + 2: half a float
    }
}

@Suite("Event buffer")
struct EventBufferTests {
    @Test func ringKeepsOnlyTheLastSeconds() {
        var ring = SampleRing(maxSeconds: 5)
        for index in 0..<200 { ring.append(time: Double(index) / 10, values: [Double(index)]) }
        // Samples from t = 14.9 … 19.9: 51 of them at 10 Hz.
        #expect(ring.count >= 50 && ring.count <= 52)
        let recent = ring.samples(since: 18)
        #expect(recent.first?.time == 18)
        #expect(recent.last?.time == 19.9)
    }

    @Test func ringSurvivesLongRuns() {
        var ring = SampleRing(maxSeconds: 2)
        for index in 0..<20_000 { ring.append(time: Double(index) / 100, values: [0]) }
        #expect(ring.count <= 202)
        #expect(ring.samples(since: 0).count == ring.count)
    }

    @Test func shockFiresOnceThenHoldsOff() {
        var trigger = ShockTrigger(threshold: 2, holdOff: 10)
        #expect(trigger.check(time: 1, values: [0.1, 0.1, 0.1]) == nil)
        let first = trigger.check(time: 2, values: [2, 1.5, 0.5])
        #expect(first != nil)
        #expect(trigger.check(time: 3, values: [3, 0, 0]) == nil)       // held off
        #expect(trigger.check(time: 12.5, values: [3, 0, 0]) != nil)    // quiet period over
    }
}

@Suite("Bluetooth device summary")
struct BluetoothDeviceSummaryTests {
    private let log = """
    time,seconds_elapsed,address,rssi,name,manufacturer_hex,services
    100.000000,1.000000,AAAAAAAA-0000-0000-0000-000000000001,-60.000000,"Ruuvi, 4F2A",9904,181A
    101.000000,2.000000,AAAAAAAA-0000-0000-0000-000000000001,-70.000000,"Ruuvi, 4F2A",9904,181A
    102.000000,3.000000,BBBBBBBB-0000-0000-0000-000000000002,-90.000000,,,
    """

    @Test func oneRowPerDevice() throws {
        let csv = try #require(BluetoothDeviceSummary.csv(fromAdvertisementLog: log))
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0] == BluetoothDeviceSummary.header)
        let first = BluetoothDeviceSummary.parse(lines[1])
        #expect(first[0] == "AAAAAAAA-0000-0000-0000-000000000001")
        #expect(first[1] == "Ruuvi, 4F2A")
        #expect(first[6] == "2")
        #expect(first[7] == "-70.000")
        #expect(first[8] == "-65.000")
        #expect(first[9] == "-60.000")
    }

    @Test func manufacturerBecomesACompany() throws {
        let csv = try #require(BluetoothDeviceSummary.csv(fromAdvertisementLog: log))
        let fields = BluetoothDeviceSummary.parse(csv.split(separator: "\n").map(String.init)[1])
        #expect(fields[2].contains("Ruuvi"))
    }

    @Test func emptyLogHasNoSummary() {
        #expect(BluetoothDeviceSummary.csv(fromAdvertisementLog: BluetoothDeviceSummary.header) == nil)
    }

    @Test func hexReading() {
        #expect(Data(hex: "9904") == Data([0x99, 0x04]))
        #expect(Data(hex: "99f") == nil)
        #expect(Data(hex: "zz") == nil)
    }
}
