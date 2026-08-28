import MapKit
import SensorstormCore
import SwiftUI

/// Marking how far a finding reaches.
///
/// Two ways, because the field offers two situations. A circle is one slider and covers the
/// common case — "everything within about four metres of where I am standing". A polygon is
/// for when the shape matters: tap the corners on the map, or walk the edge and drop a point
/// at each turn with the phone's own position.
struct AreaEditorView: View {
    @Environment(SurveyModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let center: Coordinate2D
    @Binding var area: FindingArea?

    @State private var kind: FindingArea.Kind
    @State private var circleCenter: Coordinate2D
    @State private var radius: Double
    @State private var points: [Coordinate2D]
    @State private var position: MapCameraPosition

    init(center: Coordinate2D, area: Binding<FindingArea?>) {
        self.center = center
        _area = area

        let existing = area.wrappedValue
        let isCircle = existing?.kind != .polygon
        _kind = State(initialValue: existing?.kind ?? .circle)
        _circleCenter = State(initialValue: isCircle ? (existing?.points.first ?? center) : center)
        _radius = State(initialValue: max(existing?.radius ?? 5, 1))
        _points = State(initialValue: existing?.kind == .polygon ? (existing?.points ?? []) : [])
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: center.clCoordinate,
            latitudinalMeters: 150, longitudinalMeters: 150)))
    }

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $position) {
                    mapContent
                    UserAnnotation()
                }
                .mapControls {
                    MapUserLocationButton()
                    MapScaleView()
                }
                .onTapGesture { point in
                    guard let coordinate = proxy.convert(point, from: .local) else { return }
                    handleTap(Coordinate2D(coordinate))
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .safeAreaInset(edge: .bottom, spacing: 0) { controls }
            .task { model.location.acquire() }
            .onDisappear { model.location.release() }
            .navigationTitle("Bereich")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        area = builtArea
                        dismiss()
                    }
                    .disabled(builtArea == nil)
                }
            }
        }
    }

    // MARK: - Map

    @MapContentBuilder
    private var mapContent: some MapContent {
        switch kind {
        case .circle:
            MapCircle(center: circleCenter.clCoordinate, radius: max(radius, 1))
                .foregroundStyle(Theme.accent.opacity(0.25))
                .stroke(Theme.accent, lineWidth: 2)
            Annotation("Mittelpunkt", coordinate: circleCenter.clCoordinate) {
                Image(systemName: "scope")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
            }
        case .polygon:
            if points.count >= 3 {
                MapPolygon(coordinates: points.map(\.clCoordinate))
                    .foregroundStyle(Theme.accent.opacity(0.25))
                    .stroke(Theme.accent, lineWidth: 2)
            } else if points.count == 2 {
                MapPolyline(coordinates: points.map(\.clCoordinate))
                    .stroke(Theme.accent, lineWidth: 2)
            }
            ForEach(indexedPoints) { point in
                Annotation("Punkt", coordinate: point.coordinate.clCoordinate) {
                    Text("\(point.id + 1)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(.black)
                        .frame(width: 22, height: 22)
                        .background(Theme.accent, in: .circle)
                }
            }
        }
    }

    private var indexedPoints: [IndexedPoint] {
        points.enumerated().map { IndexedPoint(id: $0.offset, coordinate: $0.element) }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 12) {
            Picker("Form", selection: $kind) {
                Text("Kreis").tag(FindingArea.Kind.circle)
                Text("Polygon").tag(FindingArea.Kind.polygon)
            }
            .pickerStyle(.segmented)

            switch kind {
            case .circle:
                circleControls
            case .polygon:
                polygonControls
            }

            HStack {
                Text(summary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if area != nil {
                    Button("Bereich entfernen", role: .destructive) {
                        area = nil
                        dismiss()
                    }
                    .font(.caption)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var circleControls: some View {
        VStack(spacing: 6) {
            Slider(value: $radius, in: 1...100, step: 1) {
                Text("Radius")
            } minimumValueLabel: {
                Text("1 m").font(.caption2)
            } maximumValueLabel: {
                Text("100 m").font(.caption2)
            }
            .tint(Theme.accent)

            Text("Tippe auf die Karte, um den Mittelpunkt zu versetzen.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var polygonControls: some View {
        HStack(spacing: 10) {
            Button {
                addCurrentPosition()
            } label: {
                Label("Meine Position", systemImage: "location.fill")
                    .font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .disabled(model.location.fix?.isUsable != true)

            Button {
                if !points.isEmpty { points.removeLast() }
            } label: {
                Label("Zurück", systemImage: "arrow.uturn.backward")
                    .font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .disabled(points.isEmpty)

            Button(role: .destructive) {
                points.removeAll()
            } label: {
                Label("Leeren", systemImage: "trash")
                    .font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .disabled(points.isEmpty)
        }
    }

    private var summary: String {
        guard let built = builtArea else {
            return kind == .polygon
                ? String(localized: "Mindestens 3 Punkte antippen oder ablaufen")
                : String(localized: "Radius wählen")
        }
        let squareMetres = Int(built.squareMetres.rounded())
        return kind == .circle
            ? String(localized: "Kreis · \(Int(radius)) m Radius · \(squareMetres) m²")
            : String(localized: "Polygon · \(points.count) Punkte · \(squareMetres) m²")
    }

    // MARK: - Editing

    private var builtArea: FindingArea? {
        let candidate: FindingArea = switch kind {
        case .circle: .circle(center: circleCenter, radius: radius)
        case .polygon: .polygon(points)
        }
        return candidate.isValid ? candidate : nil
    }

    private func handleTap(_ coordinate: Coordinate2D) {
        switch kind {
        case .circle:
            circleCenter = coordinate
        case .polygon:
            points.append(coordinate)
        }
    }

    /// Walking the edge: every stop adds the corner the phone is standing on.
    private func addCurrentPosition() {
        guard let fix = model.location.fix, fix.isUsable else { return }
        points.append(fix.coordinate)
    }
}

/// A polygon corner with a stable identity for the map's `ForEach` — its position in the
/// ring, which is also what the numbered marker shows.
private struct IndexedPoint: Identifiable {
    let id: Int
    let coordinate: Coordinate2D
}
