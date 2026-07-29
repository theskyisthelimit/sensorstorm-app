import Foundation
import simd

/// `scene.json` — everything a 3D application needs to place the video in a world, without
/// having to know anything about how the recording was made.
public struct SceneManifest: Codable, Sendable, Hashable {
    public static let format = "sensorstorm-scene"
    public static let formatVersion = 1

    public var format: String = SceneManifest.format
    public var formatVersion: Int = SceneManifest.formatVersion

    public var recording: Recording
    public var coordinateSystem: CoordinateSystem
    public var anchor: Anchor?
    public var video: Video?
    public var camera: Camera
    public var frames: Frames
    public var alignment: Alignment?

    public struct Recording: Codable, Sendable, Hashable {
        public var id: String
        public var name: String
        public var startedAt: Date
        public var durationSeconds: Double
        public var deviceModel: String
        public var systemVersion: String
        public var appVersion: String
        public var captureEngine: String
        public var attitudeReferenceFrame: String?
    }

    /// Where the numbers live. Spelled out rather than implied, because every reprojection
    /// bug in this domain is somebody assuming a different one of these lines.
    public struct CoordinateSystem: Codable, Sendable, Hashable {
        public var world = "ENU metres from anchor: +X east, +Y north, +Z up"
        public var camera = "camera-local: -Z view direction, +Y image up, +X image right"
        public var quaternionOrder = "xyzw"
        public var quaternionMeaning = "rotates camera-local vectors into the world frame"
        public var heightReference = "z_enu is ellipsoidal; alt_msl column is orthometric"
        public var angleUnit = "radians"
    }

    public struct Anchor: Codable, Sendable, Hashable {
        public var latitude: Double
        public var longitude: Double
        public var altitudeOrthometric: Double
        public var altitudeEllipsoidal: Double
        public var horizontalAccuracy: Double
        public var verticalAccuracy: Double
        /// Same point in EPSG:2056, for dropping the scene straight onto swisstopo data.
        public var lv95East: Double
        public var lv95North: Double
        public var lv95Height: Double
        public var lv95IsInRange: Bool
    }

    public struct Video: Codable, Sendable, Hashable {
        public var fileName: String
        public var width: Int
        public var height: Int
        public var nominalFrameRate: Double
        /// `sensorTime = videoPlayerTime + startOffsetSeconds`.
        public var startOffsetSeconds: Double
        public var appliedRotationAngle: Double?
        public var isMirrored: Bool?
        /// `false` means the intrinsics below describe the sensor, not the stored pixels,
        /// and have to be rotated by `appliedRotationAngle` before use.
        public var intrinsicsMatchStoredPixels: Bool
    }

    public struct Camera: Codable, Sendable, Hashable {
        public var model = "pinhole"
        public var intrinsicsArePerFrame: Bool
        public var medianHorizontalFovDegrees: Double?
        public var distortion = "none recorded; iPhone wide-angle video is close enough to rectilinear for a background plate"
    }

    public struct Frames: Codable, Sendable, Hashable {
        public var file = "frames.csv"
        public var count: Int
        /// Frames with a trusted pose and usable intrinsics.
        public var reliableCount: Int
        public var poseSource: String
        public var timingSource: String
    }

    public struct Alignment: Codable, Sendable, Hashable {
        public var method = "umeyama-yaw"
        public var yawDegrees: Double
        public var rmsResidualMetres: Double
        /// How far the track reached from its own centre. A heading can only be read off a
        /// track that went somewhere.
        public var trackSpreadMetres: Double
        /// One-sigma uncertainty of `yawDegrees`. Above about 10° the scene's rotation is a
        /// suggestion rather than a measurement.
        public var yawUncertaintyDegrees: Double
        public var sampleCount: Int
    }
}

/// How the camera positions in `frames.csv` were arrived at.
public enum PoseSource: String, Sendable, Hashable {
    /// ARKit visual-inertial odometry, yaw-corrected against the GPS track. Metric and
    /// locally centimetre-accurate.
    case arkitVIO
    /// Position interpolated from GPS fixes; orientation columns are empty. Metres of
    /// uncertainty, and no viewing direction at all.
    case gpsPositionOnly
    /// No position could be derived — timing and intrinsics only.
    case none
}

/// How the frame timestamps were arrived at.
public enum FrameTimingSource: String, Sendable, Hashable {
    /// One recorded timestamp per stored frame. Exact.
    case perFrame
    /// Reconstructed from the first frame plus the nominal rate, because the recording
    /// predates per-frame timestamps. Drifts wherever a frame was dropped.
    case nominalRate
}
