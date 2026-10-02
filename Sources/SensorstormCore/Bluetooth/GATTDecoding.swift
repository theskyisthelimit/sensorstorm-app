import Foundation

/// Reading the value of a GATT characteristic: the standard ones by their UUID, anything else
/// through the device's own Presentation Format descriptor or a template the user wrote.
///
/// Everything here is a pure function of bytes, because that is where a Bluetooth app goes
/// wrong without anybody noticing: a flag bit read as its neighbour, a 16-bit float read as an
/// integer. Each decoder is pinned by a test vector.
public enum GATTDecoding {

    // MARK: - Standard characteristics

    /// Decodes a standard characteristic, or `nil` if this app does not know it.
    ///
    /// - Parameter uuid: as CoreBluetooth prints it, short (`2A6E`) or full.
    public static func decode(characteristic uuid: String, _ data: Data) -> BLEReading? {
        let b = [UInt8](data)
        let short = BluetoothNames.shortForm(uuid)
        let name = BluetoothNames.characteristic(short) ?? short
        switch short {
        case "2A19":
            guard let level = b.first else { return nil }
            return reading(name, [("batteryLevel", Double(level))])
        case "2A6E":  // Temperature: sint16, 0.01 °C
            guard b.count >= 2 else { return nil }
            let raw = Int16(bitPattern: UInt16(b[1]) << 8 | UInt16(b[0]))
            return raw == Int16.min ? nil : reading(name, [("temperature", Double(raw) * 0.01)])
        case "2A6F":  // Humidity: uint16, 0.01 %
            guard b.count >= 2 else { return nil }
            let raw = UInt16(b[1]) << 8 | UInt16(b[0])
            return raw == .max ? nil : reading(name, [("humidity", Double(raw) * 0.01)])
        case "2A6D":  // Pressure: uint32, 0.1 Pa → hPa
            guard b.count >= 4 else { return nil }
            let raw = (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[$1]) << (8 * UInt32($1)) }
            return reading(name, [("pressure", Double(raw) * 0.1 / 100)])
        case "2A76":  // UV index: uint8
            guard let raw = b.first else { return nil }
            return reading(name, [("uvIndex", Double(raw))])
        case "2A77":  // Irradiance: uint16, 0.1 W/m²
            guard b.count >= 2 else { return nil }
            return reading(name, [("irradiance", Double(UInt16(b[1]) << 8 | UInt16(b[0])) * 0.1)])
        case "2A6C":  // Elevation: sint24, 0.01 m
            guard b.count >= 3 else { return nil }
            var raw = Int32(b[0]) | Int32(b[1]) << 8 | Int32(b[2]) << 16
            if raw & 0x800000 != 0 { raw -= 1 << 24 }
            return reading(name, [("elevation", Double(raw) * 0.01)])
        case "2A1C", "2A1E":  // Temperature Measurement: flags, IEEE-11073 FLOAT
            guard b.count >= 5 else { return nil }
            guard let value = float32(b, at: 1) else { return nil }
            let fahrenheit = b[0] & 0x01 != 0
            return reading(name, [("temperature", fahrenheit ? (value - 32) * 5 / 9 : value)])
        case "2A35":  // Blood Pressure Measurement: flags, three SFLOATs
            guard b.count >= 7 else { return nil }
            let scale = b[0] & 0x01 != 0 ? 7.500_617 : 1.0   // kPa → mmHg
            var fields: [(String, Double)] = []
            for (index, label) in ["systolic", "diastolic", "meanArterialPressure"].enumerated() {
                if let value = sfloat(b, at: 1 + 2 * index) { fields.append((label, value * scale)) }
            }
            return fields.isEmpty ? nil : reading(name, fields)
        case "2A5E", "2A5F":  // PLX: flags, SpO2 SFLOAT, pulse rate SFLOAT
            guard b.count >= 5 else { return nil }
            var fields: [(String, Double)] = []
            if let spo2 = sfloat(b, at: 1) { fields.append(("spo2", spo2)) }
            if let pulse = sfloat(b, at: 3) { fields.append(("pulseRate", pulse)) }
            return fields.isEmpty ? nil : reading(name, fields)
        case "2A9D":  // Weight Measurement: flags, uint16 — 0.005 kg, or 0.01 lb when bit 0 is set
            guard b.count >= 3 else { return nil }
            let raw = Double(UInt16(b[2]) << 8 | UInt16(b[1]))
            let imperial = b[0] & 0x01 != 0
            return raw == 0xFFFF ? nil
                : reading(name, [("weight", imperial ? raw * 0.01 * 0.453_592_37 : raw * 0.005)])
        default:
            return nil
        }
    }

    private static func reading(_ name: String, _ fields: [(String, Double)]) -> BLEReading {
        BLEReading(decoder: name, fields: fields.map { BLEReading.Field($0.0, $0.1) })
    }

    // MARK: - IEEE-11073 floats

    /// 32-bit FLOAT: an 8-bit signed exponent over a 24-bit signed mantissa, little endian.
    /// The five reserved mantissas — not a number, not at this resolution, ±infinity,
    /// reserved — are `nil`, never a value.
    static func float32(_ b: [UInt8], at index: Int) -> Double? {
        guard index + 4 <= b.count else { return nil }
        var mantissa = Int32(b[index]) | Int32(b[index + 1]) << 8 | Int32(b[index + 2]) << 16
        if mantissa & 0x800000 != 0 { mantissa -= 1 << 24 }
        if (0x7FFFFE...0x800002).contains(Int(mantissa) & 0xFFFFFF) || mantissa == 0x7FFFFF { return nil }
        let exponent = Int(Int8(bitPattern: b[index + 3]))
        return Double(mantissa) * pow(10, Double(exponent))
    }

    /// 16-bit SFLOAT: a 4-bit signed exponent over a 12-bit signed mantissa.
    static func sfloat(_ b: [UInt8], at index: Int) -> Double? {
        guard index + 2 <= b.count else { return nil }
        let raw = UInt16(b[index + 1]) << 8 | UInt16(b[index])
        var mantissa = Int(raw & 0x0FFF)
        if mantissa & 0x0800 != 0 { mantissa -= 0x1000 }
        var exponent = Int(raw >> 12)
        if exponent & 0x8 != 0 { exponent -= 16 }
        // NaN, NRes, +INF, −INF and the reserved value.
        if [0x07FF, 0x0800, 0x07FE, 0x0802, 0x0801].contains(Int(raw & 0x0FFF)) { return nil }
        return Double(mantissa) * pow(10, Double(exponent))
    }
}

