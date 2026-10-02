import Foundation

/// A recording as training data: sensors on one even grid, every sample labelled, and the same
/// thing cut into windows with the usual features.
///
/// The labels are the recording's own annotations. A note typed or tapped during the run —
/// „gehen", „rennen", „Treppe" — labels everything from that moment until the next note,
/// and the last one until the end; whatever comes before the first note is unlabelled. That is
/// how a person actually labels while moving: one tap at the change, not a start and a stop for
/// each.
///
/// Three outputs, because three tools want three shapes:
/// - `samples.csv`: every grid point, one column per channel, plus `label`. For anything that
///   learns on raw sequences.
/// - `windows.csv`: one row per window with mean, standard deviation, minimum, maximum and RMS
///   of every column. For tabular learners and for scikit-learn.
/// - `activity/<label>/window-<n>.csv`: each labelled window as its own file, the folder layout
///   Create ML's Activity Classifier reads.
public struct MLDatasetExporter: Sendable {

    public struct Options: Sendable, Equatable {
        /// Fixed-rate sensors only: an even grid of an event-driven stream is a lie about when
        /// things happened.
        public var sensors: [SensorID]
        public var rateHz: Double
        public var windowSeconds: Double
        /// 0…0.9 of a window shared with the next.
        public var overlap: Double
        public var includesUnlabelled: Bool
        public var writesActivityFiles: Bool

        public init(sensors: [SensorID] = [.userAcceleration, .rotationRate, .gravity],
                    rateHz: Double = 50, windowSeconds: Double = 2, overlap: Double = 0.5,
                    includesUnlabelled: Bool = false, writesActivityFiles: Bool = true) {
            self.sensors = sensors
            self.rateHz = rateHz
            self.windowSeconds = windowSeconds
            self.overlap = overlap
            self.includesUnlabelled = includesUnlabelled
            self.writesActivityFiles = writesActivityFiles
        }
    }

    public struct Summary: Sendable, Equatable {
        public var samples: Int
        public var windows: Int
        public var labels: [String: Int]
    }

    public enum DatasetError: Error, LocalizedError {
        case noData

        public var errorDescription: String? {
            String(localized: "Die Aufnahme enthält keinen der gewählten Sensoren.")
        }
    }

    private let store: RecordingStore

    public init(store: RecordingStore) {
        self.store = store
    }

