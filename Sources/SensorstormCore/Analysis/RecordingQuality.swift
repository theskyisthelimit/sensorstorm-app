import Foundation

/// How trustworthy a recording is — answered from the recording itself, so that a technician
/// can say „the measurement ran cleanly" and a reviewer can check it.
///
/// A sensor log fails quietly. A stream that stopped for eight seconds when the app was
/// throttled, a clock that stepped back, a GPS that never got a fix indoors: none of them
/// shows in a chart until somebody builds a conclusion on the gap. This looks for exactly
/// those, stream by stream, and ends in one of three words.
public enum QualityVerdict: Int, Sendable, Comparable, Codable {
    case good = 0
    case fair = 1
    case poor = 2

    public static func < (lhs: QualityVerdict, rhs: QualityVerdict) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One finding about a stream. A code, not a sentence — the words belong to the interface.
public enum QualityNote: Sendable, Equatable {
    case rateBelowRequested(measured: Double, requested: Double)
    case gaps(count: Int, longest: Double)
    case missingValues(share: Double)
    case timeWentBackwards(count: Int)
    case frozen(share: Double)
    case tooShort
}

public struct StreamQuality: Sendable, Equatable, Identifiable {
    public var key: String
    public var title: String
    public var sampleCount: Int
    public var measuredRate: Double
    public var requestedRate: Double?
    public var longestGap: Double
    public var gapCount: Int
    public var missingShare: Double
    public var backwardsCount: Int
    public var frozenShare: Double
    public var verdict: QualityVerdict
    public var notes: [QualityNote]

    public var id: String { key }
}

public struct GPSQuality: Sendable, Equatable {
    public var fixCount: Int
    /// Metres, over the fixes that had one.
    public var medianAccuracy: Double
    public var worstDecile: Double
    /// Share of fixes with an accuracy of 10 m or better.
    public var shareWithin10m: Double
    /// Seconds without a fix, the longest stretch.
    public var longestOutage: Double
    public var verdict: QualityVerdict
}

public struct QualityReport: Sendable, Equatable {
    public var duration: Double
    public var streams: [StreamQuality]
    public var gps: GPSQuality?
    public var verdict: QualityVerdict

    /// The fraction of streams that came out good.
    public var goodShare: Double {
        streams.isEmpty ? 0 : Double(streams.filter { $0.verdict == .good }.count) / Double(streams.count)
    }
}

public enum RecordingQuality {

    /// Looks at one stream. `requestedRate` is what the person asked of the sensor, for the
    /// streams that run at a set rate; event-driven ones are judged on gaps alone.
    public static func assess(key: String, title: String, series: TimeSeries, isEventDriven: Bool,
                              requestedRate: Double?, checksFrozen: Bool,
                              recordingDuration: Double) -> StreamQuality {
        var notes: [QualityNote] = []
        var verdict = QualityVerdict.good
        func raise(_ level: QualityVerdict) { verdict = max(verdict, level) }

        guard series.count >= 3 else {
            return StreamQuality(key: key, title: title, sampleCount: series.count, measuredRate: 0,
                                 requestedRate: requestedRate, longestGap: 0, gapCount: 0, missingShare: 0,
                                 backwardsCount: 0, frozenShare: 0,
                                 verdict: recordingDuration >= 5 && !isEventDriven ? .poor : .fair,
                                 notes: [.tooShort])
        }

        let interval = series.medianInterval ?? 0
        let measured = interval > 0 ? 1 / interval : 0

        // Clock steps backwards or stands still.
        var backwards = 0
        var longest = 0.0
        var gaps = 0
        // What counts as a hole: several missed samples at a set rate, several seconds for a
        // stream that only speaks when something changes.
        let threshold = isEventDriven ? max(10 * interval, 15) : max(5 * interval, 0.5)
        for index in 1..<series.count {
            let step = series.times[index] - series.times[index - 1]
            if step <= 0 {
                backwards += 1
            } else if step > threshold {
                gaps += 1
                longest = max(longest, step)
            }
        }
        if backwards > 0 {
            notes.append(.timeWentBackwards(count: backwards))
            raise(.poor)
        }
        if gaps > 0 {
            notes.append(.gaps(count: gaps, longest: longest))
            let lost = longest / max(recordingDuration, 1)
            raise(longest > 10 || lost > 0.1 ? .poor : .fair)
        }

        if !isEventDriven, let requestedRate, requestedRate > 0, measured < requestedRate * 0.9 {
            notes.append(.rateBelowRequested(measured: measured, requested: requestedRate))
            raise(measured < requestedRate * 0.7 ? .poor : .fair)
        }

        let missing = Double(series.values.filter { !$0.isFinite }.count) / Double(series.count)
        if missing > 0.05 {
            notes.append(.missingValues(share: missing))
            raise(missing > 0.3 ? .poor : .fair)
        }

        var frozen = 0.0
        if checksFrozen, series.count >= 50 {
            let same = zip(series.values.dropFirst(), series.values).filter { $0 == $1 }.count
            frozen = Double(same) / Double(series.count - 1)
            if frozen > 0.9 {
                notes.append(.frozen(share: frozen))
                raise(.poor)
            }
        }

        return StreamQuality(key: key, title: title, sampleCount: series.count, measuredRate: measured,
                             requestedRate: requestedRate, longestGap: longest, gapCount: gaps,
                             missingShare: missing, backwardsCount: backwards, frozenShare: frozen,
                             verdict: verdict, notes: notes)
    }

