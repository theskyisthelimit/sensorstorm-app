import CoreLocation
import ImageIO
import MapKit
import SensorstormCore
import SwiftUI
import UIKit

extension Coordinate2D {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

extension Theme {
    /// Severity as a colour: green at 1, amber in the middle, red at 10. The same ramp the
    /// KML export writes, so a map on the phone and a map in Google Earth agree.
    static func severity(_ value: Int) -> Color {
        let clamped = GroundFinding.clamp(value)
        let fraction = Double(clamped - 1) / 9
        return Color(hue: 0.33 * (1 - fraction), saturation: 0.85, brightness: 0.95)
    }
}

enum SeverityWording {
    /// A number sorts and averages; a word tells the person holding the phone whether they
    /// picked the one they meant.
    static func label(for severity: Int) -> LocalizedStringKey {
        switch GroundFinding.clamp(severity) {
        case 1, 2: "unauffällig"
        case 3, 4: "leicht"
        case 5, 6: "deutlich"
        case 7, 8: "schwer"
        default: "kritisch"
        }
    }
}

/// The 1…10 judgement, as ten targets you can hit while walking.
struct SeverityPicker: View {
    @Binding var severity: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Bewertung")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Text("\(severity)/10")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Theme.severity(severity))
                Text(SeverityWording.label(for: severity))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                ForEach(GroundFinding.severityRange, id: \.self) { value in
                    Button {
                        severity = value
                    } label: {
                        Text("\(value)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(value <= severity ? .black : .secondary)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(value <= severity ? Theme.severity(value) : Theme.cardBorder,
                                        in: .rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Bewertung \(value)"))
                }
            }
        }
    }
}

/// The severity as it appears in lists and on the map.
struct SeverityBadge: View {
    let severity: Int
    var compact = false

    var body: some View {
        Text(compact ? "\(severity)" : "\(severity)/10")
            .font(.caption.monospacedDigit().weight(.bold))
            .foregroundStyle(.black)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 2 : 4)
            .background(Theme.severity(severity), in: .capsule)
    }
}

/// A map pin whose colour is the judgement.
struct FindingPin: View {
    let severity: Int
    var isSelected = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.severity(severity))
                .frame(width: isSelected ? 34 : 26, height: isSelected ? 34 : 26)
            Circle()
                .strokeBorder(.white.opacity(isSelected ? 1 : 0.75), lineWidth: isSelected ? 3 : 2)
                .frame(width: isSelected ? 34 : 26, height: isSelected ? 34 : 26)
            Text("\(severity)")
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(.black)
        }
        .shadow(radius: 3)
    }
}

/// Findings and their marked areas on one map.
///
/// `.automatic` framing rather than a computed region: MapKit already knows how to fit the
/// content it is given, and a hand-rolled region is one more thing to get wrong when a
/// walk crosses a degree boundary or holds a single point.
struct SurveyMapView: View {
    let findings: [GroundFinding]
    var selection: UUID?
    var showsUserLocation = true
    var onSelect: ((GroundFinding) -> Void)?

    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position) {
            ForEach(findings) { finding in
                if let area = finding.area, area.isValid {
                    areaContent(area, severity: finding.severity)
                }
            }
            ForEach(findings) { finding in
                Annotation(finding.label, coordinate: finding.location.coordinate.clCoordinate) {
                    FindingPin(severity: finding.severity, isSelected: finding.id == selection)
                        .onTapGesture { onSelect?(finding) }
                }
            }
            if showsUserLocation {
                UserAnnotation()
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
    }

    @MapContentBuilder
    private func areaContent(_ area: FindingArea, severity: Int) -> some MapContent {
        switch area.kind {
        case .circle:
            if let center = area.center {
                MapCircle(center: center.clCoordinate, radius: area.radius)
                    .foregroundStyle(Theme.severity(severity).opacity(0.25))
                    .stroke(Theme.severity(severity), lineWidth: 2)
            }
        case .polygon:
            MapPolygon(coordinates: area.points.map(\.clCoordinate))
                .foregroundStyle(Theme.severity(severity).opacity(0.25))
                .stroke(Theme.severity(severity), lineWidth: 2)
        }
    }
}

/// One finding as a row: what it is, how bad, how well located.
struct FindingRow: View {
    let finding: GroundFinding
    var thumbnail: URL?

    var body: some View {
        HStack(spacing: 12) {
            FindingThumbnail(url: thumbnail, severity: finding.severity)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(finding.label.isEmpty ? String(localized: "Befund") : finding.label)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    SeverityBadge(severity: finding.severity)
                }

                Text(finding.capturedAt.formatted(date: .omitted, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    if finding.location.horizontalAccuracy > 0 {
                        Label(String(format: "±%.0f m", finding.location.horizontalAccuracy),
                              systemImage: "location.fill")
                    }
                    if let area = finding.area, area.isValid {
                        Label("\(Int(area.squareMetres.rounded())) m²", systemImage: "square.dashed")
                    }
                    if finding.videoFileName != nil {
                        Image(systemName: "video.fill")
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The photo, or a coloured placeholder when a finding was recorded without one.
struct FindingThumbnail: View {
    let url: URL?
    let severity: Int
    var size: CGFloat = 56

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Theme.severity(severity).opacity(0.25)
                    .overlay {
                        Image(systemName: url == nil ? "mappin" : "camera.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 10))
        .task(id: url) {
            image = await ThumbnailCache.shared.thumbnail(for: url, maxPixel: size * 3)
        }
    }
}

/// The photo at reading size: the whole frame, not a square crop of it.
struct FindingPhotoView: View {
    let url: URL?
    let severity: Int
    var maxHeight: CGFloat = 340

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: maxHeight)
                    .clipShape(.rect(cornerRadius: 16))
            } else {
                Theme.severity(severity).opacity(0.2)
                    .frame(height: 180)
                    .overlay {
                        ProgressView()
                    }
                    .clipShape(.rect(cornerRadius: 16))
            }
        }
        .task(id: url) {
            image = await ThumbnailCache.shared.thumbnail(for: url, maxPixel: 1600)
        }
    }
}

/// Downsampled photos for the lists.
///
/// A finding's photo is an eight-megapixel JPEG. Decoding a dozen of them on the main
/// thread to draw 56-point squares is exactly how a list starts stuttering, so ImageIO
/// makes the thumbnails off the main actor and they are kept for the session.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private var images: [String: UIImage] = [:]

    func thumbnail(for url: URL?, maxPixel: CGFloat) async -> UIImage? {
        guard let url else { return nil }
        let key = "\(url.path)|\(Int(maxPixel))"
        if let cached = images[key] { return cached }

        // Only the encoded bytes cross the actor boundary; the decoded image is built here.
        let data = await Task.detached(priority: .utility) {
            Self.thumbnailData(at: url, maxPixel: maxPixel)
        }.value
        guard let data, let image = UIImage(data: data) else { return nil }
        images[key] = image
        return image
    }

    nonisolated private static func thumbnailData(at url: URL, maxPixel: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 64)
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.9)
    }
}
