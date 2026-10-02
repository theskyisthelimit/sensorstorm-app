import Foundation
import Testing
@testable import SensorstormCore

private func sine(_ amplitude: Double, hz: Double, rate: Double, seconds: Double, start: Double = 0,
                  offset: Double = 0) -> TimeSeries {
    let count = Int(seconds * rate)
    return TimeSeries(times: (0..<count).map { start + Double($0) / rate },
                      values: (0..<count).map { offset + amplitude * sin(2 * .pi * hz * Double($0) / rate) })
}

@Suite("Zeitreihen und Filter")
struct SeriesAndFilterTests {

    @Test("Ein Wert gilt, bis der nächste kommt, und vor dem ersten gibt es keinen")
    func holdAndSlice() {
        let series = TimeSeries(times: [1, 2, 4], values: [10, .nan, 40])
        #expect(series.value(at: 0.5) == nil && series.value(at: 1) == 10 && series.value(at: 1.9) == 10)
        #expect(series.value(at: 2.5) == nil)                  // a NaN is not a value
        #expect(series.value(at: 100) == 40)
        #expect(series.slice(1.5...4).times == [2, 4])
        #expect(series.medianInterval == 1.5 || series.medianInterval == 2 || series.medianInterval == 1)
    }

    @Test("Auf ein gleichmässiges Raster umrechnen, glätten, Perzentile")
    func resampleAndStats() {
        let uneven = TimeSeries(times: [0, 1, 3], values: [0, 10, 30])
        let even = uneven.resampled(rate: 1)
        #expect(even.times == [0, 1, 2, 3] && even.values == [0, 10, 20, 30])
        let smooth = TimeSeries.uniform([0, 0, 9, 0, 0], rate: 10).smoothed(seconds: 0.3)
        #expect(smooth.values[2] == 3)
        #expect(Statistics.percentile([1, 2, 3, 4, 5], 0.5) == 3)
        #expect(Statistics.percentile([1, 2, 3, 4, 5, .nan], 1) == 5)
        #expect(Statistics.percentile([], 0.5) == nil)
        #expect(abs((Statistics.rms([3, 4]) ?? 0) - 12.5.squareRoot()) < 1e-12)
    }

    @Test("Hochpass und Tiefpass lassen durch und sperren, wo sie sollen")
    func butterworth() {
        let high = Biquad.highPass(cutoff: 1, rate: 100)
        #expect(high.magnitude(at: 10, rate: 100) > 0.999)
        #expect(high.magnitude(at: 0.1, rate: 100) < 0.02)
        #expect(abs(high.magnitude(at: 1, rate: 100) - 1 / 2.0.squareRoot()) < 0.01)
        let low = Biquad.lowPass(cutoff: 10, rate: 100)
        #expect(low.magnitude(at: 1, rate: 100) > 0.999 && low.magnitude(at: 40, rate: 100) < 0.1)
        // A constant goes through a high-pass as zero.
        let flat = FilterChain.bandPass(low: 0.5, high: 20, rate: 100).apply(to: TimeSeries.uniform(Array(repeating: 5, count: 2_000), rate: 100))
        #expect(abs(flat.values.last ?? 1) < 1e-3)
    }

    @Test("Die A-Bewertung folgt der Tabelle der Norm")
    func aWeighting() {
        // IEC 61672-1, table of nominal frequencies, with the tolerance of a class 1 meter
        // loosened a little at the ends, where the bilinear transform bends the curve.
        let table: [(Double, Double, Double)] = [
            (20, -50.5, 1.5), (31.5, -39.4, 1.0), (63, -26.2, 0.8), (100, -19.1, 0.6), (200, -10.9, 0.5),
            (500, -3.2, 0.4), (1_000, 0, 0.05), (2_000, 1.2, 0.5), (4_000, 1.0, 0.6), (8_000, -1.1, 1.0),
            (10_000, -2.5, 1.5),
        ]
        for (frequency, expected, tolerance) in table {
            let measured = AWeighting.decibels(at: frequency, rate: 48_000)
            #expect(abs(measured - expected) <= tolerance, "\(frequency) Hz: \(measured) dB, expected \(expected)")
        }
        // And through the filter, a 100 Hz tone comes out a ninth of its size.
        var chain = AWeighting.filter(rate: 48_000)
        let input = sine(1, hz: 100, rate: 48_000, seconds: 1)
        let output = input.values.map { chain.process($0) }
        let peak = output.suffix(24_000).map(abs).max() ?? 0
        #expect(abs(peak - pow(10, -19.1 / 20)) < 0.015)
    }
}

