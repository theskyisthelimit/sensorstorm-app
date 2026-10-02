import Foundation

/// Names for the numbers Bluetooth devices send, so a scanner can say „Apple" and „Heart Rate"
/// instead of `0x004C` and `180D`.
///
/// Only entries that are certain are in here. A scanner that mislabels a device is worse
/// than one that shows the number: the number is at least checkable. The company list is the
/// part of the Bluetooth SIG's assigned numbers that turns up in practice; the services and
/// characteristics are the GATT ones this app decodes or that every device carries.
public enum BluetoothNames {

    /// `0x004C` → „Apple, Inc.". `nil` for a number not in the list.
    public static func company(_ identifier: UInt16) -> String? {
        companies[identifier]
    }

    /// The company a manufacturer-specific data block names: its first two bytes, little
    /// endian.
    public static func company(in manufacturerData: Data) -> (id: UInt16, name: String?)? {
        guard manufacturerData.count >= 2 else { return nil }
        let bytes = [UInt8](manufacturerData.prefix(2))
        let id = UInt16(bytes[1]) << 8 | UInt16(bytes[0])
        return (id, company(id))
    }

    /// A service by its UUID as CoreBluetooth prints it: `180D` or the full 128-bit form.
    public static func service(_ uuid: String) -> String? {
        let key = shortForm(uuid)
        return services[key]
    }

    public static func characteristic(_ uuid: String) -> String? {
        characteristics[shortForm(uuid)]
    }

    /// `0000180D-0000-1000-8000-00805F9B34FB` → `180D`; anything else upper-cased unchanged.
    public static func shortForm(_ uuid: String) -> String {
        let upper = uuid.uppercased()
        let suffix = "-0000-1000-8000-00805F9B34FB"
        if upper.count == 36, upper.hasSuffix(suffix), upper.hasPrefix("0000") {
            return String(upper.dropFirst(4).prefix(4))
        }
        return upper
    }

    private static let companies: [UInt16: String] = [
        0x0000: "Ericsson Technology Licensing",
        0x0001: "Nokia Mobile Phones",
        0x0002: "Intel Corp.",
        0x0003: "IBM Corp.",
        0x0004: "Toshiba Corp.",
        0x0006: "Microsoft",
        0x0008: "Motorola",
        0x0009: "Infineon Technologies AG",
        0x000D: "Texas Instruments Inc.",
        0x000F: "Broadcom Corporation",
        0x001D: "Qualcomm",
        0x0030: "ST Microelectronics",
        0x0046: "MediaTek, Inc.",
        0x004C: "Apple, Inc.",
        0x0059: "Nordic Semiconductor ASA",
        0x006B: "Polar Electro Oy",
        0x0075: "Samsung Electronics Co. Ltd.",
        0x0078: "Nike, Inc.",
        0x0087: "Garmin International, Inc.",
        0x009E: "Bose Corporation",
        0x00C4: "LG Electronics",
        0x00D2: "Dialog Semiconductor B.V.",
        0x00E0: "Google",
        0x012D: "Sony Corporation",
        0x0131: "Cypress Semiconductor",
        0x0157: "Anhui Huami Information Technology Co.",
        0x015D: "Estimote, Inc.",
        0x0171: "Amazon.com Services, Inc.",
        0x02E5: "Espressif Incorporated",
        0x02FF: "Silicon Laboratories",
        0x038F: "Xiaomi Inc.",
        0x0499: "Ruuvi Innovations Ltd.",
    ]

    private static let services: [String: String] = [
        "1800": "Generic Access",
        "1801": "Generic Attribute",
        "1802": "Immediate Alert",
        "1803": "Link Loss",
        "1804": "Tx Power",
        "1805": "Current Time",
        "1808": "Glucose",
        "1809": "Health Thermometer",
        "180A": "Device Information",
        "180D": "Heart Rate",
        "180F": "Battery",
        "1810": "Blood Pressure",
        "1811": "Alert Notification",
        "1812": "Human Interface Device",
        "1813": "Scan Parameters",
        "1814": "Running Speed and Cadence",
        "1815": "Automation IO",
        "1816": "Cycling Speed and Cadence",
        "1818": "Cycling Power",
        "1819": "Location and Navigation",
        "181A": "Environmental Sensing",
        "181B": "Body Composition",
        "181C": "User Data",
        "181D": "Weight Scale",
        "181E": "Bond Management",
        "181F": "Continuous Glucose Monitoring",
        "1820": "Internet Protocol Support",
        "1821": "Indoor Positioning",
        "1822": "Pulse Oximeter",
        "1823": "HTTP Proxy",
        "1826": "Fitness Machine",
        "1827": "Mesh Provisioning",
        "1828": "Mesh Proxy",
        "FCD2": "BTHome",
        "FE2C": "Google Fast Pair",
        "FEAA": "Eddystone",
        "FD6F": "Exposure Notification",
        "6E400001-B5A3-F393-E0A9-E50E24DCCA9E": "Nordic UART",
    ]

