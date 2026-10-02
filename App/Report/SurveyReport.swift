import MapKit
import SensorstormCore
import UIKit

/// The walk as a document a client, a council or an insurer accepts: who walked, when, how far,
/// what was found and where, with a photo of each.
///
/// Two outcomes are written down with equal care. A walk with findings is a list of them. A
/// walk without any is a **proof of control** — the path, the times and the statement that
/// nothing was found — because for a municipality that has to show it inspected its roads,
/// „nothing found" is exactly the thing that needs a document.
@MainActor
enum SurveyReport {

    struct Input {
        var survey: Survey
        var catalog: FindingCatalog?
        var inspector: String
        var organisation: String
        var history: (GroundFinding) -> [FindingHistory.Entry]
        var photoURL: (CaseMedia) -> URL?
        var anonymises: Bool
        var includesResolved: Bool
    }

    static func render(_ input: Input) async -> URL? {
        let survey = input.survey
        let findings = survey.findingsByTime.filter { input.includesResolved || $0.status.isOutstanding }
        let map = await mapSnapshot(survey: survey, findings: findings)

        // Photos are read before drawing: the canvas is main-actor and the anonymiser is not
        // quick, so a report of forty photos should not freeze a scroll view for a minute.
        var thumbnails: [UUID: UIImage] = [:]
        for finding in findings {
            guard let cover = finding.coverPhoto, let url = input.photoURL(cover) else { continue }
            if let image = await Task.detached(priority: .userInitiated, operation: {
                Self.loadPhoto(url, anonymise: input.anonymises)
            }).value {
                thumbnails[finding.id] = image
            }
        }

        let language = CatalogStore.language
        let footer = "\(survey.name) · Sensorstorm"
        let data = ReportCanvas.render(footer: footer) { canvas in
            // Cover
            canvas.title(String(localized: "Begehungsprotokoll"))
            canvas.text(survey.name, font: .systemFont(ofSize: 15, weight: .medium), after: 10)
            canvas.row(String(localized: "Beginn"), survey.startedAt.formatted(date: .complete, time: .shortened))
            canvas.row(String(localized: "Ende"), survey.endedAt?.formatted(date: .complete, time: .shortened)
                       ?? String(localized: "nicht abgeschlossen"))
            if !input.inspector.isEmpty { canvas.row(String(localized: "Geprüft von"), input.inspector) }
            if !input.organisation.isEmpty { canvas.row(String(localized: "Organisation"), input.organisation) }
            if let catalog = input.catalog {
                canvas.row(String(localized: "Katalog"), catalog.name.resolve(language))
            }
            if survey.track.count >= 2 {
                canvas.row(String(localized: "Begangener Weg"),
                           "\(Self.length(survey.trackLength)) · \(Self.duration(survey.trackDuration))")
            }
            if let first = survey.track.first {
                canvas.row(String(localized: "Ausgangspunkt"), Self.coordinates(first.latitude, first.longitude))
            }
            if !survey.notes.isEmpty { canvas.row(String(localized: "Notiz"), survey.notes) }

            canvas.heading(String(localized: "Zusammenfassung"))
            if survey.findings.isEmpty {
                canvas.text(String(localized: "Bei der Begehung wurden keine Mängel festgestellt."),
                            font: .systemFont(ofSize: 12, weight: .medium), after: 6)
                if survey.track.count >= 2 {
                    canvas.text(String(localized: "Der Weg wurde zwischen \(survey.track[0].time.formatted(date: .omitted, time: .shortened)) und \(survey.track[survey.track.count - 1].time.formatted(date: .omitted, time: .shortened)) begangen und ist auf der Karte eingetragen."),
                                font: .systemFont(ofSize: 10), color: .darkGray)
                }
            } else {
                canvas.row(String(localized: "Beobachtungen"), "\(survey.findings.count)")
                for status in FindingStatus.allCases {
                    let count = survey.findings.count { $0.status == status }
                    if count > 0 { canvas.row(status.reportTitle, "\(count)") }
                }
                if let worst = survey.worstSeverity { canvas.row(String(localized: "Schlimmster Fall"), "\(worst)/10") }
                if let average = survey.averageSeverity { canvas.row(String(localized: "Durchschnitt"), String(format: "%.1f/10", average)) }
                if survey.markedSquareMetres > 0 {
                    canvas.row(String(localized: "Markierte Fläche"), "\(Int(survey.markedSquareMetres.rounded())) m²")
                }
            }
            if let map {
                canvas.space(6)
                canvas.image(map, maxWidth: canvas.contentWidth, maxHeight: 300, after: 4)
            }

            // The cases
            if !findings.isEmpty {
                canvas.heading(String(localized: "Beobachtungen"))
            }
            for (index, finding) in findings.enumerated() {
                Self.draw(finding, number: index + 1, canvas: canvas, thumbnail: thumbnails[finding.id],
                          catalog: input.catalog, language: language, history: input.history(finding))
            }

            // Signature
            canvas.ensure(70)
            canvas.space(24)
            canvas.rule()
            canvas.text(String(localized: "Ort, Datum, Unterschrift"), font: .systemFont(ofSize: 8), color: .gray)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("\(RecordingExporter.sanitize(survey.name)).pdf")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - One case

    private static func draw(_ finding: GroundFinding, number: Int, canvas: ReportCanvas, thumbnail: UIImage?,
                             catalog: FindingCatalog?, language: String, history: [FindingHistory.Entry]) {
        canvas.ensure(150)
        let title = "\(number). \(finding.label.isEmpty ? String(localized: "Beobachtung") : finding.label)"
        canvas.imageBeside(thumbnail, width: 150, height: 112) { indent in
            canvas.text(title, font: .systemFont(ofSize: 12, weight: .semibold), indent: indent, after: 2)
            canvas.text("\(String(localized: "Schweregrad")) \(finding.severity)/10 · \(finding.status.reportTitle)",
                        font: .systemFont(ofSize: 10, weight: .medium), color: finding.status.isOutstanding ? .systemRed : .darkGray,
                        indent: indent, after: 2)
            canvas.text(finding.capturedAt.formatted(date: .abbreviated, time: .shortened),
                        font: .systemFont(ofSize: 9), color: .darkGray, indent: indent, after: 2)
            if let address = finding.address, !address.singleLine.isEmpty {
                canvas.text(address.singleLine, font: .systemFont(ofSize: 9), indent: indent, after: 2)
            }
            canvas.text(coordinates(finding.location.latitude, finding.location.longitude)
                        + (finding.location.horizontalAccuracy > 0 ? String(format: " (±%.0f m)", finding.location.horizontalAccuracy) : ""),
                        font: .monospacedDigitSystemFont(ofSize: 8, weight: .regular), color: .darkGray, indent: indent, after: 1)
            let lv95 = finding.location.lv95
            canvas.text(String(format: "LV95 %.0f / %.0f", lv95.east, lv95.north),
                        font: .monospacedDigitSystemFont(ofSize: 8, weight: .regular), color: .darkGray, indent: indent, after: 2)
        }
        if let catalog {
            for line in catalog.describe(finding.attributes, entryKey: finding.attributes[FindingCatalog.entryAttribute], language: language) {
                canvas.row(line.title, line.value, keyWidth: 110)
            }
        }
        for measurement in finding.measurements {
            canvas.row(measurementTitle(measurement.kind), MeasurementsCard.value(measurement), keyWidth: 110)
        }
        if let area = finding.area, area.isValid {
            canvas.row(String(localized: "Fläche"), "\(Int(area.squareMetres.rounded())) m²", keyWidth: 110)
        }
        if let volume = finding.volumeCubicMetres {
            canvas.row(String(localized: "Volumen"), String(format: "%.3f m³", volume), keyWidth: 110)
        }
        if !finding.note.isEmpty { canvas.row(String(localized: "Notiz"), finding.note, keyWidth: 110) }
        if !finding.resolutionNote.isEmpty { canvas.row(String(localized: "Erledigung"), finding.resolutionNote, keyWidth: 110) }
        if history.count >= 2 {
            let trail = history.map { "\($0.date.formatted(date: .numeric, time: .omitted)): \($0.severity)/10" }.joined(separator: "  →  ")
            canvas.row(String(localized: "Verlauf"), trail, keyWidth: 110)
        }
        canvas.space(8)
    }

    private static func measurementTitle(_ kind: CaseMeasurement.Kind) -> String {
        switch kind {
        case .slope: String(localized: "Neigung")
        case .depth: String(localized: "Tiefe")
        case .length: String(localized: "Länge")
        case .width: String(localized: "Breite")
        case .count: String(localized: "Stückzahl")
        case .other: String(localized: "Sonstiges")
        }
    }

    // MARK: - Helpers

    nonisolated private static func loadPhoto(_ url: URL, anonymise: Bool) -> UIImage? {
        if anonymise {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("report-\(UUID().uuidString).jpg")
            defer { try? FileManager.default.removeItem(at: scratch) }
            if (try? PhotoAnonymizer.anonymise(url, to: scratch)) != nil, let image = UIImage(contentsOfFile: scratch.path) {
                return downscaled(image)
            }
            // Never fall back to the original when blurring was asked for.
            return nil
        }
        return UIImage(contentsOfFile: url.path).map(downscaled)
    }

    /// Reports carry thumbnails, not 12-megapixel originals: a forty-case PDF would be 200 MB.
    nonisolated private static func downscaled(_ image: UIImage) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > 900 else { return image }
        let scale = 900 / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    static func coordinates(_ latitude: Double, _ longitude: Double) -> String {
        String(format: "%.5f° N, %.5f° E", latitude, longitude)
    }

    static func length(_ metres: Double) -> String {
        metres >= 1_000 ? String(format: "%.2f km", metres / 1_000) : String(format: "%.0f m", metres)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 3_600 ? String(format: "%d:%02d h", total / 3_600, total % 3_600 / 60)
            : String(format: "%d:%02d min", total / 60, total % 60)
    }

    /// The map of the walk as a picture: the path in blue, a numbered dot per finding.
    private static func mapSnapshot(survey: Survey, findings: [GroundFinding]) async -> UIImage? {
        guard let bounds = survey.bounds else { return nil }
        let span = MKCoordinateSpan(latitudeDelta: max(bounds.latitudeSpan * 1.4, 0.0015),
                                    longitudeDelta: max(bounds.longitudeSpan * 1.4, 0.0015))
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: bounds.center.clCoordinate, span: span)
        options.size = CGSize(width: 520, height: 300)
        options.traitCollection = UITraitCollection(userInterfaceStyle: .light)
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }

        return UIGraphicsImageRenderer(size: options.size).image { context in
            snapshot.image.draw(at: .zero)
            if survey.track.count >= 2 {
                let path = UIBezierPath()
                for (index, point) in survey.track.enumerated() {
                    let position = snapshot.point(for: point.coordinate.clCoordinate)
                    if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
                }
                UIColor.systemBlue.setStroke()
                path.lineWidth = 3
                path.lineJoinStyle = .round
                path.stroke()
            }
            for (index, finding) in findings.enumerated() {
                let position = snapshot.point(for: finding.location.coordinate.clCoordinate)
                let radius: CGFloat = 8
                let rect = CGRect(x: position.x - radius, y: position.y - radius, width: radius * 2, height: radius * 2)
                (finding.status.isOutstanding ? UIColor.systemRed : UIColor.gray).setFill()
                UIBezierPath(ovalIn: rect).fill()
                UIColor.white.setStroke()
                let ring = UIBezierPath(ovalIn: rect)
                ring.lineWidth = 1.5
                ring.stroke()
                let label = "\(index + 1)" as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8, weight: .bold), .foregroundColor: UIColor.white]
                let size = label.size(withAttributes: attributes)
                label.draw(at: CGPoint(x: position.x - size.width / 2, y: position.y - size.height / 2), withAttributes: attributes)
            }
        }
    }
}

extension FindingStatus {
    /// Plain words for a document.
    var reportTitle: String {
        switch self {
        case .open: String(localized: "Offen")
        case .scheduled: String(localized: "Geplant")
        case .resolved: String(localized: "Erledigt")
        case .noAction: String(localized: "Kein Handlungsbedarf")
        }
    }
}
