import Foundation
import Testing
@testable import SensorstormCore

@Suite("Binary stream round-trip")
struct StreamRoundTripTests {

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensorstorm-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Every written sample reads back bit-exact")
    func roundTrip() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = try StreamWriter(sensor: .accelerometer, channelCount: 3, directory: directory)
        // Enough samples to cross the 64 KB flush threshold several times.
        let count = 20_000
        for i in 0..<count {
            let t = 1000.0 + Double(i) / 200.0
            writer.append(time: t, values: [Double(i), -Double(i) * 0.5, 9.81])
        }
        let info = writer.close()

        #expect(info.sampleCount == count)
        #expect(abs(info.effectiveRateHz - 200) < 0.01)

        let reader = try StreamReader(url: writer.url)
        #expect(reader.sampleCount == count)
        #expect(reader.channelCount == 3)

        for i in stride(from: 0, to: count, by: 997) {
            #expect(reader.time(at: i) == 1000.0 + Double(i) / 200.0)
            #expect(reader.value(at: i, channel: 0) == Double(i))
            #expect(reader.value(at: i, channel: 1) == -Double(i) * 0.5)
            #expect(reader.value(at: i, channel: 2) == 9.81)
        }
    }

    @Test("Latitude survives the round-trip at full double precision")
    func precision() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let latitude = 47.376887654321098
        let longitude = 8.541694123456789

        let writer = try StreamWriter(sensor: .location, channelCount: 10, directory: directory)
        writer.append(time: 12.5, values: [latitude, longitude] + Array(repeating: 0, count: 8))
        writer.close()

        let reader = try StreamReader(url: writer.url)
        #expect(reader.value(at: 0, channel: 0) == latitude)
        #expect(reader.value(at: 0, channel: 1) == longitude)
    }

    @Test("An empty stream is readable and reports zero samples")
    func emptyStream() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = try StreamWriter(sensor: .gyroscope, channelCount: 3, directory: directory)
        let info = writer.close()
        #expect(info.sampleCount == 0)
        #expect(info.effectiveRateHz == 0)

        let reader = try StreamReader(url: writer.url)
        #expect(reader.isEmpty)
        #expect(reader.timeRange == nil)
        #expect(reader.series(channel: 0).isEmpty)
    }

    @Test("Header of a foreign file is rejected")
    func badMagic() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("bogus.ssbin")
        try Data(repeating: 0x41, count: 128).write(to: url)
        #expect(throws: StreamError.self) { try StreamReader(url: url) }
    }
}
