import Foundation
import Observation
import SensorstormCore
import SwiftUI
import UIKit

/// A photo still in memory, or a clip still in the temporary directory.
///
/// Media only become part of a case when the case is saved. Until then they hang here, so
/// that cancelling a capture leaves nothing behind and a photo taken by mistake is one tap
/// away from being gone.
struct PendingMedia: Identifiable {
    let id: UUID
    let kind: CaseMedia.Kind
    let photoData: Data?
    let clipURL: URL?
    /// Built once at capture time; decoding a full-size JPEG for every redraw of the strip
    /// is what makes a capture screen feel slow.
    let thumbnail: UIImage?
    let capturedAt: Date
    let duration: TimeInterval?

    init(photo data: Data, thumbnail: UIImage?, capturedAt: Date = Date()) {
        self.id = UUID()
        self.kind = .photo
        self.photoData = data
        self.clipURL = nil
        self.thumbnail = thumbnail
        self.capturedAt = capturedAt
        self.duration = nil
    }

    init(clip url: URL, duration: TimeInterval?, capturedAt: Date = Date()) {
        self.id = UUID()
        self.kind = .video
        self.photoData = nil
        self.clipURL = url
        self.thumbnail = nil
        self.capturedAt = capturedAt
        self.duration = duration
    }
}

/// Everything the capture screen has collected about one case, before it becomes a
/// ``GroundFinding``.
struct FindingDraft {
    var id = UUID()
    var severity = 5
    var label = ""
    var note = ""
    var media: [PendingMedia] = []
    /// The position that will be written. May have come from one fix, from an average, or
    /// from a pin the user placed by hand.
    var location: FindingLocation?
    var positionSource: PositionSource = .gps
    /// What GPS said before the pin was moved.
    var measuredLocation: FindingLocation?
    var positionSampleCount: Int?
    var positionSpread: Double?
    var area: FindingArea?
    var capturedAt = Date()
    var hostTime: Double = HostClock.now
    var recordingID: UUID?

    /// A case without a position is not a case — it cannot be found again, which is the
    /// entire point of writing it down. A hand-placed pin needs no accuracy figure; a GPS
    /// position without one is not a fix.
    var isSaveable: Bool {
        guard let location, location.coordinate.isValid else { return false }
        return positionSource == .manual || location.isUsable
    }

    var photoCount: Int { media.count { $0.kind == .photo } }
    var videoCount: Int { media.count { $0.kind == .video } }

    /// Takes the position from a single fix, unless the pin has been placed by hand — a
    /// correction must not be undone by the next GPS update.
    mutating func follow(_ fix: LiveFix, heading: Double?) {
        guard positionSource != .manual, fix.isUsable else { return }
        location = fix.findingLocation(heading: heading)
        positionSource = .gps
        positionSampleCount = nil
        positionSpread = nil
    }

    /// Replaces the position with an averaged one.
    mutating func apply(_ averaged: AveragedFix, heading: Double?) {
        location = averaged.findingLocation(heading: heading)
        positionSource = .averaged
        positionSampleCount = averaged.sampleCount
        positionSpread = averaged.spread
        measuredLocation = nil
    }

    /// Moves the pin by hand, keeping what GPS had said as the measured position.
    mutating func placePin(at coordinate: Coordinate2D) {
        let previous = location
        if positionSource != .manual { measuredLocation = previous }
        location = FindingLocation(latitude: coordinate.latitude,
                                   longitude: coordinate.longitude,
                                   altitude: previous?.altitude,
                                   ellipsoidalAltitude: previous?.ellipsoidalAltitude,
                                   // A pin has no error bar. Claiming the fix's would be
                                   // claiming a measurement that was not made.
                                   horizontalAccuracy: -1,
                                   verticalAccuracy: -1,
                                   heading: previous?.heading)
        positionSource = .manual
        positionSampleCount = nil
        positionSpread = nil
    }

