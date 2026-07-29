import Foundation
import Testing
import simd
@testable import SensorstormCore

@Suite("Geodesy")
struct GeodesyTests {

    /// Bern, Zurich, Zermatt, and a point outside Switzerland to make sure nothing in the
    /// ellipsoid maths is tuned to one latitude.
    static let samples: [Geodetic] = [
        Geodetic(latitude: 46.9480, longitude: 7.4474, height: 590),      // Bern
        Geodetic(latitude: 47.3769, longitude: 8.5417, height: 450),      // Zürich
        Geodetic(latitude: 46.0207, longitude: 7.7491, height: 1_620),    // Zermatt
        Geodetic(latitude: 0, longitude: 0, height: 0),                   // null island
        Geodetic(latitude: -33.8688, longitude: 151.2093, height: 25)     // Sydney
    ]

    @Test("Geodetic survives a trip through ECEF")
    func ecefRoundTrip() {
        for point in Self.samples {
            let back = Geodesy.geodetic(fromECEF: Geodesy.ecef(from: point))
            #expect(abs(back.latitude - point.latitude) < 1e-9)
            #expect(abs(back.longitude - point.longitude) < 1e-9)
            #expect(abs(back.height - point.height) < 1e-6)
        }
    }

    @Test("The anchor is the origin of its own ENU frame")
    func anchorIsOrigin() {
        for anchor in Self.samples {
            let local = Geodesy.enu(of: anchor, from: anchor)
            #expect(abs(local.east) < 1e-9)
            #expect(abs(local.north) < 1e-9)
            #expect(abs(local.up) < 1e-9)
        }
    }

    @Test("ENU axes point east, north and up")
    func enuAxisDirections() {
        let anchor = Geodetic(latitude: 46.9480, longitude: 7.4474, height: 590)

        let east = Geodesy.enu(
            of: Geodetic(latitude: anchor.latitude, longitude: anchor.longitude + 0.001,
                         height: anchor.height), from: anchor)
        #expect(east.east > 0)
        #expect(abs(east.north) < 0.01)

        let north = Geodesy.enu(
            of: Geodetic(latitude: anchor.latitude + 0.001, longitude: anchor.longitude,
                         height: anchor.height), from: anchor)
        #expect(north.north > 0)
        #expect(abs(north.east) < 0.01)

        let up = Geodesy.enu(
            of: Geodetic(latitude: anchor.latitude, longitude: anchor.longitude,
                         height: anchor.height + 100), from: anchor)
        #expect(abs(up.up - 100) < 1e-6)
        #expect(abs(up.east) < 0.01)
        #expect(abs(up.north) < 0.01)
    }

    @Test("A degree of latitude is about 111 km")
    func enuScaleIsMetric() {
        let anchor = Geodetic(latitude: 46.9480, longitude: 7.4474, height: 0)
        let local = Geodesy.enu(
            of: Geodetic(latitude: anchor.latitude + 1, longitude: anchor.longitude, height: 0),
            from: anchor)
        // Chord, not arc, so slightly under the 111.2 km meridian arc at this latitude.
        #expect(local.north > 110_000 && local.north < 112_000)
    }

    @Test("ENU survives a round-trip back to geodetic")
    func enuRoundTrip() {
        let anchor = Geodetic(latitude: 46.9480, longitude: 7.4474, height: 590)
        for point in Self.samples.prefix(3) {
            let back = Geodesy.geodetic(fromENU: Geodesy.enu(of: point, from: anchor),
                                        anchor: anchor)
            #expect(abs(back.latitude - point.latitude) < 1e-9)
            #expect(abs(back.longitude - point.longitude) < 1e-9)
            #expect(abs(back.height - point.height) < 1e-6)
        }
    }

    // MARK: - LV95

    /// The polynomials are written around the old Bern observatory, so feeding that exact
    /// point in has to leave every term but the constant at zero. It pins all the constants
    /// at once — a single mistyped digit anywhere shows up here.
    @Test("The Bern observatory lands on the LV95 constants exactly")
    func lv95Origin() {
        let observatory = Geodetic(latitude: 169_028.66 / 3600,
                                   longitude: 26_782.5 / 3600,
                                   height: 0)
        let swiss = Geodesy.lv95(from: observatory)
        #expect(abs(swiss.east - 2_600_072.37) < 1e-6)
        #expect(abs(swiss.north - 1_200_147.07) < 1e-6)
        #expect(abs(swiss.height - (-49.55)) < 1e-6)
    }

