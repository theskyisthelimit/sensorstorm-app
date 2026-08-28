import Foundation

/// Turns a walk into something another tool can open.
///
/// Four formats, because the four things people do with ground documentation are different:
/// GeoJSON for QGIS and anything web, CSV for a spreadsheet or a database import, GPX to
/// walk back to the spot with a handheld receiver, KML to hand a client a file that opens
/// in Google Earth with the bad spots already red. The bundle is all four plus the photos
/// and clips, zipped — the form the data leaves the phone in when it is going into someone
/// else's hands.
public struct SurveyExporter: Sendable {
    public enum Format: String, Sendable, CaseIterable {
        /// A single `.geojson`: one point feature per finding, one polygon feature per
        /// marked area. Media are referenced by file name, not embedded.
        case geoJSON
        /// One row per finding, WGS84 and LV95 side by side.
        case csv
        /// Waypoints. GPX has no way to say "area", so areas are left out on purpose.
        case gpx
        /// Points and areas, coloured by severity, for Google Earth.
        case kml
        /// Everything above plus every photo and clip, zipped.
        case bundle

        public var fileExtension: String {
            switch self {
            case .geoJSON: "geojson"
            case .csv: "csv"
            case .gpx: "gpx"
            case .kml: "kml"
            case .bundle: "zip"
            }
        }
    }

    /// Where the media sit inside a bundle, relative to its root.
    static let bundleMediaFolder = "media"

    private let store: SurveyStore

    public init(store: SurveyStore) {
        self.store = store
    }

    /// Writes the export into `destinationDirectory` and returns the file to share.
    public func export(_ survey: Survey, format: Format,
                       into destinationDirectory: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let baseName = RecordingExporter.sanitize(survey.name.isEmpty ? "Begehung" : survey.name)
        let destination = destinationDirectory
            .appendingPathComponent("\(baseName).\(format.fileExtension)")
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        switch format {
        case .geoJSON:
            try Data(Self.geoJSON(survey).utf8).write(to: destination, options: .atomic)
        case .csv:
            try Data(Self.csv(survey).utf8).write(to: destination, options: .atomic)
        case .gpx:
            try Data(Self.gpx(survey).utf8).write(to: destination, options: .atomic)
        case .kml:
            try Data(Self.kml(survey).utf8).write(to: destination, options: .atomic)
        case .bundle:
            try writeBundle(survey, to: destination, in: destinationDirectory)
        }
        return destination
    }

