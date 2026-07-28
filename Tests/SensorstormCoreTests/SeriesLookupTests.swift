import Foundation
import Testing
@testable import SensorstormCore

@Suite("Lookup and decimation")
struct SeriesLookupTests {

    /// 1000 samples at 100 Hz starting at host time 500, channel 0 = index, channel 1 = sin.
    private func makeReader() throws -> (StreamReader, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensorstorm-series-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let writer = try StreamWriter(sensor: .userAcceleration, channelCount: 2, directory: directory)
        for i in 0..<1000 {
            writer.append(time: 500 + Double(i) / 100.0,
                          values: [Double(i), sin(Double(i) / 10.0)])
        }
        writer.close()
        return (try StreamReader(url: writer.url), directory)
    }

    @Test("Scrubbing to a time returns the sample in effect")
    func indexAtOrBefore() throws {
        let (reader, directory) = try makeReader()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(reader.index(atOrBefore: 499.9) == nil)          // before the stream
        #expect(reader.index(atOrBefore: 500.0) == 0)            // exactly the first sample
        #expect(reader.index(atOrBefore: 500.005) == 0)          // between samples → earlier one
        #expect(reader.index(atOrBefore: 500.01) == 1)
        #expect(reader.index(atOrBefore: 505.0) == 500)
        #expect(reader.index(atOrBefore: 10_000) == 999)         // past the end → last sample

        let sample = try #require(reader.sample(atOrBefore: 502.5))
        #expect(sample[0] == 250)
    }

    @Test("Decimation keeps the peaks a mean would swallow")
    func decimationPreservesExtremes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensorstorm-spike-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = try StreamWriter(sensor: .accelerometer, channelCount: 1, directory: directory)
        for i in 0..<10_000 {
            // Flat line with one single-sample spike in the middle.
            writer.append(time: Double(i) / 1000.0, values: [i == 5000 ? 42.0 : 0.0])
        }
        writer.close()

        let reader = try StreamReader(url: writer.url)
        let series = reader.series(channel: 0, maxPoints: 100)

        #expect(series.count <= 100)
        #expect(series.contains { $0.high == 42.0 })
        // The spike must not dominate the mean of its bucket.
        let spikePoint = try #require(series.first { $0.high == 42.0 })
        #expect(spikePoint.value < 1.0)
    }

    @Test("A short stream is returned untouched")
    func noDecimationWhenSmall() throws {
        let (reader, directory) = try makeReader()
        defer { try? FileManager.default.removeItem(at: directory) }

        let series = reader.series(channel: 0, maxPoints: 5000)
        #expect(series.count == 1000)
        #expect(series.first?.value == 0)
        #expect(series.last?.value == 999)
    }

    @Test("Windowing restricts the series to the requested range")
    func windowedSeries() throws {
        let (reader, directory) = try makeReader()
        defer { try? FileManager.default.removeItem(at: directory) }

        let series = reader.series(channel: 0, maxPoints: 5000, in: 502.0...503.0)
        let times = series.map(\.time)
        #expect(times.allSatisfy { $0 >= 501.99 && $0 <= 503.01 })
        #expect(series.count > 90 && series.count < 110)
    }
}