    /// Back to what the receiver says, throwing the correction away.
    mutating func resetToMeasured() {
        guard let measured = measuredLocation else { return }
        location = measured
        measuredLocation = nil
        positionSource = .gps
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

    /// Writes the draft's media into the survey folder and adds the case.
    ///
    /// Media first, document second: if writing a photo fails there is no case pointing at
    /// a file that is not there.
    @discardableResult
    func addFinding(_ draft: FindingDraft, to surveyID: UUID) -> GroundFinding? {
        guard var survey = survey(surveyID) else { return nil }
        guard let location = draft.location, location.coordinate.isValid else {
            errorMessage = String(localized: "Ohne Position lässt sich der Fall nicht sichern.")
            return nil
        }

        let stored = writeMedia(draft.media, to: surveyID)
        guard stored.count == draft.media.count else { return nil }

        let finding = GroundFinding(id: draft.id,
                                    capturedAt: draft.capturedAt,
                                    hostTime: draft.hostTime,
                                    location: location,
                                    positionSource: draft.positionSource,
                                    measuredLocation: draft.measuredLocation,
                                    positionSampleCount: draft.positionSampleCount,
                                    positionSpread: draft.positionSpread,
                                    severity: draft.severity,
                                    label: draft.label.trimmingCharacters(in: .whitespacesAndNewlines),
                                    note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines),
                                    media: stored,
                                    area: draft.area,
                                    recordingID: draft.recordingID)

        survey.upsert(finding)
        save(survey)
        return finding
    }

    /// Adds photos and clips to a case that already exists — the second visit to the same
    /// pothole, or the close-up somebody forgot.
    @discardableResult
    func addMedia(_ pending: [PendingMedia], to findingID: UUID, in surveyID: UUID) -> Bool {
        guard var survey = survey(surveyID), var finding = survey.finding(findingID) else {
            return false
        }
        let stored = writeMedia(pending, to: surveyID)
        guard stored.count == pending.count else { return false }

        for item in stored { finding.add(item) }
        survey.upsert(finding)
        save(survey)
        return true
    }

    func deleteMedia(_ media: CaseMedia, from findingID: UUID, in surveyID: UUID) {
        guard var survey = survey(surveyID), var finding = survey.finding(findingID) else { return }
        finding.removeMedia(media.id)
        store.delete(media, in: surveyID)
        survey.upsert(finding)
        save(survey)
    }

    /// Writes every pending item and returns the entries. On the first failure it removes
    /// what it already wrote and reports — half a case's photos on disk with nothing
    /// pointing at them is the one outcome worth avoiding.
    private func writeMedia(_ pending: [PendingMedia], to surveyID: UUID) -> [CaseMedia] {
        var stored: [CaseMedia] = []
        for item in pending {
            do {
                if let data = item.photoData {
                    stored.append(try store.writePhoto(data, id: item.id,
                                                       capturedAt: item.capturedAt,
                                                       in: surveyID))
                } else if let url = item.clipURL {
                    stored.append(try store.importVideo(from: url, id: item.id,
                                                        capturedAt: item.capturedAt,
                                                        duration: item.duration,
                                                        in: surveyID))
                }
            } catch {
                errorMessage = error.localizedDescription
                for written in stored { store.delete(written, in: surveyID) }
                return []
            }
        }
        return stored
    }

    func update(_ finding: GroundFinding, in surveyID: UUID) {
        guard var survey = survey(surveyID) else { return }
        survey.upsert(finding)
        save(survey)
    }

    func deleteFinding(_ finding: GroundFinding, from surveyID: UUID) {
        guard var survey = survey(surveyID) else { return }
        survey.remove(finding.id)
        // The photos and clips go with it; nothing else points at them.
        store.deleteMedia(of: finding, in: surveyID)
        save(survey)
    }

    func url(for media: CaseMedia, in surveyID: UUID) -> URL? {
        store.url(for: media, in: surveyID)
    }

    func coverURL(for finding: GroundFinding, in surveyID: UUID) -> URL? {
        guard let cover = finding.coverPhoto else { return nil }
        return store.url(for: cover, in: surveyID)
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
