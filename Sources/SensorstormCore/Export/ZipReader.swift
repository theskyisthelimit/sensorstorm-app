import Foundation
import zlib

/// Reads a zip back: the central directory, and stored or deflated entries.
///
/// The app writes zips in two ways — the system's own packager (deflated, nested in a
/// folder) and ``ZipWriter`` (stored) — and a person can hand it a third from a laptop.
/// What all of them have in common is the plain 1990s subset implemented here: no zip64,
/// no encryption, no split archives. Anything outside it is refused by name, not misread.
public enum ZipReader {

    public struct Entry: Sendable, Equatable {
        public var name: String
        public var method: UInt16
        public var compressedSize: UInt32
        public var uncompressedSize: UInt32
        public var crc: UInt32
        public var localHeaderOffset: UInt32

        public var isDirectory: Bool { name.hasSuffix("/") }
    }

    public enum ZipError: Error, LocalizedError, Equatable {
        case notAZip
        case unsupported(String)
        case corrupt(String)
        case unsafePath(String)
        case tooLarge

        public var errorDescription: String? {
            switch self {
            case .notAZip: String(localized: "Die Datei ist kein Zip-Archiv.")
            case .unsupported(let what): String(localized: "Das Archiv nutzt etwas, das hier nicht gelesen wird: \(what).")
            case .corrupt(let name): String(localized: "Das Archiv ist beschädigt (\(name)).")
            case .unsafePath(let name): String(localized: "Das Archiv enthält einen unzulässigen Pfad: \(name).")
            case .tooLarge: String(localized: "Das Archiv ist zu gross.")
            }
        }
    }

    // MARK: - Directory

    public static func entries(of url: URL) throws -> [Entry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try entries(in: handle)
    }

