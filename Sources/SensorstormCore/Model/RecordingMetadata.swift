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

    /// Which capture path produced this recording. `nil` for recordings written before the
    /// field existed — those are all ``CaptureEngine/classic``.
    public var captureEngine: CaptureEngine?
    /// Reference frame the ``SensorID/orientation`` quaternion is expressed in. `nil` means
    /// the recording predates the field and the frame is genuinely unknown — which is the
    /// difference between a yaw you can georeference and one you cannot.
    public var attitudeReferenceFrame: AttitudeReferenceFrame?
    /// First usable GPS fix, kept verbatim so a local metric frame can be rebuilt without
    /// re-reading the location stream. `nil` when the recording never got a fix.
    public var geodeticAnchor: GeodeticAnchor?

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
        notes: String = "",
        captureEngine: CaptureEngine? = nil,
        attitudeReferenceFrame: AttitudeReferenceFrame? = nil,
        geodeticAnchor: GeodeticAnchor? = nil
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
        self.captureEngine = captureEngine
        self.attitudeReferenceFrame = attitudeReferenceFrame
        self.geodeticAnchor = geodeticAnchor
    }

    public func stream(_ sensor: SensorID) -> StreamInfo? {
        streams.first { $0.sensor == sensor }
    }

    public var totalSampleCount: Int {
        streams.reduce(0) { $0 + $1.sampleCount }
    }
}

/// Which camera stack recorded the video, because it decides what else is in the folder.
public enum CaptureEngine: String, Codable, Sendable, Hashable, CaseIterable {
    /// `AVCaptureSession` + `AVAssetWriter`. Exact frame timing, no camera pose.
    case classic
    /// `ARWorldTrackingConfiguration`. Full 6-DoF pose and per-frame intrinsics.
    case arkit
}

/// The frame ``SensorID/orientation`` is referenced to — `CMAttitudeReferenceFrame` by
/// another name, recorded because it cannot be recovered from the samples themselves.
public enum AttitudeReferenceFrame: String, Codable, Sendable, Hashable, CaseIterable {
    /// `.xTrueNorthZVertical` — yaw is bearing from true north. Needs location authorisation.
    case trueNorth
    /// `.xArbitraryCorrectedZVertical` — yaw is relative to wherever the device was pointing
    /// at start. Comparable within a recording, meaningless between two.
    case arbitraryCorrected
}

/// The geodetic origin a recording's local metric frame hangs off.
public struct GeodeticAnchor: Codable, Sendable, Hashable {
    public var latitude: Double
    public var longitude: Double
    /// Orthometric height (`CLLocation.altitude`, roughly mean sea level).
    public var altitude: Double
    /// Height above the WGS84 ellipsoid. In Switzerland this sits ~46–52 m above the
    /// orthometric value; confusing the two is the classic way to float a scene.
    public var ellipsoidalAltitude: Double
    public var horizontalAccuracy: Double
    public var verticalAccuracy: Double
    /// Host time of the fix, so it can be lined up with the rest of the streams.
    public var hostTime: Double

    public init(latitude: Double, longitude: Double, altitude: Double,
                ellipsoidalAltitude: Double, horizontalAccuracy: Double,
                verticalAccuracy: Double, hostTime: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.ellipsoidalAltitude = ellipsoidalAltitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.hostTime = hostTime
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

    /// Rotation in degrees that the capture connection applied to the stored pixels. `0`
    /// means the file holds the sensor's native orientation, which is the only case where
    /// camera intrinsics apply to it unchanged. `nil` for recordings written before this was
    /// tracked — a rotation was applied then too, we just no longer know which.
    public var appliedRotationAngle: Double?
    /// Whether the stored pixels are mirrored. Mirroring flips the image's handedness
    /// relative to the device axes and has to be undone before any reprojection.
    public var isMirrored: Bool?

    public init(fileName: String, startHostTime: Double, duration: TimeInterval,
                width: Int, height: Int, nominalFrameRate: Double,
                hasAudio: Bool, isFrontCamera: Bool,
                appliedRotationAngle: Double? = nil, isMirrored: Bool? = nil) {
        self.fileName = fileName
        self.startHostTime = startHostTime
        self.duration = duration
        self.width = width
        self.height = height
        self.nominalFrameRate = nominalFrameRate
        self.hasAudio = hasAudio
        self.isFrontCamera = isFrontCamera
        self.appliedRotationAngle = appliedRotationAngle
        self.isMirrored = isMirrored
    }

    /// `true` when the stored pixels sit in the camera's native orientation and are not
    /// mirrored — the precondition for applying intrinsics directly.
    public var isSensorNative: Bool {
        appliedRotationAngle == 0 && isMirrored == false
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