    @Test("Swiss cities land in their LV95 map sheets")
    func lv95Plausible() {
        let bern = Geodesy.lv95(from: Geodetic(latitude: 46.9480, longitude: 7.4474, height: 590))
        #expect(abs(bern.east - 2_600_600) < 1_500)
        #expect(abs(bern.north - 1_199_700) < 1_500)
        // Ellipsoidal 590 m minus a ~50 m geoid undulation.
        #expect(bern.height > 530 && bern.height < 550)

        let zurich = Geodesy.lv95(from: Geodetic(latitude: 47.3769, longitude: 8.5417, height: 450))
        #expect(zurich.east > 2_670_000 && zurich.east < 2_690_000)
        #expect(zurich.north > 1_240_000 && zurich.north < 1_260_000)

        // East of Bern must be east in LV95 too.
        #expect(zurich.east > bern.east)
        #expect(zurich.north > bern.north)
    }

    @Test("LV95 round-trips within the formula's stated one metre")
    func lv95RoundTrip() {
        for point in Self.samples.prefix(3) {
            let back = Geodesy.geodetic(fromLV95: Geodesy.lv95(from: point))
            let drift = Geodesy.enu(of: back, from: point)
            #expect(abs(drift.east) < 1.0, "east drifted \(drift.east) m")
            #expect(abs(drift.north) < 1.0, "north drifted \(drift.north) m")
            #expect(abs(back.height - point.height) < 2.0)
        }
    }
}

@Suite("Camera pose")
struct CameraPoseTests {

    @Test("The ARKit world frame maps onto east/north/up")
    func arkitAxes() {
        // ARKit .gravityAndHeading: +X east, +Y up, +Z south.
        let east = ARWorldFrame.position(fromARKit: SIMD3(1, 0, 0))
        #expect(east.east == 1 && east.north == 0 && east.up == 0)

        let up = ARWorldFrame.position(fromARKit: SIMD3(0, 1, 0))
        #expect(up.east == 0 && up.north == 0 && up.up == 1)

        let south = ARWorldFrame.position(fromARKit: SIMD3(0, 0, 1))
        #expect(south.east == 0 && south.north == -1 && south.up == 0)
    }

    @Test("The rotation matches the position swizzle")
    func arkitRotationAgreesWithPosition() {
        // Whatever the quaternion does to a world vector has to be what the position
        // swizzle does, or poses and points end up in two different worlds.
        for v in [SIMD3<Double>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(2, -3, 5)] {
            let byQuaternion = ARWorldFrame.toENU.act(v)
            let bySwizzle = ARWorldFrame.position(fromARKit: v).simd
            #expect(simd_distance(byQuaternion, bySwizzle) < 1e-12)
        }
    }

    @Test("A camera looking north in ARKit still looks north in the export frame")
    func viewingDirection() {
        // ARKit camera looks down its local −Z. North in ARKit is −Z of the world, so the
        // identity rotation is already a camera pointing north.
        let pose = CameraPose(
            hostTime: 0,
            position: ENU(east: 0, north: 0, up: 0),
            orientation: ARWorldFrame.orientation(fromARKit: simd_quatd(angle: 0, axis: SIMD3(0, 0, 1))),
            intrinsics: CameraIntrinsics(fx: 1000, fy: 1000, cx: 960, cy: 540,
                                         imageWidth: 1920, imageHeight: 1080))

        let forward = pose.orientation.act(SIMD3(0, 0, -1))
        #expect(abs(forward.y - 1) < 1e-9, "should point north, got \(forward)")

        let imageUp = pose.orientation.act(SIMD3(0, 1, 0))
        #expect(abs(imageUp.z - 1) < 1e-9, "image up should be world up, got \(imageUp)")
    }

    @Test("Intrinsics convert to a plausible field of view")
    func fieldOfView() {
        // iPhone wide camera, 1920 px across, roughly 1500 px focal length.
        let intrinsics = CameraIntrinsics(fx: 1500, fy: 1500, cx: 960, cy: 540,
                                          imageWidth: 1920, imageHeight: 1080)
        #expect(intrinsics.horizontalFieldOfView > 55 && intrinsics.horizontalFieldOfView < 75)

        // A centred principal point means no lens shift in Blender.
        let shift = intrinsics.blenderShift
        #expect(abs(shift.x) < 1e-12)
        #expect(abs(shift.y) < 1e-12)

        #expect(abs(intrinsics.blenderLens(sensorWidth: 36) - 28.125) < 1e-9)
    }

    @Test("An off-centre principal point shifts the right way")
    func principalPointShift() {
        // Principal point to the right of centre shifts the lens to the right.
        let right = CameraIntrinsics(fx: 1500, fy: 1500, cx: 1060, cy: 540,
                                     imageWidth: 1920, imageHeight: 1080)
        #expect(right.blenderShift.x > 0)

        // Principal point below centre — image coordinates grow downwards, Blender's shift_y
        // grows upwards, so this has to come out negative.
        let low = CameraIntrinsics(fx: 1500, fy: 1500, cx: 960, cy: 640,
                                   imageWidth: 1920, imageHeight: 1080)
        #expect(low.blenderShift.y < 0)
    }