    /// Label intervals from annotations: `(start, end, label)` in host time.
    public static func labelIntervals(_ annotations: [Annotation], end: Double) -> [(start: Double, end: Double, label: String)] {
        let sorted = annotations.sorted { $0.hostTime < $1.hostTime }
        return sorted.enumerated().map { index, annotation in
            (annotation.hostTime, index + 1 < sorted.count ? sorted[index + 1].hostTime : end,
             annotation.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    @discardableResult
    public func write(_ metadata: RecordingMetadata, options: Options = Options(), into folder: URL) throws -> Summary {
        let rate = max(options.rateHz, 1)
        let start = metadata.startHostTime
        let end = start + metadata.duration
        let count = Int((end - start) * rate)

        // Columns: every channel of every chosen sensor that this recording has.
        var names: [String] = []
        var columns: [[Double]] = []
        let grid = (0..<max(count, 0)).map { start + Double($0) / rate }
        for sensor in options.sensors {
            guard let reader = store.reader(for: sensor, recording: metadata.id), !reader.isEmpty else { continue }
            let descriptor = sensor.descriptor
            for channel in 0..<reader.channelCount {
                let series = TimeSeries(reader: reader, channel: channel)
                columns.append(Self.interpolate(series, at: grid))
                let channelName = descriptor.channels.indices.contains(channel) ? descriptor.channels[channel] : "c\(channel)"
                names.append("\(sensor.rawValue)_\(channelName)")
            }
        }
        guard !columns.isEmpty, count > 0 else { throw DatasetError.noData }

        let intervals = Self.labelIntervals(store.annotations(for: metadata.id), end: end)
        func label(at time: Double) -> String {
            intervals.last { $0.start <= time && time < $0.end }?.label ?? ""
        }
        let labels = grid.map(label(at:))

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // samples.csv
        var samples = "time,label," + names.joined(separator: ",") + "\n"
        for index in 0..<count {
            guard options.includesUnlabelled || !labels[index].isEmpty else { continue }
            var row = [RecordingExporter.number(grid[index] - start), RecordingExporter.csvEscape(labels[index])]
            for column in columns { row.append(RecordingExporter.number(column[index])) }
            samples += row.joined(separator: ",") + "\n"
        }
        try Data(samples.utf8).write(to: folder.appendingPathComponent("samples.csv"), options: .atomic)

        // windows.csv and the activity folders
        let size = max(Int(options.windowSeconds * rate), 2)
        let hop = max(Int(Double(size) * (1 - min(max(options.overlap, 0), 0.9))), 1)
        var windows = "window_start,window_end,label," + names.flatMap { name in
            ["mean", "std", "min", "max", "rms"].map { "\(name)_\($0)" }
        }.joined(separator: ",") + "\n"
        var summary = Summary(samples: count, windows: 0, labels: [:])
        var cursor = 0
        var perLabel: [String: Int] = [:]
        while cursor + size <= count {
            defer { cursor += hop }
            // A window that straddles two labels says neither.
            let first = labels[cursor]
            guard labels[cursor..<(cursor + size)].allSatisfy({ $0 == first }) else { continue }
            guard options.includesUnlabelled || !first.isEmpty else { continue }

            var row = [RecordingExporter.number(grid[cursor] - start),
                       RecordingExporter.number(grid[cursor + size - 1] - start), RecordingExporter.csvEscape(first)]
            for column in columns {
                let part = Array(column[cursor..<(cursor + size)])
                row.append(RecordingExporter.number(Statistics.mean(part) ?? .nan))
                row.append(RecordingExporter.number(Statistics.standardDeviation(part) ?? .nan))
                row.append(RecordingExporter.number(part.filter(\.isFinite).min() ?? .nan))
                row.append(RecordingExporter.number(part.filter(\.isFinite).max() ?? .nan))
                row.append(RecordingExporter.number(Statistics.rms(part) ?? .nan))
            }
            windows += row.joined(separator: ",") + "\n"
            summary.windows += 1
            summary.labels[first, default: 0] += 1

            if options.writesActivityFiles, !first.isEmpty {
                let directory = folder.appendingPathComponent("activity", isDirectory: true)
                    .appendingPathComponent(RecordingExporter.sanitize(first), isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                perLabel[first, default: 0] += 1
                var file = names.joined(separator: ",") + "\n"
                for index in cursor..<(cursor + size) {
                    file += columns.map { RecordingExporter.number($0[index]) }.joined(separator: ",") + "\n"
                }
                try Data(file.utf8).write(to: directory.appendingPathComponent("window-\(perLabel[first] ?? 0).csv"),
                                          options: .atomic)
            }
        }
        try Data(windows.utf8).write(to: folder.appendingPathComponent("windows.csv"), options: .atomic)

        var labelFile = "start,end,label\n"
        for interval in intervals {
            labelFile += "\(RecordingExporter.number(interval.start - start)),\(RecordingExporter.number(interval.end - start)),\(RecordingExporter.csvEscape(interval.label))\n"
        }
        try Data(labelFile.utf8).write(to: folder.appendingPathComponent("labels.csv"), options: .atomic)
        try Data(Self.readme(rate: rate, options: options, columns: names).utf8)
            .write(to: folder.appendingPathComponent("README.txt"), options: .atomic)
        return summary
    }

    /// Values of `series` at each of `grid`'s times, interpolated linearly between the two
    /// neighbouring samples and held at the ends. The grid is ascending, so one pass will do.
    static func interpolate(_ series: TimeSeries, at grid: [Double]) -> [Double] {
        guard !series.isEmpty else { return grid.map { _ in .nan } }
        var cursor = 0
        return grid.map { time in
            if time < series.times[0] { return .nan }
            while cursor + 1 < series.times.count, series.times[cursor + 1] <= time { cursor += 1 }
            guard cursor + 1 < series.times.count else { return series.values[cursor] }
            let (t0, t1) = (series.times[cursor], series.times[cursor + 1])
            let (v0, v1) = (series.values[cursor], series.values[cursor + 1])
            guard t1 > t0, v0.isFinite, v1.isFinite else { return v0 }
            return v0 + (v1 - v0) * (time - t0) / (t1 - t0)
        }
    }

    private static func readme(rate: Double, options: Options, columns: [String]) -> String {
        """
        Sensorstorm — dataset for machine learning

        samples.csv   every \(RecordingExporter.number(1 / rate)) s: time (seconds since the start), label, then \(columns.count) channels
        windows.csv   windows of \(RecordingExporter.number(options.windowSeconds)) s, \(Int(options.overlap * 100)) % overlap: mean, std, min, max, rms of every channel
        labels.csv    the label intervals, in seconds since the start
        activity/     one folder per label, one file per window (Create ML activity classifier)

        Labels come from the recording's notes: a note labels everything from its time until the
        next note, the last until the end. Samples before the first note are unlabelled\(options.includesUnlabelled ? "" : " and left out").
        A window that spans two labels is left out. Sensors are interpolated linearly onto the grid.

        Columns: \(columns.joined(separator: ", "))
        """
    }
}
