import Foundation
import simd

/// A pinhole camera, in pixels of the image it belongs to.
public struct CameraIntrinsics: Sendable, Hashable {
    public var fx: Double
    public var fy: Double
    public var cx: Double
    public var cy: Double
    public var imageWidth: Int
    public var imageHeight: Int

    public init(fx: Double, fy: Double, cx: Double, cy: Double,
                imageWidth: Int, imageHeight: Int) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }

    public var isUsable: Bool {
        fx.isFinite && fy.isFinite && fx > 0 && fy > 0 && imageWidth > 0 && imageHeight > 0
    }

    /// Horizontal field of view in degrees — the sanity check that catches a wrong focal
    /// length faster than any reprojection does. A phone's wide camera lands near 60–70°.
    public var horizontalFieldOfView: Double {
        guard isUsable else { return .nan }
        return 2 * atan(Double(imageWidth) / (2 * fx)) * 180 / .pi
    }

    /// Blender's `Camera.lens`, given its `sensor_width` (36 mm by default). Blender fits the
    /// sensor to the *larger* image dimension, which is why this divides by the width only
    /// after `sensorFitWidth` has been confirmed by the caller.
    public func blenderLens(sensorWidth: Double = 36) -> Double {
        fx * sensorWidth / Double(imageWidth)
    }

    /// Blender's `shift_x`/`shift_y`, which are normalised by the larger image dimension.
    public var blenderShift: (x: Double, y: Double) {
        let larger = Double(max(imageWidth, imageHeight))
        return ((cx - Double(imageWidth) / 2) / larger,
                (Double(imageHeight) / 2 - cy) / larger)
    }

    /// The same camera, seen after the image has been rotated counter-clockwise by
    /// `degrees` — the convention `AVCaptureConnection.videoRotationAngle` uses.
    ///
    /// Only needed on the classic capture path, where the connection rotates the delivered
    /// buffers but the intrinsics keep describing the sensor. The ARKit path stores its video
    /// unrotated precisely so this never has to run.
    public func rotatedCounterClockwise(by degrees: Double) -> CameraIntrinsics {
        let steps = ((Int(degrees.rounded()) / 90) % 4 + 4) % 4
        var result = self
        for _ in 0..<steps { result = result.rotatedOneQuarterCounterClockwise() }
        return result
    }

    private func rotatedOneQuarterCounterClockwise() -> CameraIntrinsics {
        // (x, y) → (y, W − x): the axes swap, and the new vertical axis runs back along the
        // old horizontal one.
        CameraIntrinsics(fx: fy, fy: fx,
                         cx: cy, cy: Double(imageWidth) - cx,
                         imageWidth: imageHeight, imageHeight: imageWidth)
    }
}

/// One camera at one instant, already in the frame the exporter writes: metres east/north/up
/// from the recording's anchor, and an orientation that takes camera-local vectors into that
/// same frame.
///
/// The camera-local convention is the one ARKit and Blender happen to share: **−Z** is the
/// viewing direction, **+Y** is up in the image, **+X** is right.
public struct CameraPose: Sendable, Hashable {
    public var hostTime: Double
    public var position: ENU
    public var orientation: simd_quatd
    public var intrinsics: CameraIntrinsics
    public var trackingState: CameraTrackingState
    public var trackingReason: CameraTrackingReason

    public init(hostTime: Double, position: ENU, orientation: simd_quatd,
                intrinsics: CameraIntrinsics,
                trackingState: CameraTrackingState = .normal,
                trackingReason: CameraTrackingReason = .none) {
        self.hostTime = hostTime
        self.position = position
        self.orientation = orientation
        self.intrinsics = intrinsics
        self.trackingState = trackingState
        self.trackingReason = trackingReason
    }

    /// Blender wants XYZ Euler angles in radians.
    public var eulerXYZ: SIMD3<Double> {
        let m = simd_double3x3(orientation)
        // Standard R = Rz(γ)·Ry(β)·Rx(α) decomposition, which is Blender's "XYZ" order.
        let sy = -m[0][2]
        if abs(sy) < 0.999_999 {
            return SIMD3(atan2(m[1][2], m[2][2]), asin(sy), atan2(m[0][1], m[0][0]))
        }
        // Gimbal lock: roll and yaw are degenerate, fold everything into roll.
        return SIMD3(atan2(-m[2][1], m[1][1]), sy > 0 ? .pi / 2 : -.pi / 2, 0)
    }

    public var isReliable: Bool {
        trackingState == .normal && position.simd.x.isFinite && intrinsics.isUsable
    }
}

/// Turning an ARKit world pose into the frame everything downstream speaks.
public enum ARWorldFrame {

    /// `ARWorldTrackingConfiguration` with `.gravityAndHeading` puts **+X east, +Y up,
    /// +Z south**. The export frame is east/north/up. Mapping one to the other is a single
    /// +90° rotation about the east axis: `(x, y, z) → (x, −z, y)`.
    public static let toENU = simd_quatd(angle: .pi / 2, axis: SIMD3(1, 0, 0))

