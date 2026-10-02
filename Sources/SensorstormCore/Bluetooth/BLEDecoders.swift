import Foundation

/// One advertisement as the decoders see it — CoreBluetooth's dictionary with the parts
/// that carry measurements pulled out.
public struct BLEAdvertisement: Sendable {
    public var name: String?
    public var manufacturerData: Data?
    /// Keyed by the service UUID as CoreBluetooth prints it: `FCD2`, `181A`, or a full UUID.
    public var serviceData: [String: Data]

    public init(name: String? = nil, manufacturerData: Data? = nil, serviceData: [String: Data] = [:]) {
        self.name = name
        self.manufacturerData = manufacturerData
        self.serviceData = serviceData
    }
}

/// What a decoder made of one packet: named numbers, in the order the format defines them.
public struct BLEReading: Sendable, Equatable {
    public struct Field: Sendable, Equatable {
        public var name: String
        public var value: Double

        public init(_ name: String, _ value: Double) {
            self.name = name
            self.value = value
        }
    }

    public var decoder: String
    public var fields: [Field]

    public init(decoder: String, fields: [Field]) {
        self.decoder = decoder
        self.fields = fields
    }

    public func value(_ name: String) -> Double? {
        fields.first { $0.name == name }?.value
    }
}

/// The formats that are open, documented and common enough to build in.
///
/// Broadcast sensors put their reading into every advertisement, so they need no
/// connection: RuuviTag, BTHome (Shelly, pvvx firmware, ESPHome) and the ATC/pvvx custom
/// format of the cheap Xiaomi thermometers. Everything else is what a decoder file is for.
public enum BLEDecoders {

    public static func decode(_ advertisement: BLEAdvertisement) -> BLEReading? {
        if let data = advertisement.manufacturerData, let reading = ruuvi(data) { return reading }
        if let data = advertisement.serviceData["FCD2"], let reading = bthome(data) { return reading }
        if let data = advertisement.serviceData["181A"], let reading = environmentalSensing(data) {
            return reading
        }
        return nil
    }

    // MARK: - RuuviTag

    /// Data format 5 (RAWv2), behind Ruuvi's company identifier 0x0499.
    static func ruuvi(_ data: Data) -> BLEReading? {
        let b = [UInt8](data)
        guard b.count >= 26, b[0] == 0x99, b[1] == 0x04, b[2] == 5 else { return nil }
        var fields: [BLEReading.Field] = []
        let temperature = Int16(bitPattern: UInt16(b[3]) << 8 | UInt16(b[4]))
        if temperature != Int16.min { fields.append(.init("temperature", Double(temperature) * 0.005)) }
        let humidity = UInt16(b[5]) << 8 | UInt16(b[6])
        if humidity != .max { fields.append(.init("humidity", Double(humidity) * 0.0025)) }
        let pressure = UInt16(b[7]) << 8 | UInt16(b[8])
        if pressure != .max { fields.append(.init("pressure", (Double(pressure) + 50_000) / 100)) }
        for (offset, axis) in [(9, "accelerationX"), (11, "accelerationY"), (13, "accelerationZ")] {
            let raw = Int16(bitPattern: UInt16(b[offset]) << 8 | UInt16(b[offset + 1]))
            if raw != Int16.min { fields.append(.init(axis, Double(raw) / 1000)) }
        }
        let power = UInt16(b[15]) << 8 | UInt16(b[16])
        if power >> 5 != 0x7FF { fields.append(.init("batteryVoltage", (Double(power >> 5) + 1600) / 1000)) }
        if b[17] != 0xFF { fields.append(.init("movementCounter", Double(b[17]))) }
        return fields.isEmpty ? nil : BLEReading(decoder: "RuuviTag", fields: fields)
    }

    // MARK: - BTHome v2

