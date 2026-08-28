import Foundation
import Observation
import SensorstormCore
import SwiftUI

/// Everything the capture screen has collected about one spot, before it becomes a
/// ``GroundFinding``. Media are still loose files at this point: the photo is in memory and
/// the clip sits in the temporary directory, and neither belongs to a survey until the user
/// actually saves.
struct FindingDraft {
    var id = UUID()
    var severity = 5
    var label = ""
    var note = ""
    var photo: Data?
    var clipURL: URL?
    var location: FindingLocation?
    var area: FindingArea?
    var capturedAt = Date()
    var hostTime: Double = HostClock.now
    var recordingID: UUID?

    /// A finding without a position is not a finding — it cannot be found again, which is
    /// the entire point of writing it down.
    var isSaveable: Bool {
        location?.isUsable == true
    }
}

/// The surveys on disk plus every operation the survey screens offer.
///
/// The same shape as ``RecordingLibrary`` on purpose: one observable object owns the store,
/// the list and the error message, and the views stay free of file handling.
@MainActor
@Observable
final class SurveyModel {
    private(set) var surveys: [Survey] = []
    private(set) var totalBytes: Int64 = 0
    private(set) var isExporting = false
    var errorMessage: String?

    let store: SurveyStore
    let location = SurveyLocationProvider()
    let camera = SurveyCamera()

    init(store: SurveyStore) {
        self.store = store
        refresh()
    }

    // MARK: - Surveys

    func refresh() {
        surveys = store.allSurveys()
        totalBytes = surveys.reduce(0) { $0 + store.byteSize(of: $1.id) }
    }

    func survey(_ id: UUID) -> Survey? {
        surveys.first { $0.id == id }
    }

    func byteSize(of survey: Survey) -> Int64 {
        store.byteSize(of: survey.id)
    }

    @discardableResult
    func createSurvey(name: String? = nil, recordingID: UUID? = nil) -> Survey? {
        let now = Date()
        let survey = Survey(name: name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                            ?? Self.defaultName(for: now),
                            startedAt: now,
                            recordingID: recordingID)
        do {
            try store.save(survey)
            refresh()
            return survey
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func rename(_ survey: Survey, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = survey
        updated.name = trimmed
        save(updated)
    }

    func updateNotes(_ survey: Survey, notes: String) {
        var updated = survey
        updated.notes = notes
        save(updated)
    }

    func delete(_ survey: Survey) {
        do {
            try store.delete(survey.id)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(atOffsets offsets: IndexSet) {
        for index in offsets {
            guard surveys.indices.contains(index) else { continue }
            try? store.delete(surveys[index].id)
        }
        refresh()
    }

    private func save(_ survey: Survey) {
        do {
            try store.save(survey)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Findings

    /// Writes the draft's media into the survey folder and adds the finding.
    ///
    /// Media first, document second: if writing the photo fails there is no finding
    /// pointing at a file that is not there.
    @discardableResult
    func addFinding(_ draft: FindingDraft, to surveyID: UUID) -> GroundFinding? {
        guard var survey = survey(surveyID) else { return nil }
        guard let location = draft.location else {
            errorMessage = String(localized: "Ohne GPS-Position lässt sich der Befund nicht sichern.")
            return nil
        }

        var photoFileName: String?
        var videoFileName: String?
        do {
            if let photo = draft.photo {
                photoFileName = try store.writePhoto(photo, for: draft.id, in: surveyID)
            }
            if let clipURL = draft.clipURL {
                videoFileName = try store.importVideo(from: clipURL, for: draft.id, in: surveyID)
            }
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }

        let finding = GroundFinding(id: draft.id,
                                    capturedAt: draft.capturedAt,
                                    hostTime: draft.hostTime,
                                    location: location,
                                    severity: draft.severity,
                                    label: draft.label.trimmingCharacters(in: .whitespacesAndNewlines),
                                    note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines),
                                    photoFileName: photoFileName,
                                    videoFileName: videoFileName,
                                    area: draft.area,
                                    recordingID: draft.recordingID)

        survey.upsert(finding)
        save(survey)
        return finding
    }

    func update(_ finding: GroundFinding, in surveyID: UUID) {
        guard var survey = survey(surveyID) else { return }
        survey.upsert(finding)
        save(survey)
    }

    func deleteFinding(_ finding: GroundFinding, from surveyID: UUID) {
        guard var survey = survey(surveyID) else { return }
        survey.remove(finding.id)
        // The photo and the clip go with it; nothing else points at them.
        store.deleteMedia(of: finding, in: surveyID)
        save(survey)
    }

    func photoURL(for finding: GroundFinding, in surveyID: UUID) -> URL? {
        store.photoURL(for: finding, in: surveyID)
    }

    func videoURL(for finding: GroundFinding, in surveyID: UUID) -> URL? {
        store.videoURL(for: finding, in: surveyID)
    }

    // MARK: - Export

    func export(_ survey: Survey, format: SurveyExporter.Format) async -> URL? {
        isExporting = true
        defer { isExporting = false }

        let store = self.store
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("exports", isDirectory: true)

        do {
            return try await Task.detached(priority: .userInitiated) {
                try SurveyExporter(store: store).export(survey, format: format, into: destination)
            }.value
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Helpers

    static func defaultName(for date: Date) -> String {
        let stamp = date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        return String(localized: "Begehung \(stamp)")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension View {
    /// Surfaces ``SurveyModel/errorMessage`` the same way the library screens do.
    func surveyErrorAlert(_ model: SurveyModel) -> some View {
        alert("Fehler", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