    public static func position(fromARKit p: SIMD3<Double>) -> ENU {
        ENU(east: p.x, north: -p.z, up: p.y)
    }

    /// The camera-local axes are identical in both frames, so only the world side rotates.
    public static func orientation(fromARKit q: simd_quatd) -> simd_quatd {
        (toENU * q).normalized
    }
}

/// Result of fitting one horizontal track onto another.
public struct GroundAlignment: Sendable, Hashable {
    /// Rotation about the up axis that takes the source track onto the target, in radians.
    public var yaw: Double
    /// Applied *after* the rotation, in metres.
    public var translation: SIMD2<Double>
    /// Root-mean-square distance left over, in metres. This is the honest quality number for
    /// a whole recording: a few metres is GPS noise, tens of metres means something is wrong.
    public var rmsResidual: Double
    /// Root-mean-square distance of the source points from their own centroid — how much
    /// track there was to take a heading from.
    public var rmsSpread: Double
    public var sampleCount: Int

    public var yawDegrees: Double { yaw * 180 / .pi }

    /// Rough one-sigma uncertainty of ``yaw``, in degrees.
    ///
    /// A lever arm argument: noise of `rmsResidual` at a radius of `rmsSpread` can swing the
    /// fitted angle by about `atan(residual / spread)`. Ten metres of walking with three
    /// metres of GPS noise pins the heading to roughly 17° — worth knowing before trusting a
    /// scene's rotation, and the reason a short recording is a poor one to georeference.
    public var yawUncertaintyDegrees: Double {
        guard rmsSpread > 0 else { return .infinity }
        return atan2(rmsResidual, rmsSpread) * 180 / .pi
    }

    public static let identity = GroundAlignment(yaw: 0, translation: .zero,
                                                 rmsResidual: 0, rmsSpread: 0, sampleCount: 0)

    public func apply(to point: ENU) -> ENU {
        let c = cos(yaw), s = sin(yaw)
        return ENU(east: c * point.east - s * point.north + translation.x,
                   north: s * point.east + c * point.north + translation.y,
                   up: point.up)
    }

    public func apply(to orientation: simd_quatd) -> simd_quatd {
        (simd_quatd(angle: yaw, axis: SIMD3(0, 0, 1)) * orientation).normalized
    }
}

public enum TrajectoryAlignment {

    /// Least-squares yaw and translation taking `source` onto `target`, scale fixed at 1.
    ///
    /// This is the closed-form Umeyama solution restricted to the horizontal plane. Scale is
    /// *not* solved for on purpose: ARKit's visual-inertial odometry is already metric, and
    /// letting a noisy GPS track rescale it would trade a known-good number for a guess.
    ///
    /// Used to fix the one thing `.gravityAndHeading` gets wrong — the initial heading comes
    /// from the magnetometer and can be several degrees out, though it does not drift after.
    public static func horizontal(source: [ENU], target: [ENU]) -> GroundAlignment {
        let n = min(source.count, target.count)
        guard n >= 2 else { return .identity }

        var sourceMean = SIMD2<Double>.zero
        var targetMean = SIMD2<Double>.zero
        for i in 0..<n {
            sourceMean += SIMD2(source[i].east, source[i].north)
            targetMean += SIMD2(target[i].east, target[i].north)
        }
        sourceMean /= Double(n)
        targetMean /= Double(n)

        var cross = 0.0   // Σ (aₓ·b_y − a_y·bₓ)
        var dot = 0.0     // Σ (aₓ·bₓ + a_y·b_y)
        var spread = 0.0
        for i in 0..<n {
            let a = SIMD2(source[i].east, source[i].north) - sourceMean
            let b = SIMD2(target[i].east, target[i].north) - targetMean
            cross += a.x * b.y - a.y * b.x
            dot += a.x * b.x + a.y * b.y
            spread += a.x * a.x + a.y * a.y
        }

        // A track that never moved has no direction to align; any yaw fits equally badly.
        guard spread > 1e-9 else { return .identity }

        let yaw = atan2(cross, dot)
        let c = cos(yaw), s = sin(yaw)
        let rotatedMean = SIMD2(c * sourceMean.x - s * sourceMean.y,
                                s * sourceMean.x + c * sourceMean.y)
        let translation = targetMean - rotatedMean

        var squared = 0.0
        for i in 0..<n {
            let a = SIMD2(source[i].east, source[i].north)
            let rotated = SIMD2(c * a.x - s * a.y, s * a.x + c * a.y) + translation
            let b = SIMD2(target[i].east, target[i].north)
            squared += simd_length_squared(rotated - b)
        }

        return GroundAlignment(yaw: yaw,
                               translation: translation,
                               rmsResidual: (squared / Double(n)).squareRoot(),
                               rmsSpread: (spread / Double(n)).squareRoot(),
                               sampleCount: n)
    }
}