    /// Object id → name, byte length, signedness, factor. The common ones; an id not in
    /// here ends the packet, because without its length nothing after it can be found.
    private static let bthomeObjects: [UInt8: (String, Int, Bool, Double)] = [
        0x00: ("packetId", 1, false, 1),
        0x01: ("battery", 1, false, 1),
        0x02: ("temperature", 2, true, 0.01),
        0x03: ("humidity", 2, false, 0.01),
        0x04: ("pressure", 3, false, 0.01),
        0x05: ("illuminance", 3, false, 0.01),
        0x06: ("mass", 2, false, 0.01),
        0x07: ("massLb", 2, false, 0.01),
        0x08: ("dewPoint", 2, true, 0.01),
        0x09: ("count", 1, false, 1),
        0x0A: ("energy", 3, false, 0.001),
        0x0B: ("power", 3, false, 0.01),
        0x0C: ("voltage", 2, false, 0.001),
        0x0D: ("pm25", 2, false, 1),
        0x0E: ("pm10", 2, false, 1),
        0x0F: ("generic", 1, false, 1),
        0x10: ("powerOn", 1, false, 1),
        0x11: ("opening", 1, false, 1),
        0x12: ("co2", 2, false, 1),
        0x13: ("tvoc", 2, false, 1),
        0x14: ("moisture", 2, false, 0.01),
        0x15: ("batteryLow", 1, false, 1),
        0x16: ("batteryCharging", 1, false, 1),
        0x17: ("carbonMonoxide", 1, false, 1),
        0x18: ("cold", 1, false, 1),
        0x19: ("connectivity", 1, false, 1),
        0x1A: ("door", 1, false, 1),
        0x1B: ("garageDoor", 1, false, 1),
        0x1C: ("gas", 1, false, 1),
        0x1D: ("heat", 1, false, 1),
        0x1E: ("light", 1, false, 1),
        0x1F: ("lock", 1, false, 1),
        0x20: ("moist", 1, false, 1),
        0x21: ("motion", 1, false, 1),
        0x22: ("moving", 1, false, 1),
        0x23: ("occupancy", 1, false, 1),
        0x24: ("plug", 1, false, 1),
        0x25: ("presence", 1, false, 1),
        0x26: ("problem", 1, false, 1),
        0x27: ("running", 1, false, 1),
        0x28: ("safety", 1, false, 1),
        0x29: ("smoke", 1, false, 1),
        0x2A: ("sound", 1, false, 1),
        0x2B: ("tamper", 1, false, 1),
        0x2C: ("vibration", 1, false, 1),
        0x2D: ("window", 1, false, 1),
        0x2E: ("humidity", 1, false, 1),
        0x2F: ("moisture", 1, false, 1),
        0x3A: ("button", 1, false, 1),
        0x3D: ("count", 2, false, 1),
        0x3E: ("count", 4, false, 1),
        0x3F: ("rotation", 2, true, 0.1),
        0x40: ("distanceMm", 2, false, 1),
        0x41: ("distance", 2, false, 0.1),
        0x42: ("duration", 3, false, 0.001),
        0x43: ("current", 2, false, 0.001),
        0x44: ("speed", 2, false, 0.01),
        0x45: ("temperature", 2, true, 0.1),
        0x46: ("uvIndex", 1, false, 0.1),
        0x47: ("volume", 2, false, 0.1),
        0x48: ("volumeMl", 2, false, 1),
        0x49: ("volumeFlowRate", 2, false, 0.001),
        0x4A: ("voltage", 2, false, 0.1),
        0x4B: ("gas", 3, false, 0.001),
        0x4C: ("gas", 4, false, 0.001),
        0x4D: ("energy", 4, false, 0.001),
        0x4E: ("volume", 4, false, 0.001),
        0x4F: ("water", 4, false, 0.001),
        0x50: ("timestamp", 4, false, 1),
        0x51: ("acceleration", 2, false, 0.001),
        0x52: ("gyroscope", 2, false, 0.001),
    ]

    static func bthome(_ data: Data) -> BLEReading? {
        let b = [UInt8](data)
        // Encrypted packets need the device's key, which only its owner has.
        guard let info = b.first, info & 0x01 == 0, info >> 5 == 2 else { return nil }
        var fields: [BLEReading.Field] = []
        var index = 1
        while index < b.count, let (name, length, signed, factor) = bthomeObjects[b[index]] {
            guard index + 1 + length <= b.count else { break }
            var raw: UInt64 = 0
            for position in 0 ..< length {
                raw |= UInt64(b[index + 1 + position]) << (8 * position)
            }
            var value = Double(raw)
            if signed, raw & (1 << (8 * length - 1)) != 0 {
                value -= Double(UInt64(1) << (8 * length))
            }
            if b[index] != 0x00 {
                fields.append(.init(uniqueName(name, in: fields), value * factor))
            }
            index += 1 + length
        }
        return fields.isEmpty ? nil : BLEReading(decoder: "BTHome", fields: fields)
    }