@Suite("Qualitätsbericht")
struct QualityTests {

    private func assess(_ series: TimeSeries, event: Bool = false, requested: Double? = 100,
                        frozen: Bool = true, duration: Double = 60) -> StreamQuality {
        RecordingQuality.assess(key: "k", title: "t", series: series, isEventDriven: event,
                                requestedRate: requested, checksFrozen: frozen, recordingDuration: duration)
    }

    @Test("Ein sauberer Strom ist gut")
    func clean() {
        let result = assess(sine(1, hz: 3, rate: 100, seconds: 10))
        #expect(result.verdict == .good && result.notes.isEmpty && abs(result.measuredRate - 100) < 0.5)
    }

    @Test("Lücken, Rate, fehlende Werte, rückwärts laufende Zeit, eingefrorene Werte")
    func problems() {
        let base = sine(1, hz: 3, rate: 100, seconds: 10)

        var gap = base
        gap.times = gap.times.enumerated().map { $0.offset >= 500 ? $0.element + 3 : $0.element }
        let gapped = assess(gap, duration: 10)
        #expect(gapped.verdict == .poor && gapped.gapCount == 1 && abs(gapped.longestGap - 3.01) < 0.02)
        // A second missing in a minute is worth a note, not a failure.
        let shortGap = assess(TimeSeries(times: base.times.enumerated().map { $0.offset >= 500 ? $0.element + 1 : $0.element },
                                         values: base.values), duration: 60)
        #expect(shortGap.verdict == .fair && shortGap.gapCount == 1)

        let slow = assess(sine(1, hz: 3, rate: 60, seconds: 10))
        #expect(slow.verdict == .poor)
        #expect(assess(sine(1, hz: 3, rate: 85, seconds: 10)).verdict == .fair)
        // Event-driven streams are not held to a rate.
        #expect(assess(sine(1, hz: 0.1, rate: 1, seconds: 100), event: true, requested: nil).verdict == .good)

        var holes = base
        holes.values = holes.values.enumerated().map { $0.offset % 10 < 4 ? .nan : $0.element }
        #expect(assess(holes).verdict == .poor)
        holes.values = base.values.enumerated().map { $0.offset % 10 == 0 ? .nan : $0.element }
        #expect(assess(holes).verdict == .fair)

        var back = base
        back.times[500] = back.times[499]
        #expect(assess(back).verdict == .poor && assess(back).backwardsCount == 1)

        let frozen = TimeSeries.uniform(Array(repeating: 0.5, count: 1_000), rate: 100)
        #expect(assess(frozen).verdict == .poor)
        #expect(assess(frozen, frozen: false).verdict == .good)

        #expect(assess(TimeSeries.uniform([1, 2], rate: 100), duration: 20).verdict == .poor)
        #expect(assess(TimeSeries.uniform([1, 2], rate: 1), event: true, requested: nil, duration: 20).verdict == .fair)
    }

    @Test("Position: Genauigkeit und Ausfall")
    func gps() {
        func accuracy(_ value: Double, gapAfter: Int? = nil) -> TimeSeries {
            TimeSeries(times: (0..<100).map { Double($0) + ($0 > (gapAfter ?? 1_000) ? 30 : 0) },
                       values: Array(repeating: value, count: 100))
        }
        #expect(RecordingQuality.assessGPS(accuracy: accuracy(5))?.verdict == .good)
        #expect(RecordingQuality.assessGPS(accuracy: accuracy(15))?.verdict == .fair)
        #expect(RecordingQuality.assessGPS(accuracy: accuracy(40))?.verdict == .poor)
        #expect(RecordingQuality.assessGPS(accuracy: accuracy(5, gapAfter: 50))?.verdict == .fair)
        #expect(RecordingQuality.assessGPS(accuracy: accuracy(-1)) == nil)
        let result = RecordingQuality.assessGPS(accuracy: accuracy(5))
        #expect(result?.shareWithin10m == 1 && result?.medianAccuracy == 5 && result?.fixCount == 100)
    }
}

@Suite("Strecke einfärben und Strassenzustand")
struct TrackAndRoadTests {

