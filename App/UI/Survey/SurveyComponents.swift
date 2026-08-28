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

/// Which basemap the survey maps draw on.
///
/// Satellite is not decoration here: placing a pin on the exact crack in a road is a
/// question of "which of those two joints is it", and the standard map has neither joint
/// on it.
enum SurveyMapStyle: String, CaseIterable, Hashable {
    case standard
    case satellite

    var title: LocalizedStringKey {
        switch self {
        case .standard: "Karte"
        case .satellite: "Satellit"
        }
    }

    var symbol: String {
        switch self {
        case .standard: "map"
        case .satellite: "globe.europe.africa.fill"
        }
    }
}

extension View {
    @ViewBuilder
    func surveyMapStyle(_ style: SurveyMapStyle) -> some View {
        switch style {
        case .standard: mapStyle(.standard(elevation: .flat))
        case .satellite: mapStyle(.hybrid(elevation: .flat))
        }
    }
}

/// How good a position is, as a colour. The thresholds are what a street needs: a lane is
/// 3 m wide, so ±5 m still says which lane, ±15 m only says which street, and beyond that
/// the pin is a suggestion.
enum PositionQuality {
    case good
    case usable
    case poor
    case none

    init(accuracy: Double?) {
        guard let accuracy, accuracy > 0 else { self = .none; return }
        switch accuracy {
        case ..<5: self = .good
        case ..<15: self = .usable
        default: self = .poor
        }
    }

    var color: Color {
        switch self {
        case .good: Color(red: 0.40, green: 0.85, blue: 0.51)
        case .usable: Color(red: 0.96, green: 0.74, blue: 0.32)
        case .poor: Color(red: 0.95, green: 0.36, blue: 0.36)
        case .none: .secondary
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .good: "gut"
        case .usable: "brauchbar"
        case .poor: "grob"
        case .none: "kein Fix"
        }
    }
}

/// The accuracy of a position, written the way it has to be read: a number, a unit, and
/// where it came from.
struct AccuracyBadge: View {
    let metres: Double?
    var source: PositionSource = .gps
    var compact = false

    var body: some View {
        let quality = PositionQuality(accuracy: metres)
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption2)
            Text(text)
                .font(.caption.monospacedDigit().weight(.semibold))
            if !compact {
                Text(quality.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(source == .manual ? Theme.accent : quality.color)
    }

    private var symbol: String {
        switch source {
        case .gps: "location.fill"
        case .averaged: "scope"
        case .manual: "mappin.circle.fill"
        }
    }

    private var text: String {
        if source == .manual { return String(localized: "Nadel") }
        guard let metres, metres > 0 else { return String(localized: "kein Fix") }
        return metres < 10
            ? String(format: "±%.1f m", metres)
            : String(format: "±%.0f m", metres)
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

/// A map pin whose colour is the judgement, with a mark when the position was set by hand.
struct FindingPin: View {
    let severity: Int
    var isSelected = false
    var isManual = false

    var body: some View {
        let size: CGFloat = isSelected ? 34 : 26
        ZStack {
            Circle()
                .fill(Theme.severity(severity))
                .frame(width: size, height: size)
            Circle()
                .strokeBorder(.white.opacity(isSelected ? 1 : 0.75), lineWidth: isSelected ? 3 : 2)
                .frame(width: size, height: size)
            Text("\(severity)")
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(.black)
        }
        .overlay(alignment: .topTrailing) {
            if isManual {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white, Theme.accent)
                    .offset(x: 4, y: -4)
            }
        }
        .shadow(radius: 3)
    }
}

/// Cases, their marked areas and their position uncertainty on one map.
///
/// `.automatic` framing rather than a computed region: MapKit already knows how to fit the
/// content it is given, and a hand-rolled region is one more thing to get wrong when a
/// walk crosses a degree boundary or holds a single point.
struct SurveyMapView: View {
    let findings: [GroundFinding]
    var selection: UUID?
    var showsUserLocation = true
    var showsUncertainty = true
    var onSelect: ((GroundFinding) -> Void)?

    @State private var position: MapCameraPosition = .automatic
    @State private var style: SurveyMapStyle = .standard

    var body: some View {
        Map(position: $position) {
            ForEach(findings) { finding in
                if let area = finding.area, area.isValid {
                    areaContent(area, severity: finding.severity)
                }
            }
            if showsUncertainty {
                ForEach(findings) { finding in
                    if let radius = finding.uncertaintyRadius, radius > 0 {
                        // What the position is worth, drawn to scale. A pin sitting in a
                        // 30 m circle is a different claim from one sitting in a 3 m circle,
                        // and on a map they otherwise look identical.
                        MapCircle(center: finding.location.coordinate.clCoordinate,
                                  radius: radius)
                            .foregroundStyle(Color.white.opacity(0.08))
                            .stroke(Color.white.opacity(0.5), lineWidth: 1)
                    }
                }
            }
            ForEach(findings) { finding in
                Annotation(finding.label, coordinate: finding.location.coordinate.clCoordinate) {
                    FindingPin(severity: finding.severity,
                               isSelected: finding.id == selection,
                               isManual: finding.positionSource == .manual)
                        .onTapGesture { onSelect?(finding) }
                }
            }
            if showsUserLocation {
                UserAnnotation()
            }
        }
        .surveyMapStyle(style)
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .overlay(alignment: .topLeading) {
            MapStylePicker(style: $style)
                .padding(10)
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

/// Two buttons, not a menu: switching the basemap is something you do while looking for a
/// spot, not something you go into a menu for.
struct MapStylePicker: View {
    @Binding var style: SurveyMapStyle

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SurveyMapStyle.allCases, id: \.self) { candidate in
                Button {
                    style = candidate
                } label: {
                    Label(candidate.title, systemImage: candidate.symbol)
                        .labelStyle(.iconOnly)
                        .font(.footnote.weight(.semibold))
                        .frame(width: 34, height: 30)
                        .foregroundStyle(style == candidate ? Color.black : .primary)
                        .background(style == candidate ? Theme.accent : .clear)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(candidate.title))
            }
        }
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 8))
        .clipShape(.rect(cornerRadius: 8))
    }
}

