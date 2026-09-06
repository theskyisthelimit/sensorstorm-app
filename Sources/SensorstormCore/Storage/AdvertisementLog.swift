import Foundation

/// The raw Bluetooth advertisements of one recording, as a CSV alongside the binary streams.
///
/// It is a separate file rather than a stream because it cannot be one. A `.ssbin` stream is
/// a fixed-width row of `Double`s, and that is precisely what makes scrubbing a half-hour
/// recording instant — a binary search needs rows of a known size. An advertisement is a
/// UUID, a name and a bag of manufacturer bytes. Bending the stream format around it would
/// cost every other sensor its random access, so it goes next to them instead of into them.
///
/// What this buys: RuuviTag, BTHome and similar sensors put their temperature, humidity and
/// pressure straight into the manufacturer data field. Logging it raw means those readings
/// are in the recording and can be decoded afterwards, by whichever decoder matches the
/// beacon — rather than needing a decoder for every beacon to be built into this app first.
///
/// **The addresses are not device addresses.** iOS never hands out a BLE hardware address;
/// what CoreBluetooth reports is a per-app, per-device identifier that a beacon's own
/// rotating address also changes underneath. Two recordings will not agree on it.
public final class AdvertisementLog: @unchecked Sendable {
    public static let fileName = "bluetooth_advertisements.csv"
    public static let header =
        "time,seconds_elapsed,address,rssi,name,manufacturer_hex,services"

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

    /// Called from the Bluetooth scan queue, once per advertisement — which at a busy
    /// station is a few hundred a second, hence the buffer.
    public func append(hostTime: Double, address: UUID, rssi: Double,
                       name: String?, manufacturerData: Data?, services: [String]) {
        var row = "\(number(hostTime)),\(number(hostTime - startHostTime))"
        row += ",\(address.uuidString),\(number(rssi))"
        row += ",\(RecordingExporter.csvEscape(name ?? ""))"
        row += ",\(manufacturerData.map(Self.hex) ?? "")"
        row += ",\(RecordingExporter.csvEscape(services.joined(separator: " ")))"
        row += "\n"

        let flush: String? = lock.withLock {
            pending += row
            rows += 1
            guard rows % 256 == 0 else { return nil }
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

    /// Lower-case, no separators — the shape every BLE decoder's documentation uses, and
    /// what `bytes.fromhex()` reads in one call.
    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func number(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        return String(format: "%.6f", value)
    }
}