    @Test("Die Farbe folgt dem Wert, ungenaue Fixe fallen heraus")
    func coloring() {
        let times = (0..<100).map(Double.init)
        let latitude = TimeSeries(times: times, values: times.map { 46.0 + $0 * 0.0001 })
        let longitude = TimeSeries(times: times, values: Array(repeating: 7.0, count: 100))
        var accuracy = TimeSeries(times: times, values: Array(repeating: 5, count: 100))
        accuracy.values[50] = -1
        let metric = TimeSeries(times: times, values: times)
        let result = TrackColoring.make(latitude: latitude, longitude: longitude, accuracy: accuracy, metric: metric)
        #expect(result.segments.count == 98)
        let fractions = result.segments.compactMap(\.fraction)
        #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(fractions.first == 0 && fractions.last == 1 && result.low < result.high)
        #expect(TrackColoring.make(latitude: latitude, longitude: longitude, accuracy: accuracy, metric: metric,
                                   maximumSegments: 20).segments.count <= 21)
        // A metric that starts late leaves the early pieces without a value.
        let late = TimeSeries(times: [50, 60], values: [1, 2])
        let partial = TrackColoring.make(latitude: latitude, longitude: longitude, metric: late)
        #expect(partial.segments.first?.value == nil && partial.segments.last?.value != nil)
        #expect(TrackColoring.make(latitude: .init(times: [], values: []), longitude: .init(times: [], values: []),
                                   metric: metric).isEmpty)
    }

    @Test("Rauheit steigt mit der Amplitude, ein Schlag wird gefunden, Stillstand wird nicht beurteilt")
    func roughness() {
        let rate = 50.0
        var vertical = sine(0.02, hz: 3, rate: rate, seconds: 20)
        let rough = sine(0.2, hz: 3, rate: rate, seconds: 20, start: 20)
        vertical.times += rough.times
        vertical.values += rough.values
        // One pothole, ten seconds into the rough half.
        for offset in 0..<3 { vertical.values[Int(30 * rate) + offset] += 2.0 }
        let speed = TimeSeries(times: stride(from: 0, to: 40, by: 0.1).map { $0 }, values: Array(repeating: 10, count: 400))

        let result = RoadRoughness.analyse(vertical: vertical, speed: speed)
        #expect(result.segments.count > 30)
        let first = result.segments.filter { $0.endTime < 19 }.map(\.rms)
        let second = result.segments.filter { $0.startTime > 22 && ($0.endTime < 29 || $0.startTime > 32) }.map(\.rms)
        let ratio = (Statistics.mean(second) ?? 0) / (Statistics.mean(first) ?? 1)
        #expect(ratio > 6 && ratio < 14, "ratio \(ratio)")
        #expect(abs((Statistics.mean(first) ?? 0) - 0.02 * standardGravity / 2.0.squareRoot()) < 0.04)
        #expect(result.shocks.count == 1 && (result.shocks.first?.peak ?? 0) > 0.35)
        #expect(abs((result.shocks.first?.time ?? 0) - 30) < 0.5)
        #expect(abs(result.distance - 380) < 30)
        #expect(result.segments.contains { $0.rank == 1 } && result.segments.contains { $0.rank == 0 })

        // Crawling traffic is not a road.
        let slow = TimeSeries(times: speed.times, values: Array(repeating: 1.5, count: 400))
        #expect(RoadRoughness.analyse(vertical: vertical, speed: slow).segments.isEmpty)
        // And a recording that is too coarse cannot say anything.
        #expect(RoadRoughness.analyse(vertical: sine(1, hz: 1, rate: 5, seconds: 60), speed: speed).segments.isEmpty)
    }
}

@Suite("Aufzug, Fahrkomfort, Erschütterung")
struct ComfortAndVibrationTests {