    private static let characteristics: [String: String] = [
        "2A00": "Device Name",
        "2A01": "Appearance",
        "2A04": "Peripheral Preferred Connection Parameters",
        "2A19": "Battery Level",
        "2A1C": "Temperature Measurement",
        "2A1E": "Intermediate Temperature",
        "2A24": "Model Number",
        "2A25": "Serial Number",
        "2A26": "Firmware Revision",
        "2A27": "Hardware Revision",
        "2A28": "Software Revision",
        "2A29": "Manufacturer Name",
        "2A2B": "Current Time",
        "2A35": "Blood Pressure Measurement",
        "2A37": "Heart Rate Measurement",
        "2A38": "Body Sensor Location",
        "2A39": "Heart Rate Control Point",
        "2A53": "RSC Measurement",
        "2A5B": "CSC Measurement",
        "2A5E": "PLX Spot-Check Measurement",
        "2A5F": "PLX Continuous Measurement",
        "2A63": "Cycling Power Measurement",
        "2A67": "Location and Speed",
        "2A6C": "Elevation",
        "2A6D": "Pressure",
        "2A6E": "Temperature",
        "2A6F": "Humidity",
        "2A76": "UV Index",
        "2A77": "Irradiance",
        "2A9C": "Body Composition Measurement",
        "2A9D": "Weight Measurement",
        "2ACD": "Treadmill Data",
        "2AD1": "Rower Data",
        "2AD2": "Indoor Bike Data",
        "6E400002-B5A3-F393-E0A9-E50E24DCCA9E": "Nordic UART RX",
        "6E400003-B5A3-F393-E0A9-E50E24DCCA9E": "Nordic UART TX",
    ]
}

/// What the advertisements of a beacon say, as text a scanner can show.
public enum BeaconInfo: Sendable, Equatable {
    case eddystoneUID(namespace: String, instance: String, txPower: Int)
    case eddystoneURL(url: String, txPower: Int)
    case eddystoneTLM(batteryVoltage: Double?, temperature: Double?, advertisementCount: UInt32,
                      uptimeSeconds: Double)
    case altBeacon(id1: String, id2: Int, id3: Int, referenceRSSI: Int)
    case iBeacon(uuid: String, major: Int, minor: Int, txPower: Int)

    public var kind: String {
        switch self {
        case .eddystoneUID: "Eddystone-UID"
        case .eddystoneURL: "Eddystone-URL"
        case .eddystoneTLM: "Eddystone-TLM"
        case .altBeacon: "AltBeacon"
        case .iBeacon: "iBeacon"
        }
    }

    /// The one-line description for a list row.
    public var summary: String {
        switch self {
        case let .eddystoneUID(namespace, instance, _): "\(namespace) · \(instance)"
        case let .eddystoneURL(url, _): url
        case let .eddystoneTLM(battery, temperature, count, uptime):
            [battery.map { String(format: "%.3f V", $0) },
             temperature.map { String(format: "%.1f °C", $0) },
             "\(count) ×", String(format: "%.0f s", uptime)]
                .compactMap { $0 }.joined(separator: " · ")
        case let .altBeacon(id1, id2, id3, _): "\(id1) · \(id2) · \(id3)"
        case let .iBeacon(uuid, major, minor, _): "\(uuid) · \(major) · \(minor)"
        }
    }

    /// The power the beacon says it sends at one metre — what a distance estimate needs.
    public var referencePower: Int? {
        switch self {
        case let .eddystoneUID(_, _, power), let .eddystoneURL(_, power): power
        case let .altBeacon(_, _, _, power): power
        case let .iBeacon(_, _, _, power): power
        case .eddystoneTLM: nil
        }
    }

    /// Eddystone's TLM frame as a reading: battery, temperature, counters.
    public var reading: BLEReading? {
        guard case let .eddystoneTLM(battery, temperature, count, uptime) = self else { return nil }
        var fields: [BLEReading.Field] = []
        if let battery { fields.append(.init("batteryVoltage", battery)) }
        if let temperature { fields.append(.init("temperature", temperature)) }
        fields.append(.init("advertisementCount", Double(count)))
        fields.append(.init("uptime", uptime))
        return BLEReading(decoder: "Eddystone-TLM", fields: fields)
    }
}

public enum BeaconDecoder {

    /// Reads whichever beacon format an advertisement carries, or `nil`.
    public static func decode(_ advertisement: BLEAdvertisement) -> BeaconInfo? {
        if let frame = advertisement.serviceData["FEAA"], let info = eddystone([UInt8](frame)) {
            return info
        }
        if let data = advertisement.manufacturerData {
            let b = [UInt8](data)
            if let info = altBeacon(b) ?? iBeacon(b) { return info }
        }
        return nil
    }