    /// A second temperature in one packet becomes `temperature2`, not a silent overwrite.
    private static func uniqueName(_ name: String, in fields: [BLEReading.Field]) -> String {
        guard fields.contains(where: { $0.name == name }) else { return name }
        var counter = 2
        while fields.contains(where: { $0.name == "\(name)\(counter)" }) { counter += 1 }
        return "\(name)\(counter)"
    }

    // MARK: - ATC / pvvx

    /// Service data 0x181A in either custom firmware's layout, told apart by length.
    static func environmentalSensing(_ data: Data) -> BLEReading? {
        let b = [UInt8](data)
        switch b.count {
        case 13:  // ATC1441: big-endian, temperature in tenths
            let temperature = Int16(bitPattern: UInt16(b[6]) << 8 | UInt16(b[7]))
            return BLEReading(decoder: "ATC", fields: [
                .init("temperature", Double(temperature) / 10),
                .init("humidity", Double(b[8])),
                .init("battery", Double(b[9])),
                .init("batteryVoltage", Double(UInt16(b[10]) << 8 | UInt16(b[11])) / 1000),
            ])
        case 15:  // pvvx: little-endian, hundredths
            let temperature = Int16(bitPattern: UInt16(b[7]) << 8 | UInt16(b[6]))
            return BLEReading(decoder: "pvvx", fields: [
                .init("temperature", Double(temperature) / 100),
                .init("humidity", Double(UInt16(b[9]) << 8 | UInt16(b[8])) / 100),
                .init("batteryVoltage", Double(UInt16(b[11]) << 8 | UInt16(b[10])) / 1000),
                .init("battery", Double(b[12])),
            ])
        default:
            return nil
        }
    }

    // MARK: - GATT profiles

    /// The standard services a strap, a power meter or a foot pod speaks, whatever the brand.
    public enum Profile: String, Sendable, CaseIterable {
        case heartRate = "180D"
        case cyclingSpeedCadence = "1816"
        case cyclingPower = "1818"
        case runningSpeedCadence = "1814"

        /// The measurement characteristic that notifies.
        public var measurement: String {
            switch self {
            case .heartRate: "2A37"
            case .cyclingSpeedCadence: "2A5B"
            case .cyclingPower: "2A63"
            case .runningSpeedCadence: "2A53"
            }
        }
    }

    public static func decode(_ profile: Profile, _ data: Data) -> BLEReading? {
        let b = [UInt8](data)
        switch profile {
        case .heartRate: return heartRate(b)
        case .cyclingPower: return cyclingPower(b)
        case .runningSpeedCadence: return runningSpeedCadence(b)
        case .cyclingSpeedCadence: return cyclingSpeedCadence(b)
        }
    }

    static func heartRate(_ b: [UInt8]) -> BLEReading? {
        guard let flags = b.first else { return nil }
        let wide = flags & 0x01 != 0
        guard b.count >= (wide ? 3 : 2) else { return nil }
        var fields = [BLEReading.Field("heartRate", wide ? Double(UInt16(b[2]) << 8 | UInt16(b[1])) : Double(b[1]))]
        var index = wide ? 3 : 2
        if flags & 0x08 != 0 { index += 2 }                       // energy expended
        if flags & 0x10 != 0, b.count >= index + 2 {              // newest RR interval
            let last = b.count - (b.count - index) % 2 - 2
            fields.append(.init("rrInterval", Double(UInt16(b[last + 1]) << 8 | UInt16(b[last])) / 1024))
        }
        return BLEReading(decoder: "Heart Rate", fields: fields)
    }

