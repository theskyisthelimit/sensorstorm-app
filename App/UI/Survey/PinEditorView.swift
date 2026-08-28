import MapKit
import SensorstormCore
import SwiftUI

/// Placing the pin by hand.
///
/// GPS on a street is a circle, not a point: between buildings ±10 m is a good day, and a
/// damage report that says "somewhere in this circle" is a report somebody has to search
/// for. Anyone standing in front of the crack can see on an aerial image exactly which
/// joint it is — so the map moves under a fixed crosshair, which is both the most precise
/// way to point at something on a phone and the only one that keeps the finger out of the
/// way of the target.
///
/// What GPS said is kept and drawn: the fix, its accuracy circle, and how far the pin ended
/// up from it. A corrected position that hides the measurement it replaced would be worth
/// less than either of the two on its own.
struct PinEditorView: View {
    /// The GPS fix, drawn with its accuracy circle. `nil` when there never was one.
    let measured: FindingLocation?
    let initial: Coordinate2D
    let onApply: (Coordinate2D) -> Void
    var onReset: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var position: MapCameraPosition
    @State private var center: Coordinate2D
    @State private var style: SurveyMapStyle = .satellite

    init(measured: FindingLocation?,
         initial: Coordinate2D,
         onApply: @escaping (Coordinate2D) -> Void,
         onReset: (() -> Void)? = nil) {
        self.measured = measured
        self.initial = initial
        self.onApply = onApply
        self.onReset = onReset
        // 60 m across: close enough that one metre is a visible distance on screen.
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: initial.clCoordinate,
            latitudinalMeters: 60, longitudinalMeters: 60)))
        _center = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            // The map sits above the panel rather than behind it: the crosshair marks the
            // centre of the map's frame, and a frame that ran under the panel would put the
            // crosshair somewhere the camera centre is not.
            VStack(spacing: 0) {
                ZStack {
                    map
                    crosshair
                }
                panel
            }
            .navigationTitle("Nadel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Übernehmen") {
                        onApply(center)
                        dismiss()
                    }
                    .disabled(!center.isValid)
                }
            }
        }
    }

    // MARK: - Map

    private var map: some View {
        Map(position: $position) {
            if let measured, measured.coordinate.isValid {
                if measured.horizontalAccuracy > 0 {
                    MapCircle(center: measured.coordinate.clCoordinate,
                              radius: measured.horizontalAccuracy)
                        .foregroundStyle(Color.white.opacity(0.10))
                        .stroke(Color.white.opacity(0.6), lineWidth: 1)
                }
                Annotation("GPS", coordinate: measured.coordinate.clCoordinate) {
                    Image(systemName: "location.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, Theme.accent)
                        .shadow(radius: 2)
                }
            }
            UserAnnotation()
        }
        .surveyMapStyle(style)
        .mapControls {
            MapUserLocationButton()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .continuous) { context in
            center = Coordinate2D(context.camera.centerCoordinate)
        }
        .overlay(alignment: .topLeading) {
            MapStylePicker(style: $style)
                .padding(10)
        }
    }

    /// Deliberately open in the middle: a filled marker would cover the very thing being
    /// pointed at.
    private var crosshair: some View {
        ZStack {
            Circle()
                .strokeBorder(Theme.accent, lineWidth: 2)
                .frame(width: 34, height: 34)
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 1, height: 14)
                .offset(y: -24)
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 1, height: 14)
                .offset(y: 24)
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 14, height: 1)
                .offset(x: -24)
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 14, height: 1)
                .offset(x: 24)
            Circle()
                .fill(Theme.accent)
                .frame(width: 3, height: 3)
        }
        .shadow(radius: 3)
        .allowsHitTesting(false)
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(Format.coordinate(center.latitude)), \(Format.coordinate(center.longitude))")
                    .font(.caption.monospacedDigit())
                Spacer(minLength: 0)
                if let offset = offsetFromFix {
                    Label(offset < 10
                          ? String(format: "%.1f m vom Fix", offset)
                          : String(format: "%.0f m vom Fix", offset),
                          systemImage: "arrow.left.and.right")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(offset > 25 ? .orange : .secondary)
                }
            }

            Text("Karte unter das Fadenkreuz schieben. Der GPS-Fix und sein Genauigkeitskreis bleiben sichtbar und werden mitgespeichert.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack(spacing: 12) {
                if let onReset {
                    Button {
                        onReset()
                        dismiss()
                    } label: {
                        Label("Zurück auf GPS", systemImage: "location.fill")
                            .font(.caption.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                }

                Button {
                    guard let measured, measured.coordinate.isValid else { return }
                    withAnimation {
                        position = .region(MKCoordinateRegion(
                            center: measured.coordinate.clCoordinate,
                            latitudinalMeters: 60, longitudinalMeters: 60))
                    }
                } label: {
                    Label("Zum Fix", systemImage: "scope")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .disabled(measured?.coordinate.isValid != true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var offsetFromFix: Double? {
        guard let measured, measured.coordinate.isValid, center.isValid else { return nil }
        return measured.coordinate.distance(to: center)
    }
}