    private func writeBundle(_ survey: Survey, to destination: URL,
                             in destinationDirectory: URL) throws {
        let fileManager = FileManager.default
        let baseName = RecordingExporter.sanitize(survey.name.isEmpty ? "Begehung" : survey.name)
        let staging = destinationDirectory
            .appendingPathComponent("staging-\(survey.id.uuidString)", isDirectory: true)
        let payload = staging.appendingPathComponent(baseName, isDirectory: true)

        if fileManager.fileExists(atPath: staging.path) {
            try fileManager.removeItem(at: staging)
        }
        try fileManager.createDirectory(at: payload, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let prefix = "\(Self.bundleMediaFolder)/"
        try Data(Self.geoJSON(survey, mediaPrefix: prefix).utf8)
            .write(to: payload.appendingPathComponent("findings.geojson"), options: .atomic)
        try Data(Self.csv(survey, mediaPrefix: prefix).utf8)
            .write(to: payload.appendingPathComponent("findings.csv"), options: .atomic)
        try Data(Self.gpx(survey).utf8)
            .write(to: payload.appendingPathComponent("findings.gpx"), options: .atomic)
        try Data(Self.kml(survey, mediaPrefix: prefix).utf8)
            .write(to: payload.appendingPathComponent("findings.kml"), options: .atomic)
        try SurveyStore.encoder.encode(survey)
            .write(to: payload.appendingPathComponent(SurveyStore.surveyFileName), options: .atomic)
        try Data(Self.readme(survey).utf8)
            .write(to: payload.appendingPathComponent("README.txt"), options: .atomic)

        let media = payload.appendingPathComponent(Self.bundleMediaFolder, isDirectory: true)
        try fileManager.createDirectory(at: media, withIntermediateDirectories: true)
        for finding in survey.findings {
            for source in [store.photoURL(for: finding, in: survey.id),
                           store.videoURL(for: finding, in: survey.id)] {
                guard let source else { continue }
                let target = media.appendingPathComponent(source.lastPathComponent)
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                try fileManager.copyItem(at: source, to: target)
            }
        }

        try ZipPackager.zip(directory: payload, to: destination)
    }

    // MARK: - GeoJSON

    /// - Parameter mediaPrefix: prepended to every photo and clip reference, so a bundle can
    ///   point at its own `media/` folder while a lone `.geojson` points next to itself.
    public static func geoJSON(_ survey: Survey, mediaPrefix: String = "") -> String {
        var features: [[String: Any]] = []

        for finding in survey.findingsByTime where finding.location.coordinate.isValid {
            features.append(pointFeature(finding, mediaPrefix: mediaPrefix))
            if let area = finding.area, area.isValid {
                features.append(areaFeature(area, of: finding))
            }
        }

        var collection: [String: Any] = [
            "type": "FeatureCollection",
            "name": survey.name,
            "features": features
        ]
        var meta: [String: Any] = [
            "id": survey.id.uuidString,
            "startedAt": TrackExporter.iso8601(survey.startedAt),
            "findingCount": survey.findings.count,
            "generator": "Sensorstorm"
        ]
        if !survey.notes.isEmpty { meta["notes"] = survey.notes }
        if let recordingID = survey.recordingID { meta["recording"] = recordingID.uuidString }
        collection["survey"] = meta

        guard let data = try? JSONSerialization.data(
            withJSONObject: collection,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return "{\"type\":\"FeatureCollection\",\"features\":[]}\n"
        }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private static func pointFeature(_ finding: GroundFinding, mediaPrefix: String) -> [String: Any] {
        var coordinates: [Double] = [finding.location.longitude, finding.location.latitude]
        if let altitude = finding.location.altitude { coordinates.append(altitude) }

        var properties: [String: Any] = [
            "kind": "finding",
            "id": finding.id.uuidString,
            "time": TrackExporter.iso8601(finding.capturedAt),
            "severity": finding.severity
        ]
        if !finding.label.isEmpty { properties["label"] = finding.label }
        if !finding.note.isEmpty { properties["note"] = finding.note }
        if let photo = finding.photoFileName { properties["photo"] = mediaPrefix + photo }
        if let video = finding.videoFileName { properties["video"] = mediaPrefix + video }
        if finding.location.horizontalAccuracy > 0 {
            properties["horizontalAccuracy"] = finding.location.horizontalAccuracy
        }
        if let heading = finding.location.heading { properties["heading"] = heading }
        if let recordingID = finding.recordingID { properties["recording"] = recordingID.uuidString }
        if let area = finding.area, area.isValid {
            properties["areaSquareMetres"] = rounded(area.squareMetres)
        }
        let lv95 = finding.location.lv95
        properties["lv95East"] = rounded(lv95.east)
        properties["lv95North"] = rounded(lv95.north)

        let geometry: [String: Any] = ["type": "Point", "coordinates": coordinates]
        return ["type": "Feature", "geometry": geometry, "properties": properties]
    }

    private static func areaFeature(_ area: FindingArea, of finding: GroundFinding) -> [String: Any] {
        var ring = area.ring().map { [$0.longitude, $0.latitude] }
        // GeoJSON rings are closed: the last position repeats the first.
        if let first = ring.first { ring.append(first) }

        var properties: [String: Any] = [
            "kind": "area",
            "finding": finding.id.uuidString,
            "severity": finding.severity,
            "shape": area.kind.rawValue,
            "squareMetres": rounded(area.squareMetres)
        ]
        if area.kind == .circle { properties["radius"] = rounded(area.radius) }
        if !finding.label.isEmpty { properties["label"] = finding.label }

        let geometry: [String: Any] = ["type": "Polygon", "coordinates": [ring]]
        return ["type": "Feature", "geometry": geometry, "properties": properties]
    }

    /// `JSONSerialization` refuses NaN and infinity outright, and no consumer wants
    /// fifteen digits of a square-metre estimate either.
    private static func rounded(_ value: Double, decimals: Int = 3) -> Double {
        guard value.isFinite else { return 0 }
        let factor = pow(10.0, Double(decimals))
        return (value * factor).rounded() / factor
    }

    // MARK: - CSV

    public static func csv(_ survey: Survey, mediaPrefix: String = "") -> String {
        var out = "id,time,latitude,longitude,altitude,ellipsoidalAltitude,horizontalAccuracy,"
        out += "heading,severity,label,note,photo,video,areaKind,areaRadius,areaSquareMetres,"
        out += "lv95East,lv95North,recording\n"

        for finding in survey.findingsByTime {
            let location = finding.location
            let lv95 = location.lv95
            var row: [String] = [
                finding.id.uuidString,
                TrackExporter.iso8601(finding.capturedAt),
                RecordingExporter.number(location.latitude),
                RecordingExporter.number(location.longitude),
                RecordingExporter.number(location.altitude ?? .nan),
                RecordingExporter.number(location.ellipsoidalAltitude ?? .nan),
                RecordingExporter.number(location.horizontalAccuracy),
                RecordingExporter.number(location.heading ?? .nan),
                "\(finding.severity)",
                RecordingExporter.csvEscape(finding.label),
                RecordingExporter.csvEscape(finding.note),
                RecordingExporter.csvEscape(finding.photoFileName.map { mediaPrefix + $0 } ?? ""),
                RecordingExporter.csvEscape(finding.videoFileName.map { mediaPrefix + $0 } ?? "")
            ]
            if let area = finding.area, area.isValid {
                row.append(area.kind.rawValue)
                row.append(area.kind == .circle ? RecordingExporter.number(area.radius) : "")
                row.append(RecordingExporter.fixed(area.squareMetres))
            } else {
                row.append(contentsOf: ["", "", ""])
            }
            row.append(RecordingExporter.fixed(lv95.east))
            row.append(RecordingExporter.fixed(lv95.north))
            row.append(finding.recordingID?.uuidString ?? "")

            out += row.joined(separator: ",")
            out += "\n"
        }
        return out
    }

    // MARK: - GPX

    /// Waypoints only. GPX describes tracks and points; it has no polygon, and inventing
    /// one as a closed track would hand the next tool something it would draw as a walk
    /// that never happened.
    public static func gpx(_ survey: Survey) -> String {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Sensorstorm" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata>
            <name>\(TrackExporter.xmlEscape(survey.name))</name>
            <time>\(TrackExporter.iso8601(survey.startedAt))</time>
          </metadata>

        """

        for finding in survey.findingsByTime where finding.location.coordinate.isValid {
            let location = finding.location
            out += "  <wpt lat=\"\(TrackExporter.number(location.latitude))\""
            out += " lon=\"\(TrackExporter.number(location.longitude))\">\n"
            if let altitude = location.altitude {
                out += "    <ele>\(TrackExporter.number(altitude))</ele>\n"
            }
            out += "    <time>\(TrackExporter.iso8601(finding.capturedAt))</time>\n"
            out += "    <name>\(TrackExporter.xmlEscape(waypointName(finding)))</name>\n"
            if !finding.note.isEmpty {
                out += "    <desc>\(TrackExporter.xmlEscape(finding.note))</desc>\n"
            }
            out += "    <sym>Flag, Red</sym>\n"
            out += "  </wpt>\n"
        }

        out += "</gpx>\n"
        return out
    }

    private static func waypointName(_ finding: GroundFinding) -> String {
        finding.label.isEmpty ? "\(finding.severity)/10" : "\(finding.severity)/10 \(finding.label)"
    }

    // MARK: - KML

    public static func kml(_ survey: Survey, mediaPrefix: String = "") -> String {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
          <Document>
            <name>\(TrackExporter.xmlEscape(survey.name))</name>

        """

        for severity in GroundFinding.severityRange {
            let colour = kmlColour(forSeverity: severity)
            out += """
                <Style id="severity\(severity)">
                  <IconStyle><color>\(colour)</color><scale>1.1</scale></IconStyle>
                  <LineStyle><color>\(colour)</color><width>2</width></LineStyle>
                  <PolyStyle><color>\(kmlColour(forSeverity: severity, alpha: 0x66))</color></PolyStyle>
                </Style>

            """
        }

        for finding in survey.findingsByTime where finding.location.coordinate.isValid {
            let location = finding.location
            let height = location.altitude ?? 0
            out += """
                <Placemark>
                  <name>\(TrackExporter.xmlEscape(waypointName(finding)))</name>
                  <styleUrl>#severity\(finding.severity)</styleUrl>
                  <TimeStamp><when>\(TrackExporter.iso8601(finding.capturedAt))</when></TimeStamp>
                  <description>\(TrackExporter.xmlEscape(placemarkDescription(of: finding, mediaPrefix: mediaPrefix)))</description>
                  <Point>
                    <coordinates>\(TrackExporter.number(location.longitude)),\(TrackExporter.number(location.latitude)),\(TrackExporter.number(height))</coordinates>
                  </Point>
                </Placemark>

            """

            guard let area = finding.area, area.isValid else { continue }
            var ring = area.ring()
            if let first = ring.first { ring.append(first) }
            let coordinates = ring
                .map { "\(TrackExporter.number($0.longitude)),\(TrackExporter.number($0.latitude)),0" }
                .joined(separator: " ")
            out += """
                <Placemark>
                  <name>\(TrackExporter.xmlEscape(waypointName(finding))) · \(Int(area.squareMetres.rounded())) m²</name>
                  <styleUrl>#severity\(finding.severity)</styleUrl>
                  <Polygon>
                    <tessellate>1</tessellate>
                    <outerBoundaryIs><LinearRing><coordinates>\(coordinates)</coordinates></LinearRing></outerBoundaryIs>
                  </Polygon>
                </Placemark>

            """
        }

        out += """
          </Document>
        </kml>

        """
        return out
    }

    private static func placemarkDescription(of finding: GroundFinding,
                                             mediaPrefix: String) -> String {
        var parts = ["Bewertung \(finding.severity)/10"]
        if !finding.note.isEmpty { parts.append(finding.note) }
        if let area = finding.area, area.isValid {
            parts.append("Bereich \(Int(area.squareMetres.rounded())) m²")
        }
        if finding.location.horizontalAccuracy > 0 {
            parts.append(String(format: "GPS ±%.0f m", finding.location.horizontalAccuracy))
        }
        if let photo = finding.photoFileName { parts.append(mediaPrefix + photo) }
        if let video = finding.videoFileName { parts.append(mediaPrefix + video) }
        return parts.joined(separator: " · ")
    }

    /// KML colours are `aabbggrr`, not `aarrggbb`. Severity runs green → amber → red, the
    /// same ramp the app draws, so a file opened in Google Earth reads like the screen it
    /// came from.
    static func kmlColour(forSeverity severity: Int, alpha: Int = 0xFF) -> String {
        let clamped = GroundFinding.clamp(severity)
        let fraction = Double(clamped - 1) / 9.0
        let red = Int((60 + 195 * fraction).rounded())
        let green = Int((200 - 160 * fraction).rounded())
        let blue = 60
        return hexByte(alpha) + hexByte(blue) + hexByte(green) + hexByte(red)
    }

    private static func hexByte(_ value: Int) -> String {
        let byte = min(max(value, 0), 255)
        let text = String(byte, radix: 16)
        return byte < 16 ? "0" + text : text
    }

    // MARK: - README

    private static func readme(_ survey: Survey) -> String {
        let area = survey.markedSquareMetres
        return """
        \(survey.name)
        Begehung vom \(TrackExporter.iso8601(survey.startedAt))

        \(survey.findings.count) Befund(e), markierte Fläche insgesamt \(Int(area.rounded())) m².

        findings.geojson  Punkte und Bereiche, WGS84. Öffnet in QGIS, Leaflet, Mapbox.
        findings.csv      eine Zeile pro Befund, WGS84 und LV95 nebeneinander.
        findings.gpx      Wegpunkte, um dieselbe Stelle wiederzufinden. Ohne Bereiche —
                          GPX kennt keine Flächen.
        findings.kml      Punkte und Bereiche, nach Bewertung eingefärbt (Google Earth).
        survey.json       das Original, so wie die App es speichert.
        \(bundleMediaFolder)/            Foto und Clip je Befund, benannt nach der Befund-ID.

        Die Bewertung ist eine Zahl von 1 bis 10: 1 unauffällig, 10 so schlimm wie es geht.
        Die Genauigkeit des Fixes steht bei jedem Befund dabei — eine Koordinate ohne sie
        ist nicht wiederauffindbar.
        """
    }
}
