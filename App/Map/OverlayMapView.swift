@preconcurrency import MapKit
import SensorstormCore
import SwiftUI

/// A `MKMapView` for the things SwiftUI's `Map` cannot do: a tile layer from another
/// provider, and a track drawn in many colours.
///
/// Everything it draws is handed in as plain values and compared by a signature, so a
/// SwiftUI refresh that changes nothing does not tear the map down and re-frame it — which
/// is the difference between a map that can be panned and one that snaps back every second.
struct OverlayMapView: UIViewRepresentable {

    struct Pin: Equatable {
        var id: String
        var coordinate: CLLocationCoordinate2D
        var title: String
        var color: UIColor
        var glyph: String
        var isClosed = false

        static func == (lhs: Pin, rhs: Pin) -> Bool {
            lhs.id == rhs.id && lhs.coordinate.latitude == rhs.coordinate.latitude
                && lhs.coordinate.longitude == rhs.coordinate.longitude && lhs.color == rhs.color
                && lhs.isClosed == rhs.isClosed && lhs.glyph == rhs.glyph
        }
    }

    struct Line: Equatable {
        var coordinates: [CLLocationCoordinate2D]
        var color: UIColor
        var width: CGFloat = 4

        static func == (lhs: Line, rhs: Line) -> Bool {
            lhs.color == rhs.color && lhs.width == rhs.width && lhs.coordinates.count == rhs.coordinates.count
                && lhs.coordinates.first?.latitude == rhs.coordinates.first?.latitude
                && lhs.coordinates.last?.latitude == rhs.coordinates.last?.latitude
        }
    }

    struct Area: Equatable {
        var coordinates: [CLLocationCoordinate2D]
        var color: UIColor

        static func == (lhs: Area, rhs: Area) -> Bool {
            lhs.color == rhs.color && lhs.coordinates.count == rhs.coordinates.count
                && lhs.coordinates.first?.latitude == rhs.coordinates.first?.latitude
        }
    }

    enum Basemap: Equatable {
        case apple
        case swisstopo(layer: String)
    }

    var basemap: Basemap = .apple
    var pins: [Pin] = []
    var lines: [Line] = []
    var areas: [Area] = []
    var showsUserLocation = false
    var onSelect: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let view = MKMapView()
        view.delegate = context.coordinator
        view.pointOfInterestFilter = .excludingAll
        view.overrideUserInterfaceStyle = .dark
        return view
    }

    func updateUIView(_ view: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        view.showsUserLocation = showsUserLocation

        if coordinator.basemap != basemap {
            coordinator.basemap = basemap
            if let overlay = coordinator.tileOverlay { view.removeOverlay(overlay) }
            coordinator.tileOverlay = nil
            if case .swisstopo(let layer) = basemap {
                let overlay = SwisstopoTileOverlay(layer: layer)
                coordinator.tileOverlay = overlay
                view.addOverlay(overlay, level: .aboveLabels)
            }
            // The tile layer has to sit under what is drawn on it: draw the content again,
            // after it.
            coordinator.signature = nil
        }

        let signature = Coordinator.Signature(pins: pins, lines: lines, areas: areas)
        guard coordinator.signature != signature else { return }
        let isFirst = !coordinator.hasFramed
        coordinator.hasFramed = true
        coordinator.signature = signature

        // Content only; the tile layer is managed above and must survive a redraw.
        view.removeAnnotations(view.annotations.filter { $0 is PinAnnotation })
        view.removeOverlays(view.overlays.filter { !($0 is MKTileOverlay) })

        for pin in pins {
            let annotation = PinAnnotation(pin: pin)
            view.addAnnotation(annotation)
        }
        for line in lines where line.coordinates.count >= 2 {
            view.addOverlay(ColoredPolyline(coordinates: line.coordinates, count: line.coordinates.count)
                .styled(color: line.color, width: line.width), level: .aboveLabels)
        }
        for area in areas where area.coordinates.count >= 3 {
            view.addOverlay(ColoredPolygon(coordinates: area.coordinates, count: area.coordinates.count)
                .styled(color: area.color), level: .aboveLabels)
        }
        if isFirst { frame(view) }
    }

    /// Frames everything that was drawn, once. After that the person's own panning rules.
    private func frame(_ view: MKMapView) {
        var rect = MKMapRect.null
        for pin in pins { rect = rect.union(MKMapRect(origin: MKMapPoint(pin.coordinate), size: MKMapSize(width: 1, height: 1))) }
        for line in lines { for point in line.coordinates { rect = rect.union(MKMapRect(origin: MKMapPoint(point), size: MKMapSize(width: 1, height: 1))) } }
        for area in areas { for point in area.coordinates { rect = rect.union(MKMapRect(origin: MKMapPoint(point), size: MKMapSize(width: 1, height: 1))) } }
        guard !rect.isNull else { return }
        view.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 50, left: 40, bottom: 40, right: 40), animated: false)
    }

    // MARK: - Pieces

    final class PinAnnotation: NSObject, MKAnnotation {
        let pin: Pin
        var coordinate: CLLocationCoordinate2D { pin.coordinate }
        var title: String? { pin.title }

        init(pin: Pin) {
            self.pin = pin
        }
    }

    final class ColoredPolyline: MKPolyline {
        var color: UIColor = .systemBlue
        var width: CGFloat = 4

        func styled(color: UIColor, width: CGFloat) -> ColoredPolyline {
            self.color = color
            self.width = width
            return self
        }
    }

    final class ColoredPolygon: MKPolygon {
        var color: UIColor = .systemRed

        func styled(color: UIColor) -> ColoredPolygon {
            self.color = color
            return self
        }
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        struct Signature: Equatable {
            var pins: [Pin]
            var lines: [Line]
            var areas: [Area]
        }

        var basemap: Basemap = .apple
        var tileOverlay: MKTileOverlay?
        var signature: Signature?
        var hasFramed = false
        var onSelect: ((String) -> Void)?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            switch overlay {
            case let tiles as MKTileOverlay:
                return MKTileOverlayRenderer(tileOverlay: tiles)
            case let line as ColoredPolyline:
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = line.color
                renderer.lineWidth = line.width
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            case let area as ColoredPolygon:
                let renderer = MKPolygonRenderer(polygon: area)
                renderer.fillColor = area.color.withAlphaComponent(0.25)
                renderer.strokeColor = area.color
                renderer.lineWidth = 2
                return renderer
            default:
                return MKOverlayRenderer(overlay: overlay)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let pinAnnotation = annotation as? PinAnnotation else { return nil }
            let identifier = "pin"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.markerTintColor = pinAnnotation.pin.isClosed ? .systemGray : pinAnnotation.pin.color
            view.glyphText = pinAnnotation.pin.glyph
            view.canShowCallout = true
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            guard let pinAnnotation = annotation as? PinAnnotation else { return }
            onSelect?(pinAnnotation.pin.id)
        }
    }
}
