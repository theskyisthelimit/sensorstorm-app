import CoreLocation
import Foundation
import SensorstormCore

/// Turns a coordinate into an address — only when asked, and only by sending that one
/// coordinate to a third party.
///
/// In Switzerland the federal building register answers first: it names the nearest
/// building with its EGID, which is what an office joins on. Anywhere else, and where the
/// register finds nothing within 20 m, Apple's geocoder answers. Which one did is written
/// into the address, because they do not always agree on a house number.
///
/// Nothing here runs by itself. `RecordingSettings.looksUpAddresses` is the consent for the
/// automatic lookup after saving a case; the button on a case is its own.
enum AddressLookup {
    static func address(for coordinate: Coordinate2D) async -> PostalAddress? {
        if let url = SwisstopoAddress.identifyURL(for: coordinate),
           let swiss = await swisstopo(url, near: coordinate) {
            return swiss
        }
        return await apple(coordinate)
    }

    private static func swisstopo(_ url: URL, near coordinate: Coordinate2D) async -> PostalAddress? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return SwisstopoAddress.parse(data, near: coordinate)
    }

    private static func apple(_ coordinate: Coordinate2D) async -> PostalAddress? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else {
            return nil
        }
        let address = PostalAddress(street: placemark.thoroughfare,
                                    houseNumber: placemark.subThoroughfare,
                                    postcode: placemark.postalCode,
                                    locality: placemark.locality,
                                    country: placemark.isoCountryCode,
                                    source: "apple")
        return address.isEmpty ? nil : address
    }

    /// Walking directions to a coordinate in Apple Maps, as a link — handed to `openURL`
    /// instead of constructing a map item, whose initialisers are being replaced.
    static func directionsURL(to coordinate: Coordinate2D, name: String) -> URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "daddr", value: String(format: "%.6f,%.6f", coordinate.latitude, coordinate.longitude)),
            URLQueryItem(name: "dirflg", value: "w"),
            URLQueryItem(name: "q", value: name),
        ]
        return components?.url
    }
}
