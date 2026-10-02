import CoreNFC
import Foundation

/// Reads one NFC sticker and hands back what is written on it: the text, or the address.
///
/// A sticker on a hydrant, a manhole cover or a piece of play equipment is the cheapest
/// proof there is that somebody stood there. The sticker carries the object's number; the
/// scan carries the time and, through the walk, the position.
final class NFCCheckpointReader: NSObject, NFCNDEFReaderSessionDelegate, @unchecked Sendable {
    enum Failure: Error, LocalizedError {
        case unavailable, cancelled, empty

        var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "Dieses Gerät kann keine NFC-Aufkleber lesen.")
            case .cancelled: nil
            case .empty: String(localized: "Auf dem Aufkleber steht kein Text und keine Adresse.")
            }
        }
    }

    static var isAvailable: Bool { NFCNDEFReaderSession.readingAvailable }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var session: NFCNDEFReaderSession?

    /// Shows the system scan sheet with `prompt` and returns the first record's text or URL.
    func scan(prompt: String) async throws -> String {
        guard Self.isAvailable else { throw Failure.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            let session = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: true)
            session.alertMessage = prompt
            lock.withLock { self.session = session }
            session.begin()
        }
    }

    private func finish(_ result: Result<String, Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<String, Error>? in
            let current = continuation
            continuation = nil
            return current
        }
        pending?.resume(with: result)
    }

    /// The first record that holds readable text or an address. Plain text wins over nothing;
    /// an address is returned as the string a person would copy.
    static func text(from messages: [NFCNDEFMessage]) -> String? {
        for message in messages {
            for record in message.records {
                if let url = record.wellKnownTypeURIPayload() { return url.absoluteString }
                let (text, _) = record.wellKnownTypeTextPayload()
                if let text, !text.isEmpty { return text }
            }
        }
        return nil
    }

    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        if let text = Self.text(from: messages) {
            session.alertMessage = text
            finish(.success(text))
        } else {
            finish(.failure(Failure.empty))
        }
    }

    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        // After a successful read the session ends with `firstNDEFTagRead`; the continuation
        // is gone by then and this does nothing.
        let code = (error as? NFCReaderError)?.code
        if code == .readerSessionInvalidationErrorUserCanceled {
            finish(.failure(Failure.cancelled))
        } else {
            finish(.failure(error))
        }
    }
}
