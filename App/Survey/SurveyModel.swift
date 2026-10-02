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
    /// The catalog entry and the answers to its questions, when the walk uses a catalog.
    var attributes: [String: String] = [:]

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
    private(set) var isImporting = false
    /// The walk whose path is being recorded right now, if any. Only one at a time: there is
    /// one phone and it is in one place.
    private(set) var trackingSurveyID: UUID?
    private var trackSavedAt = Date.distantPast
    var errorMessage: String?

    let store: SurveyStore
    let catalogs = CatalogStore()
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

    func save(_ survey: Survey) {
        do {
            try store.save(survey)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }


    // MARK: - Walk

    var isTracking: Bool { trackingSurveyID != nil }

    /// Starts recording the path of `surveyID`: a point every few metres, with the screen
    /// locked as well. A closed walk is reopened — nobody records a track on a walk they
    /// consider finished.
    func startTracking(_ surveyID: UUID) {
        guard trackingSurveyID == nil, var survey = survey(surveyID) else { return }
        trackingSurveyID = surveyID
        if survey.endedAt != nil {
            survey.endedAt = nil
            save(survey)
        }
        location.requestAuthorization()
        location.acquire()
        location.setBackgroundTracking(true)
        location.onFix = { [weak self] fix in self?.trackFix(fix) }
    }

    func stopTracking() {
        guard trackingSurveyID != nil else { return }
        flushTrack()
        location.onFix = nil
        location.setBackgroundTracking(false)
        location.release()
        trackingSurveyID = nil
    }

    private func trackFix(_ fix: LiveFix) {
        guard let id = trackingSurveyID, let index = surveys.firstIndex(where: { $0.id == id }) else { return }
        let point = WalkPoint(time: fix.timestamp, latitude: fix.latitude, longitude: fix.longitude,
                              altitude: fix.altitude, horizontalAccuracy: fix.horizontalAccuracy)
        guard surveys[index].appendTrackPoint(point) else { return }
        // To disk every quarter minute, not every point: the path is one JSON document, and
        // rewriting a walk's findings 20 times a minute would be wear for no reason. What a
        // kill between two saves loses is at most that quarter minute.
        if Date().timeIntervalSince(trackSavedAt) >= 15 { flushTrack() }
    }

    private func flushTrack() {
        guard let id = trackingSurveyID, let survey = surveys.first(where: { $0.id == id }) else { return }
        trackSavedAt = Date()
        do {
            try store.save(survey)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Closes the walk: stops its path and stamps the end.
    func finish(_ surveyID: UUID) {
        if trackingSurveyID == surveyID { stopTracking() }
        guard var survey = survey(surveyID), survey.endedAt == nil else { return }
        survey.endedAt = Date()
        save(survey)
    }

    func reopen(_ surveyID: UUID) {
        guard var survey = survey(surveyID), survey.endedAt != nil else { return }
        survey.endedAt = nil
        save(survey)
    }

    /// A new walk that starts from this one. See ``FindingHistory/repeating(_:name:id:now:includeResolved:copyID:)``.
    @discardableResult
    func repeatSurvey(_ survey: Survey, includeResolved: Bool = false) -> Survey? {
        let name = String(localized: "\(survey.name) (Wiederholung)")
        let next = FindingHistory.repeating(survey, name: name, includeResolved: includeResolved)
        do {
            try store.save(next)
            refresh()
            return next
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Puts several walks together as one new one. The originals stay: merging is not a
    /// reason to lose the pieces it was made of.
    @discardableResult
    func combine(_ ids: [UUID], name: String) -> Survey? {
        let sources = ids.compactMap { survey($0) }
        guard sources.count >= 2 else { return nil }
        let combined = SurveyMerge.combine(sources, name: name)
        do {
            let target = try store.prepareDirectory(for: combined.id)
            for source in sources {
                for finding in source.findings {
                    for item in finding.media {
                        guard let from = store.url(for: item, in: source.id) else { continue }
                        let to = target.appendingPathComponent(item.fileName)
                        if !FileManager.default.fileExists(atPath: to.path) {
                            try FileManager.default.copyItem(at: from, to: to)
                        }
                    }
                }
            }
            try store.save(combined)
            refresh()
            return combined
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Reads an archive another phone exported and folds it into this one.
    func importArchive(from url: URL, recordings: RecordingStore) async -> ArchiveImporter.Result? {
        isImporting = true
        defer { isImporting = false }
        let store = self.store
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try ArchiveImporter(surveyStore: store, recordingStore: recordings).importArchive(at: url)
            }.value
            refresh()
            return result
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// The history of a case across every walk on the phone.
    func history(of finding: GroundFinding) -> [FindingHistory.Entry] {
        FindingHistory.chain(for: finding, in: surveys)
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
            errorMessage = String(localized: "Ohne Position lässt sich die Beobachtung nicht sichern.")
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
                                    recordingID: draft.recordingID,
                                    attributes: draft.attributes)

        survey.upsert(finding)
        save(survey)
        let settings = SettingsStore.load()
        if settings.autoSendsFindings, RemoteReporter.isWebhookConfigured(settings) {
            Task { await send(finding.id, in: surveyID, to: .webhook) }
        }
        return finding
    }

    enum Destination { case webhook, open311 }

    /// Sends a case on and writes down that it went. A case already sent to a destination is
    /// sent again only on purpose: the mark is replaced, not stacked.
    @discardableResult
    func send(_ findingID: UUID, in surveyID: UUID, to destination: Destination) async -> RemoteReporter.Outcome {
        guard let survey = survey(surveyID), var finding = survey.finding(findingID) else { return .failed("—") }
        let settings = SettingsStore.load()
        let outcome: RemoteReporter.Outcome
        switch destination {
        case .webhook:
            var photo: Data?
            if settings.webhookIncludesPhoto, let cover = finding.coverPhoto, let url = store.url(for: cover, in: surveyID) {
                photo = try? Data(contentsOf: url)
            }
            outcome = await RemoteReporter.sendWebhook(finding, in: survey, settings: settings, coverPhoto: photo)
        case .open311:
            outcome = await RemoteReporter.sendOpen311(finding, settings: settings)
        }
        if case .sent(let reference) = outcome {
            let key = destination == .webhook ? RemoteReporter.webhookMark : RemoteReporter.open311Mark
            finding.attributes[key] = reference ?? TrackExporter.iso8601(Date())
            update(finding, in: surveyID)
        }
        return outcome
    }

    /// Adds photos and clips to a case that already exists — the second visit to the same
    /// pothole, or the close-up somebody forgot.
    ///
    /// - Parameter role: marks every new item as taken before or after the repair.
    @discardableResult
    func addMedia(_ pending: [PendingMedia], to findingID: UUID, in surveyID: UUID,
                  role: CaseMedia.Role? = nil) -> Bool {
        guard var survey = survey(surveyID), var finding = survey.finding(findingID) else {
            return false
        }
        let stored = writeMedia(pending, to: surveyID)
        guard stored.count == pending.count else { return false }

        for var item in stored {
            item.role = role
            finding.add(item)
        }
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

    /// Looks the address up and writes it into the case. `false` when nothing was found —
    /// no network, no building within reach, or the case was deleted in the meantime.
    ///
    /// The case is read again after the answer arrives: the lookup takes seconds, and the
    /// person may have changed the note, the rating or the pin in the meantime. Writing back
    /// the copy from before the question would undo that.
    @discardableResult
    func resolveAddress(for findingID: UUID, in surveyID: UUID) async -> Bool {
        guard let coordinate = survey(surveyID)?.finding(findingID)?.location.coordinate,
              let address = await AddressLookup.address(for: coordinate),
              var survey = survey(surveyID), var finding = survey.finding(findingID) else {
            return false
        }
        finding.address = address
        survey.upsert(finding)
        save(survey)
        return true
    }

    func setStatus(_ status: FindingStatus, of findingID: UUID, in surveyID: UUID) {
        guard var survey = survey(surveyID), var finding = survey.finding(findingID),
              finding.status != status else { return }
        finding.setStatus(status)
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

        let copier = Self.photoCopier()
        do {
            return try await Task.detached(priority: .userInitiated) {
                try SurveyExporter(store: store, photoCopier: copier).export(survey, format: format, into: destination)
            }.value
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// The way photos get into an export: copied as they are, or pixelated where they show a
    /// face or a plate, when the person switched that on.
    static func photoCopier() -> SurveyExporter.PhotoCopier? {
        guard SettingsStore.load().anonymisesPhotos else { return nil }
        return { source, destination in try PhotoAnonymizer.anonymise(source, to: destination) }
    }

    // MARK: - Helpers

    static func defaultName(for date: Date) -> String {
        let stamp = date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        return String(localized: "Route \(stamp)")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
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
