import AppIntents
import Foundation
import SensorstormCore

/// What the shortcuts reach into: the running app's objects. Set once at launch; an intent that
/// runs before that has nothing to act on and says so rather than doing nothing silently.
@MainActor
enum AppServices {
    static var hub: SensorHub?
    static var surveys: SurveyModel?
    static var network: NetworkHub?
}

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case notReady

    var localizedStringResource: LocalizedStringResource {
        "Sensorstorm ist noch nicht bereit. Öffne die App und versuche es noch einmal."
    }
}

// MARK: - Recording

struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Aufnahme starten"
    static let description = IntentDescription("Startet eine Aufnahme mit den eingestellten Sensoren.")
    // The camera and the sensors need the app in front, and the first start asks for permissions.
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let hub = AppServices.hub else { throw IntentFailure.notReady }
        if hub.phase == .recording { return .result(dialog: "Es läuft schon eine Aufnahme.") }
        await hub.startRecording()
        return .result(dialog: "Die Aufnahme läuft.")
    }
}

struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Aufnahme beenden"
    static let description = IntentDescription("Beendet die laufende Aufnahme und speichert sie.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let hub = AppServices.hub else { throw IntentFailure.notReady }
        guard hub.phase == .recording else { return .result(dialog: "Es läuft keine Aufnahme.") }
        _ = await hub.stopRecording()
        return .result(dialog: "Die Aufnahme ist gespeichert.")
    }
}

struct MarkMomentIntent: AppIntent {
    static let title: LocalizedStringResource = "Zeitpunkt markieren"
    static let description = IntentDescription("Setzt eine Notiz in die laufende Aufnahme, auf die gemeinsame Uhr aller Sensoren.")
    static let openAppWhenRun = false

    @Parameter(title: "Text", default: "Markierung")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let hub = AppServices.hub else { throw IntentFailure.notReady }
        guard hub.phase == .recording else { return .result(dialog: "Es läuft keine Aufnahme.") }
        hub.addAnnotation(text)
        return .result(dialog: "Markiert.")
    }
}

// MARK: - Observations

struct QuickObservationIntent: AppIntent {
    static let title: LocalizedStringResource = "Beobachtung an meinem Standort"
    static let description = IntentDescription("Hält an der aktuellen Position eine Beobachtung fest, ohne die App zu öffnen. Für die Aktionstaste.")
    static let openAppWhenRun = false

    @Parameter(title: "Bezeichnung")
    var label: String?

    @Parameter(title: "Schweregrad", default: 5, inclusiveRange: (1, 10))
    var severity: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppServices.surveys else { throw IntentFailure.notReady }
        model.location.requestAuthorization()
        model.location.acquire()
        defer { model.location.release() }

        // Up to ten seconds for a fix a finding can be found again from. Standing outside, it
        // takes two or three.
        var fix: LiveFix?
        for _ in 0..<40 {
            if let candidate = model.location.fix, candidate.isUsable, candidate.horizontalAccuracy <= 30 {
                fix = candidate
                break
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard let fix else {
            return .result(dialog: "Keine genaue Position gefunden. Versuche es im Freien noch einmal.")
        }

        // The walk that is still open, or a notebook of its own for quick ones.
        let survey = model.surveys.first { $0.endedAt == nil }
            ?? model.createSurvey(name: String(localized: "Schnellnotizen"))
        guard let survey else { throw IntentFailure.notReady }

        var draft = FindingDraft()
        draft.location = fix.findingLocation(heading: model.location.heading)
        draft.positionSource = .gps
        draft.label = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        draft.severity = severity
        guard model.addFinding(draft, to: survey.id) != nil else { throw IntentFailure.notReady }
        return .result(dialog: "Beobachtung gesichert.")
    }
}

struct StartWalkTrackingIntent: AppIntent {
    static let title: LocalizedStringResource = "Weg aufzeichnen"
    static let description = IntentDescription("Zeichnet den Weg der offenen Route auf, auch bei gesperrtem Bildschirm.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppServices.surveys else { throw IntentFailure.notReady }
        let survey = model.surveys.first { $0.endedAt == nil } ?? model.createSurvey()
        guard let survey else { throw IntentFailure.notReady }
        model.startTracking(survey.id)
        return .result(dialog: "Der Weg wird aufgezeichnet.")
    }
}

struct StopWalkTrackingIntent: AppIntent {
    static let title: LocalizedStringResource = "Weg anhalten"
    static let description = IntentDescription("Hält die Aufzeichnung des Wegs an.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppServices.surveys else { throw IntentFailure.notReady }
        guard model.isTracking else { return .result(dialog: "Es wird gerade kein Weg aufgezeichnet.") }
        model.stopTracking()
        return .result(dialog: "Der Weg ist gespeichert.")
    }
}

// MARK: - Network

struct ScanNetworkIntent: AppIntent {
    static let title: LocalizedStringResource = "Netz absuchen"
    static let description = IntentDescription("Sucht die Geräte im lokalen Netz und nennt, wie viele es sind.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let network = AppServices.network else { throw IntentFailure.notReady }
        network.environment.start()
        try await Task.sleep(for: .seconds(1))
        network.scanner.start(environment: network.environment, inventory: network.inventory)
        while network.scanner.isRunning { try await Task.sleep(for: .milliseconds(500)) }
        let count = network.scanner.hosts.count
        return .result(dialog: "Im Netz sind \(count) Geräte.")
    }
}

// MARK: - Shortcuts

struct SensorstormShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRecordingIntent(),
                    phrases: ["Starte eine Aufnahme in \(.applicationName)", "Aufnahme starten in \(.applicationName)"],
                    shortTitle: "Aufnahme starten", systemImageName: "record.circle")
        AppShortcut(intent: StopRecordingIntent(),
                    phrases: ["Beende die Aufnahme in \(.applicationName)", "Aufnahme beenden in \(.applicationName)"],
                    shortTitle: "Aufnahme beenden", systemImageName: "stop.circle")
        AppShortcut(intent: MarkMomentIntent(),
                    phrases: ["Markiere einen Zeitpunkt in \(.applicationName)", "Markierung in \(.applicationName)"],
                    shortTitle: "Zeitpunkt markieren", systemImageName: "flag")
        AppShortcut(intent: QuickObservationIntent(),
                    phrases: ["Halte eine Beobachtung in \(.applicationName) fest", "Beobachtung hier in \(.applicationName)"],
                    shortTitle: "Beobachtung hier", systemImageName: "mappin.and.ellipse")
        AppShortcut(intent: StartWalkTrackingIntent(),
                    phrases: ["Zeichne meinen Weg in \(.applicationName) auf", "Weg aufzeichnen in \(.applicationName)"],
                    shortTitle: "Weg aufzeichnen", systemImageName: "figure.walk")
        AppShortcut(intent: StopWalkTrackingIntent(),
                    phrases: ["Halte den Weg in \(.applicationName) an"],
                    shortTitle: "Weg anhalten", systemImageName: "stop")
        AppShortcut(intent: ScanNetworkIntent(),
                    phrases: ["Suche das Netz mit \(.applicationName) ab", "Netz absuchen in \(.applicationName)"],
                    shortTitle: "Netz absuchen", systemImageName: "network")
    }
}
