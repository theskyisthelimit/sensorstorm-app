import Foundation

/// What one advertisement carried, reduced to plain values — CoreBluetooth's dictionary with
/// the parts a scanner shows pulled out.
public struct ScannedAdvertisement: Sendable, Equatable {
    public var name: String?
    public var manufacturerData: Data?
    /// Service UUIDs as CoreBluetooth prints them, advertised and overflow ones together.
    public var serviceUUIDs: [String]
    public var serviceData: [String: Data]
    /// Transmit power the device says it sends at, in dBm.
    public var txPower: Double?
    public var isConnectable: Bool?
    public var beacon: BeaconInfo?
    /// Values a broadcast decoder (RuuviTag, BTHome, …) read out of the packet.
    public var reading: BLEReading?

    public init(name: String? = nil, manufacturerData: Data? = nil, serviceUUIDs: [String] = [],
                serviceData: [String: Data] = [:], txPower: Double? = nil,
                isConnectable: Bool? = nil, beacon: BeaconInfo? = nil, reading: BLEReading? = nil) {
        self.name = name
        self.manufacturerData = manufacturerData
        self.serviceUUIDs = serviceUUIDs
        self.serviceData = serviceData
        self.txPower = txPower
        self.isConnectable = isConnectable
        self.beacon = beacon
        self.reading = reading
    }
}

/// One device as the scanner knows it: the newest of everything it ever sent, the signal
/// strength over the last minutes, and how often it speaks.
///
/// A device sends several kinds of packet — the advertisement itself and, when asked, a scan
/// response — and each carries only part of the picture. The name often arrives in the
/// second, the manufacturer data in the first. So a field that a packet does not carry keeps
/// the value an earlier one gave it; only a packet that carries it replaces it.
public struct ScannedDevice: Sendable, Identifiable, Equatable {
    public struct Point: Sendable, Equatable {
        public var time: Double
        public var rssi: Double
        public init(time: Double, rssi: Double) {
            self.time = time
            self.rssi = rssi
        }
    }

    /// How many signal readings are kept, and how far apart. Two per second for a minute is
    /// what a curve needs; a beacon advertising at 10 Hz would otherwise fill memory with
    /// points no pixel can show.
    public static let historyLimit = 120
    public static let historyStep = 0.5

    public let id: UUID
    public private(set) var name: String?
    public private(set) var rssi: Double
    public private(set) var history: [Point] = []
    public private(set) var txPower: Double?
    public private(set) var isConnectable: Bool?
    public private(set) var manufacturerData: Data?
    public private(set) var serviceUUIDs: [String] = []
    public private(set) var serviceData: [String: Data] = [:]
    public private(set) var beacon: BeaconInfo?
    public private(set) var reading: BLEReading?
    public let firstSeen: Double
    public private(set) var lastSeen: Double
    public private(set) var count = 0
    /// Seconds between two packets, smoothed. `nil` until there are two.
    public private(set) var meanInterval: Double?

    public init(id: UUID, time: Double, rssi: Double) {
        self.id = id
        self.firstSeen = time
        self.lastSeen = time
        self.rssi = rssi
    }

    public mutating func record(time: Double, rssi: Double, advertisement: ScannedAdvertisement) {
        if count > 0, time > lastSeen {
            let gap = time - lastSeen
            meanInterval = meanInterval.map { $0 * 0.8 + gap * 0.2 } ?? gap
        }
        count += 1
        lastSeen = max(lastSeen, time)
        self.rssi = rssi
        if history.last.map({ time - $0.time >= Self.historyStep }) ?? true {
            history.append(Point(time: time, rssi: rssi))
            if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        }

        if let name = advertisement.name, !name.isEmpty { self.name = name }
        if let data = advertisement.manufacturerData { manufacturerData = data }
        for uuid in advertisement.serviceUUIDs where !serviceUUIDs.contains(uuid) {
            serviceUUIDs.append(uuid)
        }
        for (key, value) in advertisement.serviceData { serviceData[key] = value }
        if let power = advertisement.txPower { txPower = power }
        if let connectable = advertisement.isConnectable { isConnectable = connectable }
        if let beacon = advertisement.beacon { self.beacon = beacon }
        if let reading = advertisement.reading { self.reading = reading }
    }

    // MARK: - Derived

    /// The company the manufacturer data names, with its name when the list has it.
    public var company: (id: UInt16, name: String?)? {
        manufacturerData.flatMap { BluetoothNames.company(in: $0) }
    }

