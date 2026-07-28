import AVFoundation
import Foundation
import Observation
import SensorstormCore

/// Owns an `AVPlayer` periodic time observer and removes it when it goes out of scope.
///
/// The player retains the observer, so forgetting to remove it leaks the whole playback
/// object — once per opened recording. `deinit` on a `@MainActor` type cannot touch its
/// own isolated state, so the cleanup lives here, outside any actor.
private final class PlayerTimeObserver {
    private let player: AVPlayer
    private var token: Any?

    init(player: AVPlayer, interval: TimeInterval,
         onTick: @escaping @MainActor (TimeInterval) -> Void) {
        self.player = player
        self.token = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: interval, preferredTimescale: 600),
            queue: .main
        ) { time in
            MainActor.assumeIsolated { onTick(time.seconds) }
        }
    }

    deinit {
        if let token { player.removeTimeObserver(token) }
    }
}

/// A chart-ready view of one stream, already decimated for the visible time window.
struct SensorChartData: Identifiable, Sendable {
    let sensor: SensorID
    let channels: [String]
    /// One decimated series per channel, in seconds relative to the recording start.
    let series: [[SeriesPoint]]
    let yDomain: ClosedRange<Double>

    var id: SensorID { sensor }
}

/// Drives the playback screen: one playhead that the video, the charts and the numeric
/// readouts all follow.
///
/// The playhead is in seconds since the recording started. Everything else converts into
/// it — the video by adding its own start offset, the sensor streams by adding the
/// recording's start host time. That is the whole reason the recorder bothers to store
/// those two numbers.
@MainActor
@Observable
final class RecordingPlayback {
    let metadata: RecordingMetadata
    let store: RecordingStore

    private(set) var charts: [SensorChartData] = []
    private(set) var annotations: [Annotation] = []
    private(set) var isPlaying = false
    private(set) var player: AVPlayer?
    private(set) var isLoading = true

    var playhead: TimeInterval = 0
    private(set) var visibleRange: ClosedRange<Double>

    private var readers: [SensorID: StreamReader] = [:]
    private var timeObserver: PlayerTimeObserver?
    private var tickTask: Task<Void, Never>?
    private var lastTickHostTime: Double = 0

    var duration: TimeInterval { max(metadata.duration, 0.001) }

    /// Video timeline offset: `playerTime = playhead - videoOffset`.
    private var videoOffset: TimeInterval {
        metadata.video?.offset(from: metadata.startHostTime) ?? 0
    }

    init(metadata: RecordingMetadata, store: RecordingStore) {
        self.metadata = metadata
        self.store = store
        self.visibleRange = 0...max(metadata.duration, 0.001)
    }

    // MARK: - Loading

    func load() async {
        annotations = store.annotations(for: metadata.id)

        for stream in metadata.streams where stream.sampleCount > 0 {
            readers[stream.sensor] = store.reader(for: stream.sensor, recording: metadata.id)
        }

        if let videoURL = store.videoURL(for: metadata) {
            let player = AVPlayer(url: videoURL)
            player.actionAtItemEnd = .pause
            self.player = player
            installTimeObserver(on: player)
        }

        rebuildCharts()
        isLoading = false
    }

    // MARK: - Charts

    private func rebuildCharts() {
        let start = metadata.startHostTime
        let hostRange = (start + visibleRange.lowerBound)...(start + visibleRange.upperBound)

        charts = metadata.streams
            .filter { $0.sampleCount > 0 }
            .compactMap { stream -> SensorChartData? in
                guard let reader = readers[stream.sensor] else { return nil }
                let channels = chartChannels(for: stream.sensor, available: stream.channels.count)

                var series: [[SeriesPoint]] = []
                var low = Double.greatestFiniteMagnitude
                var high = -Double.greatestFiniteMagnitude
                var hasFiniteValue = false

                for channel in channels {
                    let points = reader.series(channel: channel, maxPoints: 500, in: hostRange)
                        .map { SeriesPoint(time: $0.time - start, value: $0.value,
                                           low: $0.low, high: $0.high) }
                    for point in points where point.value.isFinite {
                        hasFiniteValue = true
                        low = Swift.min(low, point.low.isFinite ? point.low : point.value)
                        high = Swift.max(high, point.high.isFinite ? point.high : point.value)
                    }
                    series.append(points)
                }

                // A stream can be recorded and still hold nothing plottable — an unknown
                // battery level is written as NaN. An empty chart is just confusing.
                guard hasFiniteValue, series.contains(where: { !$0.isEmpty }) else { return nil }
                if low > high { low = 0; high = 1 }
                if low == high { low -= 0.5; high += 0.5 }
                // A little headroom so peaks don't sit on the frame.
                let padding = (high - low) * 0.08

                return SensorChartData(
                    sensor: stream.sensor,
                    channels: channels.map { stream.channels[$0] },
                    series: series,
                    yDomain: (low - padding)...(high + padding)
                )
            }
    }

