import Foundation

/// Decoded Bluetooth sensor values of one recording, one row per field.
///
/// Long rather than wide for the same reason ``AdvertisementLog`` is a CSV at all: which
/// sensors turn up, and with which fields, is only known once they do. A RuuviTag brings
/// eight columns, a heart rate strap two, a decoder file whatever it returns — one table per
/// combination would be a schema nobody can predict. `pandas.pivot` makes it wide in a line.
public final class BLEReadingLog: @unchecked Sendable {
    public static let fileName = "bluetooth_sensors.csv"
    public static let header = "time,seconds_elapsed,device,name,decoder,field,value"

    private let handle: FileHandle
    private let startHostTime: Double
    private let lock = NSLock()
    private var pending = ""
    private var rows = 0

    public init(directory: URL, startHostTime: Double) throws {
        let url = directory.appendingPathComponent(Self.fileName)
        FileManager.default.createFile(atPath: url.path,
                                       contents: Data((Self.header + "\n").utf8))
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        self.startHostTime = startHostTime
    }

    public func append(hostTime: Double, device: UUID, name: String?, reading: BLEReading) {
        let prefix = "\(Self.number(hostTime)),\(Self.number(hostTime - startHostTime)),"
            + "\(device.uuidString),\(RecordingExporter.csvEscape(name ?? "")),"
            + "\(RecordingExporter.csvEscape(reading.decoder)),"
        let text = reading.fields.map {
            prefix + "\(RecordingExporter.csvEscape($0.name)),\(Self.number($0.value))\n"
        }.joined()

        let flush: String? = lock.withLock {
            pending += text
            rows += reading.fields.count
            guard rows >= 256 else { return nil }
            rows = 0
            let out = pending
            pending.removeAll(keepingCapacity: true)
            return out
        }
        if let flush { try? handle.write(contentsOf: Data(flush.utf8)) }
    }

    public func close() {
        let remaining = lock.withLock { () -> String in
            let out = pending
            pending.removeAll()
            return out
        }
        if !remaining.isEmpty { try? handle.write(contentsOf: Data(remaining.utf8)) }
        try? handle.close()
    }

    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        return String(format: "%.6f", value)
    }
}