    @Test("Eine Fahrt nach oben: Höhe, Spitzengeschwindigkeit, Beschleunigung, Ruck")
    func elevator() {
        // A quintic S-curve of 9 m over 8 s, as a real car's controller drives it: the
        // acceleration starts and ends at zero. Peak speed 2.1 m/s, peak acceleration
        // 0.81 m/s², peak jerk 1.05 m/s³.
        func height(_ t: Double) -> Double {
            let tau = min(max((t - 10) / 8, 0), 1)
            return 9 * (6 * pow(tau, 5) - 15 * pow(tau, 4) + 10 * pow(tau, 3))
        }
        func acceleration(_ t: Double) -> Double {
            let tau = (t - 10) / 8
            return tau >= 0 && tau <= 1 ? 9 * (120 * pow(tau, 3) - 180 * tau * tau + 60 * tau) / 64 / standardGravity : 0
        }
        let altitude = TimeSeries(times: stride(from: 0, to: 40, by: 0.5).map { $0 }, values: stride(from: 0, to: 40, by: 0.5).map(height))
        let vertical = TimeSeries(times: stride(from: 0, to: 40, by: 0.02).map { $0 }, values: stride(from: 0, to: 40, by: 0.02).map(acceleration))

        let rides = ElevatorAnalysis.analyse(altitude: altitude, vertical: vertical)
        #expect(rides.count == 1)
        let ride = rides[0]
        #expect(ride.isUp && abs(ride.heightChange - 9) < 0.8)
        #expect(ride.peakSpeed > 1.4 && ride.peakSpeed < 2.3)
        #expect(abs(ride.peakAcceleration - 0.81) < 0.2 && abs(ride.peakDeceleration - 0.81) < 0.2)
        #expect(ride.peakJerk > 0.6 && ride.peakJerk < 1.5, "jerk \(ride.peakJerk)")
        #expect(ride.duration > 4 && ride.duration < 12)

        // Standing still is no ride.
        let flat = TimeSeries(times: altitude.times, values: altitude.values.map { _ in 3 })
        #expect(ElevatorAnalysis.analyse(altitude: flat, vertical: vertical).isEmpty)
        // The same ride downwards.
        let down = TimeSeries(times: altitude.times, values: altitude.values.map { 9 - $0 })
        let downward = TimeSeries(times: vertical.times, values: vertical.values.map { -$0 })
        let descent = ElevatorAnalysis.analyse(altitude: down, vertical: downward)
        #expect(descent.count == 1 && !descent[0].isUp && abs(descent[0].peakAcceleration - 0.81) < 0.2)
    }

    @Test("Fahrkomfort: Klasse nach dem Index, Ruck mit Zeit")
    func comfort() throws {
        let rate = 100.0
        let z = sine(0.1, hz: 2, rate: rate, seconds: 60)
        let x = sine(0.02, hz: 1, rate: rate, seconds: 60)
        let y = sine(0.02, hz: 1.3, rate: rate, seconds: 60)
        let result = try #require(RideComfort.analyse(x: x, y: y, z: z, joltThreshold: 2))
        #expect(abs(result.vertical - 0.1 * standardGravity / 2.0.squareRoot()) < 0.05)
        #expect(result.comfortClass == .lessComfortable, "index \(result.comfortIndex)")
        #expect(result.jolts.isEmpty && result.windows >= 10)

        var spiked = z
        for offset in 0..<2 { spiked.values[Int(30 * rate) + offset] += 0.5 }
        let jolted = try #require(RideComfort.analyse(x: x, y: y, z: spiked, joltThreshold: 2))
        #expect(jolted.jolts.count == 1 && jolted.jolts[0].axis == .vertical && abs(jolted.jolts[0].time - 30) < 0.5)

        #expect(RideComfort.Class(index: 1) == .veryComfortable && RideComfort.Class(index: 3) == .medium
                && RideComfort.Class(index: 9) == .uncomfortable)
        #expect(RideComfort.analyse(x: x, y: y, z: sine(0.1, hz: 2, rate: 10, seconds: 60)) == nil)
    }

    @Test("Schwinggeschwindigkeit aus der Beschleunigung, gegen die Richtwerte der DIN 4150-3")
    func vibration() throws {
        // 20 Hz at 10 mm/s needs an acceleration amplitude of 2π·20·0.01 = 1.2566 m/s².
        let amplitude = 2 * Double.pi * 20 * 0.010 / standardGravity
        let z = sine(amplitude, hz: 20, rate: 200, seconds: 20)
        let quiet = TimeSeries(times: z.times, values: z.values.map { _ in 0 })
        let result = try #require(VibrationScreening.analyse(x: quiet, y: quiet, z: z, category: .dwelling))
        #expect(abs(result.z.peakVelocity - 10) < 1.0, "\(result.z.peakVelocity) mm/s")
        #expect(abs(result.z.frequency - 20) < 3)
        #expect(result.x.peakVelocity < 0.01 && result.governing == result.z)
        // At 20 Hz the dwelling line is 5 + (15 − 5)·10/40 = 7.5 mm/s.
        #expect(abs(result.guideValue - 7.5) < 0.4 && result.exceeded)
        let commercial = try #require(VibrationScreening.analyse(x: quiet, y: quiet, z: z, category: .commercial))
        #expect(!commercial.exceeded && abs(commercial.guideValue - 25) < 0.7)

        #expect(VibrationScreening.guideValue(.dwelling, frequency: 5) == 5)
        #expect(VibrationScreening.guideValue(.dwelling, frequency: 50) == 15)
        #expect(VibrationScreening.guideValue(.dwelling, frequency: 500) == 20)
        #expect(VibrationScreening.guideValue(.sensitive, frequency: 10) == 3)
        // Too coarse a recording does not cover the band.
        #expect(VibrationScreening.analyse(x: quiet, y: quiet, z: sine(1, hz: 2, rate: 50, seconds: 20), category: .dwelling) == nil)
    }
}

