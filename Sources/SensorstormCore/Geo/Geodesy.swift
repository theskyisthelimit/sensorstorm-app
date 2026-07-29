import Foundation
import simd

/// A position on the WGS84 ellipsoid.
///
/// `height` is **ellipsoidal** throughout this file — the value CoreLocation calls
/// `ellipsoidalAltitude`, not the orthometric `altitude` it shows the user. The two differ by
/// the geoid undulation, which is 46–52 m across Switzerland: large enough that mixing them up
/// leaves a whole scene floating, small enough that it looks like a plausible GPS error.
public struct Geodetic: Sendable, Hashable {
    public var latitude: Double
    public var longitude: Double
    public var height: Double

    public init(latitude: Double, longitude: Double, height: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.height = height
    }
}

/// A local metric position: metres east, north and up from an anchor. Right-handed, and the
/// same axis order Blender uses for a Z-up scene, so no further swizzle is needed downstream.
public struct ENU: Sendable, Hashable {
    public var east: Double
    public var north: Double
    public var up: Double

    public init(east: Double, north: Double, up: Double) {
        self.east = east
        self.north = north
        self.up = up
    }

    public var simd: SIMD3<Double> { SIMD3(east, north, up) }
}

/// Swiss LV95 (EPSG:2056) coordinates. `east`/`north` are the axes swisstopo prints as
/// *E* and *N*; the older LV03 names them *y* and *x*, which is a trap worth avoiding.
public struct LV95: Sendable, Hashable {
    public var east: Double
    public var north: Double
    /// Height in the Swiss system (LN02-ish), i.e. orthometric.
    public var height: Double

    public init(east: Double, north: Double, height: Double) {
        self.east = east
        self.north = north
        self.height = height
    }
}

/// Coordinate conversions, pure arithmetic and no dependencies.
public enum Geodesy {

    // MARK: - WGS84 ellipsoid

    /// Semi-major axis.
    public static let a = 6_378_137.0
    /// Flattening.
    public static let f = 1.0 / 298.257_223_563
    /// Semi-minor axis.
    public static let b = a * (1 - f)
    /// First eccentricity squared.
    public static let e2 = f * (2 - f)
    /// Second eccentricity squared.
    public static let ep2 = (a * a - b * b) / (b * b)

    // MARK: - Geodetic ↔ ECEF

    /// Earth-centred, earth-fixed metres.
    public static func ecef(from position: Geodetic) -> SIMD3<Double> {
        let lat = position.latitude * .pi / 180
        let lon = position.longitude * .pi / 180
        let sinLat = sin(lat), cosLat = cos(lat)
        let sinLon = sin(lon), cosLon = cos(lon)
        let n = a / (1 - e2 * sinLat * sinLat).squareRoot()

        return SIMD3(
            (n + position.height) * cosLat * cosLon,
            (n + position.height) * cosLat * sinLon,
            (n * (1 - e2) + position.height) * sinLat
        )
    }

    /// Bowring's closed-form inverse — millimetre-accurate at terrestrial heights and, unlike
    /// the iterative solutions, has no convergence to reason about.
    public static func geodetic(fromECEF p: SIMD3<Double>) -> Geodetic {
        let px = (p.x * p.x + p.y * p.y).squareRoot()
        guard px > 0 else {
            // On the axis: longitude is undefined, latitude is a pole.
            return Geodetic(latitude: p.z >= 0 ? 90 : -90,
                            longitude: 0,
                            height: abs(p.z) - b)
        }

        let theta = atan2(p.z * a, px * b)
        let sinTheta = sin(theta), cosTheta = cos(theta)
        let lat = atan2(p.z + ep2 * b * sinTheta * sinTheta * sinTheta,
                        px - e2 * a * cosTheta * cosTheta * cosTheta)
        let lon = atan2(p.y, p.x)
        let sinLat = sin(lat)
        let n = a / (1 - e2 * sinLat * sinLat).squareRoot()

        return Geodetic(latitude: lat * 180 / .pi,
                        longitude: lon * 180 / .pi,
                        height: px / cos(lat) - n)
    }

