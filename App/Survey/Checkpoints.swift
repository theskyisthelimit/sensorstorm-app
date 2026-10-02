import Foundation
import SensorstormCore

extension SurveyModel {
    /// A scanned NFC sticker becomes an observation at the current position, closed at once:
    /// it says "somebody was here and the object is number 4711", not "something is wrong".
    /// Closed with no action needed, so it appears in the report as a checked point and never
    /// among the open ones.
    func addCheckpoint(code: String, to surveyID: UUID) async -> GroundFinding? {
        location.requestAuthorization()
        location.acquire()
        defer { location.release() }

        var fix: LiveFix?
        for _ in 0..<40 {
            if let candidate = location.fix, candidate.isUsable, candidate.horizontalAccuracy <= 30 {
                fix = candidate
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let fix else {
            errorMessage = String(localized: "Keine genaue Position gefunden. Versuche es im Freien noch einmal.")
            return nil
        }

        var draft = FindingDraft()
        draft.location = fix.findingLocation(heading: location.heading)
        draft.positionSource = .gps
        draft.label = String(localized: "Kontrollpunkt")
        draft.severity = FindingDraft().severity
        draft.note = code
        draft.attributes[Self.checkpointKey] = code
        guard let finding = addFinding(draft, to: surveyID) else { return nil }
        setStatus(.noAction, of: finding.id, in: surveyID)
        return finding
    }

    /// The attribute under which the sticker's text is stored.
    static let checkpointKey = "objekt"
}
