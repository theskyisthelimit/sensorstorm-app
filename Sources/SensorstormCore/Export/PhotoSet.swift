import Foundation
import simd

/// Turning a recording into posed still images for photogrammetry software.
///
/// **What this is not.** It does not build a 3D model, and neither does anything else that
/// starts from a video — reconstruction happens in RealityScan, Metashape, Meshroom or
/// COLMAP. What a recording can contribute is the part those programs otherwise have to
/// guess: sharp, well-spaced images with a known focal length, a known position, and on the
/// ARKit path a known viewing direction. That is what this writes.
///
/// The split follows the rule the rest of the package follows: everything here is pure —
/// which frames to look at, what goes in the EXIF, every byte of every text file — while
/// decoding and encoding pixels lives in the app behind ``PhotogrammetryImageProvider``.
/// That keeps the derivations, which is where the mistakes are, testable without a device.

// MARK: - Options

/// How far the camera should travel between two kept images.
///
/// The right spacing depends on how far away the subject is, and the recording does not
/// measure that. So this is a choice the user makes, and the three presets say what they
/// assume rather than pretending to know.
public enum SubjectDistance: String, Sendable, Hashable, CaseIterable, Codable {
    /// An object at arm's length. Small steps, or consecutive frames overlap almost entirely.
    case object
    /// A façade, a room, a piece of machinery.
    case facade
    /// Terrain, a street, anything walked or flown over.
    case terrain

    /// Minimum distance between two kept images, in metres.
    public var baselineMetres: Double {
        switch self {
        case .object: 0.10
        case .facade: 0.35
        case .terrain: 1.50
        }
    }

    /// Minimum change of viewing direction that also closes a window, in radians. A camera
    /// that pans without translating still sees something new.
    public var rotationRadians: Double {
        switch self {
        case .object: 3 * .pi / 180
        case .facade: 3 * .pi / 180
        case .terrain: 2 * .pi / 180
        }
    }
}

public struct PhotoSetOptions: Sendable, Hashable, Codable {
    /// How many images to aim for. Not a guarantee: the baseline rule can keep fewer when
    /// the camera stood still, and that is the point of the rule.
    public var targetCount: Int
    public var subject: SubjectDistance
    /// How many frames are scored per window before the sharpest one wins. Bounds the
    /// decoding work at `targetCount × candidatesPerWindow` rather than "every frame".
    public var candidatesPerWindow: Int
    /// Write `colmap/` alongside the images. Cheap, and the only output whose geometry can
    /// be checked by computation rather than by eye.
    public var writesColmapModel: Bool

    public init(targetCount: Int = 150,
                subject: SubjectDistance = .facade,
                candidatesPerWindow: Int = 5,
                writesColmapModel: Bool = true) {
        self.targetCount = max(1, targetCount)
        self.subject = subject
        self.candidatesPerWindow = max(1, candidatesPerWindow)
        self.writesColmapModel = writesColmapModel
    }
}

// MARK: - The seam between pure logic and pixels

/// One frame the app is asked to look at. A plain value — no `CVPixelBuffer`, no `CGImage`,
/// no path into the app — so the planning above it stays testable and `Sendable`.
public struct PhotoFrameRef: Sendable, Hashable {
    public var hostTime: Double
    public var videoFrameIndex: Int

    public init(hostTime: Double, videoFrameIndex: Int) {
        self.hostTime = hostTime
        self.videoFrameIndex = videoFrameIndex
    }
}