/// The 7-byte Presentation Format descriptor (`0x2904`): how to read the characteristic it
/// belongs to. A device that sets it can be read with no decoder at all, and with its unit.
public struct PresentationFormat: Sendable, Equatable {
    public var format: UInt8
    public var exponent: Int8
    public var unit: UInt16

    public init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 7 else { return nil }
        format = b[0]
        exponent = Int8(bitPattern: b[1])
        unit = UInt16(b[3]) << 8 | UInt16(b[2])
    }

    /// The size in bytes of a format this can read, or `nil` for text, bit fields and structs.
    public var byteCount: Int? {
        switch format {
        case 0x04, 0x0C: 1
        case 0x06, 0x0E, 0x16: 2
        case 0x07, 0x0F: 3
        case 0x08, 0x10, 0x14, 0x17: 4
        case 0x0A, 0x12, 0x15: 8
        default: nil
        }
    }

    /// The number the characteristic's value stands for: the raw value times ten to the
    /// exponent. `nil` when the format is not a number this can read.
    public func value(from data: Data) -> Double? {
        let b = [UInt8](data)
        guard let size = byteCount, b.count >= size else { return nil }
        let raw: Double
        switch format {
        case 0x04: raw = Double(b[0])
        case 0x0C: raw = Double(Int8(bitPattern: b[0]))
        case 0x06: raw = Double(UInt16(b[1]) << 8 | UInt16(b[0]))
        case 0x0E: raw = Double(Int16(bitPattern: UInt16(b[1]) << 8 | UInt16(b[0])))
        case 0x07: raw = Double(Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16)
        case 0x0F:
            var v = Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16
            if v & 0x800000 != 0 { v -= 1 << 24 }
            raw = Double(v)
        case 0x08: raw = Double((0..<4).reduce(UInt32(0)) { $0 | UInt32(b[$1]) << (8 * UInt32($1)) })
        case 0x10:
            raw = Double(Int32(bitPattern: (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[$1]) << (8 * UInt32($1)) }))
        case 0x14:
            raw = Double(Float(bitPattern: (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[$1]) << (8 * UInt32($1)) }))
        case 0x15:
            raw = Double(bitPattern: (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[$1]) << (8 * UInt64($1)) })
        case 0x0A: raw = Double((0..<8).reduce(UInt64(0)) { $0 | UInt64(b[$1]) << (8 * UInt64($1)) })
        case 0x12:
            raw = Double(Int64(bitPattern: (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[$1]) << (8 * UInt64($1)) }))
        case 0x16: guard let v = GATTDecoding.sfloat(b, at: 0) else { return nil }; return v * pow(10, Double(exponent))
        case 0x17: guard let v = GATTDecoding.float32(b, at: 0) else { return nil }; return v * pow(10, Double(exponent))
        default: return nil
        }
        return raw.isFinite ? raw * pow(10, Double(exponent)) : nil
    }

    /// The unit's symbol for the assigned numbers that are certain; empty otherwise.
    public var unitSymbol: String {
        switch unit {
        case 0x2701: "m"
        case 0x2702: "kg"
        case 0x2703: "s"
        case 0x2704: "A"
        case 0x2705: "K"
        case 0x2712: "m/s"
        case 0x2713: "m/s²"
        case 0x272F: "°C"
        default: ""
        }
    }
}

