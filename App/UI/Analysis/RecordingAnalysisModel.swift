import Foundation
import Observation
import SensorstormCore
import UIKit

/// What a recording can be asked after the fact. Each analysis is a button and runs on its own,
/// off the main actor — a two-hour 100 Hz accelerometer stream is 720 000 samples per axis, and
/// nobody wants that computed just for opening the screen.
@MainActor @Observable
final class RecordingAnalysisModel {

    /// One thing the track can be coloured by.
    struct Metric: Identifiable, Hashable {
        enum Source: Hashable {
            case sensor(SensorID, channel: Int)
            case external(String, channel: Int)
        }

        let id: String
        let title: String
        let unit: String
        let source: Source
    }

    let metadata: RecordingMetadata
    let store: RecordingStore

    private(set) var metrics: [Metric] = []
    var selectedMetricID = ""

    private(set) var coloring: TrackColoring?
    private(set) var quality: QualityReport?
    private(set) var road: RoadRoughness.Result?
    private(set) var rides: [ElevatorAnalysis.Ride]?
    private(set) var comfort: RideComfort.Result?
    private(set) var comfortFailed = false
    private(set) var vibration: VibrationScreening.Result?
    private(set) var vibrationFailed = false
    var vibrationCategory: VibrationScreening.Category = .dwelling
    private(set) var running = Set<String>()
    private(set) var datasetSummary: MLDatasetExporter.Summary?

    init(metadata: RecordingMetadata, store: RecordingStore) {
        self.metadata = metadata
        self.store = store
        metrics = Self.buildMetrics(metadata)
        selectedMetricID = metrics.first?.id ?? ""
    }

    var hasLocation: Bool { metadata.stream(.location) != nil }

    var selectedMetric: Metric? { metrics.first { $0.id == selectedMetricID } }

    // MARK: - Metrics

    private static func buildMetrics(_ metadata: RecordingMetadata) -> [Metric] {
        var list: [Metric] = []
        if metadata.stream(.location) != nil {
            list.append(Metric(id: "speed", title: String(localized: "Geschwindigkeit"), unit: "m/s",
                               source: .sensor(.location, channel: 4)))
            list.append(Metric(id: "altitude", title: String(localized: "Höhe"), unit: "m",
                               source: .sensor(.location, channel: 2)))
            list.append(Metric(id: "accuracy", title: String(localized: "Genauigkeit der Position"), unit: "m",
                               source: .sensor(.location, channel: 8)))
        }
        for info in metadata.streams {
            switch info.sensor {
            case .location: continue
            case .loudness:
                list.append(Metric(id: "loudness", title: String(localized: "Lautstärke"), unit: "dBFS",
                                   source: .sensor(.loudness, channel: 0)))
            case .verticalAcceleration:
                list.append(Metric(id: "vertical", title: String(localized: "Vertikalbeschleunigung"), unit: "g",
                                   source: .sensor(.verticalAcceleration, channel: 0)))
            case .barometer:
                list.append(Metric(id: "pressure", title: String(localized: "Luftdruck"), unit: "kPa",
                                   source: .sensor(.barometer, channel: 0)))
            default: continue
            }
        }
        for info in metadata.externalStreams ?? [] {
            for (index, channel) in info.channels.enumerated() {
                list.append(Metric(id: "\(info.id)#\(index)", title: "\(info.title) · \(channel)",
                                   unit: info.unit(forChannel: index), source: .external(info.id, channel: index)))
            }
        }
        return list
    }

    private func series(_ source: Metric.Source) -> TimeSeries? {
        switch source {
        case .sensor(let sensor, let channel):
            guard let reader = store.reader(for: sensor, recording: metadata.id), !reader.isEmpty else { return nil }
            return TimeSeries(reader: reader, channel: channel)
        case .external(let id, let channel):
            guard let info = metadata.externalStreams?.first(where: { $0.id == id }),
                  let reader = store.reader(for: info, recording: metadata.id), !reader.isEmpty else { return nil }
            return TimeSeries(reader: reader, channel: channel)
        }
    }

    private func sensorSeries(_ sensor: SensorID, _ channel: Int) -> TimeSeries? {
        series(.sensor(sensor, channel: channel))
    }

    // MARK: - Runs

    private func perform<T: Sendable>(_ key: String, work: @escaping @Sendable () -> T, apply: (T) -> Void) async {
        guard !running.contains(key) else { return }
        running.insert(key)
        let result = await Task.detached(priority: .userInitiated, operation: work).value
        apply(result)
        running.remove(key)
    }

