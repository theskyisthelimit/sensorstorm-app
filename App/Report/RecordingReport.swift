import Foundation
import SensorstormCore
import UIKit

/// The quality report of one recording as a document: a technician can attach it to a
/// measurement and a reviewer can see, stream by stream, that the data was complete.
@MainActor
enum RecordingReport {

    static func render(metadata: RecordingMetadata, quality: QualityReport, road: RoadRoughness.Result?,
                       rides: [ElevatorAnalysis.Ride]?, comfort: RideComfort.Result?,
                       vibration: VibrationScreening.Result?, inspector: String, organisation: String) -> URL? {
        let data = ReportCanvas.render(footer: "\(metadata.name) · Sensorstorm") { canvas in
            canvas.title(String(localized: "Qualitätsbericht der Aufnahme"))
            canvas.text(metadata.name, font: .systemFont(ofSize: 15, weight: .medium), after: 10)
            canvas.row(String(localized: "Beginn"), metadata.startedAt.formatted(date: .complete, time: .standard))
            canvas.row(String(localized: "Dauer"), SurveyReport.duration(metadata.duration))
            canvas.row(String(localized: "Gerät"), "\(metadata.device.model) · \(metadata.device.systemName) \(metadata.device.systemVersion)")
            canvas.row(String(localized: "App"), metadata.device.appVersion)
            canvas.row(String(localized: "Verlangte Rate"), "\(Int(metadata.requestedRateHz)) Hz")
            if !inspector.isEmpty { canvas.row(String(localized: "Geprüft von"), inspector) }
            if !organisation.isEmpty { canvas.row(String(localized: "Organisation"), organisation) }

            canvas.heading(String(localized: "Urteil"))
            canvas.text(title(quality.verdict), font: .systemFont(ofSize: 14, weight: .semibold), color: color(quality.verdict), after: 4)
            canvas.text(String(localized: "\(Int((quality.goodShare * 100).rounded())) % der Ströme sind einwandfrei."),
                        font: .systemFont(ofSize: 10), color: .darkGray)

            if let gps = quality.gps {
                canvas.heading(String(localized: "Position"))
                canvas.row(String(localized: "Fixe"), "\(gps.fixCount)")
                canvas.row(String(localized: "Genauigkeit (Median)"), String(format: "±%.1f m", gps.medianAccuracy))
                canvas.row(String(localized: "90 % besser als"), String(format: "±%.1f m", gps.worstDecile))
                canvas.row(String(localized: "Anteil unter 10 m"), String(format: "%.0f %%", gps.shareWithin10m * 100))
                canvas.row(String(localized: "Längster Ausfall"), String(format: "%.0f s", gps.longestOutage))
                canvas.row(String(localized: "Urteil"), title(gps.verdict))
            }

            canvas.heading(String(localized: "Ströme"))
            canvas.table(
                header: [String(localized: "Strom"), String(localized: "Werte"), String(localized: "Rate"),
                         String(localized: "Lücken"), String(localized: "Urteil")],
                rows: quality.streams.map { stream in
                    [stream.title, "\(stream.sampleCount)", String(format: "%.1f Hz", stream.measuredRate),
                     stream.gapCount > 0 ? String(format: "%d (%.1f s)", stream.gapCount, stream.longestGap) : "—",
                     title(stream.verdict)]
                },
                weights: [3, 1.4, 1.2, 1.6, 1.8])
            for stream in quality.streams where !stream.notes.isEmpty {
                for note in stream.notes {
                    canvas.text("\(stream.title): \(RecordingAnalysisView.sentence(note))",
                                font: .systemFont(ofSize: 8.5), color: .darkGray, indent: 8, after: 1)
                }
            }

            if let road, !road.segments.isEmpty {
                canvas.heading(String(localized: "Strassenzustand"))
                canvas.row(String(localized: "Beurteilte Strecke"), ReportFormat.length(road.distance))
                canvas.row(String(localized: "Abschnitte"), "\(road.segments.count)")
                canvas.row(String(localized: "Schläge"), "\(road.shocks.count)")
                canvas.text(String(localized: "Richtwert aus der Vertikalbeschleunigung, kein Messwert nach Norm."),
                            font: .systemFont(ofSize: 8.5), color: .darkGray)
            }
            if let rides, !rides.isEmpty {
                canvas.heading(String(localized: "Aufzugfahrten"))
                canvas.table(
                    header: [String(localized: "Fahrt"), String(localized: "Höhe"), String(localized: "Tempo"),
                             String(localized: "Anfahren"), String(localized: "Ruck"), String(localized: "A95")],
                    rows: rides.enumerated().map { index, ride in
                        ["\(index + 1)", String(format: "%+.1f m", ride.heightChange), String(format: "%.2f m/s", ride.peakSpeed),
                         String(format: "%.2f m/s²", ride.peakAcceleration), String(format: "%.2f m/s³", ride.peakJerk),
                         ride.cruiseVibration.map { String(format: "%.0f mg", $0) } ?? "—"]
                    },
                    weights: [1, 1.3, 1.3, 1.4, 1.4, 1.2])
            }
            if let comfort {
                canvas.heading(String(localized: "Fahrkomfort"))
                canvas.row(String(localized: "Komfortindex"), String(format: "%.2f", comfort.comfortIndex))
                canvas.row(String(localized: "Senkrecht"), String(format: "%.2f m/s²", comfort.vertical))
                canvas.row(String(localized: "Quer"), String(format: "%.2f m/s²", comfort.lateral))
                canvas.row(String(localized: "Längs"), String(format: "%.2f m/s²", comfort.longitudinal))
                canvas.row(String(localized: "Stösse"), "\(comfort.jolts.count)")
            }
            if let vibration {
                canvas.heading(String(localized: "Erschütterung"))
                canvas.row(String(localized: "Höchste Schwinggeschwindigkeit"), String(format: "%.1f mm/s", vibration.governing.peakVelocity))
                canvas.row(String(localized: "Frequenz"), String(format: "%.0f Hz", vibration.governing.frequency))
                canvas.row(String(localized: "Richtwert (DIN 4150-3)"), String(format: "%.1f mm/s", vibration.guideValue))
                canvas.row(String(localized: "Ergebnis"), vibration.exceeded ? String(localized: "überschritten") : String(localized: "eingehalten"))
                canvas.text(String(localized: "Screening mit dem Beschleunigungssensor eines Telefons, kein Gutachten."),
                            font: .systemFont(ofSize: 8.5), color: .darkGray)
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("\(RecordingExporter.sanitize(metadata.name))-Bericht.pdf")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func title(_ verdict: QualityVerdict) -> String {
        switch verdict {
        case .good: String(localized: "gut")
        case .fair: String(localized: "mit Einschränkungen")
        case .poor: String(localized: "schlecht")
        }
    }

    private static func color(_ verdict: QualityVerdict) -> UIColor {
        switch verdict {
        case .good: .systemGreen
        case .fair: .systemOrange
        case .poor: .systemRed
        }
    }
}