/// One case as a row: what it is, how bad, how well located, how much of it is documented.
struct FindingRow: View {
    let finding: GroundFinding
    var thumbnail: URL?

    var body: some View {
        HStack(spacing: 12) {
            FindingThumbnail(url: thumbnail, severity: finding.severity)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(finding.label.isEmpty ? String(localized: "Fall") : finding.label)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    SeverityBadge(severity: finding.severity)
                }

                HStack(spacing: 8) {
                    Text(finding.capturedAt.formatted(date: .omitted, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    AccuracyBadge(metres: finding.uncertaintyRadius,
                                  source: finding.positionSource,
                                  compact: true)
                }

                HStack(spacing: 10) {
                    if !finding.photos.isEmpty {
                        Label("\(finding.photos.count)", systemImage: "photo")
                    }
                    if !finding.videos.isEmpty {
                        Label("\(finding.videos.count)", systemImage: "video")
                    }
                    if let area = finding.area, area.isValid {
                        Label("\(Int(area.squareMetres.rounded())) m²", systemImage: "square.dashed")
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The photos and clips of a case, as a scrollable strip.
struct CaseMediaStrip: View {
    let media: [CaseMedia]
    let urlFor: (CaseMedia) -> URL?
    var onSelect: ((CaseMedia) -> Void)?
    var onDelete: ((CaseMedia) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(media) { item in
                    Button {
                        onSelect?(item)
                    } label: {
                        MediaTile(url: urlFor(item), kind: item.kind, duration: item.duration)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if let onDelete {
                            Button(role: .destructive) {
                                onDelete(item)
                            } label: {
                                Label("Entfernen", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// One tile in a media strip: the photo, or a clip's icon and length.
struct MediaTile: View {
    let url: URL?
    let kind: CaseMedia.Kind
    var duration: TimeInterval?
    var size: CGFloat = 84

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Theme.cardBackground
                    .overlay {
                        Image(systemName: kind == .video ? "video.fill" : "photo")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 10))
        .overlay(alignment: .bottomLeading) {
            if kind == .video {
                Text(duration.map { Format.duration($0) } ?? String(localized: "Clip"))
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: .capsule)
                    .padding(5)
            }
        }
        .task(id: url) {
            guard kind == .photo else { return }
            image = await ThumbnailCache.shared.thumbnail(for: url, maxPixel: size * 3)
        }
    }
}

/// The strip on the capture screen: media that exist only in memory so far.
struct PendingMediaStrip: View {
    let media: [PendingMedia]
    var onDelete: (PendingMedia) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(media) { item in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let thumbnail = item.thumbnail {
                                Image(uiImage: thumbnail)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Theme.cardBackground
                                    .overlay {
                                        VStack(spacing: 4) {
                                            Image(systemName: "video.fill")
                                            if let duration = item.duration {
                                                Text(Format.duration(duration))
                                                    .font(.caption2.monospacedDigit())
                                            }
                                        }
                                        .foregroundStyle(.secondary)
                                    }
                            }
                        }
                        .frame(width: 84, height: 84)
                        .clipShape(.rect(cornerRadius: 10))

                        Button {
                            onDelete(item)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .padding(4)
                        .accessibilityLabel(Text("Aufnahme entfernen"))
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// The cover photo of a case at list size, or a coloured placeholder when a case was
/// documented without one.
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

    /// The same for a photo that has just been taken and is not on disk yet.
    func thumbnail(from data: Data, maxPixel: CGFloat) async -> UIImage? {
        let reduced = await Task.detached(priority: .userInitiated) {
            Self.reduce(CGImageSourceCreateWithData(data as CFData, nil), maxPixel: maxPixel)
        }.value
        guard let reduced else { return nil }
        return UIImage(data: reduced)
    }

    nonisolated private static func thumbnailData(at url: URL, maxPixel: CGFloat) -> Data? {
        reduce(CGImageSourceCreateWithURL(url as CFURL, nil), maxPixel: maxPixel)
    }

    nonisolated private static func reduce(_ source: CGImageSource?, maxPixel: CGFloat) -> Data? {
        guard let source else { return nil }
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