    @Test("Four quarter turns return the original camera")
    func intrinsicsRotationIsCyclic() {
        let original = CameraIntrinsics(fx: 1500, fy: 1400, cx: 900, cy: 500,
                                        imageWidth: 1920, imageHeight: 1080)
        #expect(original.rotatedCounterClockwise(by: 360) == original)
        #expect(original.rotatedCounterClockwise(by: 0) == original)

        let quarter = original.rotatedCounterClockwise(by: 90)
        #expect(quarter.imageWidth == 1080 && quarter.imageHeight == 1920)
        #expect(quarter.fx == 1400 && quarter.fy == 1500)
        #expect(quarter.rotatedCounterClockwise(by: 270) == original)

        // Negative angles are the same as their positive complement.
        #expect(original.rotatedCounterClockwise(by: -90)
                == original.rotatedCounterClockwise(by: 270))
    }
}

@Suite("Trajectory alignment")
struct TrajectoryAlignmentTests {

    private static func track(_ points: [(Double, Double)]) -> [ENU] {
        points.map { ENU(east: $0.0, north: $0.1, up: 0) }
    }

    @Test("A known yaw offset is recovered")
    func recoversYaw() {
        let source = Self.track([(0, 0), (10, 0), (20, 5), (25, 15), (20, 25)])
        let expected = 12.0 * .pi / 180
        let c = cos(expected), s = sin(expected)
        let target = source.map {
            ENU(east: c * $0.east - s * $0.north + 100,
                north: s * $0.east + c * $0.north - 40,
                up: 0)
        }

        let fit = TrajectoryAlignment.horizontal(source: source, target: target)
        #expect(abs(fit.yawDegrees - 12) < 1e-6)
        #expect(abs(fit.translation.x - 100) < 1e-6)
        #expect(abs(fit.translation.y - (-40)) < 1e-6)
        #expect(fit.rmsResidual < 1e-9)
        #expect(fit.sampleCount == 5)
    }

    @Test("Applying the fit lands the source on the target")
    func applyReproducesTarget() {
        let source = Self.track([(0, 0), (10, 0), (20, 5), (25, 15)])
        let expected = -37.5 * .pi / 180
        let c = cos(expected), s = sin(expected)
        let target = source.map {
            ENU(east: c * $0.east - s * $0.north + 7,
                north: s * $0.east + c * $0.north + 3,
                up: 0)
        }

        let fit = TrajectoryAlignment.horizontal(source: source, target: target)
        for (a, b) in zip(source, target) {
            let moved = fit.apply(to: a)
            #expect(abs(moved.east - b.east) < 1e-9)
            #expect(abs(moved.north - b.north) < 1e-9)
        }
    }

    @Test("Height is left alone")
    func heightUntouched() {
        let fit = GroundAlignment(yaw: .pi / 3, translation: SIMD2(5, -5),
                                  rmsResidual: 0, rmsSpread: 10, sampleCount: 2)
        #expect(fit.apply(to: ENU(east: 1, north: 2, up: 42)).up == 42)
    }

    @Test("Yaw uncertainty falls as the track gets longer")
    func yawUncertaintyTracksLeverArm() {
        // Three metres of noise over ten metres of track is about 17°; over a hundred
        // metres, under two.
        let short = GroundAlignment(yaw: 0, translation: .zero,
                                    rmsResidual: 3, rmsSpread: 10, sampleCount: 100)
        let long = GroundAlignment(yaw: 0, translation: .zero,
                                   rmsResidual: 3, rmsSpread: 100, sampleCount: 100)
        #expect(abs(short.yawUncertaintyDegrees - 16.7) < 0.5)
        #expect(long.yawUncertaintyDegrees < 2)
        #expect(GroundAlignment.identity.yawUncertaintyDegrees.isInfinite)
    }

    @Test("Noise shows up in the residual rather than being hidden")
    func residualReportsNoise() {
        let source = Self.track([(0, 0), (10, 0), (20, 0), (30, 0), (40, 0)])
        let offsets = [1.0, -1.0, 1.0, -1.0, 1.0]
        let target = zip(source, offsets).map {
            ENU(east: $0.east, north: $0.north + $1, up: 0)
        }

        let fit = TrajectoryAlignment.horizontal(source: source, target: target)
        #expect(fit.rmsResidual > 0.9 && fit.rmsResidual < 1.1)
    }

    @Test("A stationary track yields no alignment rather than a random one")
    func stationaryTrackIsIdentity() {
        let source = Self.track([(5, 5), (5, 5), (5, 5)])
        let target = Self.track([(9, 1), (9, 1), (9, 1)])
        #expect(TrajectoryAlignment.horizontal(source: source, target: target) == .identity)
        #expect(TrajectoryAlignment.horizontal(source: [], target: []) == .identity)
    }
}
