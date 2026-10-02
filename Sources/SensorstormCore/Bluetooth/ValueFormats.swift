import Foundation

/// The ways a characteristic's raw bytes can be read: the explorer lets the person switch,
/// because the same four bytes are a name, a counter or a temperature depending on the device.
public enum GATTValueFormat: String, CaseIterable, Sendable, Identifiable {
    case hex, text, decimal, unsigned, signed, float, binary

    public var id: String { rawValue }

    /// The bytes in this format, or `nil` when they cannot be read that way (not valid text,
    /// a width no integer has, not four or eight bytes for a float).
    public func render(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let bytes = [UInt8](data)
        switch self {
        case .hex:
            return HexCoding.string(data)
        case .text:
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            // Control bytes other than line breaks and tabs mean this is data, not text.
            let allowed = CharacterSet.controlCharacters.subtracting(CharacterSet(charactersIn: "\n\r\t"))
            guard text.unicodeScalars.allSatisfy({ !allowed.contains($0) }) else { return nil }
            return text
        case .decimal:
            return bytes.map(String.init).joined(separator: " ")
        case .binary:
            return bytes.map { byte in
                let digits = String(byte, radix: 2)
                return String(repeating: "0", count: 8 - digits.count) + digits
            }.joined(separator: " ")
        case .unsigned:
            guard Self.integerWidths.contains(bytes.count) else { return nil }
            let little = Self.integer(bytes, bigEndian: false)
            guard bytes.count > 1 else { return String(little) }
            return "\(little) (LE), \(Self.integer(bytes, bigEndian: true)) (BE)"
        case .signed:
            guard Self.integerWidths.contains(bytes.count) else { return nil }
            let little = Self.signed(bytes, bigEndian: false)
            guard bytes.count > 1 else { return String(little) }
            return "\(little) (LE), \(Self.signed(bytes, bigEndian: true)) (BE)"
        case .float:
            switch bytes.count {
            case 4:
                let little = Float(bitPattern: UInt32(truncatingIfNeeded: Self.integer(bytes, bigEndian: false)))
                let big = Float(bitPattern: UInt32(truncatingIfNeeded: Self.integer(bytes, bigEndian: true)))
                return "\(Self.shortest(Double(little))) (LE), \(Self.shortest(Double(big))) (BE)"
            case 8:
                let little = Double(bitPattern: Self.integer(bytes, bigEndian: false))
                let big = Double(bitPattern: Self.integer(bytes, bigEndian: true))
                return "\(Self.shortest(little)) (LE), \(Self.shortest(big)) (BE)"
            default:
                return nil
            }
        }
    }

    static let integerWidths = [1, 2, 4, 8]

    static func integer(_ bytes: [UInt8], bigEndian: Bool) -> UInt64 {
        (bigEndian ? bytes : bytes.reversed()).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    static func signed(_ bytes: [UInt8], bigEndian: Bool) -> Int64 {
        let raw = integer(bytes, bigEndian: bigEndian)
        let bits = UInt64(bytes.count * 8)
        guard bits < 64, raw & (1 << (bits - 1)) != 0 else { return Int64(bitPattern: raw) }
        return Int64(bitPattern: raw | (UInt64.max << bits))
    }

    /// `%g` for a reading: enough digits to see the value, not seventeen of them.
    static func shortest(_ value: Double) -> String {
        guard value.isFinite else { return value.isNaN ? "NaN" : (value < 0 ? "-inf" : "inf") }
        return String(format: "%g", value)
    }
}

/// One device seen by the scanner and kept: when it first and last turned up, how many
/// packets, how strong it was. The scanner's own table forgets after a minute and at exit;
/// this is what stays for a walk through a building.
public struct Sighting: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String?
    public var company: String?
    public var services: [String]
    public var manufacturerData: String?
    public var firstSeen: Date
    public var lastSeen: Date
    public var packets: Int
    public var rssiMin: Double
    public var rssiMax: Double
    public var rssiLast: Double
    public var isConnectable: Bool?
}

public struct SightingLog: Codable, Sendable, Equatable {
    public private(set) var entries: [Sighting] = []

    /// The packet count each device had at the last merge. Not stored: the scanner's counters
    /// start again with every launch, and a count from the last run must not be subtracted
    /// from this one's.
    private var merged: [UUID: Int] = [:]

    public static let capacity = 2_000

    public init() {}

    private enum CodingKeys: String, CodingKey { case entries }

    public init(from decoder: Decoder) throws {
        entries = try decoder.container(keyedBy: CodingKeys.self).decode([Sighting].self, forKey: .entries)
    }

    /// Folds the scanner's current table in. A device that sent nothing since the last call
    /// is left alone, so the last-seen time is when it was last heard and not when this ran.
    public mutating func merge(_ devices: [ScannedDevice], now: Date = Date()) {
        var index: [UUID: Int] = [:]
        for (position, entry) in entries.enumerated() { index[entry.id] = position }

        for device in devices {
            let previous = merged[device.id] ?? 0
            // The scanner's list was cleared and the device came back: its counter restarted.
            let delta = device.count >= previous ? device.count - previous : device.count
            merged[device.id] = device.count

            if let position = index[device.id] {
                guard delta > 0 else { continue }
                var entry = entries[position]
                entry.lastSeen = now
                entry.packets += delta
                entry.rssiMin = min(entry.rssiMin, device.rssi)
                entry.rssiMax = max(entry.rssiMax, device.rssi)
                entry.rssiLast = device.rssi
                Self.refresh(&entry, from: device)
                entries[position] = entry
            } else {
                var entry = Sighting(id: device.id, name: nil, company: nil, services: [], manufacturerData: nil,
                                     firstSeen: now, lastSeen: now, packets: max(device.count, 1),
                                     rssiMin: device.rssi, rssiMax: device.rssi, rssiLast: device.rssi,
                                     isConnectable: nil)
                Self.refresh(&entry, from: device)
                index[device.id] = entries.count
                entries.append(entry)
            }
        }
        if entries.count > Self.capacity {
            entries.sort { $0.lastSeen > $1.lastSeen }
            entries.removeLast(entries.count - Self.capacity)
        }
    }

    private static func refresh(_ entry: inout Sighting, from device: ScannedDevice) {
        if let name = device.name { entry.name = name }
        if let company = device.company { entry.company = company.name ?? String(format: "0x%04X", company.id) }
        if !device.serviceUUIDs.isEmpty { entry.services = device.serviceNames }
        if let data = device.manufacturerData { entry.manufacturerData = HexCoding.string(data, separator: "") }
        if let connectable = device.isConnectable { entry.isConnectable = connectable }
    }

    public mutating func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        merged[id] = nil
    }

    public mutating func removeAll() {
        entries.removeAll()
        merged.removeAll()
    }

    /// One row per device, for a spreadsheet.
    public func csv() -> String {
        let formatter = ISO8601DateFormatter()
        var lines = ["id,name,company,services,first_seen,last_seen,packets,rssi_min,rssi_max,rssi_last,connectable,manufacturer_data"]
        for entry in entries.sorted(by: { $0.firstSeen < $1.firstSeen }) {
            let fields = [
                entry.id.uuidString, entry.name ?? "", entry.company ?? "", entry.services.joined(separator: "; "),
                formatter.string(from: entry.firstSeen), formatter.string(from: entry.lastSeen),
                String(entry.packets), String(Int(entry.rssiMin)), String(Int(entry.rssiMax)),
                String(Int(entry.rssiLast)), entry.isConnectable.map { $0 ? "yes" : "no" } ?? "",
                entry.manufacturerData ?? "",
            ]
            lines.append(fields.map(RecordingExporter.csvEscape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
