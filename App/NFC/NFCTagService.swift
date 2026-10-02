import CoreNFC
import Foundation
import SensorstormCore

/// What to do with the tag that is held to the phone.
enum NFCAction: Sendable {
    case read
    /// Write this message, given as NDEF bytes.
    case write(Data)
    case erase
    /// Make the tag read-only for good. There is no way back.
    case lock

    /// Only a plain read also dumps the raw memory; before a write it would be wasted time
    /// with the tag held to the phone.
    var readsMemory: Bool {
        if case .read = self { true } else { false }
    }
}

struct NFCOutcome: Sendable {
    var info: NFCTagInfo
    var didWrite = false
    var didLock = false
    /// After a write: the message read back from the tag was the one written. `nil` when the
    /// tag could not be read again, which is not the same as a failed write.
    var verified: Bool?
}

enum NFCFailure: Error, LocalizedError {
    case unavailable
    case cancelled
    case readOnly
    case notNDEF
    case tooLarge(capacity: Int, needed: Int)
    case moreThanOneTag

    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "Dieses Gerät kann keine NFC-Tags lesen oder schreiben.")
        case .cancelled: nil
        case .readOnly: String(localized: "Dieser Tag ist schreibgeschützt.")
        case .notNDEF: String(localized: "Dieser Tag lässt sich nicht im NDEF-Format beschreiben.")
        case .tooLarge(let capacity, let needed):
            String(localized: "Die Nachricht braucht \(needed) Byte, der Tag fasst \(capacity).")
        case .moreThanOneTag: String(localized: "Mehr als ein Tag in Reichweite. Halte nur einen.")
        }
    }
}

/// Reads, writes, erases and locks NFC tags through one scan sheet.
///
/// A single `NFCTagReaderSession` serves every job, and not the simpler NDEF reader session,
/// because only the tag session says what kind of chip is there: MIFARE Ultralight, NTAG,
/// ISO 15693, FeliCa. Everything that touches the tag runs in one task between `connect` and
/// the end of the session; the session and the tag never leave it.
final class NFCTagService: NSObject, NFCTagReaderSessionDelegate, @unchecked Sendable {

    static var isAvailable: Bool { NFCTagReaderSession.readingAvailable }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<NFCOutcome, Error>?
    private var action: NFCAction = .read
    private var successMessage = ""

