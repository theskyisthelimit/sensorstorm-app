import Foundation
import simd

/// `cameras.csv` — the trajectory table, and the path that is guaranteed to work.
///
/// Every photogrammetry program can be told to read a table of image names and positions;
/// they only disagree about the column order, and all of them let the user map the columns
/// at import. That makes this file the fallback that never depends on guessing somebody's
/// sidecar schema.
public enum PhotoSetCSV {
    public static let fileName = "cameras.csv"

    public static let header = [
        "name",
        "x_enu", "y_enu", "z_enu",
        "lat", "lon", "alt_msl", "alt_ellipsoidal",
        "e_lv95", "n_lv95", "h_lv95",
        "yaw", "pitch", "roll",
        "qx", "qy", "qz", "qw",
        "fx", "fy", "cx", "cy", "image_width", "image_height", "focal_35mm",
        "frame_index", "host_time", "seconds_elapsed", "utc",
        "sharpness", "baseline_m", "tracking_state"
    ].joined(separator: ",")

    static func text(_ frames: [PhotoSetExporter.SelectedFrame],
                     scene: SceneBundleExporter.Scene,
                     metadata: RecordingMetadata) -> String {
        var out = header + "\n"
        out.reserveCapacity(frames.count * 200)

        for frame in frames {
            let pose = frame.pose
            let elapsed = pose.hostTime - metadata.startHostTime
            let date = metadata.startedAt.addingTimeInterval(elapsed)
            var row = RecordingExporter.csvEscape(frame.name)

            row += ",\(num(pose.position.east)),\(num(pose.position.north)),\(num(pose.position.up))"

            if let anchor = scene.anchor, pose.position.east.isFinite {
                let geodetic = Geodesy.geodetic(fromENU: pose.position, anchor: anchor)
                let swiss = Geodesy.lv95(from: geodetic)
                let separation = anchor.height - (scene.anchorSource?.altitude ?? anchor.height)
                row += ",\(num(geodetic.latitude)),\(num(geodetic.longitude))"
                row += ",\(num(geodetic.height - separation)),\(num(geodetic.height))"
                row += ",\(num(swiss.east)),\(num(swiss.north)),\(num(swiss.height))"
            } else {
                row += ",,,,,,,"
            }

            if let angles = CameraAngles.of(pose) {
                row += ",\(num(angles.yaw)),\(num(angles.pitch)),\(num(angles.roll))"
            } else {
                row += ",,,"
            }

            let q = pose.orientation.vector
            row += ",\(num(q.x)),\(num(q.y)),\(num(q.z)),\(num(q.w))"

            let k = pose.intrinsics
            row += ",\(num(k.fx)),\(num(k.fy)),\(num(k.cx)),\(num(k.cy))"
            row += ",\(k.imageWidth),\(k.imageHeight)"
            row += ",\(ExifAttributes.focal35(k).map(String.init) ?? "")"

            row += ",\(pose.videoFrameIndex),\(num(pose.hostTime)),\(num(elapsed))"
            row += ",\(TrackExporter.iso8601(date))"
            row += ",\(num(frame.sharpness)),\(num(frame.baseline))"
            row += ",\(Int(pose.trackingState.rawValue))"

            out += row
            out += "\n"
        }
        return out
    }

    /// Non-finite becomes an empty field, never `nan` and never 0 — the same convention the
    /// scene bundle uses, and the one the Blender importer already reads as "no value".
    private static func num(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        return String(format: "%.12g", value)
    }
}

/// A COLMAP model with the poses already known.
///
/// Worth writing not because COLMAP is the likeliest destination, but because it is the only
/// output here whose geometry can be *checked by computation*: project a known world point
/// through what this writes and it must land on a known pixel. That one test catches a
/// transposed rotation, a wrong axis flip and `T = C` instead of `T = −R·C` at once.
public enum ColmapModel {

    /// COLMAP looks down camera-local **+Z** with **+Y down**; this app looks down **−Z**
    /// with **+Y up**. The difference is a 180° turn about X — `diag(1, −1, −1)`, which is a
    /// proper rotation, so it composes as a quaternion without a reflection sneaking in.
    static let axisFlip = simd_quatd(ix: 1, iy: 0, iz: 0, r: 0)

    /// COLMAP stores world→camera; ours is camera→world. Hence the conjugate.
    public static func worldToCamera(_ pose: CameraPose) -> (rotation: simd_quatd, translation: SIMD3<Double>) {
        let rotation = axisFlip * pose.orientation.conjugate
        let centre = SIMD3<Double>(pose.position.east, pose.position.north, pose.position.up)
        return (rotation, -rotation.act(centre))
    }

    /// One camera per image. Honest rather than tidy: `fx` really does change with
    /// autofocus, which is why the intrinsics are recorded per frame in the first place.
    static func camerasText(_ frames: [PhotoSetExporter.SelectedFrame]) -> String {
        var out = """
        # Camera list with one line of data per camera:
        #   CAMERA_ID, MODEL, WIDTH, HEIGHT, PARAMS[]
        # One camera per image: the intrinsics were measured per frame, and autofocus moves
        # the focal length during a recording.

        """
        for frame in frames {
            let k = frame.pose.intrinsics
            out += "\(frame.ordinal) PINHOLE \(k.imageWidth) \(k.imageHeight) "
            out += "\(num(k.fx)) \(num(k.fy)) \(num(k.cx)) \(num(k.cy))\n"
        }
        return out
    }

    static func imagesText(_ frames: [PhotoSetExporter.SelectedFrame]) -> String {
        var out = """
        # Image list with two lines of data per image:
        #   IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME
        #   POINTS2D[] as (X, Y, POINT3D_ID)
        # The second line is empty: the poses are known, the correspondences are not.

        """
        for frame in frames {
            let (rotation, translation) = worldToCamera(frame.pose)
            let q = rotation.vector
            out += "\(frame.ordinal) \(num(q.w)) \(num(q.x)) \(num(q.y)) \(num(q.z)) "
            out += "\(num(translation.x)) \(num(translation.y)) \(num(translation.z)) "
            out += "\(frame.ordinal) \(frame.name)\n\n"
        }
        return out
    }

    /// Empty, but present: COLMAP will not read a model directory without it.
    static let points3DText = """
    # 3D point list with one line of data per point:
    #   POINT3D_ID, X, Y, Z, R, G, B, ERROR, TRACK[] as (IMAGE_ID, POINT2D_IDX)
    # Empty on purpose — the points are what the reconstruction is for.

    """

    private static func num(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return String(format: "%.12g", value)
    }
}