    // MARK: - Geodetic ↔ ENU

    /// Position relative to `anchor`, in metres east/north/up.
    public static func enu(of position: Geodetic, from anchor: Geodetic) -> ENU {
        let delta = ecef(from: position) - ecef(from: anchor)
        let lat = anchor.latitude * .pi / 180
        let lon = anchor.longitude * .pi / 180
        let sinLat = sin(lat), cosLat = cos(lat)
        let sinLon = sin(lon), cosLon = cos(lon)

        return ENU(
            east: -sinLon * delta.x + cosLon * delta.y,
            north: -sinLat * cosLon * delta.x - sinLat * sinLon * delta.y + cosLat * delta.z,
            up: cosLat * cosLon * delta.x + cosLat * sinLon * delta.y + sinLat * delta.z
        )
    }

    /// Inverse of ``enu(of:from:)``. The ENU basis is orthonormal, so this is the transpose.
    public static func geodetic(fromENU local: ENU, anchor: Geodetic) -> Geodetic {
        let lat = anchor.latitude * .pi / 180
        let lon = anchor.longitude * .pi / 180
        let sinLat = sin(lat), cosLat = cos(lat)
        let sinLon = sin(lon), cosLon = cos(lon)

        let delta = SIMD3(
            -sinLon * local.east - sinLat * cosLon * local.north + cosLat * cosLon * local.up,
            cosLon * local.east - sinLat * sinLon * local.north + cosLat * sinLon * local.up,
            cosLat * local.north + sinLat * local.up
        )
        return geodetic(fromECEF: ecef(from: anchor) + delta)
    }

    // MARK: - WGS84 ↔ LV95 (EPSG:2056)

    /// swisstopo's approximate direct transformation, accurate to about 1 m in position and
    /// 2 m in height.
    ///
    /// That is deliberately good enough: a GPS fix from a phone carries ±3 m at best, so the
    /// exact CHENyx06 grid shift would only add precision the input never had. `height` is
    /// converted to the Swiss orthometric system on the way.
    public static func lv95(from position: Geodetic) -> LV95 {
        let (phi, lambda) = swissAuxiliary(position)

        let east = 2_600_072.37
            + 211_455.93 * lambda
            - 10_938.51 * lambda * phi
            - 0.36 * lambda * phi * phi
            - 44.54 * lambda * lambda * lambda

        let north = 1_200_147.07
            + 308_807.95 * phi
            + 3_745.25 * lambda * lambda
            + 76.63 * phi * phi
            - 194.56 * lambda * lambda * phi
            + 119.79 * phi * phi * phi

        let height = position.height - 49.55 + 2.73 * lambda + 6.94 * phi

        return LV95(east: east, north: north, height: height)
    }

    public static func geodetic(fromLV95 position: LV95) -> Geodetic {
        let y = (position.east - 2_600_000) / 1_000_000
        let x = (position.north - 1_200_000) / 1_000_000

        let lambda = 2.677_909_4
            + 4.728_982 * y
            + 0.791_484 * y * x
            + 0.1306 * y * x * x
            - 0.0436 * y * y * y

        let phi = 16.902_389_2
            + 3.238_272 * x
            - 0.270_978 * y * y
            - 0.002_528 * x * x
            - 0.0447 * y * y * x
            - 0.0140 * x * x * x

        let height = position.height + 49.55 - 12.60 * y - 22.64 * x

        // The polynomials are in units of 10 000 sexagesimal seconds.
        return Geodetic(latitude: phi * 100 / 36,
                        longitude: lambda * 100 / 36,
                        height: height)
    }

    /// The two reduced arguments both swisstopo polynomials are written in: degrees converted
    /// to sexagesimal seconds, offset to the old Bern observatory, scaled by 10 000.
    private static func swissAuxiliary(_ position: Geodetic) -> (phi: Double, lambda: Double) {
        let phi = (position.latitude * 3600 - 169_028.66) / 10_000
        let lambda = (position.longitude * 3600 - 26_782.5) / 10_000
        return (phi, lambda)
    }
}
