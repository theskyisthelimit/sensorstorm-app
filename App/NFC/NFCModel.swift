import Foundation
import Observation
import SensorstormCore

/// A message kept for later: a business card, a Wi-Fi tag, anything that gets written again.
struct SavedTag: Codable, Identifiable, Sendable, Equatable {
    var id = UUID()
    var name: String
    var date: Date
    /// The message as NDEF bytes.
    var message: Data
    /// The serial number of the tag it was read from, when it was read from one.
    var serial: String?

    var parsed: NDEFMessage? { NDEFMessage(data: message) }

    /// What the first meaningful record says, for the list row.
    var summary: String {
        guard let parsed else { return "" }
        for record in parsed.records {
            let text = NDEFContent(record).summary
            if !text.isEmpty { return text }
        }
        return ""
    }
}

/// The saved messages, in a small JSON file in Application Support.
@MainActor @Observable
final class NFCLibrary {
    private(set) var items: [SavedTag] = []
    private let url: URL

    init(directory: URL? = nil) {
        let base = directory ?? (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?
            .appendingPathComponent("NFC", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("NFC", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("tags.json")
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = ((try? decoder.decode([SavedTag].self, from: data)) ?? []).sorted { $0.date > $1.date }
        }
    }

    func add(name: String, message: NDEFMessage, serial: String? = nil) {
        items.insert(SavedTag(name: name, date: Date(), message: message.serialized(), serial: serial), at: 0)
        persist()
    }

    func rename(_ item: SavedTag, to name: String) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].name = name
        persist()
    }

    func delete(_ item: SavedTag) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(items) { try? data.write(to: url, options: .atomic) }
    }
}

/// The state of the NFC tool: the last tag read, what is in flight, what went wrong.
@MainActor @Observable
final class NFCModel {
    enum Job: Equatable { case reading, writing, erasing, locking }

    private(set) var info: NFCTagInfo?
    private(set) var job: Job?
    private(set) var failure: String?
    /// After a job: what happened, in a sentence.
    private(set) var notice: String?
    /// A message read from one tag and waiting to be written to another.
    private(set) var cloneSource: NDEFMessage?
    private(set) var cloneVerified: Bool?
    let library = NFCLibrary()

    private let service = NFCTagService()

    var isAvailable: Bool { NFCTagService.isAvailable }
    var isBusy: Bool { job != nil }

    func read() {
        run(.read, job: .reading, prompt: String(localized: "Halte das iPhone an den Tag."),
            success: String(localized: "Gelesen."))
    }

    func write(_ message: NDEFMessage) {
        run(.write(message.serialized()), job: .writing,
            prompt: String(localized: "Halte das iPhone an den Tag, auf den geschrieben werden soll."),
            success: String(localized: "Geschrieben."))
    }

    func erase() {
        run(.erase, job: .erasing, prompt: String(localized: "Halte das iPhone an den Tag, der gelöscht werden soll."),
            success: String(localized: "Gelöscht."))
    }

    func lock() {
        run(.lock, job: .locking,
            prompt: String(localized: "Halte das iPhone an den Tag, der für immer schreibgeschützt werden soll."),
            success: String(localized: "Schreibschutz gesetzt."))
    }

    /// Step one of copying: read the message of the source tag and keep it.
    func startClone() {
        run(.read, job: .reading, prompt: String(localized: "Halte das iPhone an den Tag, der kopiert werden soll."),
            success: String(localized: "Gelesen. Jetzt den Ziel-Tag.")) { [weak self] outcome in
            guard let self else { return }
            if let message = outcome.info.message, !message.isBlank {
                cloneSource = message
                cloneVerified = nil
            } else {
                failure = String(localized: "Auf dem Tag steht nichts, das sich kopieren lässt.")
            }
        }
    }

    /// Step two: write the kept message to the next tag.
    func finishClone() {
        guard let message = cloneSource else { return }
        run(.write(message.serialized()), job: .writing,
            prompt: String(localized: "Halte das iPhone an den Ziel-Tag."),
            success: String(localized: "Kopiert.")) { [weak self] outcome in
            self?.cloneVerified = outcome.verified
            if outcome.didWrite { self?.cloneSource = nil }
        }
    }

    func cancelClone() {
        cloneSource = nil
        cloneVerified = nil
    }

    func dismissFailure() {
        failure = nil
    }

    private func run(_ action: NFCAction, job: Job, prompt: String, success: String,
                     then handler: ((NFCOutcome) -> Void)? = nil) {
        guard !isBusy else { return }
        self.job = job
        failure = nil
        notice = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await service.run(action, prompt: prompt, success: success)
                info = outcome.info
                notice = Self.notice(for: outcome, job: job)
                handler?(outcome)
            } catch NFCFailure.cancelled {
                // The person closed the sheet: not an error to show.
            } catch {
                failure = error.localizedDescription
            }
            self.job = nil
        }
    }

    private static func notice(for outcome: NFCOutcome, job: Job) -> String? {
        switch job {
        case .reading: return nil
        case .writing:
            if outcome.verified == true { return String(localized: "Geschrieben und zurückgelesen: der Inhalt stimmt.") }
            if outcome.verified == false { return String(localized: "Geschrieben, aber der Tag gibt etwas anderes zurück. Bitte prüfen.") }
            return String(localized: "Geschrieben. Zurücklesen war nicht möglich.")
        case .erasing: return String(localized: "Der Tag ist leer.")
        case .locking: return String(localized: "Der Tag ist jetzt dauerhaft schreibgeschützt.")
        }
    }
}
