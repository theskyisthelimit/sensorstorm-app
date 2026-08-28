import Foundation

/// A point on the map, in degrees. No height: a marked area lies on the ground, and the
/// only height that means anything here is the one measured at the finding itself.
public struct Coordinate2D: Codable, Sendable, Hashable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && abs(latitude) <= 90 && abs(longitude) <= 180
    }

    var geodetic: Geodetic {
        Geodetic(latitude: latitude, longitude: longitude, height: 0)
    }

    /// Ground distance in metres, through the local metric frame rather than through a
    /// degree difference — one degree of longitude is 78 km in Bern and 111 km at the
    /// equator, and a documented damage is metres wide.
    public func distance(to other: Coordinate2D) -> Double {
        guard isValid, other.isValid else { return 0 }
        let local = Geodesy.enu(of: other.geodetic, from: geodetic)
        return (local.east * local.east + local.north * local.north).squareRoot()
    }
}

/// Where a finding was recorded, kept with the fix's own accuracy figures.
///
/// A coordinate without its accuracy is a number without a meaning: 3 m and 40 m look
/// identical on a map and decide whether a finding can be found again on the ground.
public struct FindingLocation: Codable, Sendable, Hashable {
    public var latitude: Double
    public var longitude: Double
    /// Orthometric height (`CLLocation.altitude`, roughly mean sea level) — the one GPX,
    /// KML and every map tool expects. `nil` when the fix carried none.
    public var altitude: Double?
    /// Height above the WGS84 ellipsoid, kept for the same reason as in ``GeodeticAnchor``:
    /// the two differ by ~46–52 m in Switzerland.
    public var ellipsoidalAltitude: Double?
    /// Metres, CoreLocation's convention: a negative value means there is no usable fix.
    public var horizontalAccuracy: Double
    public var verticalAccuracy: Double
    /// Direction the camera was pointing, degrees from true north. `nil` when the device
    /// had no compass reading — which is a different thing from pointing north.
    public var heading: Double?

    public init(latitude: Double, longitude: Double, altitude: Double? = nil,
                ellipsoidalAltitude: Double? = nil, horizontalAccuracy: Double = -1,
                verticalAccuracy: Double = -1, heading: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = Self.finite(altitude)
        self.ellipsoidalAltitude = Self.finite(ellipsoidalAltitude)
        self.horizontalAccuracy = horizontalAccuracy.isFinite ? horizontalAccuracy : -1
        self.verticalAccuracy = verticalAccuracy.isFinite ? verticalAccuracy : -1
        self.heading = Self.finite(heading)
    }

    /// JSON has no NaN. A missing measurement is `nil` here rather than a number nobody can
    /// serialise — which is also the more honest of the two.
    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    public var coordinate: Coordinate2D {
        Coordinate2D(latitude: latitude, longitude: longitude)
    }

    public var geodetic: Geodetic {
        Geodetic(latitude: latitude, longitude: longitude, height: ellipsoidalAltitude ?? 0)
    }

    /// Swiss national coordinates for the same point, so a finding can be handed to an
    /// office that works in LV95 without a conversion step in between.
    public var lv95: LV95 {
        Geodesy.lv95(from: Geodetic(latitude: latitude, longitude: longitude,
                                    height: altitude ?? 0))
    }

    /// A fix CoreLocation refused to vouch for is not a position: it reports (0, 0) with a
    /// negative accuracy when it has nothing at all.
    public var isUsable: Bool {
        coordinate.isValid && horizontalAccuracy > 0
    }
}

