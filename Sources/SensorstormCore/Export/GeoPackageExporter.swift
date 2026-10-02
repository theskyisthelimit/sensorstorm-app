import Foundation
import SQLite3

/// A walk as an OGC GeoPackage — the one file a GIS desktop opens without an import step.
///
/// QGIS and ArcGIS both take a `.gpkg` by drag and drop, with the layers styled by nothing
/// but their attribute tables. Three layers: `findings` (points), `areas` (the marked
/// polygons) and `track` (the walked path), all in WGS 84 (EPSG:4326), the CRS of the
/// coordinates the phone measures. Swiss users reproject to LV95 on the desktop, and the
/// findings layer carries `lv95_east` / `lv95_north` for the ones who do not want to.
///
/// Written against the specification's mandatory tables only: `gpkg_spatial_ref_sys`,
/// `gpkg_contents`, `gpkg_geometry_columns`, and feature tables with a `fid` and a `geom`.
public struct GeoPackageExporter: Sendable {
    public static let fileExtension = "gpkg"

    public enum PackageError: Error, LocalizedError {
        case cannotCreate(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .cannotCreate(let name): String(localized: "Die Datei \(name) konnte nicht angelegt werden.")
            case .failed(let message): message
            }
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init() {}

    public func write(_ survey: Survey, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db = handle else {
            sqlite3_close(handle)
            throw PackageError.cannotCreate(url.lastPathComponent)
        }
        defer { sqlite3_close(db) }

        // "GPKG" as a big-endian integer, and version 1.3.0.
        try exec(db, "PRAGMA application_id = 1196444487")
        try exec(db, "PRAGMA user_version = 10300")
        try exec(db, "BEGIN")
        try createCoreTables(db)

        let findings = survey.findingsByTime.filter { $0.location.coordinate.isValid }
        try writeFindings(db, findings)

        let areas = findings.compactMap { finding in finding.area.flatMap { $0.isValid ? (finding, $0) : nil } }
        if !areas.isEmpty { try writeAreas(db, areas) }
        if survey.track.count >= 2 { try writeTrack(db, survey) }
        try exec(db, "COMMIT")
    }

    // MARK: - Core tables

    private func createCoreTables(_ db: OpaquePointer) throws {
        try exec(db, """
            CREATE TABLE gpkg_spatial_ref_sys (
              srs_name TEXT NOT NULL, srs_id INTEGER PRIMARY KEY, organization TEXT NOT NULL,
              organization_coordsys_id INTEGER NOT NULL, definition TEXT NOT NULL, description TEXT)
            """)
        try exec(db, """
            CREATE TABLE gpkg_contents (
              table_name TEXT NOT NULL PRIMARY KEY, data_type TEXT NOT NULL, identifier TEXT UNIQUE,
              description TEXT DEFAULT '',
              last_change DATETIME NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
              min_x DOUBLE, min_y DOUBLE, max_x DOUBLE, max_y DOUBLE, srs_id INTEGER,
              CONSTRAINT fk_gc_r_srs_id FOREIGN KEY (srs_id) REFERENCES gpkg_spatial_ref_sys(srs_id))
            """)
        try exec(db, """
            CREATE TABLE gpkg_geometry_columns (
              table_name TEXT NOT NULL, column_name TEXT NOT NULL, geometry_type_name TEXT NOT NULL,
              srs_id INTEGER NOT NULL, z TINYINT NOT NULL, m TINYINT NOT NULL,
              CONSTRAINT pk_geom_cols PRIMARY KEY (table_name, column_name),
              CONSTRAINT uk_gc_table_name UNIQUE (table_name),
              CONSTRAINT fk_gc_tn FOREIGN KEY (table_name) REFERENCES gpkg_contents(table_name),
              CONSTRAINT fk_gc_srs FOREIGN KEY (srs_id) REFERENCES gpkg_spatial_ref_sys (srs_id))
            """)
        try exec(db, """
            INSERT INTO gpkg_spatial_ref_sys VALUES
              ('Undefined cartesian SRS', -1, 'NONE', -1, 'undefined', 'undefined Cartesian coordinate reference system'),
              ('Undefined geographic SRS', 0, 'NONE', 0, 'undefined', 'undefined geographic coordinate reference system'),
              ('WGS 84 geodetic', 4326, 'EPSG', 4326,
               'GEOGCS["WGS 84",DATUM["WGS_1984",SPHEROID["WGS 84",6378137,298.257223563,AUTHORITY["EPSG","7030"]],AUTHORITY["EPSG","6326"]],PRIMEM["Greenwich",0,AUTHORITY["EPSG","8901"]],UNIT["degree",0.0174532925199433,AUTHORITY["EPSG","9122"]],AUTHORITY["EPSG","4326"]]',
               'longitude/latitude coordinates in decimal degrees on the WGS 84 spheroid')
            """)
    }