    /// Service names for the UUIDs that have one, the bare UUID for the rest.
    public var serviceNames: [String] {
        serviceUUIDs.map { BluetoothNames.service($0) ?? BluetoothNames.shortForm($0) }
    }

    /// The power at one metre to measure distance against: what the device advertised, what a
    /// beacon frame states, or — said to be an assumption — −59 dBm.
    public var referencePower: (value: Double, isAssumed: Bool) {
        if let beacon = beacon?.referencePower { return (Double(beacon), false) }
        if let txPower { return (txPower, false) }
        return (-59, true)
    }

    public var distance: (near: Double, far: Double) {
        RangeEstimate.range(rssi: rssi, referencePower: referencePower.value)
    }

    /// Seconds since the last packet, at `now`.
    public func age(at now: Double) -> Double { max(now - lastSeen, 0) }
}

/// Every device seen, capped.
///
/// A scan in a station or a conference hall sees hundreds of addresses, most of them phones
/// that change theirs every quarter of an hour. Left alone the table grows with every
/// rotation; capped, it forgets the one heard from longest ago.
public struct DeviceTable: Sendable {
    public static let capacity = 400

    public private(set) var devices: [UUID: ScannedDevice] = [:]

    public init() {}

    public mutating func record(id: UUID, time: Double, rssi: Double,
                                advertisement: ScannedAdvertisement) {
        if devices[id] == nil {
            if devices.count >= Self.capacity,
               let oldest = devices.min(by: { $0.value.lastSeen < $1.value.lastSeen }) {
                devices[oldest.key] = nil
            }
            devices[id] = ScannedDevice(id: id, time: time, rssi: rssi)
        }
        devices[id]?.record(time: time, rssi: rssi, advertisement: advertisement)
    }

    /// Forgets devices not heard from for `seconds`.
    public mutating func prune(olderThan seconds: Double, now: Double) {
        devices = devices.filter { now - $0.value.lastSeen <= seconds }
    }

    public mutating func removeAll() {
        devices.removeAll()
    }
}

/// One GATT characteristic the user chose to record: from which device, how to read it, and
/// how often to ask when the device does not send on its own.
public struct GATTSubscription: Codable, Sendable, Hashable, Identifiable {
    public var device: UUID
    public var deviceName: String
    public var service: String
    public var characteristic: String
    public var characteristicName: String
    /// `nil` subscribes to notifications; a number reads the value every so many seconds, for
    /// characteristics that only answer when asked.
    public var pollSeconds: Double?
    /// The device's own description of the value, if it gave one.
    public var presentation: PresentationFormat?
    /// A recipe the user wrote for a characteristic nobody has a decoder for.
    public var template: GATTTemplate?

    public init(device: UUID, deviceName: String, service: String, characteristic: String,
                characteristicName: String, pollSeconds: Double? = nil,
                presentation: PresentationFormat? = nil, template: GATTTemplate? = nil) {
        self.device = device
        self.deviceName = deviceName
        self.service = service
        self.characteristic = characteristic
        self.characteristicName = characteristicName
        self.pollSeconds = pollSeconds
        self.presentation = presentation
        self.template = template
    }

    public var id: String { "\(device.uuidString)|\(BluetoothNames.shortForm(service))|\(BluetoothNames.shortForm(characteristic))" }

    /// The base id of the stream this makes, stable across recordings.
    public var streamBase: String {
        "ble.\(String(device.uuidString.prefix(8)).lowercased()).gatt."
            + ExternalStreamInfo.slug(BluetoothNames.shortForm(characteristic))
    }

    /// Turns a received value into named numbers: the user's template first, then the
    /// standard decoding, then the device's own presentation format. `nil` when none applies —
    /// a raw value nobody can interpret is not a measurement.
    public func decode(_ data: Data) -> BLEReading? {
        if let template, let reading = template.decode(data) { return reading }
        if let reading = GATTDecoding.decode(characteristic: characteristic, data) { return reading }
        if let presentation, let value = presentation.value(from: data) {
            return BLEReading(decoder: characteristicName,
                              fields: [.init("value", value)])
        }
        return nil
    }

    /// Unit of a field this subscription produces — the presentation format's, when that is
    /// where the number came from.
    public func unit(forField field: String, decoder: String) -> String {
        if field == "value", let presentation, template == nil { return presentation.unitSymbol }
        if let template, let match = template.fields.first(where: { $0.name == field }) { return match.unit }
        return BLEUnits.unit(for: field, decoder: decoder)
    }
}
