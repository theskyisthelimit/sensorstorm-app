import Foundation

/// One point of a GPS track, ready to be written out.
public struct TrackPoint: Sendable, Hashable {
    public var hostTime: Double
    public var position: Geodetic
    /// Orthometric height, the one GPX and KML consumers expect in `<ele>`.
    public var orthometricHeight: Double
    public var speed: Double
    public var course: Double
    public var horizontalAccuracy: Double

    public init(hostTime: Double, position: Geodetic, orthometricHeight: Double,
                speed: Double, course: Double, horizontalAccuracy: Double) {
        self.hostTime = hostTime
        self.position = position
        self.orthometricHeight = orthometricHeight
        self.speed = speed
        self.course = course
        self.horizontalAccuracy = horizontalAccuracy
    }
}

/// Reads the `location` stream into a track, and writes it as GPX or KML.
///
/// Both formats want wall-clock time and orthometric height, which is the opposite of what
/// the scene bundle wants — hence the two heights carried side by side everywhere.
public enum TrackExporter {

    /// Column layout of ``SensorID/location``.
    private enum Column {
        static let latitude = 0
        static let longitude = 1
        static let altitude = 2
        static let ellipsoidalAltitude = 3
        static let speed = 4
        static let course = 6
        static let horizontalAccuracy = 8
    }

    public static func track(from reader: StreamReader) -> [TrackPoint] {
        var points: [TrackPoint] = []
        points.reserveCapacity(reader.sampleCount)

        reader.forEachSample { hostTime, values in
            guard values.count > Column.horizontalAccuracy else { return }
            let latitude = values[Column.latitude]
            let longitude = values[Column.longitude]
            // CoreLocation reports (0, 0) with a negative accuracy when it has nothing.
            guard latitude.isFinite, longitude.isFinite,
                  values[Column.horizontalAccuracy] > 0 else { return }

            points.append(TrackPoint(
                hostTime: hostTime,
                position: Geodetic(latitude: latitude, longitude: longitude,
                                   height: values[Column.ellipsoidalAltitude]),
                orthometricHeight: values[Column.altitude],
                speed: values[Column.speed],
                course: values[Column.course],
                horizontalAccuracy: values[Column.horizontalAccuracy]))
        }
        return points
    }

    // MARK: - GPX

    public static func gpx(_ points: [TrackPoint], metadata: RecordingMetadata) -> String {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Sensorstorm" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata>
            <name>\(xmlEscape(metadata.name))</name>
            <time>\(iso8601(metadata.startedAt))</time>
          </metadata>
          <trk>
            <name>\(xmlEscape(metadata.name))</name>
            <trkseg>

        """

        for point in points {
            let date = wallClock(point.hostTime, in: metadata)
            out += "      <trkpt lat=\"\(number(point.position.latitude))\""
            out += " lon=\"\(number(point.position.longitude))\">\n"
            if point.orthometricHeight.isFinite {
                out += "        <ele>\(number(point.orthometricHeight))</ele>\n"
            }
            out += "        <time>\(iso8601(date))</time>\n"
            if point.speed >= 0 {
                out += "        <extensions><speed>\(number(point.speed))</speed></extensions>\n"
            }
            out += "      </trkpt>\n"
        }

        out += """
            </trkseg>
          </trk>
        </gpx>

        """
        return out
    }

    // MARK: - KML

    public static func kml(_ points: [TrackPoint], metadata: RecordingMetadata) -> String {
        // `absolute` altitude mode means the numbers are read as heights above sea level
        // rather than above the terrain — otherwise the track sinks into any hillside.
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
          <Document>
            <name>\(xmlEscape(metadata.name))</name>
            <Placemark>
              <name>\(xmlEscape(metadata.name))</name>
              <LineString>
                <altitudeMode>absolute</altitudeMode>
                <coordinates>

        """

        for point in points {
            let height = point.orthometricHeight.isFinite ? point.orthometricHeight : 0
            out += "          \(number(point.position.longitude)),"
            out += "\(number(point.position.latitude)),\(number(height))\n"
        }

        out += """
                </coordinates>
              </LineString>
            </Placemark>
          </Document>
        </kml>

        """
        return out
    }

    // MARK: - Helpers

    static func wallClock(_ hostTime: Double, in metadata: RecordingMetadata) -> Date {
        metadata.startedAt.addingTimeInterval(hostTime - metadata.startHostTime)
    }

    static func iso8601(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day()
            .dateTimeSeparator(.standard)
            .time(includingFractionalSeconds: true)
            .timeZone(separator: .omitted))
    }

    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return String(format: "%.9g", value)
    }

    static func xmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