    /// GPS has ten columns; plotting all of them on one axis is unreadable. Sensors with a
    /// natural subset get one, everything else is plotted in full.
    private func chartChannels(for sensor: SensorID, available: Int) -> [Int] {
        let preferred: [Int]
        switch sensor {
        case .location: preferred = [2, 4]          // altitude, speed
        case .pedometer: preferred = [0, 1]         // steps, distance
        case .magneticField: preferred = [0, 1, 2]  // drop accuracy
        case .compass: preferred = [0]
        case .battery: preferred = [0]
        case .network: preferred = [0]
        case .orientation: preferred = [0, 1, 2]    // roll, pitch, yaw
        default: preferred = Array(0..<available)
        }
        return preferred.filter { $0 < available }
    }

    // MARK: - Values at the playhead

    func values(for sensor: SensorID) -> [Double]? {
        guard let reader = readers[sensor], !reader.isEmpty else { return nil }
        // At playhead 0 no sample has been taken *yet* — the first one lands a few
        // milliseconds later. Showing the first sample beats showing dashes.
        return reader.sample(atOrBefore: metadata.startHostTime + playhead)
            ?? reader.sample(at: 0)
    }

    // MARK: - Transport

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard !isPlaying else { return }
        if playhead >= duration - 0.05 { seek(to: 0) }
        isPlaying = true

        if let player {
            player.play()
        } else {
            // No video to follow, so the playhead advances itself. A task rather than a
            // Timer: it dies with the object instead of being retained by the run loop.
            lastTickHostTime = HostClock.now
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(33))
                    guard let self, self.isPlaying else { return }
                    self.tick()
                }
            }
        }
    }

    func pause() {
        isPlaying = false
        player?.pause()
        tickTask?.cancel()
        tickTask = nil
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(time, 0), duration)
        playhead = clamped
        guard let player else { return }
        let target = clamped - videoOffset
        // Zero tolerance: scrubbing a sensor chart has to land on the matching frame.
        player.seek(to: CMTime(seconds: max(target, 0), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(by delta: TimeInterval) {
        seek(to: playhead + delta)
    }

    private func tick() {
        let now = HostClock.now
        let delta = now - lastTickHostTime
        lastTickHostTime = now
        playhead += delta
        if playhead >= duration {
            playhead = duration
            pause()
        }
    }

    private func installTimeObserver(on player: AVPlayer) {
        timeObserver = PlayerTimeObserver(player: player, interval: 1.0 / 30) { [weak self] time in
            guard let self, self.isPlaying else { return }
            self.playhead = min(time + self.videoOffset, self.duration)
            if self.playhead >= self.duration { self.pause() }
        }
    }

    // MARK: - Zoom

    var isZoomed: Bool {
        visibleRange.lowerBound > 0.001 || visibleRange.upperBound < duration - 0.001
    }

    func zoom(by factor: Double) {
        let span = visibleRange.upperBound - visibleRange.lowerBound
        // Below a quarter second there is nothing left to see even at 400 Hz.
        let newSpan = min(max(span * factor, 0.25), duration)
        let center = min(max(playhead, visibleRange.lowerBound), visibleRange.upperBound)

        var lower = center - newSpan / 2
        var upper = center + newSpan / 2
        if lower < 0 { upper -= lower; lower = 0 }
        if upper > duration { lower -= upper - duration; upper = duration }

        visibleRange = max(lower, 0)...min(upper, duration)
        rebuildCharts()
    }

    func resetZoom() {
        visibleRange = 0...duration
        rebuildCharts()
    }
}
