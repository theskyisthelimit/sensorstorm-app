import CoreBluetooth
import Foundation
import SensorstormCore

/// A characteristic as the explorer shows it: what the device says about it, and the last
/// value it was seen to hold.
struct GATTCharacteristicInfo: Sendable, Identifiable, Equatable {
    /// `<service uuid>/<characteristic uuid>#<index>` — a UUID alone is not unique: the same
    /// characteristic appears under two services, and a device may repeat one.
    let id: String
    let serviceUUID: String
    let uuid: String
    var properties: [Property]
    var value: Data?
    var valueTime: Double?
    /// 0x2901, the characteristic's own description.
    var userDescription: String?
    /// 0x2904, how to read the value.
    var presentation: PresentationFormat?
    var isNotifying = false

    enum Property: String, Sendable, CaseIterable {
        case broadcast, read, writeWithoutResponse, write, notify, indicate
        case authenticatedSignedWrites, extendedProperties
        case notifyEncryptionRequired, indicateEncryptionRequired

        /// The short mark BLE tools put on a characteristic: R, W, WWR, N, I and so on.
        var badge: String {
            switch self {
            case .broadcast: "BC"
            case .read: "R"
            case .writeWithoutResponse: "WWR"
            case .write: "W"
            case .notify: "N"
            case .indicate: "I"
            case .authenticatedSignedWrites: "ASW"
            case .extendedProperties: "EXT"
            case .notifyEncryptionRequired: "NENC"
            case .indicateEncryptionRequired: "IENC"
            }
        }
    }

    var name: String? { BluetoothNames.characteristic(uuid) }
    var canRead: Bool { properties.contains(.read) }
    var canWrite: Bool { properties.contains(.write) || properties.contains(.writeWithoutResponse) }
    var canNotify: Bool { properties.contains(.notify) || properties.contains(.indicate) }

    /// What a value means, if anything in this app can say: the standard decoding, then the
    /// device's own presentation format.
    func decoded() -> BLEReading? {
        guard let value else { return nil }
        if let reading = GATTDecoding.decode(characteristic: uuid, value) { return reading }
        if let presentation, let number = presentation.value(from: value) {
            return BLEReading(decoder: userDescription ?? name ?? uuid,
                              fields: [.init("value", number)])
        }
        return nil
    }

    static func properties(of raw: CBCharacteristicProperties) -> [Property] {
        var result: [Property] = []
        if raw.contains(.broadcast) { result.append(.broadcast) }
        if raw.contains(.read) { result.append(.read) }
        if raw.contains(.writeWithoutResponse) { result.append(.writeWithoutResponse) }
        if raw.contains(.write) { result.append(.write) }
        if raw.contains(.notify) { result.append(.notify) }
        if raw.contains(.indicate) { result.append(.indicate) }
        if raw.contains(.authenticatedSignedWrites) { result.append(.authenticatedSignedWrites) }
        if raw.contains(.extendedProperties) { result.append(.extendedProperties) }
        if raw.contains(.notifyEncryptionRequired) { result.append(.notifyEncryptionRequired) }
        if raw.contains(.indicateEncryptionRequired) { result.append(.indicateEncryptionRequired) }
        return result
    }
}

struct GATTServiceInfo: Sendable, Identifiable, Equatable {
    let uuid: String
    var isPrimary: Bool
    var characteristics: [GATTCharacteristicInfo]

    var id: String { uuid }
    var name: String? { BluetoothNames.service(uuid) }
}

/// What the explorer's connection tells the screen. Delivered on the Bluetooth queue; the
/// model hops to the main actor.
enum GATTExplorerEvent: Sendable {
    case connected
    case failed(String)
    case disconnected(String?)
    case services([GATTServiceInfo])
    case rssi(Double)
    case written(characteristic: String, error: String?)
}

/// What the central is able to do right now, in words the screen can use.
enum BluetoothAvailability: Sendable, Equatable {
    case unknown
    case poweredOn
    case poweredOff
    case unauthorized
    case unsupported
    case resetting

    init(_ state: CBManagerState) {
        switch state {
        case .poweredOn: self = .poweredOn
        case .poweredOff: self = .poweredOff
        case .unauthorized: self = .unauthorized
        case .unsupported: self = .unsupported
        case .resetting: self = .resetting
        default: self = .unknown
        }
    }
}
