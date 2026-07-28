import Foundation

/// Sidecar written next to the binary streams. Everything needed to interpret a recording
/// without opening a single sample file.
public struct RecordingMetadata: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// Wall-clock start, for display and for mapping back into absolute time.
    public var startedAt: Date
    /// Host-clock reading at the exact moment recording started. All sample timestamps are
    /// on this clock; subtract this to get seconds-since-start.
    public var startHostTime: Double
    public var duration: TimeInterval
    public var device: DeviceInfo
    public var streams: [StreamInfo]
    public var video: VideoInfo?
    /// Set for microphone-only recordings; when a video is present its audio lives in the
    /// movie file instead.
    public var audio: AudioInfo?
    /// Requested motion sample rate. Actual per-stream rates live in ``StreamInfo``.
    public var requestedRateHz: Double
    public var notes: String

    public init(
        id: UUID = UUID(),
        name: String,
        startedAt: Date,
        startHostTime: Double,
        duration: TimeInterval = 0,
        device: DeviceInfo,
        streams: [StreamInfo] = [],
        video: VideoInfo? = nil,
        audio: AudioInfo? = nil,
        requestedRateHz: Double,
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.startedAt = startedAt
        self.startHostTime = startHostTime
        self.duration = duration
        self.device = device
        self.streams = streams
        self.video = video
        self.audio = audio
        self.requestedRateHz = requestedRateHz
        self.notes = notes
    }

    public func stream(_ sensor: SensorID) -> StreamInfo? {
        streams.first { $0.sensor == sensor }
    }

    public var totalSampleCount: Int {
        streams.reduce(0) { $0 + $1.sampleCount }
    }
}

public struct DeviceInfo: Codable, Sendable, Hashable {
    public var model: String
    public var systemName: String
    public var systemVersion: String
    public var appVersion: String

    public init(model: String, systemName: String, systemVersion: String, appVersion: String) {
        self.model = model
        self.systemName = systemName
        self.systemVersion = systemVersion
        self.appVersion = appVersion
    }
}

public struct StreamInfo: Codable, Sendable, Hashable, Identifiable {
    public var sensor: SensorID
    public var channels: [String]
    public var unit: String
    public var sampleCount: Int
    /// Samples per second actually achieved, measured over the recording.
    public var effectiveRateHz: Double

    public var id: SensorID { sensor }
    public var fileName: String { "\(sensor.rawValue).ssbin" }

    public init(sensor: SensorID, channels: [String], unit: String,
                sampleCount: Int, effectiveRateHz: Double) {
        self.sensor = sensor
        self.channels = channels
        self.unit = unit
        self.sampleCount = sampleCount
        self.effectiveRateHz = effectiveRateHz
    }
}

public struct VideoInfo: Codable, Sendable, Hashable {
    public var fileName: String
    /// Host-clock timestamp of the first written video frame. Together with
    /// ``RecordingMetadata/startHostTime`` this gives exact frame ↔ sample alignment.
    public var startHostTime: Double
    public var duration: TimeInterval
    public var width: Int
    public var height: Int
    public var nominalFrameRate: Double
    public var hasAudio: Bool
    public var isFrontCamera: Bool

    public init(fileName: String, startHostTime: Double, duration: TimeInterval,
                width: Int, height: Int, nominalFrameRate: Double,
                hasAudio: Bool, isFrontCamera: Bool) {
        self.fileName = fileName
        self.startHostTime = startHostTime
        self.duration = duration
        self.width = width
        self.height = height
        self.nominalFrameRate = nominalFrameRate
        self.hasAudio = hasAudio
        self.isFrontCamera = isFrontCamera
    }

    /// Offset of the video timeline relative to the recording timeline, in seconds.
    /// `playerTime = recordingTime - videoOffset`.
    public func offset(from recordingStart: Double) -> TimeInterval {
        startHostTime - recordingStart
    }
}

public struct AudioInfo: Codable, Sendable, Hashable {
    public var fileName: String
    /// Host-clock timestamp of the first captured audio frame.
    public var startHostTime: Double
    public var duration: TimeInterval
    public var sampleRate: Double
    public var channelCount: Int

    public init(fileName: String, startHostTime: Double, duration: TimeInterval,
                sampleRate: Double, channelCount: Int) {
        self.fileName = fileName
        self.startHostTime = startHostTime
        self.duration = duration
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    public func offset(from recordingStart: Double) -> TimeInterval {
        startHostTime - recordingStart
    }
}

/// A timestamped text marker the user drops during or after a recording.
public struct Annotation: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var hostTime: Double
    public var text: String

    public init(id: UUID = UUID(), hostTime: Double, text: String) {
        self.id = id
        self.hostTime = hostTime
        self.text = text
    }
}
