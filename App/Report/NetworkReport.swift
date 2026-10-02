import Foundation
import SensorstormCore
import UIKit

/// The network as a document a customer signs: what was found, how fast it was, what looked
/// wrong. For an installer handing over a Wi-Fi, an IT service reviewing an office, a person
/// who wants to know what is plugged into their own network.
@MainActor
enum NetworkReport {
    struct Input {
        var snapshot: NetworkSnapshot
        var previous: NetworkSnapshot?
        var wifi: WiFiInfo?
        var radio: [String]
        var speed: SpeedTestSummary?
        var inspector: String
        var organisation: String
        var aliases: [String: HostAnnotation]
    }

    static func render(_ input: Input) -> URL? {
        let snapshot = input.snapshot
        let findings = NetworkAudit.findings(for: snapshot)
        let data = ReportCanvas.render(footer: "\(snapshot.networkName) · Sensorstorm") { canvas in
            canvas.title(String(localized: "Netzwerk-Abnahmeprotokoll"))
            canvas.text(snapshot.networkName, font: .systemFont(ofSize: 15, weight: .medium), after: 10)
            canvas.row(String(localized: "Datum"), snapshot.date.formatted(date: .complete, time: .shortened))
            canvas.row(String(localized: "Netz"), snapshot.subnet)
            if let gateway = snapshot.gateway { canvas.row(String(localized: "Router"), gateway) }
            if let wifi = input.wifi {
                canvas.row(String(localized: "WLAN"), wifi.ssid)
                canvas.row(String(localized: "Signal"), String(format: "%.0f %%", wifi.signalStrength * 100))
                canvas.row(String(localized: "Verschlüsselt"), wifi.isSecure ? String(localized: "ja") : String(localized: "nein"))
            }
            if !input.radio.isEmpty { canvas.row(String(localized: "Mobilfunk"), input.radio.joined(separator: ", ")) }
            if !input.inspector.isEmpty { canvas.row(String(localized: "Geprüft von"), input.inspector) }
            if !input.organisation.isEmpty { canvas.row(String(localized: "Organisation"), input.organisation) }

            canvas.heading(String(localized: "Zusammenfassung"))
            canvas.row(String(localized: "Geräte gefunden"), "\(snapshot.hosts.count)")
            let critical = findings.count { $0.severity == .critical }
            let warnings = findings.count { $0.severity == .warning }
            canvas.row(String(localized: "Kritische Befunde"), "\(critical)")
            canvas.row(String(localized: "Warnungen"), "\(warnings)")

            if let speed = input.speed {
                canvas.heading(String(localized: "Geschwindigkeit"))
                canvas.row(String(localized: "Gemessen"), speed.date.formatted(date: .abbreviated, time: .shortened))
                if let down = speed.downloadMegabits { canvas.row(String(localized: "Download"), NetFormat.megabits(down)) }
                if let up = speed.uploadMegabits { canvas.row(String(localized: "Upload"), NetFormat.megabits(up)) }
                if let idle = speed.idleLatency {
                    canvas.row(String(localized: "Antwortzeit im Leerlauf"), NetFormat.milliseconds(idle))
                }
                if let loaded = speed.loadedLatency {
                    canvas.row(String(localized: "Antwortzeit unter Last"), NetFormat.milliseconds(loaded))
                }
            }

            if !findings.isEmpty {
                canvas.heading(String(localized: "Befunde"))
                canvas.table(
                    header: [String(localized: "Stufe"), String(localized: "Gerät"), String(localized: "Port"),
                             String(localized: "Befund")],
                    rows: findings.map { finding in
                        [severity(finding.severity), "\(finding.name) (\(finding.address))", "\(finding.port)",
                         sentence(finding.kind)]
                    },
                    weights: [1.2, 3, 0.9, 4])
            }

            if let previous = input.previous {
                let diff = InventoryDiff.between(previous, snapshot)
                if !diff.isEmpty {
                    canvas.heading(String(localized: "Änderungen seit dem letzten Scan"))
                    canvas.text(String(localized: "Verglichen mit dem Scan vom \(previous.date.formatted(date: .abbreviated, time: .shortened))."),
                                font: .systemFont(ofSize: 9), color: .darkGray, after: 4)
                    for host in diff.added {
                        canvas.text("+ \(host.displayName) (\(host.address))", indent: 8, after: 1)
                    }
                    for host in diff.removed {
                        canvas.text("− \(host.displayName) (\(host.address))", indent: 8, after: 1)
                    }
                    for change in diff.changed {
                        canvas.text("± \(change.name) (\(change.address))", indent: 8, after: 1)
                    }
                }
            }

            canvas.heading(String(localized: "Geräte"))
            canvas.table(
                header: [String(localized: "Adresse"), String(localized: "Name"), String(localized: "Dienste")],
                rows: snapshot.hosts.map { host in
                    let alias = input.aliases[host.address]?.alias
                    let ports = host.openPorts.map { "\($0) \(PortCatalog.name($0))" }.joined(separator: ", ")
                    return [host.address, alias.flatMap { $0.isEmpty ? nil : $0 } ?? host.displayName,
                            ports.isEmpty ? "—" : ports]
                },
                weights: [2, 3, 5])

            canvas.space(18)
            canvas.text(String(localized: "Gefunden werden Geräte, die auf Ping, Bonjour oder eine Verbindung auf einem der geprüften Ports antworten. Ein Gerät, das schweigt, taucht nicht auf. Hardware-Adressen gibt iOS nicht heraus."),
                        font: .systemFont(ofSize: 8.5), color: .darkGray)
            canvas.space(30)
            canvas.text(String(localized: "Ort, Datum, Unterschrift"), font: .systemFont(ofSize: 9), color: .darkGray)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("\(RecordingExporter.sanitize(snapshot.networkName))-Netzwerk.pdf")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func severity(_ severity: NetworkFinding.Severity) -> String {
        switch severity {
        case .critical: String(localized: "kritisch")
        case .warning: String(localized: "Warnung")
        case .info: String(localized: "Hinweis")
        }
    }

    static func sentence(_ kind: NetworkFinding.Kind) -> String {
        switch kind {
        case .remoteShell:
            String(localized: "Fernzugriff auf die Kommandozeile ohne Verschlüsselung. Abschalten oder durch SSH ersetzen.")
        case .ftp:
            String(localized: "FTP überträgt Passwörter im Klartext. Durch SFTP ersetzen.")
        case .remoteDesktop:
            String(localized: "Fernzugriff auf den Bildschirm ist offen. Nur aus dem eigenen Netz, mit starkem Passwort.")
        case .fileSharing:
            String(localized: "Dateifreigabe ist erreichbar. Prüfen, wer Zugriff hat.")
        case .database:
            String(localized: "Eine Datenbank ist im Netz erreichbar. Auf den Rechner selbst beschränken oder mit Zugangsdaten und Verschlüsselung schützen.")
        case .plainHTTPOnly:
            String(localized: "Die Weboberfläche läuft nur unverschlüsselt. Das Passwort reist im Klartext.")
        case .camera:
            String(localized: "Kamera-Datenstrom ist erreichbar. Prüfen, ob er Zugangsdaten verlangt.")
        case .messageBroker:
            String(localized: "MQTT-Broker ohne Verschlüsselung erreichbar.")
        }
    }
}
