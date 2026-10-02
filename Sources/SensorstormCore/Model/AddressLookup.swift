import Foundation

/// Where to ask, and how to read the answer, when a coordinate should become an address.
///
/// The network call itself lives in the app target; what lives here is the part that can be
/// wrong without anybody noticing — the URL's coordinate system and the shape of the reply —
/// and is therefore worth a test.
public enum SwisstopoAddress {

    /// A point inside the area the federal building register covers: Switzerland and
    /// Liechtenstein, with a margin. Outside it the question is not asked at all — the
    /// coordinate would be sent to a Swiss authority for nothing.
    public static func covers(_ coordinate: Coordinate2D) -> Bool {
        guard coordinate.isValid else { return false }
        let lv95 = Geodesy.lv95(from: Geodetic(latitude: coordinate.latitude,
                                               longitude: coordinate.longitude, height: 0))
        return (2_480_000...2_840_000).contains(lv95.east)
            && (1_070_000...1_300_000).contains(lv95.north)
    }

    /// `identify` on the building register layer, 20 m around the point, in LV95 so the
    /// answer needs no conversion afterwards.
    public static func identifyURL(for coordinate: Coordinate2D, tolerance: Int = 20) -> URL? {
        guard covers(coordinate) else { return nil }
        let lv95 = Geodesy.lv95(from: Geodetic(latitude: coordinate.latitude,
                                               longitude: coordinate.longitude, height: 0))
        let e = lv95.east, n = lv95.north
        var components = URLComponents(string: "https://api3.geo.admin.ch/rest/services/api/MapServer/identify")
        components?.queryItems = [
            URLQueryItem(name: "geometryType", value: "esriGeometryPoint"),
            URLQueryItem(name: "geometry", value: String(format: "%.1f,%.1f", e, n)),
            URLQueryItem(name: "sr", value: "2056"),
            URLQueryItem(name: "layers", value: "all:ch.bfs.gebaeude_wohnungs_register"),
            URLQueryItem(name: "tolerance", value: "\(tolerance)"),
            URLQueryItem(name: "mapExtent", value: String(format: "%.0f,%.0f,%.0f,%.0f", e - 100, n - 100, e + 100, n + 100)),
            URLQueryItem(name: "imageDisplay", value: "500,500,96"),
            URLQueryItem(name: "returnGeometry", value: "false"),
            URLQueryItem(name: "lang", value: "de"),
        ]
        return components?.url
    }

    /// The nearest building's address out of an `identify` reply, or `nil` when there is none.
    ///
    /// Read defensively: the register's attribute names are not something this app controls,
    /// and a field that is a string in one reply and a one-element array in the next is
    /// exactly what an address register does. Anything that cannot be read is left empty
    /// rather than guessed.
    public static func parse(_ data: Data, near coordinate: Coordinate2D) -> PostalAddress? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]], !results.isEmpty else { return nil }

        // `identify` returns every building within the tolerance; the nearest is the one the
        // person was standing in front of. Without geometry the reply carries no distance,
        // so the first one stands — the service sorts by proximity.
        let attributes = results[0]["attributes"] as? [String: Any] ?? [:]

        func text(_ keys: [String]) -> String? {
            for key in keys {
                guard let value = attributes[key] else { continue }
                if let string = value as? String, !string.isEmpty { return string }
                if let array = value as? [String], let first = array.first, !first.isEmpty { return first }
                if let number = value as? NSNumber { return number.stringValue }
            }
            return nil
        }

        var street = text(["strname", "strname_deinr_street"])
        var number = text(["deinr"])
        if street == nil || number == nil, let combined = text(["strname_deinr"]) {
            // „Bahnhofstrasse 12a“ — the number is the last word when it starts with a digit.
            let words = combined.split(separator: " ")
            if let last = words.last, last.first?.isNumber == true, words.count > 1 {
                street = street ?? words.dropLast().joined(separator: " ")
                number = number ?? String(last)
            } else {
                street = street ?? combined
            }
        }

        let egidText = text(["egid"]) ?? (results[0]["featureId"] as? String)
        let egid = egidText.flatMap { Int($0.filter(\.isNumber)) }

        let address = PostalAddress(
            street: street,
            houseNumber: number,
            postcode: text(["plz4", "dplz4", "plz_plz6"]).map { String($0.prefix(4)) },
            locality: text(["plzname", "dplzname", "ggdename", "gdename"]),
            country: "CH",
            egid: egid,
            source: "swisstopo")
        return address.isEmpty ? nil : address
    }
}