    private final class Box<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    func run(_ action: NFCAction, prompt: String, success: String) async throws -> NFCOutcome {
        guard Self.isAvailable,
              let session = NFCTagReaderSession(pollingOption: [.iso14443, .iso15693, .iso18092], delegate: self)
        else { throw NFCFailure.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                self.continuation = continuation
                self.action = action
                self.successMessage = success
            }
            session.alertMessage = prompt
            session.begin()
        }
    }

    private func finish(_ result: Result<NFCOutcome, Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<NFCOutcome, Error>? in
            let current = continuation
            continuation = nil
            return current
        }
        pending?.resume(with: result)
    }

    // MARK: Delegate

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        // After a job ends the continuation is gone and this does nothing.
        if (error as? NFCReaderError)?.code == .readerSessionInvalidationErrorUserCanceled {
            finish(.failure(NFCFailure.cancelled))
        } else {
            finish(.failure(error))
        }
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard tags.count == 1, let tag = tags.first else {
            session.alertMessage = String(localized: "Mehr als ein Tag erkannt. Halte nur einen.")
            session.restartPolling()
            return
        }
        let (action, success) = lock.withLock { (self.action, self.successMessage) }
        let session = Box(session)
        let tag = Box(tag)
        Task { await self.handle(tag, session: session, action: action, success: success) }
    }

    // MARK: Job

    private func handle(_ tag: Box<NFCTag>, session: Box<NFCTagReaderSession>, action: NFCAction,
                        success: String) async {
        do {
            try await session.value.connect(to: tag.value)
            var outcome = try await Self.inspect(tag.value, readMemory: action.readsMemory)
            switch action {
            case .read:
                break
            case .write(let bytes):
                try await Self.write(bytes, to: tag.value, into: &outcome)
            case .erase:
                try await Self.write(NDEFMessage.erased.serialized(), to: tag.value, into: &outcome)
            case .lock:
                guard outcome.info.ndefStatus != .notSupported else { throw NFCFailure.notNDEF }
                guard outcome.info.isWritable else { throw NFCFailure.readOnly }
                try await Self.ndefTag(of: tag.value).writeLock()
                outcome.didLock = true
                outcome.info.ndefStatus = .readOnly
            }
            session.value.alertMessage = success
            finish(.success(outcome))
            session.value.invalidate()
        } catch {
            finish(.failure(error))
            session.value.invalidate(errorMessage: error.localizedDescription)
        }
    }

    private static func ndefTag(of tag: NFCTag) throws -> NFCNDEFTag {
        switch tag {
        case .miFare(let tag): return tag
        case .iso7816(let tag): return tag
        case .feliCa(let tag): return tag
        case .iso15693(let tag): return tag
        @unknown default: throw NFCFailure.notNDEF
        }
    }

    /// Everything the chip answers without being written to.
    private static func inspect(_ tag: NFCTag, readMemory: Bool) async throws -> NFCOutcome {
        var info: NFCTagInfo
        var miFare: NFCMiFareTag?
        switch tag {
        case .miFare(let tag):
            let technology: NFCTagInfo.Technology
            switch tag.mifareFamily {
            case .ultralight: technology = .miFareUltralight
            case .plus: technology = .miFarePlus
            case .desfire: technology = .miFareDESFire
            case .unknown: technology = .miFare
            @unknown default: technology = .miFare
            }
            info = NFCTagInfo(technology: technology, uid: tag.identifier, historicalBytes: tag.historicalBytes)
            miFare = tag
        case .iso7816(let tag):
            info = NFCTagInfo(technology: .iso7816, uid: tag.identifier, historicalBytes: tag.historicalBytes,
                              applicationData: tag.applicationData)
        case .feliCa(let tag):
            info = NFCTagInfo(technology: .felica, uid: tag.currentIDm, systemCode: tag.currentSystemCode)
        case .iso15693(let tag):
            info = NFCTagInfo(technology: .iso15693, uid: tag.identifier,
                              manufacturerCode: UInt8(truncatingIfNeeded: tag.icManufacturerCode))
        @unknown default:
            throw NFCFailure.notNDEF
        }

        let ndef = try ndefTag(of: tag)
        if let (status, capacity) = try? await ndef.queryNDEFStatus() {
            switch status {
            case .notSupported: info.ndefStatus = .notSupported
            case .readOnly: info.ndefStatus = .readOnly
            case .readWrite: info.ndefStatus = .readWrite
            @unknown default: info.ndefStatus = nil
            }
            info.ndefCapacity = capacity
        }
        if info.ndefStatus != .notSupported, let message = try? await ndef.readNDEF() {
            info.message = convert(message)
        }
        if readMemory, let miFare, info.technology == .miFareUltralight {
            await dumpMemory(of: miFare, into: &info)
        }
        return NFCOutcome(info: info)
    }

    /// Pages of an Ultralight or NTAG chip, four bytes each, read sixteen bytes at a time. The
    /// chip is asked what it is first, because it answers a read past its end by wrapping to
    /// page 0, and a dump that silently repeats itself is worse than a short one.
    private static func dumpMemory(of tag: NFCMiFareTag, into info: inout NFCTagInfo) async {
        var pages = 16
        if let response = try? await tag.sendMiFareCommand(commandPacket: Data([0x60])),
           let version = NTAGVersion(response: response) {
            info.version = version
            pages = version.totalPages ?? 16
        }
        var memory = Data()
        var page = 0
        while page < pages {
            guard let chunk = try? await tag.sendMiFareCommand(commandPacket: Data([0x30, UInt8(page)])),
                  chunk.count == 16 else { break }
            memory.append(chunk)
            page += 4
        }
        if !memory.isEmpty { info.memory = memory.prefix(pages * 4) }
    }

    private static func write(_ bytes: Data, to tag: NFCTag, into outcome: inout NFCOutcome) async throws {
        guard let message = NDEFMessage(data: bytes) else { throw NFCFailure.notNDEF }
        let status = outcome.info.ndefStatus
        guard status != .notSupported else { throw NFCFailure.notNDEF }
        guard status == .readWrite else { throw NFCFailure.readOnly }
        if let capacity = outcome.info.ndefCapacity, bytes.count > capacity {
            throw NFCFailure.tooLarge(capacity: capacity, needed: bytes.count)
        }
        let ndef = try ndefTag(of: tag)
        try await ndef.writeNDEF(convert(message))
        outcome.didWrite = true
        // Read it back: a write that the tag accepted and then lost is rare and costly.
        if let readBack = try? await ndef.readNDEF() {
            let confirmed = convert(readBack)
            outcome.verified = confirmed == message || (message.isBlank && confirmed.isBlank)
            outcome.info.message = confirmed
        } else {
            outcome.verified = message.isBlank ? true : nil
            outcome.info.message = message.isBlank ? .erased : message
        }
    }

    // MARK: Conversion

    private static func convert(_ message: NFCNDEFMessage) -> NDEFMessage {
        NDEFMessage(records: message.records.map { payload in
            NDEFRecord(format: NDEFRecord.Format(rawValue: payload.typeNameFormat.rawValue) ?? .unknown,
                       type: payload.type, identifier: payload.identifier, payload: payload.payload)
        })
    }

    private static func convert(_ message: NDEFMessage) -> NFCNDEFMessage {
        NFCNDEFMessage(records: message.records.map { record in
            NFCNDEFPayload(format: NFCTypeNameFormat(rawValue: record.format.rawValue) ?? .unknown,
                           type: record.type, identifier: record.identifier, payload: record.payload)
        })
    }
}