/// The extent of a finding: either a circle around the point or a walked polygon.
///
/// Two shapes rather than one, because the two ways of marking an area in the field are
/// genuinely different. Standing in front of a damaged patch, a radius is one slider and
/// takes three seconds. Walking the perimeter and dropping a point at each corner traces
/// what is actually there. Both end up as a ring in ``ring(segments:)``, so everything
/// downstream — drawing, area, GeoJSON — only ever sees a polygon.
public struct FindingArea: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case circle
        case polygon
    }

    public var kind: Kind
    /// Circle: the single centre point. Polygon: the ring in order, first point not repeated.
    public var points: [Coordinate2D]
    /// Radius in metres. Only meaningful for ``Kind/circle``.
    public var radius: Double

    public init(kind: Kind, points: [Coordinate2D], radius: Double = 0) {
        self.kind = kind
        self.points = points
        self.radius = radius.isFinite ? radius : 0
    }

    public static func circle(center: Coordinate2D, radius: Double) -> FindingArea {
        FindingArea(kind: .circle, points: [center], radius: radius)
    }

    public static func polygon(_ points: [Coordinate2D]) -> FindingArea {
        FindingArea(kind: .polygon, points: points)
    }

    /// A circle needs a centre and a radius, a polygon needs three corners. Anything else
    /// is a half-finished sketch and must not reach a map or an export.
    public var isValid: Bool {
        switch kind {
        case .circle:
            points.count == 1 && points[0].isValid && radius > 0 && radius.isFinite
        case .polygon:
            points.count >= 3 && points.allSatisfy(\.isValid)
        }
    }

    public var center: Coordinate2D? {
        guard !points.isEmpty else { return nil }
        switch kind {
        case .circle:
            return points[0]
        case .polygon:
            let latitude = points.reduce(0) { $0 + $1.latitude } / Double(points.count)
            let longitude = points.reduce(0) { $0 + $1.longitude } / Double(points.count)
            return Coordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    /// Ground area in square metres.
    ///
    /// The polygon case projects into the local metric frame first (``Geodesy/enu(of:from:)``)
    /// and then runs the shoelace formula. Doing the shoelace on degrees directly would be
    /// wrong by the cosine of the latitude — 33 % in Switzerland.
    public var squareMetres: Double {
        guard isValid else { return 0 }
        switch kind {
        case .circle:
            return .pi * radius * radius
        case .polygon:
            let anchor = points[0].geodetic
            let local = points.map { Geodesy.enu(of: $0.geodetic, from: anchor) }
            var doubled = 0.0
            for index in local.indices {
                let current = local[index]
                let next = local[(index + 1) % local.count]
                doubled += current.east * next.north - next.east * current.north
            }
            return abs(doubled) / 2
        }
    }

    /// The area as a closed-in-order ring. A circle becomes a regular polygon, so a map
    /// overlay, a KML `<Polygon>` and a GeoJSON ring all take the same input.
    public func ring(segments: Int = 48) -> [Coordinate2D] {
        guard isValid else { return [] }
        switch kind {
        case .polygon:
            return points
        case .circle:
            let count = max(segments, 8)
            let anchor = points[0].geodetic
            return (0..<count).map { step in
                let angle = 2 * Double.pi * Double(step) / Double(count)
                let offset = ENU(east: radius * sin(angle), north: radius * cos(angle), up: 0)
                let point = Geodesy.geodetic(fromENU: offset, anchor: anchor)
                return Coordinate2D(latitude: point.latitude, longitude: point.longitude)
            }
        }
    }
}

/// How the position of a case was arrived at.
///
/// Recorded because the three are not equally good and the difference has to survive the
/// trip to whoever reads the file: a single fix is whatever the phone had at that second,
/// an averaged one is quieter, and a hand-placed pin is as good as the person's eye on the
/// aerial image — often the best of the three on a street, and the only one that cannot be
/// checked against an accuracy figure.
public enum PositionSource: String, Codable, Sendable, Hashable, CaseIterable {
    /// One GPS fix, taken when the shutter went.
    case gps
    /// The mean of several fixes taken over a few seconds.
    case averaged
    /// Placed by hand on the map. ``GroundFinding/measuredLocation`` keeps what GPS said.
    case manual
}

/// One photo or one clip belonging to a case.
///
/// A case is not one picture. A pothole gets an overview, a close-up, a shot with a ruler
/// next to it and thirty seconds of video walking around it — and all of that is one case
/// on the map, not four.
public struct CaseMedia: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case photo
        case video
    }

    public var id: UUID
    public var kind: Kind
    /// File name inside the survey folder.
    public var fileName: String
    public var capturedAt: Date
    /// Clip length in seconds; `nil` for photos.
    public var duration: TimeInterval?
    public var note: String

    public init(id: UUID = UUID(), kind: Kind, fileName: String,
                capturedAt: Date = Date(), duration: TimeInterval? = nil,
                note: String = "") {
        self.id = id
        self.kind = kind
        self.fileName = fileName
        self.capturedAt = capturedAt
        self.duration = duration
        self.note = note
    }

    public static func fileName(for id: UUID, kind: Kind) -> String {
        switch kind {
        case .photo: "\(id.uuidString).jpg"
        case .video: "\(id.uuidString).mov"
        }
    }
}

/// One documented damage: where it is, how well that is known, how bad it is, how far it
/// reaches, and every photo and clip taken of it.
///
/// The severity is deliberately a plain 1…10 integer rather than a category. Walking a
/// street, the judgement that matters is comparative ("this one is worse than the one at
/// the corner"), and a number sorts, colours and averages without anyone having to agree
/// on a vocabulary first.
public struct GroundFinding: Codable, Sendable, Hashable, Identifiable {
    /// 1 = barely worth noting, 10 = as bad as it gets.
    public static let severityRange = 1...10

