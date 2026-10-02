import Foundation

/// One square of a web map: zoom, column, row, in the scheme every slippy map uses
/// (EPSG:3857, origin top left).
public struct MapTile: Hashable, Sendable, Comparable {
    public var z: Int
    public var x: Int
    public var y: Int

    public init(z: Int, x: Int, y: Int) {
        self.z = z
        self.x = x
        self.y = y
    }

    public static func < (lhs: MapTile, rhs: MapTile) -> Bool {
        (lhs.z, lhs.x, lhs.y) < (rhs.z, rhs.x, rhs.y)
    }
}

/// Which tiles cover a walk — what has to be downloaded to see a map without a connection.
public enum TileMath {

    /// The latitude Web Mercator stops at; beyond it the formula runs off the map.
    public static let maximumLatitude = 85.0511

    public static func tile(latitude: Double, longitude: Double, zoom: Int) -> MapTile {
        let n = Double(1 << zoom)
        let lat = min(max(latitude, -maximumLatitude), maximumLatitude) * .pi / 180
        let x = (longitude + 180) / 360 * n
        let y = (1 - asinh(tan(lat)) / .pi) / 2 * n
        let last = Int(n) - 1
        return MapTile(z: zoom, x: min(max(Int(x.rounded(.down)), 0), last),
                       y: min(max(Int(y.rounded(.down)), 0), last))
    }

    /// Every tile that touches `bounds` at one zoom level, `margin` degrees of padding all
    /// round — a map panned a little past the walk should not show a hole.
    public static func tiles(in bounds: GeoBounds, zoom: Int, margin: Double = 0) -> [MapTile] {
        let northWest = tile(latitude: bounds.maxLatitude + margin, longitude: bounds.minLongitude - margin, zoom: zoom)
        let southEast = tile(latitude: bounds.minLatitude - margin, longitude: bounds.maxLongitude + margin, zoom: zoom)
        guard southEast.x >= northWest.x, southEast.y >= northWest.y else { return [] }
        var tiles: [MapTile] = []
        for x in northWest.x...southEast.x {
            for y in northWest.y...southEast.y {
                tiles.append(MapTile(z: zoom, x: x, y: y))
            }
        }
        return tiles
    }

    /// The tiles for `zooms`, with the deepest levels dropped until the count is within
    /// `limit` — a long walk at zoom 18 would be tens of thousands of tiles.
    public static func plan(bounds: GeoBounds, zooms: ClosedRange<Int>, limit: Int,
                            margin: Double = 0.0005) -> (tiles: [MapTile], deepest: Int) {
        var deepest = zooms.upperBound
        while deepest > zooms.lowerBound {
            let total = (zooms.lowerBound...deepest).reduce(0) { $0 + tiles(in: bounds, zoom: $1, margin: margin).count }
            if total <= limit { break }
            deepest -= 1
        }
        let all = (zooms.lowerBound...deepest).flatMap { tiles(in: bounds, zoom: $0, margin: margin) }
        return (all, deepest)
    }

    /// swisstopo's WMTS, free to use with attribution. `layer` is e.g.
    /// `ch.swisstopo.pixelkarte-farbe` (JPEG) or `ch.swisstopo.swissimage` (JPEG).
    public static func swisstopoURL(layer: String, tile: MapTile) -> URL? {
        URL(string: "https://wmts.geo.admin.ch/1.0.0/\(layer)/default/current/3857/\(tile.z)/\(tile.x)/\(tile.y).jpeg")
    }

    /// Where a tile lives on disk below a cache folder: `<layer>/<z>/<x>/<y>.jpeg`.
    public static func cachePath(layer: String, tile: MapTile) -> String {
        "\(layer)/\(tile.z)/\(tile.x)/\(tile.y).jpeg"
    }
}