    static func entries(in handle: FileHandle) throws -> [Entry] {
        let size = try handle.seekToEnd()
        guard size >= 22 else { throw ZipError.notAZip }

        // The end-of-central-directory record sits in the last 64 KB plus 22 bytes: its fixed
        // part, and up to 65 535 bytes of comment after it.
        let tail = min(size, 65_557)
        try handle.seek(toOffset: size - tail)
        let end = [UInt8](try handle.read(upToCount: Int(tail)) ?? Data())
        guard let position = (0...(end.count - 22)).reversed().first(where: {
            end[$0] == 0x50 && end[$0 + 1] == 0x4B && end[$0 + 2] == 0x05 && end[$0 + 3] == 0x06
        }) else { throw ZipError.notAZip }

        let count = Int(le16(end, position + 10))
        let directorySize = Int(le32(end, position + 12))
        let directoryOffset = UInt64(le32(end, position + 16))
        if count == 0xFFFF || directoryOffset == 0xFFFF_FFFF || directorySize == 0xFFFF_FFFF {
            throw ZipError.unsupported("zip64")
        }
        guard directoryOffset + UInt64(directorySize) <= size else { throw ZipError.corrupt("directory") }

        try handle.seek(toOffset: directoryOffset)
        let directory = [UInt8](try handle.read(upToCount: directorySize) ?? Data())
        var entries: [Entry] = []
        var cursor = 0
        for _ in 0..<count {
            guard cursor + 46 <= directory.count, le32(directory, cursor) == 0x0201_4B50 else {
                throw ZipError.corrupt("directory")
            }
            let flags = le16(directory, cursor + 8)
            let nameLength = Int(le16(directory, cursor + 28))
            let extraLength = Int(le16(directory, cursor + 30))
            let commentLength = Int(le16(directory, cursor + 32))
            guard cursor + 46 + nameLength <= directory.count else { throw ZipError.corrupt("directory") }
            if flags & 1 != 0 { throw ZipError.unsupported("encryption") }
            let name = String(decoding: directory[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            entries.append(Entry(name: name, method: le16(directory, cursor + 10),
                                 compressedSize: le32(directory, cursor + 20),
                                 uncompressedSize: le32(directory, cursor + 24),
                                 crc: le32(directory, cursor + 16),
                                 localHeaderOffset: le32(directory, cursor + 42)))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    // MARK: - Extract

    /// Unpacks every entry below `destination`.
    ///
    /// - Parameter maximumTotalSize: the sum of the declared sizes beyond which nothing is
    ///   written. A few kilobytes of zip can claim terabytes.
    public static func extract(_ url: URL, to destination: URL,
                               maximumTotalSize: Int64 = 16 << 30,
                               progress: (@Sendable (Double) -> Void)? = nil) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let entries = try entries(in: handle)
        guard entries.reduce(0, { $0 + Int64($1.uncompressedSize) }) <= maximumTotalSize else { throw ZipError.tooLarge }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let root = destination.standardizedFileURL.path

        for (index, entry) in entries.enumerated() {
            // Mac zips carry a resource-fork shadow of every file; nothing here reads it.
            guard !entry.name.hasPrefix("__MACOSX/"), !entry.name.hasSuffix(".DS_Store") else { continue }
            let parts = entry.name.split(separator: "/", omittingEmptySubsequences: true)
            guard !entry.name.hasPrefix("/"), !entry.name.contains("\\"),
                  !parts.contains("..") else { throw ZipError.unsafePath(entry.name) }
            let target = destination.appendingPathComponent(parts.joined(separator: "/"),
                                                            isDirectory: entry.isDirectory)
            guard target.standardizedFileURL.path.hasPrefix(root) else { throw ZipError.unsafePath(entry.name) }

            if entry.isDirectory {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try write(entry, from: handle, to: target)
            }
            progress?(Double(index + 1) / Double(entries.count))
        }
    }

    private static func write(_ entry: Entry, from handle: FileHandle, to target: URL) throws {
        try handle.seek(toOffset: UInt64(entry.localHeaderOffset))
        let header = [UInt8](try handle.read(upToCount: 30) ?? Data())
        guard header.count == 30, le32(header, 0) == 0x0403_4B50 else { throw ZipError.corrupt(entry.name) }
        let skip = UInt64(le16(header, 26)) + UInt64(le16(header, 28))
        try handle.seek(toOffset: UInt64(entry.localHeaderOffset) + 30 + skip)

        FileManager.default.createFile(atPath: target.path, contents: nil)
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }

        var crc: uLong = 0
        var remaining = Int(entry.compressedSize)
        let chunk = 1 << 16

        switch entry.method {
        case 0:
            while remaining > 0 {
                guard let piece = try handle.read(upToCount: min(remaining, chunk)), !piece.isEmpty else {
                    throw ZipError.corrupt(entry.name)
                }
                crc = piece.withUnsafeBytes { crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
                try output.write(contentsOf: piece)
                remaining -= piece.count
            }
        case 8:
            var stream = z_stream()
            guard inflateInit2_(&stream, -15, "1.2.11", Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw ZipError.corrupt(entry.name)
            }
            defer { inflateEnd(&stream) }
            var finished = false
            var produced = [UInt8](repeating: 0, count: chunk)
            while remaining > 0, !finished {
                guard var input = try handle.read(upToCount: min(remaining, chunk)), !input.isEmpty else {
                    throw ZipError.corrupt(entry.name)
                }
                remaining -= input.count
                let available = input.count
                try input.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                    stream.next_in = raw.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_in = uInt(available)
                    while stream.avail_in > 0, !finished {
                        let status: Int32 = produced.withUnsafeMutableBufferPointer { out in
                            stream.next_out = out.baseAddress
                            stream.avail_out = uInt(chunk)
                            return inflate(&stream, Z_NO_FLUSH)
                        }
                        guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                            throw ZipError.corrupt(entry.name)
                        }
                        let count = chunk - Int(stream.avail_out)
                        if count > 0 {
                            let piece = Data(produced[0..<count])
                            crc = piece.withUnsafeBytes { crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
                            try output.write(contentsOf: piece)
                        }
                        if status == Z_STREAM_END { finished = true }
                        if status == Z_BUF_ERROR, count == 0 { break }
                    }
                }
            }
        default:
            throw ZipError.unsupported("method \(entry.method)")
        }
        guard UInt32(truncatingIfNeeded: crc) == entry.crc else { throw ZipError.corrupt(entry.name) }
    }

    // MARK: - Bytes

    private static func le16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(le16(bytes, offset)) | UInt32(le16(bytes, offset + 2)) << 16
    }
}