    static func cyclingPower(_ b: [UInt8]) -> BLEReading? {
        guard b.count >= 4 else { return nil }
        let power = Int16(bitPattern: UInt16(b[3]) << 8 | UInt16(b[2]))
        var fields = [BLEReading.Field("power", Double(power))]
        if b[0] & 0x01 != 0, b.count >= 5 { fields.append(.init("pedalBalance", Double(b[4]) / 2)) }
        return BLEReading(decoder: "Cycling Power", fields: fields)
    }

    static func runningSpeedCadence(_ b: [UInt8]) -> BLEReading? {
        guard b.count >= 4 else { return nil }
        let flags = b[0]
        var fields = [
            BLEReading.Field("speed", Double(UInt16(b[2]) << 8 | UInt16(b[1])) / 256),
            BLEReading.Field("cadence", Double(b[3])),
        ]
        var index = 4
        if flags & 0x01 != 0, b.count >= index + 2 {
            fields.append(.init("strideLength", Double(UInt16(b[index + 1]) << 8 | UInt16(b[index])) / 100))
            index += 2
        }
        if flags & 0x02 != 0, b.count >= index + 4 {
            let distance = (0 ..< 4).reduce(UInt32(0)) { $0 | UInt32(b[index + $1]) << (8 * $1) }
            fields.append(.init("totalDistance", Double(distance) / 10))
        }
        return BLEReading(decoder: "Running Speed and Cadence", fields: fields)
    }

    /// Cumulative counters as sent. Speed and cadence are their differences over time, which
    /// needs the previous packet — see ``CSCTracker``.
    static func cyclingSpeedCadence(_ b: [UInt8]) -> BLEReading? {
        guard let flags = b.first else { return nil }
        var fields: [BLEReading.Field] = []
        var index = 1
        if flags & 0x01 != 0, b.count >= index + 6 {
            let revolutions = (0 ..< 4).reduce(UInt32(0)) { $0 | UInt32(b[index + $1]) << (8 * $1) }
            fields.append(.init("wheelRevolutions", Double(revolutions)))
            fields.append(.init("wheelEventTime", Double(UInt16(b[index + 5]) << 8 | UInt16(b[index + 4]))))
            index += 6
        }
        if flags & 0x02 != 0, b.count >= index + 4 {
            fields.append(.init("crankRevolutions", Double(UInt16(b[index + 1]) << 8 | UInt16(b[index]))))
            fields.append(.init("crankEventTime", Double(UInt16(b[index + 3]) << 8 | UInt16(b[index + 2]))))
        }
        return fields.isEmpty ? nil : BLEReading(decoder: "Cycling Speed and Cadence", fields: fields)
    }
}

/// Turns the cumulative CSC counters into revolutions per minute.
///
/// Both counters wrap — the event times every 64 seconds — so the difference is taken
/// modulo their width. A packet with an unchanged event time carries no new revolution and
/// says nothing about the rate; the previous rate stands.
public struct CSCTracker: Sendable {
    private var previous: BLEReading?
    private var wheel: Double?
    private var crank: Double?

    public init() {}

    public mutating func update(_ reading: BLEReading) -> BLEReading {
        defer { previous = reading }
        var out = reading
        if let rpm = Self.rate(reading, previous, "wheelRevolutions", "wheelEventTime", 4_294_967_296) {
            wheel = rpm
        }
        if let rpm = Self.rate(reading, previous, "crankRevolutions", "crankEventTime", 65_536) {
            crank = rpm
        }
        if let wheel { out.fields.append(.init("wheelRpm", wheel)) }
        if let crank { out.fields.append(.init("cadence", crank)) }
        return out
    }

    private static func rate(_ now: BLEReading, _ before: BLEReading?, _ count: String,
                             _ time: String, _ countModulo: Double) -> Double? {
        guard let before,
              let c1 = now.value(count), let t1 = now.value(time),
              let c0 = before.value(count), let t0 = before.value(time) else { return nil }
        let dt = (t1 - t0 + 65_536).truncatingRemainder(dividingBy: 65_536) / 1024
        guard dt > 0 else { return nil }
        let dc = (c1 - c0 + countModulo).truncatingRemainder(dividingBy: countModulo)
        return dc / dt * 60
    }
}