/// A recipe for a characteristic nobody has a decoder for: where each number sits, how wide it
/// is, and what to multiply by. Enough for most sensors that send a few fixed-width fields,
/// without anyone writing code. Stored as JSON next to the user's decoder files.
public struct GATTTemplate: Codable, Sendable, Hashable {
    public enum RawType: String, Codable, Sendable, CaseIterable {
        case uint8, int8, uint16, int16, uint24, int24, uint32, int32, float32, float64

        public var byteCount: Int {
            switch self {
            case .uint8, .int8: 1
            case .uint16, .int16: 2
            case .uint24, .int24: 3
            case .uint32, .int32, .float32: 4
            case .float64: 8
            }
        }
    }

    public struct Field: Codable, Sendable, Hashable {
        public var name: String
        /// Byte offset into the characteristic's value.
        public var offset: Int
        public var type: RawType
        public var bigEndian: Bool
        public var factor: Double
        public var addend: Double
        public var unit: String

        public init(name: String, offset: Int, type: RawType, bigEndian: Bool = false,
                    factor: Double = 1, addend: Double = 0, unit: String = "") {
            self.name = name
            self.offset = offset
            self.type = type
            self.bigEndian = bigEndian
            self.factor = factor
            self.addend = addend
            self.unit = unit
        }
    }

    /// Short (`FFF1`) or full UUID of the characteristic this applies to.
    public var characteristic: String
    public var name: String
    public var fields: [Field]

    public init(characteristic: String, name: String, fields: [Field]) {
        self.characteristic = characteristic
        self.name = name
        self.fields = fields
    }

    public func matches(_ uuid: String) -> Bool {
        BluetoothNames.shortForm(uuid) == BluetoothNames.shortForm(characteristic)
    }

    /// Reads every field the value is long enough for; one that does not fit is left out
    /// rather than read from past the end.
    public func decode(_ data: Data) -> BLEReading? {
        let b = [UInt8](data)
        var out: [BLEReading.Field] = []
        for field in fields {
            guard field.offset >= 0, field.offset + field.type.byteCount <= b.count else { continue }
            var bytes = Array(b[field.offset..<(field.offset + field.type.byteCount)])
            if field.bigEndian { bytes.reverse() }
            guard let raw = Self.number(bytes, field.type), raw.isFinite else { continue }
            out.append(.init(field.name, raw * field.factor + field.addend))
        }
        return out.isEmpty ? nil : BLEReading(decoder: name, fields: out)
    }

    /// `bytes` are little endian here.
    static func number(_ b: [UInt8], _ type: RawType) -> Double? {
        func unsigned(_ count: Int) -> UInt64 {
            (0..<count).reduce(UInt64(0)) { $0 | UInt64(b[$1]) << (8 * UInt64($1)) }
        }
        switch type {
        case .uint8, .uint16, .uint24, .uint32: return Double(unsigned(type.byteCount))
        case .int8: return Double(Int8(bitPattern: b[0]))
        case .int16: return Double(Int16(bitPattern: UInt16(unsigned(2))))
        case .int24:
            var v = Int(unsigned(3))
            if v & 0x800000 != 0 { v -= 1 << 24 }
            return Double(v)
        case .int32: return Double(Int32(bitPattern: UInt32(unsigned(4))))
        case .float32: return Double(Float(bitPattern: UInt32(unsigned(4))))
        case .float64: return Double(bitPattern: unsigned(8))
        }
    }
}
