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
        0x000A: "Cambridge Silicon Radio (CSR)",
        0x00D7: "Qualcomm Technologies International, Ltd. (QTIL)",
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
        "1806": "Reference Time Update",
        "1807": "Next DST Change",
        "180E": "Phone Alert Status",
        "1824": "Transport Discovery",
        "1825": "Object Transfer",
        "1829": "Reconnection Configuration",
        "183A": "Insulin Delivery",
        "183B": "Binary Sensor",
        "183C": "Emergency Configuration",
        "183D": "Authorization Control",
        "183E": "Physical Activity Monitor",
        "1843": "Audio Input Control",
        "1844": "Volume Control",
        "1845": "Volume Offset Control",
        "1846": "Coordinated Set Identification",
        "1847": "Device Time",
        "1848": "Media Control",
        "1849": "Generic Media Control",
        "184A": "Constant Tone Extension",
        "184B": "Telephone Bearer",
        "184C": "Generic Telephone Bearer",
        "184D": "Microphone Control",
        "184E": "Audio Stream Control",
        "184F": "Broadcast Audio Scan",
        "1850": "Published Audio Capabilities",
        "1851": "Basic Audio Announcement",
        "1852": "Broadcast Audio Announcement",
        "1853": "Common Audio",
        "1854": "Hearing Access",
        "1855": "Telephony and Media Audio",
        "1856": "Public Broadcast Announcement",
        "FE59": "Nordic Semiconductor DFU",
        "FE95": "Xiaomi",
        "FE9F": "Google",
        "FEE0": "Anhui Huami (Mi Band)",
        "FEE7": "Tencent",
        "FEED": "Tile",
        "D0611E78-BBB4-4591-A5F8-487910AE4366": "Apple Continuity",
        "7905F431-B5CE-4E99-A40F-4B1E122D00D0": "Apple Notification Center",
        "89D3502B-0F36-433A-8EF4-C502AD55F8DC": "Apple Media Service",
        "49535343-FE7D-4AE5-8FA9-9FAFD205E455": "Microchip Transparent UART",
        "F000AA00-0451-4000-B000-000000000000": "TI SensorTag IR Temperature",
        "F000AA20-0451-4000-B000-000000000000": "TI SensorTag Humidity",
        "F000AA40-0451-4000-B000-000000000000": "TI SensorTag Barometer",
        "F000AA70-0451-4000-B000-000000000000": "TI SensorTag Optical",
        "F000AA80-0451-4000-B000-000000000000": "TI SensorTag Movement",
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
        "2A02": "Peripheral Privacy Flag",
        "2A03": "Reconnection Address",
        "2A05": "Service Changed",
        "2A06": "Alert Level",
        "2A07": "Tx Power Level",
        "2A08": "Date Time",
        "2A09": "Day of Week",
        "2A0A": "Day Date Time",
        "2A0C": "Exact Time 256",
        "2A0D": "DST Offset",
        "2A0E": "Time Zone",
        "2A0F": "Local Time Information",
        "2A11": "Time with DST",
        "2A12": "Time Accuracy",
        "2A13": "Time Source",
        "2A14": "Reference Time Information",
        "2A16": "Time Update Control Point",
        "2A17": "Time Update State",
        "2A18": "Glucose Measurement",
        "2A1A": "Battery Power State",
        "2A1B": "Battery Level State",
        "2A1D": "Temperature Type",
        "2A1F": "Temperature in Celsius",
        "2A20": "Temperature in Fahrenheit",
        "2A21": "Measurement Interval",
        "2A22": "Boot Keyboard Input Report",
        "2A23": "System ID",
        "2A2A": "IEEE 11073-20601 Regulatory Certification Data List",
        "2A2C": "Magnetic Declination",
        "2A31": "Scan Refresh",
        "2A32": "Boot Keyboard Output Report",
        "2A33": "Boot Mouse Input Report",
        "2A34": "Glucose Measurement Context",
        "2A36": "Intermediate Cuff Pressure",
        "2A3F": "Alert Status",
        "2A40": "Ringer Control Point",
        "2A41": "Ringer Setting",
        "2A42": "Alert Category ID Bit Mask",
        "2A43": "Alert Category ID",
        "2A44": "Alert Notification Control Point",
        "2A45": "Unread Alert Status",
        "2A46": "New Alert",
        "2A47": "Supported New Alert Category",
        "2A48": "Supported Unread Alert Category",
        "2A49": "Blood Pressure Feature",
        "2A4A": "HID Information",
        "2A4B": "Report Map",
        "2A4C": "HID Control Point",
        "2A4D": "Report",
        "2A4E": "Protocol Mode",
        "2A4F": "Scan Interval Window",
        "2A50": "PnP ID",
        "2A51": "Glucose Feature",
        "2A52": "Record Access Control Point",
        "2A54": "RSC Feature",
        "2A55": "SC Control Point",
        "2A56": "Digital",
        "2A58": "Analog",
        "2A5A": "Aggregate",
        "2A5C": "CSC Feature",
        "2A5D": "Sensor Location",
        "2A60": "PLX Features",
        "2A62": "Pulse Oximetry Control Point",
        "2A64": "Cycling Power Vector",
        "2A65": "Cycling Power Feature",
        "2A66": "Cycling Power Control Point",
        "2A68": "Navigation",
        "2A69": "Position Quality",
        "2A6A": "LN Feature",
        "2A6B": "LN Control Point",
        "2A70": "True Wind Speed",
        "2A71": "True Wind Direction",
        "2A72": "Apparent Wind Speed",
        "2A73": "Apparent Wind Direction",
        "2A74": "Gust Factor",
        "2A75": "Pollen Concentration",
        "2A78": "Rainfall",
        "2A79": "Wind Chill",
        "2A7A": "Heat Index",
        "2A7B": "Dew Point",
        "2A7D": "Descriptor Value Changed",
        "2A7E": "Aerobic Heart Rate Lower Limit",
        "2A7F": "Aerobic Threshold",
        "2A80": "Age",
        "2A81": "Anaerobic Heart Rate Lower Limit",
        "2A82": "Anaerobic Heart Rate Upper Limit",
        "2A83": "Anaerobic Threshold",
        "2A84": "Aerobic Heart Rate Upper Limit",
        "2A85": "Date of Birth",
        "2A86": "Date of Threshold Assessment",
        "2A87": "Email Address",
        "2A88": "Fat Burn Heart Rate Lower Limit",
        "2A89": "Fat Burn Heart Rate Upper Limit",
        "2A8A": "First Name",
        "2A8B": "Five Zone Heart Rate Limits",
        "2A8C": "Gender",
        "2A8D": "Heart Rate Max",
        "2A8E": "Height",
        "2A8F": "Hip Circumference",
        "2A90": "Last Name",
        "2A91": "Maximum Recommended Heart Rate",
        "2A92": "Resting Heart Rate",
        "2A93": "Sport Type for Aerobic and Anaerobic Thresholds",
        "2A94": "Three Zone Heart Rate Limits",
        "2A95": "Two Zone Heart Rate Limit",
        "2A96": "VO2 Max",
        "2A97": "Waist Circumference",
        "2A98": "Weight",
        "2A99": "Database Change Increment",
        "2A9A": "User Index",
        "2A9B": "Body Composition Feature",
        "2A9E": "Weight Scale Feature",
        "2A9F": "User Control Point",
        "2AA0": "Magnetic Flux Density 2D",
        "2AA1": "Magnetic Flux Density 3D",
        "2AA2": "Language",
        "2AA3": "Barometric Pressure Trend",
        "2AA4": "Bond Management Control Point",
        "2AA5": "Bond Management Feature",
        "2AA6": "Central Address Resolution",
        "2AA7": "CGM Measurement",
        "2AA8": "CGM Feature",
        "2AA9": "CGM Status",
        "2AAA": "CGM Session Start Time",
        "2AAB": "CGM Session Run Time",
        "2AAC": "CGM Specific Ops Control Point",
        "2AAD": "Indoor Positioning Configuration",
        "2AAE": "Latitude",
        "2AAF": "Longitude",
        "2AB0": "Local North Coordinate",
        "2AB1": "Local East Coordinate",
        "2AB2": "Floor Number",
        "2AB3": "Altitude",
        "2AB4": "Uncertainty",
        "2AB5": "Location Name",
        "2AB6": "URI",
        "2AB7": "HTTP Headers",
        "2AB8": "HTTP Status Code",
        "2AB9": "HTTP Entity Body",
        "2ABA": "HTTP Control Point",
        "2ABB": "HTTPS Security",
        "2ABC": "TDS Control Point",
        "2ABD": "OTS Feature",
        "2ABE": "Object Name",
        "2ABF": "Object Type",
        "2AC0": "Object Size",
        "2AC1": "Object First-Created",
        "2AC2": "Object Last-Modified",
        "2AC3": "Object ID",
        "2AC4": "Object Properties",
        "2AC5": "Object Action Control Point",
        "2AC6": "Object List Control Point",
        "2AC7": "Object List Filter",
        "2AC8": "Object Changed",
        "2AC9": "Resolvable Private Address Only",
        "2ACC": "Fitness Machine Feature",
        "2ACE": "Cross Trainer Data",
        "2ACF": "Step Climber Data",
        "2AD0": "Stair Climber Data",
        "2AD3": "Training Status",
        "2AD4": "Supported Speed Range",
        "2AD5": "Supported Inclination Range",
        "2AD6": "Supported Resistance Level Range",
        "2AD7": "Supported Heart Rate Range",
        "2AD8": "Supported Power Range",
        "2AD9": "Fitness Machine Control Point",
        "2ADA": "Fitness Machine Status",
        "2ADB": "Mesh Provisioning Data In",
        "2ADC": "Mesh Provisioning Data Out",
        "2ADD": "Mesh Proxy Data In",
        "2ADE": "Mesh Proxy Data Out",
        "2B29": "Client Supported Features",
        "2B2A": "Database Hash",
        "2B3A": "Server Supported Features",
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