    public var id: UUID
    public var capturedAt: Date
    /// Host-clock time of the capture. A case recorded while a Sensorstorm recording runs
    /// lines up with that recording's streams through this, with no clock conversion.
    public var hostTime: Double
    /// The position that counts — the one drawn on the map and written to every export.
    public var location: FindingLocation
    public var positionSource: PositionSource
    /// What GPS said, kept when the pin was moved by hand. Keeping both is the difference
    /// between a corrected position and a lost measurement.
    public var measuredLocation: FindingLocation?
    /// How many fixes an averaged position was built from.
    public var positionSampleCount: Int?
    /// How far those fixes were spread, in metres — the honest error bar on an averaged
    /// position, which is usually smaller than the accuracy any single fix claimed.
    public var positionSpread: Double?
    public var severity: Int
    /// Short label — "Schlagloch", "Riss", "Setzung". Free text on purpose: a fixed list
    /// is always missing the thing standing in front of you.
    public var label: String
    public var note: String
    public var media: [CaseMedia]
    public var area: FindingArea?
    /// The recording this case was documented during, when there was one.
    public var recordingID: UUID?

    public init(id: UUID = UUID(),
                capturedAt: Date = Date(),
                hostTime: Double = 0,
                location: FindingLocation,
                positionSource: PositionSource = .gps,
                measuredLocation: FindingLocation? = nil,
                positionSampleCount: Int? = nil,
                positionSpread: Double? = nil,
                severity: Int = 5,
                label: String = "",
                note: String = "",
                media: [CaseMedia] = [],
                area: FindingArea? = nil,
                recordingID: UUID? = nil) {
        self.id = id
        self.capturedAt = capturedAt
        self.hostTime = hostTime
        self.location = location
        self.positionSource = positionSource
        self.measuredLocation = measuredLocation
        self.positionSampleCount = positionSampleCount
        self.positionSpread = positionSpread
        self.severity = Self.clamp(severity)
        self.label = label
        self.note = note
        self.media = media
        self.area = area
        self.recordingID = recordingID
    }

    /// Out-of-range severities are clamped rather than rejected: a file written by an older
    /// or a newer version should still open, and a 12 is unambiguously "as bad as it gets".
    public static func clamp(_ severity: Int) -> Int {
        min(max(severity, severityRange.lowerBound), severityRange.upperBound)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        hostTime = try container.decodeIfPresent(Double.self, forKey: .hostTime) ?? 0
        location = try container.decode(FindingLocation.self, forKey: .location)
        positionSource = try container.decodeIfPresent(PositionSource.self,
                                                       forKey: .positionSource) ?? .gps
        measuredLocation = try container.decodeIfPresent(FindingLocation.self,
                                                         forKey: .measuredLocation)
        positionSampleCount = try container.decodeIfPresent(Int.self, forKey: .positionSampleCount)
        positionSpread = try container.decodeIfPresent(Double.self, forKey: .positionSpread)
        severity = Self.clamp(try container.decode(Int.self, forKey: .severity))
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        media = try container.decodeIfPresent([CaseMedia].self, forKey: .media) ?? []
        area = try container.decodeIfPresent(FindingArea.self, forKey: .area)
        recordingID = try container.decodeIfPresent(UUID.self, forKey: .recordingID)
    }

    // MARK: - Media

    public var photos: [CaseMedia] { media.filter { $0.kind == .photo } }
    public var videos: [CaseMedia] { media.filter { $0.kind == .video } }
    public var coverPhoto: CaseMedia? { photos.first }
    public var hasMedia: Bool { !media.isEmpty }

    public mutating func add(_ item: CaseMedia) {
        media.append(item)
    }

    @discardableResult
    public mutating func removeMedia(_ id: UUID) -> CaseMedia? {
        guard let index = media.firstIndex(where: { $0.id == id }) else { return nil }
        return media.remove(at: index)
    }

    // MARK: - Position quality

    /// How far the pin was moved from the fix, in metres. `nil` when nothing was moved.
    public var manualOffsetMetres: Double? {
        guard let measuredLocation, measuredLocation.coordinate.isValid else { return nil }
        let offset = measuredLocation.coordinate.distance(to: location.coordinate)
        return offset.isFinite ? offset : nil
    }

    /// The radius to draw around the pin: the claimed accuracy of the fix, or the measured
    /// spread of an averaged one. `nil` for a hand-placed pin — a pin has no error bar, and
    /// drawing one would invent a number.
    public var uncertaintyRadius: Double? {
        switch positionSource {
        case .manual:
            return nil
        case .averaged:
            if let spread = positionSpread, spread > 0 { return spread }
            return location.horizontalAccuracy > 0 ? location.horizontalAccuracy : nil
        case .gps:
            return location.horizontalAccuracy > 0 ? location.horizontalAccuracy : nil
        }
    }

