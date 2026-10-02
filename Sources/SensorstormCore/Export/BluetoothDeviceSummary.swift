import Foundation

/// The devices of a recording's advertisement log, one row each: which were there, under what
/// names, from which manufacturer, when first and last, how loud.
///
/// The raw log has a row per packet — thousands an hour at a station. Someone who wants to
/// know "which sensors were in that room" does not want to count them.
public enum BluetoothDeviceSummary {
    public static let fileName = "bluetooth_devices.csv"
    public static let header = "address,names,company,services,first_seen,last_seen,packets,rssi_min,rssi_mean,rssi_max"

    private struct Entry {
        var names: [String] = []
        var company: String = ""
        var services: [String] = []
        var first = Double.infinity
        var last = -Double.infinity
        var packets = 0
        var rssiSum = 0.0
        var rssiCount = 0
        var rssiMin = Double.infinity
        var rssiMax = -Double.infinity
    }

    /// `nil` when the log has no packets. Times are seconds since the recording started.
    public static func csv(fromAdvertisementLog log: String) -> String? {
        var entries: [String: Entry] = [:]
        var order: [String] = []

        for (index, line) in log.split(whereSeparator: \.isNewline).enumerated() where index > 0 {
            let fields = parse(String(line))
            // time, seconds_elapsed, address, rssi, name, manufacturer_hex, services
            guard fields.count >= 7, let elapsed = Double(fields[1]) else { continue }
            let address = fields[2]
            var entry = entries[address] ?? Entry()
            if entries[address] == nil { order.append(address) }

            entry.packets += 1
            entry.first = min(entry.first, elapsed)
            entry.last = max(entry.last, elapsed)
            if let rssi = Double(fields[3]), rssi != 0 {
                entry.rssiSum += rssi
                entry.rssiCount += 1
                entry.rssiMin = min(entry.rssiMin, rssi)
                entry.rssiMax = max(entry.rssiMax, rssi)
            }
            let name = fields[4]
            if !name.isEmpty, !entry.names.contains(name) { entry.names.append(name) }
            if entry.company.isEmpty, let data = Data(hex: fields[5]), !data.isEmpty,
               let company = BluetoothNames.company(in: data) {
                entry.company = company.name ?? String(format: "0x%04X", company.id)
            }
            for service in fields[6].split(separator: " ").map(String.init) where !entry.services.contains(service) {
                entry.services.append(service)
            }
            entries[address] = entry
        }
        guard !order.isEmpty else { return nil }

        var out = header + "\n"
        for address in order.sorted() {
            guard let entry = entries[address] else { continue }
            let mean = entry.rssiCount > 0 ? entry.rssiSum / Double(entry.rssiCount) : .nan
            let cells: [String] = [
                address,
                RecordingExporter.csvEscape(entry.names.joined(separator: " | ")),
                RecordingExporter.csvEscape(entry.company),
                RecordingExporter.csvEscape(entry.services.map { BluetoothNames.shortForm($0) }.joined(separator: " ")),
                number(entry.first), number(entry.last), "\(entry.packets)",
                number(entry.rssiMin), number(mean), number(entry.rssiMax)
            ]
            out += cells.joined(separator: ",") + "\n"
        }
        return out
    }

    private static func number(_ value: Double) -> String {
        value.isFinite ? String(format: "%.3f", value) : ""
    }

    /// One CSV line with quoted fields and doubled quotes.
    static func parse(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        var pending: Character? = iterator.next()
        while let character = pending {
            pending = iterator.next()
            if inQuotes {
                if character == "\"" {
                    if pending == "\"" {
                        current.append("\"")
                        pending = iterator.next()
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(character)
                }
            } else if character == "\"" {
                inQuotes = true
            } else if character == "," {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        fields.append(current)
        return fields
    }
}

extension Data {
    /// Lower- or upper-case hex without separators; `nil` for anything else.
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