    private func register(_ db: OpaquePointer, table: String, geometry: String, bounds: GeoBounds?) throws {
        let box = bounds.map { "\($0.minLongitude), \($0.minLatitude), \($0.maxLongitude), \($0.maxLatitude)" }
            ?? "NULL, NULL, NULL, NULL"
        try exec(db, """
            INSERT INTO gpkg_contents (table_name, data_type, identifier, min_x, min_y, max_x, max_y, srs_id)
            VALUES ('\(table)', 'features', '\(table)', \(box), 4326)
            """)
        try exec(db, """
            INSERT INTO gpkg_geometry_columns VALUES ('\(table)', 'geom', '\(geometry)', 4326, 0, 0)
            """)
    }

    // MARK: - Layers

    private func writeFindings(_ db: OpaquePointer, _ findings: [GroundFinding]) throws {
        try exec(db, """
            CREATE TABLE findings (
              fid INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, geom POINT,
              id TEXT, time TEXT, severity INTEGER, label TEXT, note TEXT,
              status TEXT, status_changed TEXT, resolution TEXT,
              street TEXT, house_number TEXT, postcode TEXT, locality TEXT, egid INTEGER,
              position_source TEXT, accuracy_m REAL, lv95_east REAL, lv95_north REAL,
              altitude_m REAL, area_m2 REAL, depth_cm REAL, slope_deg REAL, volume_m3 REAL,
              attributes TEXT, photos TEXT, videos TEXT, origin TEXT)
            """)
        var statement: OpaquePointer?
        let sql = """
            INSERT INTO findings (geom, id, time, severity, label, note, status, status_changed, resolution,
              street, house_number, postcode, locality, egid, position_source, accuracy_m, lv95_east, lv95_north,
              altitude_m, area_m2, depth_cm, slope_deg, volume_m3, attributes, photos, videos, origin)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure(db) }
        defer { sqlite3_finalize(statement) }

        for finding in findings {
            sqlite3_reset(statement)
            var index: Int32 = 1
            func text(_ value: String?) {
                if let value, !value.isEmpty {
                    sqlite3_bind_text(statement, index, value, -1, Self.transient)
                } else {
                    sqlite3_bind_null(statement, index)
                }
                index += 1
            }
            func number(_ value: Double?) {
                if let value, value.isFinite { sqlite3_bind_double(statement, index, value) } else { sqlite3_bind_null(statement, index) }
                index += 1
            }
            func integer(_ value: Int?) {
                if let value { sqlite3_bind_int64(statement, index, Int64(value)) } else { sqlite3_bind_null(statement, index) }
                index += 1
            }

            let blob = Self.pointBlob(finding.location.longitude, finding.location.latitude)
            blob.withUnsafeBytes { raw in
                _ = sqlite3_bind_blob(statement, index, raw.baseAddress, Int32(blob.count), Self.transient)
            }
            index += 1

            let lv95 = finding.location.lv95
            let address = finding.address
            text(finding.id.uuidString)
            text(TrackExporter.iso8601(finding.capturedAt))
            integer(finding.severity)
            text(finding.label)
            text(finding.note)
            text(finding.status.rawValue)
            text(finding.statusChangedAt.map(TrackExporter.iso8601))
            text(finding.resolutionNote)
            text(address?.street)
            text(address?.houseNumber)
            text(address?.postcode)
            text(address?.locality)
            integer(address?.egid)
            text(finding.positionSource.rawValue)
            number(finding.location.horizontalAccuracy > 0 ? finding.location.horizontalAccuracy : nil)
            number(lv95.east)
            number(lv95.north)
            number(finding.location.altitude)
            number(finding.area.flatMap { $0.isValid ? $0.squareMetres : nil })
            number(finding.measurement(.depth)?.value)
            number(finding.measurement(.slope)?.value)
            number(finding.volumeCubicMetres)
            text(Self.attributesJSON(finding.attributes))
            text(finding.photos.map(\.fileName).joined(separator: ";"))
            text(finding.videos.map(\.fileName).joined(separator: ";"))
            text(finding.originID?.uuidString)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure(db) }
        }
        let bounds = GeoBounds(coordinates: findings.map(\.location.coordinate))
        try register(db, table: "findings", geometry: "POINT", bounds: bounds)
    }

    private func writeAreas(_ db: OpaquePointer, _ areas: [(GroundFinding, FindingArea)]) throws {
        try exec(db, """
            CREATE TABLE areas (
              fid INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, geom POLYGON,
              finding_id TEXT, label TEXT, severity INTEGER, status TEXT, shape TEXT, area_m2 REAL)
            """)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO areas (geom, finding_id, label, severity, status, shape, area_m2) VALUES (?,?,?,?,?,?,?)",
                                 -1, &statement, nil) == SQLITE_OK else { throw failure(db) }
        defer { sqlite3_finalize(statement) }
        for (finding, area) in areas {
            sqlite3_reset(statement)
            let blob = Self.polygonBlob(area.ring())
            blob.withUnsafeBytes { raw in
                _ = sqlite3_bind_blob(statement, 1, raw.baseAddress, Int32(blob.count), Self.transient)
            }
            sqlite3_bind_text(statement, 2, finding.id.uuidString, -1, Self.transient)
            sqlite3_bind_text(statement, 3, finding.label, -1, Self.transient)
            sqlite3_bind_int64(statement, 4, Int64(finding.severity))
            sqlite3_bind_text(statement, 5, finding.status.rawValue, -1, Self.transient)
            sqlite3_bind_text(statement, 6, area.kind.rawValue, -1, Self.transient)
            sqlite3_bind_double(statement, 7, area.squareMetres)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure(db) }
        }
        try register(db, table: "areas", geometry: "POLYGON",
                     bounds: GeoBounds(coordinates: areas.flatMap { $0.1.ring() }))
    }

    private func writeTrack(_ db: OpaquePointer, _ survey: Survey) throws {
        try exec(db, """
            CREATE TABLE track (
              fid INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, geom LINESTRING,
              name TEXT, start_time TEXT, end_time TEXT, length_m REAL, points INTEGER)
            """)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO track (geom, name, start_time, end_time, length_m, points) VALUES (?,?,?,?,?,?)",
                                 -1, &statement, nil) == SQLITE_OK else { throw failure(db) }
        defer { sqlite3_finalize(statement) }
        let blob = Self.lineBlob(survey.track.map(\.coordinate))
        blob.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(statement, 1, raw.baseAddress, Int32(blob.count), Self.transient)
        }
        sqlite3_bind_text(statement, 2, survey.name, -1, Self.transient)
        sqlite3_bind_text(statement, 3, TrackExporter.iso8601(survey.track[0].time), -1, Self.transient)
        sqlite3_bind_text(statement, 4, TrackExporter.iso8601(survey.track[survey.track.count - 1].time), -1, Self.transient)
        sqlite3_bind_double(statement, 5, survey.trackLength)
        sqlite3_bind_int64(statement, 6, Int64(survey.track.count))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure(db) }
        try register(db, table: "track", geometry: "LINESTRING",
                     bounds: GeoBounds(coordinates: survey.track.map(\.coordinate)))
    }

    // MARK: - Geometry encoding

    /// The GeoPackage geometry header: `GP`, version 0, flags (little-endian, no envelope),
    /// the SRS id — and then standard WKB.
    private static func header() -> Data {
        var data = Data([0x47, 0x50, 0x00, 0x01])
        appendInt32(&data, 4326)
        return data
    }

    static func pointBlob(_ longitude: Double, _ latitude: Double) -> Data {
        var data = header()
        data.append(0x01)
        appendInt32(&data, 1)
        appendDouble(&data, longitude)
        appendDouble(&data, latitude)
        return data
    }

    static func lineBlob(_ points: [Coordinate2D]) -> Data {
        var data = header()
        data.append(0x01)
        appendInt32(&data, 2)
        appendInt32(&data, Int32(points.count))
        for point in points {
            appendDouble(&data, point.longitude)
            appendDouble(&data, point.latitude)
        }
        return data
    }

    /// One exterior ring, closed: WKB wants the first point repeated at the end.
    static func polygonBlob(_ ring: [Coordinate2D]) -> Data {
        var closed = ring
        if let first = ring.first, ring.last != first { closed.append(first) }
        var data = header()
        data.append(0x01)
        appendInt32(&data, 3)
        appendInt32(&data, 1)
        appendInt32(&data, Int32(closed.count))
        for point in closed {
            appendDouble(&data, point.longitude)
            appendDouble(&data, point.latitude)
        }
        return data
    }

    private static func appendInt32(_ data: inout Data, _ value: Int32) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func appendDouble(_ data: inout Data, _ value: Double) {
        var little = value.bitPattern.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func attributesJSON(_ attributes: [String: String]) -> String? {
        guard !attributes.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: attributes, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - SQLite

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "SQLite"
            sqlite3_free(message)
            throw PackageError.failed(text)
        }
    }

    private func failure(_ db: OpaquePointer) -> PackageError {
        .failed(String(cString: sqlite3_errmsg(db)))
    }
}