public struct WrittenImage: Sendable, Hashable {
    public var fileName: String
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(fileName: String, pixelWidth: Int, pixelHeight: Int) {
        self.fileName = fileName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// One image to be written: which frame, what to stamp into it, where it goes.
public struct PhotoWriteRequest: Sendable {
    public var ref: PhotoFrameRef
    public var exif: ExifAttributes
    public var url: URL

    public init(ref: PhotoFrameRef, exif: ExifAttributes, url: URL) {
        self.ref = ref
        self.exif = exif
        self.url = url
    }
}

public protocol PhotogrammetryImageProvider: Sendable {
    /// A sharpness score per ref, in the same order. Higher is sharper. `NaN` means the
    /// frame could not be decoded — which is treated as "not selectable", never as "worst",
    /// because a decode failure is not a blurry picture.
    func sharpness(of refs: [PhotoFrameRef]) async throws -> [Double]

    /// Writes every requested image.
    ///
    /// Deliberately a batch rather than one call per image: a video is read sequentially,
    /// and asking for one frame at a time would make the implementation seek — which on
    /// HEVC means decoding from the preceding keyframe every single time, turning a linear
    /// read into a quadratic one. The requests arrive in ascending time order.
    func write(_ requests: [PhotoWriteRequest]) async throws -> [WrittenImage]
}

// MARK: - EXIF

/// Everything the app has to stamp into an image, already derived.
///
/// Two of these fields are the ones worth getting right, and both have a classic way of
/// going wrong:
///
/// - ``focalLengthIn35mmFilm`` is `fx · 36 / max(width, height)` — a 36 mm frame fitted to
///   the longer image dimension, which is the same convention
///   ``CameraIntrinsics/blenderLens(sensorWidth:)`` already uses. Consumers invert it as
///   `fx = f35 · max(w,h) / 36`, so it round-trips. The physical sensor size is unknown and
///   is deliberately not guessed: `FocalLength` in millimetres is not written at all.
/// - ``altitude`` is **orthometric**, because that is what EXIF `GPSAltitude` is defined as.
///   Writing the ellipsoidal height instead is the ~50 m error the rest of this package
///   carries two height columns to avoid.
public struct ExifAttributes: Sendable, Hashable {
    public var make: String
    public var model: String
    public var software: String
    /// UTC, `yyyy:MM:dd HH:mm:ss`, with ``subSecondsOriginal`` carrying the fraction.
    public var dateTimeOriginal: String
    /// Milliseconds of ``dateTimeOriginal``. Carried here rather than written into the JPEG:
    /// Apple's ImageIO constant for the sub-second tag is spelled inconsistently across SDK
    /// versions, and the same instant is in `cameras.csv` to the millisecond anyway.
    public var subSecondsOriginal: String
    public var focalLengthIn35mmFilm: Int?
    public var latitude: Double?
    public var longitude: Double?
    /// Orthometric height in metres. Negative means below sea level, which the writer turns
    /// into `GPSAltitudeRef = 1` and a positive magnitude.
    public var altitude: Double?
    public var horizontalAccuracy: Double?
    /// Azimuth of the viewing direction in degrees clockwise from true north. Only ever set
    /// on the ARKit path — the classic path observes no viewing direction, and a guessed one
    /// would look like data and behave like noise.
    public var imageDirection: Double?
    public var imageUniqueID: String

    public init(make: String, model: String, software: String,
                dateTimeOriginal: String, subSecondsOriginal: String,
                focalLengthIn35mmFilm: Int?, latitude: Double?, longitude: Double?,
                altitude: Double?, horizontalAccuracy: Double?, imageDirection: Double?,
                imageUniqueID: String) {
        self.make = make
        self.model = model
        self.software = software
        self.dateTimeOriginal = dateTimeOriginal
        self.subSecondsOriginal = subSecondsOriginal
        self.focalLengthIn35mmFilm = focalLengthIn35mmFilm
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.imageDirection = imageDirection
        self.imageUniqueID = imageUniqueID
    }

    public static func focal35(_ intrinsics: CameraIntrinsics) -> Int? {
        guard intrinsics.isUsable else { return nil }
        let longer = Double(max(intrinsics.imageWidth, intrinsics.imageHeight))
        let value = intrinsics.fx * 36 / longer
        guard value.isFinite, value > 0 else { return nil }
        return Int(value.rounded())
    }
}

// MARK: - Camera angles

/// The viewing direction of a pose, in terms a photogrammetry tool can be told about.
///
/// Defined here once, and written out in words in the bundle's README, because every tool
/// names these differently and a claimed compatibility nobody can check is worth less than
/// a definition anybody can.
public struct CameraAngles: Sendable, Hashable {
    /// Degrees clockwise from true north, 0 = north, 90 = east.
    public var yaw: Double
    /// Degrees above the horizon; negative looks down.
    public var pitch: Double
    /// Degrees, positive when the camera's image-right axis tilts upwards.
    public var roll: Double

    /// `nil` when the pose has no observed orientation — the classic capture path.
    public static func of(_ pose: CameraPose) -> CameraAngles? {
        let q = pose.orientation
        guard q.vector.x.isFinite, q.vector.y.isFinite,
              q.vector.z.isFinite, q.vector.w.isFinite else { return nil }

        // Camera-local −Z is the viewing direction, +X is image right, +Y is image up.
        let forward = q.act(SIMD3<Double>(0, 0, -1))
        let right = q.act(SIMD3<Double>(1, 0, 0))

        let yaw = atan2(forward.x, forward.y) * 180 / .pi
        let horizontal = (forward.x * forward.x + forward.y * forward.y).squareRoot()
        let pitch = atan2(forward.z, horizontal) * 180 / .pi
        let roll = asin(max(-1, min(1, right.z))) * 180 / .pi
        return CameraAngles(yaw: yaw < 0 ? yaw + 360 : yaw, pitch: pitch, roll: roll)
    }
}
