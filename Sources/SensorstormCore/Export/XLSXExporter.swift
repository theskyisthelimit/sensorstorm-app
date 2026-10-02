import Foundation
import zlib

/// The recording as an Excel workbook: one sheet per sensor, `time` and `epoch` first.
///
/// Written by hand rather than through a library. A workbook is a zip of five small XML
/// files plus one per sheet, and numbers and inline header strings are all this needs — no
/// styles, no shared-string table, no formulas.
public struct XLSXExporter: Sendable {
    public static let fileName = "recording.xlsx"

    /// Excel's hard row limit, header included. A longer stream is cut, and the sheet says so
    /// in its last header cell rather than quietly ending early.
    static let maximumRows = 1_048_576

    private let store: RecordingStore

    public init(store: RecordingStore) {
        self.store = store
    }

    public func write(_ metadata: RecordingMetadata, to url: URL,
                      progress: (@Sendable (Double) -> Void)? = nil) throws {
        let streams = metadata.streams.filter { $0.sampleCount > 0 }
        let zip = try ZipWriter(url: url)
        let epochAtStart = metadata.startedAt.timeIntervalSince1970

        var sheetNames: [String] = []
        for (index, stream) in streams.enumerated() {
            guard let reader = store.reader(for: stream.sensor, recording: metadata.id) else { continue }
            let truncated = stream.sampleCount > Self.maximumRows - 1
            var header = ["time", "epoch"] + stream.channels.enumerated().map { $1.isEmpty ? "c\($0)" : $1 }
            if truncated { header.append("truncated to \(Self.maximumRows - 1) rows") }

            // ponytail: one sheet in memory at a time — a 30-minute 400 Hz stream is ~100 MB
            // of XML. Stream it to the zip if that ever runs a phone out of memory.
            var xml = """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
                """
            xml += "<row>" + header.map { "<c t=\"inlineStr\"><is><t>\(Self.escape($0))</t></is></c>" }.joined() + "</row>"
            var rows = 1
            reader.forEachSample { hostTime, values in
                guard rows < Self.maximumRows else { return }
                rows += 1
                let relative = hostTime - metadata.startHostTime
                xml += "<row>" + Self.cell(relative) + Self.cell(epochAtStart + relative)
                for value in values { xml += Self.cell(value) }
                xml += "</row>"
            }
            xml += "</sheetData></worksheet>"
            sheetNames.append(stream.sensor.rawValue)
            try zip.add("xl/worksheets/sheet\(sheetNames.count).xml", Data(xml.utf8))
            progress?(Double(index + 1) / Double(streams.count + 1))
        }

        let sheets = sheetNames.enumerated().map { index, name in
            "<sheet name=\"\(Self.escape(String(name.prefix(31))))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
        }.joined()
        let relationships = sheetNames.indices.map { index in
            "<Relationship Id=\"rId\(index + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(index + 1).xml\"/>"
        }.joined()
        let overrides = sheetNames.indices.map { index in
            "<Override PartName=\"/xl/worksheets/sheet\(index + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }.joined()

        try zip.add("[Content_Types].xml", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
            \(overrides)</Types>
            """.utf8))
        try zip.add("_rels/.rels", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
            </Relationships>
            """.utf8))
        try zip.add("xl/workbook.xml", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
            <sheets>\(sheets)</sheets></workbook>
            """.utf8))
        try zip.add("xl/_rels/workbook.xml.rels", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            \(relationships)</Relationships>
            """.utf8))
        try zip.finish()
        progress?(1)
    }

    /// A value the sensor could not produce stays an empty cell, never 0.
    private static func cell(_ value: Double) -> String {
        value.isFinite ? "<c><v>\(RecordingExporter.number(value))</v></c>" : "<c/>"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// A zip with stored (uncompressed) entries — what an `.xlsx` needs and nothing more.
///
/// ``ZipPackager`` cannot do it: the system zip puts the folder itself at the root, and a
/// workbook whose `[Content_Types].xml` sits one level down is not a workbook.
final class ZipWriter {
    private let handle: FileHandle
    private var central = Data()
    private var count: UInt16 = 0
    private var offset: UInt32 = 0

    init(url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func add(_ name: String, _ data: Data) throws {
        let crc = data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
        let nameBytes = Data(name.utf8)
        let size = UInt32(data.count)

        var local = Data()
        local.le32(0x04034B50); local.le16(20); local.le16(0x0800); local.le16(0)
        local.le16(0); local.le16(0x21)                       // time 00:00, date 1980-01-01
        local.le32(crc); local.le32(size); local.le32(size)
        local.le16(UInt16(nameBytes.count)); local.le16(0)
        local.append(nameBytes)
        try handle.write(contentsOf: local)
        try handle.write(contentsOf: data)

        central.le32(0x02014B50); central.le16(20); central.le16(20); central.le16(0x0800); central.le16(0)
        central.le16(0); central.le16(0x21)
        central.le32(crc); central.le32(size); central.le32(size)
        central.le16(UInt16(nameBytes.count)); central.le16(0); central.le16(0)
        central.le16(0); central.le16(0); central.le32(0); central.le32(offset)
        central.append(nameBytes)

        offset += UInt32(local.count) + size
        count += 1
    }

    func finish() throws {
        var end = Data()
        end.le32(0x06054B50); end.le16(0); end.le16(0)
        end.le16(count); end.le16(count)
        end.le32(UInt32(central.count)); end.le32(offset); end.le16(0)
        try handle.write(contentsOf: central)
        try handle.write(contentsOf: end)
        try handle.close()
    }
}

private extension Data {
    mutating func le16(_ value: UInt16) { append(UInt8(value & 0xFF)); append(UInt8(value >> 8)) }
    mutating func le32(_ value: UInt32) { le16(UInt16(value & 0xFFFF)); le16(UInt16(value >> 16)) }
}