@Suite("Datensatz für maschinelles Lernen")
struct MLDatasetTests {

    @Test("Notizen beschriften, Fenster über zwei Beschriftungen fallen weg")
    func dataset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ml-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(root: root.appendingPathComponent("rec", isDirectory: true))

        var metadata = RecordingMetadata(
            name: "Lauf", startedAt: Date(timeIntervalSince1970: 1_700_000_000), startHostTime: 1_000, duration: 10,
            device: DeviceInfo(model: "iPhone17,1", systemName: "iOS", systemVersion: "26.0", appVersion: "1.0.0"),
            requestedRateHz: 100)
        let directory = try store.prepareDirectory(for: metadata.id)
        let writer = try StreamWriter(sensor: .userAcceleration, channelCount: 3, directory: directory)
        for step in 0..<1_000 {
            let time = 1_000 + Double(step) / 100
            writer.append(time: time, values: [time < 1_005 ? 0.1 : 0.9, 0.2, 0.3])
        }
        metadata.streams = [writer.close()]
        try store.save(metadata)
        try store.saveAnnotations([Annotation(hostTime: 1_000, text: "gehen"), Annotation(hostTime: 1_005, text: "rennen")], for: metadata.id)

        let out = root.appendingPathComponent("out")
        let summary = try MLDatasetExporter(store: store).write(
            metadata, options: .init(sensors: [.userAcceleration], rateHz: 10, windowSeconds: 1, overlap: 0), into: out)
        #expect(summary.samples == 100 && summary.windows == 10 && summary.labels == ["gehen": 5, "rennen": 5])

        let samples = try String(contentsOf: out.appendingPathComponent("samples.csv"), encoding: .utf8).split(separator: "\n")
        #expect(samples.count == 101 && samples[0] == "time,label,userAcceleration_x,userAcceleration_y,userAcceleration_z")
        #expect(samples[1].hasPrefix("0,gehen,0.1") && samples[100].contains("rennen,0.9"))
        let windows = try String(contentsOf: out.appendingPathComponent("windows.csv"), encoding: .utf8).split(separator: "\n")
        #expect(windows.count == 11 && windows[1].contains("gehen"))
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("activity/rennen/window-5.csv").path))
        let labels = try String(contentsOf: out.appendingPathComponent("labels.csv"), encoding: .utf8)
        #expect(labels.contains("0,5,gehen") && labels.contains("5,10,rennen"))

        // Overlapping windows across the change are dropped, not mislabelled.
        let overlapped = try MLDatasetExporter(store: store).write(
            metadata, options: .init(sensors: [.userAcceleration], rateHz: 10, windowSeconds: 1, overlap: 0.5,
                                     writesActivityFiles: false), into: root.appendingPathComponent("out2"))
        // Nineteen windows start every half second; the one that spans 4.5–5.5 s says neither.
        #expect(overlapped.windows == 18)
        #expect(overlapped.labels.values.reduce(0, +) == overlapped.windows)

        // A sensor the recording does not have gives no data.
        #expect(throws: MLDatasetExporter.DatasetError.self) {
            try MLDatasetExporter(store: store).write(metadata, options: .init(sensors: [.gyroscope]),
                                                      into: root.appendingPathComponent("out3"))
        }
    }
}