    /// Moves the pin by hand, keeping what was measured before as ``measuredLocation``.
    ///
    /// A corrected position that threw the measurement away would be worth less than either
    /// of the two on its own: nobody could tell afterwards whether the pin is where the
    /// receiver said or where somebody decided.
    public mutating func placePin(at coordinate: Coordinate2D) {
        guard coordinate.isValid else { return }
        if positionSource != .manual { measuredLocation = location }
        location = FindingLocation(latitude: coordinate.latitude,
                                   longitude: coordinate.longitude,
                                   altitude: location.altitude,
                                   ellipsoidalAltitude: location.ellipsoidalAltitude,
                                   // A pin has no error bar. Carrying the fix's over would
                                   // claim a measurement that was not made.
                                   horizontalAccuracy: -1,
                                   verticalAccuracy: -1,
                                   heading: location.heading)
        positionSource = .manual
        positionSampleCount = nil
        positionSpread = nil
    }

    /// Throws the correction away and goes back to what was measured.
    public mutating func resetPositionToMeasured() {
        guard let measured = measuredLocation else { return }
        location = measured
        measuredLocation = nil
        positionSource = .gps
    }

    /// Every coordinate this case puts on a map: the point plus, if there is one, the
    /// corners of its area.
    public var mapCoordinates: [Coordinate2D] {
        var all = [location.coordinate]
        if let area, area.isValid { all.append(contentsOf: area.ring()) }
        return all.filter(\.isValid)
    }
}

/// A walk: everything documented in one go, on one street, in one session.
///
/// Findings live inside the survey rather than in their own files. A walk produces tens of
/// them, not thousands, and keeping them in one document means the whole walk is written
/// atomically and can never be half-loaded.
public struct Survey: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var startedAt: Date
    public var notes: String
    /// Sensorstorm recording that ran alongside this walk, when there was one.
    public var recordingID: UUID?
    public var findings: [GroundFinding]

    public init(id: UUID = UUID(),
                name: String,
                startedAt: Date = Date(),
                notes: String = "",
                recordingID: UUID? = nil,
                findings: [GroundFinding] = []) {
        self.id = id
        self.name = name
        self.startedAt = startedAt
        self.notes = notes
        self.recordingID = recordingID
        self.findings = findings
    }

    /// Findings in the order they were captured — the order they were walked in.
    public var findingsByTime: [GroundFinding] {
        findings.sorted { $0.capturedAt < $1.capturedAt }
    }

    public var worstSeverity: Int? {
        findings.map(\.severity).max()
    }

    public var averageSeverity: Double? {
        guard !findings.isEmpty else { return nil }
        return Double(findings.reduce(0) { $0 + $1.severity }) / Double(findings.count)
    }

    /// Total marked ground area across all findings.
    public var markedSquareMetres: Double {
        findings.compactMap(\.area).reduce(0) { $0 + $1.squareMetres }
    }

    public func finding(_ id: UUID) -> GroundFinding? {
        findings.first { $0.id == id }
    }

    /// Replaces the finding with the same id, or appends it.
    public mutating func upsert(_ finding: GroundFinding) {
        if let index = findings.firstIndex(where: { $0.id == finding.id }) {
            findings[index] = finding
        } else {
            findings.append(finding)
        }
    }

    @discardableResult
    public mutating func remove(_ id: UUID) -> GroundFinding? {
        guard let index = findings.firstIndex(where: { $0.id == id }) else { return nil }
        return findings.remove(at: index)
    }

    public var bounds: GeoBounds? {
        GeoBounds(coordinates: findings.flatMap(\.mapCoordinates))
    }
}

/// The smallest latitude/longitude box holding a set of points — what a map needs to frame
/// a walk without guessing a zoom level.
public struct GeoBounds: Sendable, Hashable {
    public var minLatitude: Double
    public var maxLatitude: Double
    public var minLongitude: Double
    public var maxLongitude: Double

    public init?(coordinates: [Coordinate2D]) {
        let valid = coordinates.filter(\.isValid)
        guard let first = valid.first else { return nil }

        minLatitude = first.latitude
        maxLatitude = first.latitude
        minLongitude = first.longitude
        maxLongitude = first.longitude

        for point in valid.dropFirst() {
            minLatitude = min(minLatitude, point.latitude)
            maxLatitude = max(maxLatitude, point.latitude)
            minLongitude = min(minLongitude, point.longitude)
            maxLongitude = max(maxLongitude, point.longitude)
        }
    }

    public var center: Coordinate2D {
        Coordinate2D(latitude: (minLatitude + maxLatitude) / 2,
                     longitude: (minLongitude + maxLongitude) / 2)
    }

    public var latitudeSpan: Double { maxLatitude - minLatitude }
    public var longitudeSpan: Double { maxLongitude - minLongitude }
}