    static func eddystone(_ b: [UInt8]) -> BeaconInfo? {
        guard let type = b.first else { return nil }
        switch type {
        case 0x00:  // UID: type, txPower, 10-byte namespace, 6-byte instance
            guard b.count >= 18 else { return nil }
            return .eddystoneUID(namespace: hex(b[2..<12]), instance: hex(b[12..<18]),
                                 txPower: Int(Int8(bitPattern: b[1])))
        case 0x10:  // URL: type, txPower, scheme, encoded URL
            guard b.count >= 4 else { return nil }
            let schemes = ["http://www.", "https://www.", "http://", "https://"]
            guard Int(b[2]) < schemes.count else { return nil }
            var url = schemes[Int(b[2])]
            let expansions = [".com/", ".org/", ".edu/", ".net/", ".info/", ".biz/", ".gov/",
                              ".com", ".org", ".edu", ".net", ".info", ".biz", ".gov"]
            for byte in b[3...] {
                if Int(byte) < expansions.count {
                    url += expansions[Int(byte)]
                } else if byte >= 0x21, byte < 0x7F {
                    url.append(Character(UnicodeScalar(byte)))
                }
            }
            return .eddystoneURL(url: url, txPower: Int(Int8(bitPattern: b[1])))
        case 0x20:  // TLM: type, version, battery mV, temperature 8.8, adv count, uptime in 0.1 s
            guard b.count >= 14, b[1] == 0x00 else { return nil }
            let millivolts = UInt16(b[2]) << 8 | UInt16(b[3])
            let rawTemperature = Int16(bitPattern: UInt16(b[4]) << 8 | UInt16(b[5]))
            let count = (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(b[6 + $1]) }
            let tenths = (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(b[10 + $1]) }
            return .eddystoneTLM(
                // 0 mV means the beacon is mains powered; 0x8000 means no sensor.
                batteryVoltage: millivolts == 0 ? nil : Double(millivolts) / 1000,
                temperature: rawTemperature == Int16.min ? nil : Double(rawTemperature) / 256,
                advertisementCount: count,
                uptimeSeconds: Double(tenths) / 10)
        default:
            return nil
        }
    }

    /// Radius Networks' open format: company ID, 0xBEAC, 20 bytes of identifiers.
    static func altBeacon(_ b: [UInt8]) -> BeaconInfo? {
        guard b.count >= 26, b[2] == 0xBE, b[3] == 0xAC else { return nil }
        return .altBeacon(id1: uuid(b[4..<20]),
                          id2: Int(b[20]) << 8 | Int(b[21]),
                          id3: Int(b[22]) << 8 | Int(b[23]),
                          referenceRSSI: Int(Int8(bitPattern: b[24])))
    }

    /// Apple's: company 0x004C, type 0x02, length 0x15. iOS does not hand these to a
    /// CoreBluetooth scan — they reach an app only through Core Location — but a decoder that
    /// knows the layout costs nothing and works on a captured packet.
    static func iBeacon(_ b: [UInt8]) -> BeaconInfo? {
        guard b.count >= 25, b[0] == 0x4C, b[1] == 0x00, b[2] == 0x02, b[3] == 0x15 else { return nil }
        return .iBeacon(uuid: uuid(b[4..<20]),
                        major: Int(b[20]) << 8 | Int(b[21]),
                        minor: Int(b[22]) << 8 | Int(b[23]),
                        txPower: Int(Int8(bitPattern: b[24])))
    }

    private static func hex(_ bytes: ArraySlice<UInt8>) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    private static func uuid(_ bytes: ArraySlice<UInt8>) -> String {
        let h = hex(bytes)
        guard h.count == 32 else { return h }
        let c = Array(h)
        func part(_ a: Int, _ b: Int) -> String { String(c[a..<b]) }
        return [part(0, 8), part(8, 12), part(12, 16), part(16, 20), part(20, 32)].joined(separator: "-")
    }
}

/// A distance from a signal strength — a rough one, and said to be.
///
/// Radio does not travel in a straight line through a room: bodies, walls and the phone's own
/// antenna move the reading by ten decibels, and ten decibels is a factor of three in
/// distance. The model is the standard log-distance one, and the answer is a range from a
/// forgiving to a harsh environment rather than a single number that looks like a
/// measurement.
public enum RangeEstimate {
    /// - Parameters:
    ///   - rssi: the measured signal, in dBm.
    ///   - referencePower: the signal at one metre, in dBm. Beacons advertise it; for any
    ///     other device -59 is a common stand-in and is stated as an assumption.
    ///   - exponent: 2 in free space, 2.7–4 indoors.
    public static func metres(rssi: Double, referencePower: Double, exponent: Double = 2.5) -> Double {
        guard rssi.isFinite, referencePower.isFinite, exponent > 0 else { return .nan }
        return pow(10, (referencePower - rssi) / (10 * exponent))
    }

    /// Near and far estimate: open space (exponent 2) and cluttered indoors (exponent 3.5).
    public static func range(rssi: Double, referencePower: Double = -59) -> (near: Double, far: Double) {
        let open = metres(rssi: rssi, referencePower: referencePower, exponent: 2)
        let cluttered = metres(rssi: rssi, referencePower: referencePower, exponent: 3.5)
        return (min(open, cluttered), max(open, cluttered))
    }
}