    func isRunning(_ key: String) -> Bool { running.contains(key) }

    func runQuality() async {
        let (metadata, store) = (self.metadata, self.store)
        await perform("quality", work: { RecordingQuality.analyse(metadata, store: store) }) { quality = $0 }
    }

    func runColoring() async {
        guard let metric = selectedMetric,
              let latitude = sensorSeries(.location, 0), let longitude = sensorSeries(.location, 1),
              let metricSeries = series(metric.source) else { coloring = .empty; return }
        let accuracy = sensorSeries(.location, 8)
        await perform("coloring", work: {
            TrackColoring.make(latitude: latitude, longitude: longitude, accuracy: accuracy, metric: metricSeries)
        }) { coloring = $0 }
    }

    func runRoad() async {
        guard let vertical = verticalSeries(), let speed = sensorSeries(.location, 4) else { road = RoadRoughness.Result(segments: [], shocks: [], distance: 0); return }
        let latitude = sensorSeries(.location, 0)
        let longitude = sensorSeries(.location, 1)
        await perform("road", work: {
            RoadRoughness.analyse(vertical: vertical, speed: speed, latitude: latitude, longitude: longitude)
        }) { road = $0 }
    }

    func runElevator() async {
        guard let altitude = sensorSeries(.barometer, 1), let vertical = verticalSeries() else { rides = []; return }
        await perform("elevator", work: { ElevatorAnalysis.analyse(altitude: altitude, vertical: vertical) }) { rides = $0 }
    }

    func runComfort() async {
        guard let x = sensorSeries(.userAcceleration, 0), let y = sensorSeries(.userAcceleration, 1),
              let z = sensorSeries(.userAcceleration, 2) else { comfort = nil; comfortFailed = true; return }
        let latitude = sensorSeries(.location, 0)
        let longitude = sensorSeries(.location, 1)
        await perform("comfort", work: {
            RideComfort.analyse(x: x, y: y, z: z, latitude: latitude, longitude: longitude)
        }) { comfort = $0; comfortFailed = $0 == nil }
    }

    func runVibration() async {
        guard let x = sensorSeries(.userAcceleration, 0), let y = sensorSeries(.userAcceleration, 1),
              let z = sensorSeries(.userAcceleration, 2) else { vibration = nil; vibrationFailed = true; return }
        let category = vibrationCategory
        await perform("vibration", work: {
            VibrationScreening.analyse(x: x, y: y, z: z, category: category)
        }) { vibration = $0; vibrationFailed = $0 == nil }
    }

    /// Vertical acceleration in g: the recorded stream when there is one, else the user
    /// acceleration's z axis — which is right when the phone lies flat, as it does in a car's
    /// cup holder or on an elevator floor.
    private func verticalSeries() -> TimeSeries? {
        sensorSeries(.verticalAcceleration, 0) ?? sensorSeries(.userAcceleration, 2)
    }

    func exportDataset(options: MLDatasetExporter.Options) async -> URL? {
        let (metadata, store) = (self.metadata, self.store)
        running.insert("dataset")
        defer { running.remove("dataset") }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("\(RecordingExporter.sanitize(metadata.name))-ml", isDirectory: true)
        let outcome: (URL, MLDatasetExporter.Summary)? = await Task.detached(priority: .userInitiated) {
            try? FileManager.default.removeItem(at: folder)
            guard let summary = try? MLDatasetExporter(store: store).write(metadata, options: options, into: folder),
                  let zipped = try? Self.zip(folder) else { return nil }
            return (zipped, summary)
        }.value
        datasetSummary = outcome?.1
        return outcome?.0
    }

    nonisolated private static func zip(_ folder: URL) throws -> URL {
        let destination = folder.deletingLastPathComponent().appendingPathComponent("\(folder.lastPathComponent).zip")
        try? FileManager.default.removeItem(at: destination)
        try ZipPackager.zip(directory: folder, to: destination)
        return destination
    }
}

extension TrackColoring {
    /// The ramp the map draws: blue is low, red is high.
    static func color(fraction: Double?) -> UIColor {
        guard let fraction else { return UIColor.gray.withAlphaComponent(0.6) }
        return UIColor(hue: (1 - fraction) * 0.66, saturation: 0.9, brightness: 0.95, alpha: 1)
    }
}