    /// How well the positions can be trusted: from the accuracy channel and the gaps between
    /// fixes.
    public static func assessGPS(accuracy: TimeSeries) -> GPSQuality? {
        let usable = zip(accuracy.times, accuracy.values).filter { $0.1.isFinite && $0.1 > 0 }
        guard !usable.isEmpty else { return nil }
        let values = usable.map(\.1)
        let median = Statistics.median(values) ?? 0
        let worst = Statistics.percentile(values, 0.9) ?? median
        let within = Double(values.filter { $0 <= 10 }.count) / Double(values.count)
        var outage = 0.0
        for (previous, next) in zip(usable, usable.dropFirst()) {
            outage = max(outage, next.0 - previous.0)
        }
        let verdict: QualityVerdict
        if median > 30 { verdict = .poor }
        else if median > 10 || within < 0.5 || outage > 20 { verdict = .fair }
        else { verdict = .good }
        return GPSQuality(fixCount: usable.count, medianAccuracy: median, worstDecile: worst,
                          shareWithin10m: within, longestOutage: outage, verdict: verdict)
    }

    /// The whole recording.
    public static func analyse(_ metadata: RecordingMetadata, store: RecordingStore) -> QualityReport {
        var streams: [StreamQuality] = []

        for info in metadata.streams {
            guard let reader = store.reader(for: info.sensor, recording: metadata.id) else { continue }
            let descriptor = info.sensor.descriptor
            let series = TimeSeries(reader: reader, channel: 0)
            // Position and the device streams are event-driven or slow by nature; asking them
            // for the motion rate would mark every recording as bad.
            let ratedMotion = descriptor.category == .motion && !descriptor.isEventDriven
                && !SensorID.watchProvided.contains(info.sensor)
            streams.append(assess(
                key: info.sensor.rawValue, title: info.sensor.rawValue, series: series,
                isEventDriven: descriptor.isEventDriven,
                requestedRate: ratedMotion ? metadata.requestedRateHz : nil,
                checksFrozen: descriptor.category == .motion || descriptor.category == .audio,
                recordingDuration: metadata.duration))
        }
        for info in metadata.externalStreams ?? [] {
            guard let reader = store.reader(for: info, recording: metadata.id) else { continue }
            streams.append(assess(key: info.id, title: info.title, series: TimeSeries(reader: reader, channel: 0),
                                  isEventDriven: true, requestedRate: nil, checksFrozen: false,
                                  recordingDuration: metadata.duration))
        }

        var gps: GPSQuality?
        if let reader = store.reader(for: .location, recording: metadata.id), reader.channelCount > 8 {
            gps = assessGPS(accuracy: TimeSeries(reader: reader, channel: 8))
        }

        var verdict = streams.map(\.verdict).max() ?? .good
        if let gps { verdict = max(verdict, gps.verdict) }
        // One poor sensor among twenty does not make a poor recording; most of them being
        // poor does.
        if verdict == .poor, !streams.isEmpty, streams.filter({ $0.verdict == .poor }).count * 3 < streams.count,
           gps?.verdict != .poor {
            verdict = .fair
        }
        return QualityReport(duration: metadata.duration, streams: streams, gps: gps, verdict: verdict)
    }
}
