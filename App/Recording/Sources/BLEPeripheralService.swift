import CoreBluetooth
import Foundation
import SensorstormCore

/// The phone as a Bluetooth sensor: a GATT service other devices subscribe to — an ESP32, a
/// Raspberry Pi, a Mac, a second iPhone — with no Wi-Fi, no server and no account in between.
///
/// One characteristic per sensor (read, notify). Each notification is the sample's time on the
/// phone's host clock as a little-endian Float64, then the channels as Float32. The time is
/// what lets a receiver put two phones' streams on one timeline: it reads the **clock**
/// characteristic a few times, works out the offset (see ``PeerClock``) and subtracts it.
///
/// The **control** characteristic — start, stop, mark — exists only when the person allowed it.
/// Anyone in Bluetooth range could write to it, so it is off unless asked for.
final class BLEPeripheralService: NSObject, CBPeripheralManagerDelegate, @unchecked Sendable {
    enum Command: UInt8, Sendable {
        case start = 1, stop = 2, mark = 3
    }

    static var serviceUUID: CBUUID { CBUUID(string: "53454E53-4F52-5354-4F52-4D5000000001") }
    static var stateUUID: CBUUID { CBUUID(string: "53454E53-4F52-5354-4F52-4D5000000002") }
    static var controlUUID: CBUUID { CBUUID(string: "53454E53-4F52-5354-4F52-4D5000000003") }
    static var clockUUID: CBUUID { CBUUID(string: "53454E53-4F52-5354-4F52-4D5000000004") }

    /// A sensor's characteristic id: a hash of its name, so that adding a sensor to the app
    /// never renumbers the others. FNV-1a, 32 bit.
    static func valueUUID(for sensor: SensorID) -> CBUUID {
        var hash: UInt32 = 2_166_136_261
        for byte in sensor.rawValue.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return CBUUID(string: "53454E53-4F52-5354-4F52-4D50" + String(format: "%08X", hash))
    }

    static func sensor(for uuid: CBUUID) -> SensorID? {
        SensorID.allCases.first { valueUUID(for: $0) == uuid }
    }

    static func payload(time: Double, values: [Double]) -> Data {
        PeerPayload.encode(time: time, values: values)
    }

    static func bytes(_ value: Double) -> Data {
        PeerPayload.clock(value)
    }

    private let queue = DispatchQueue(label: "ch.sensorstorm.blueperipheral")
    private var manager: CBPeripheralManager?
    private var allowsControl = false
    private var valueCharacteristics: [SensorID: CBMutableCharacteristic] = [:]
    private var stateCharacteristic: CBMutableCharacteristic?
    private var latest: [SensorID: Data] = [:]
    private var lastSentTime: [SensorID: Double] = [:]
    private var subscribedSensors: Set<SensorID> = []
    private var subscribers: [CBUUID: Set<UUID>] = [:]
    private var stateData = Data([0])

    /// Runs on the service's queue.
    var onControl: (@Sendable (Command) -> Void)?
    /// How many different devices are subscribed to anything.
    var onSubscribers: (@Sendable (Int) -> Void)?

    func start(allowsControl: Bool) {
        queue.async { [self] in
            self.allowsControl = allowsControl
            if let manager {
                // Settings changed while running: the service is rebuilt so the control
                // characteristic appears or goes.
                if manager.state == .poweredOn { publishService(on: manager) }
                return
            }
            manager = CBPeripheralManager(delegate: self, queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            manager?.stopAdvertising()
            manager?.removeAllServices()
            manager = nil
            valueCharacteristics = [:]
            stateCharacteristic = nil
            subscribedSensors = []
            subscribers = [:]
            lastSentTime = [:]
            onSubscribers?(0)
        }
    }

    /// The newest values of the sensors that are running, at the dashboard's pace. A sensor
    /// that has not produced a new value since last time is not sent again.
    func publish(_ live: [SensorID: LiveSample]) {
        queue.async { [self] in
            guard let manager, manager.state == .poweredOn else { return }
            for (sensor, sample) in live {
                guard lastSentTime[sensor] != sample.hostTime else { continue }
                lastSentTime[sensor] = sample.hostTime
                let data = Self.payload(time: sample.hostTime, values: sample.values)
                latest[sensor] = data
                if subscribedSensors.contains(sensor), let characteristic = valueCharacteristics[sensor] {
                    _ = manager.updateValue(data, for: characteristic, onSubscribedCentrals: nil)
                }
            }
        }
    }

    /// Whether the phone is recording and since when (host clock), for the state characteristic.
    func publishState(isRecording: Bool, since hostTime: Double) {
        queue.async { [self] in
            stateData = isRecording ? Data([1]) + Self.bytes(hostTime) : Data([0])
            guard let manager, let stateCharacteristic, manager.state == .poweredOn else { return }
            _ = manager.updateValue(stateData, for: stateCharacteristic, onSubscribedCentrals: nil)
        }
    }

    // MARK: - Service

    private func publishService(on manager: CBPeripheralManager) {
        manager.stopAdvertising()
        manager.removeAllServices()

        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        var characteristics: [CBMutableCharacteristic] = []
        var byID: [SensorID: CBMutableCharacteristic] = [:]

        for sensor in SensorID.allCases {
            let characteristic = CBMutableCharacteristic(
                type: Self.valueUUID(for: sensor), properties: [.read, .notify], value: nil,
                permissions: [.readable])
            characteristic.descriptors = [
                CBMutableDescriptor(type: CBUUID(string: CBUUIDCharacteristicUserDescriptionString),
                                    value: sensor.rawValue)
            ]
            characteristics.append(characteristic)
            byID[sensor] = characteristic
        }

        let state = CBMutableCharacteristic(type: Self.stateUUID, properties: [.read, .notify], value: nil,
                                            permissions: [.readable])
        let clock = CBMutableCharacteristic(type: Self.clockUUID, properties: [.read], value: nil,
                                            permissions: [.readable])
        characteristics.append(contentsOf: [state, clock])
        if allowsControl {
            characteristics.append(CBMutableCharacteristic(type: Self.controlUUID, properties: [.write], value: nil,
                                                           permissions: [.writeable]))
        }
        service.characteristics = characteristics
        valueCharacteristics = byID
        stateCharacteristic = state
        manager.add(service)
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn { publishService(on: peripheral) }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else {
            RecordingLog.warn("Bluetooth service not added: \(error?.localizedDescription ?? "?")")
            return
        }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
            CBAdvertisementDataLocalNameKey: "Sensorstorm"
        ])
    }

    // MARK: - Requests

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        var value: Data?
        switch request.characteristic.uuid {
        case Self.clockUUID:
            value = Self.bytes(HostClock.now)
        case Self.stateUUID:
            value = stateData
        default:
            if let sensor = Self.sensor(for: request.characteristic.uuid) { value = latest[sensor] ?? Data() }
        }
        guard let value else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        guard request.offset <= value.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = value.subdata(in: request.offset..<value.count)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        guard allowsControl else {
            peripheral.respond(to: first, withResult: .writeNotPermitted)
            return
        }
        for request in requests where request.characteristic.uuid == Self.controlUUID {
            if let code = request.value?.first, let command = Command(rawValue: code) { onControl?(command) }
        }
        peripheral.respond(to: first, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        subscribers[characteristic.uuid, default: []].insert(central.identifier)
        if let sensor = Self.sensor(for: characteristic.uuid) { subscribedSensors.insert(sensor) }
        reportSubscribers()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribers[characteristic.uuid]?.remove(central.identifier)
        if subscribers[characteristic.uuid]?.isEmpty == true {
            subscribers[characteristic.uuid] = nil
            if let sensor = Self.sensor(for: characteristic.uuid) { subscribedSensors.remove(sensor) }
        }
        reportSubscribers()
    }

    private func reportSubscribers() {
        let unique = subscribers.values.reduce(into: Set<UUID>()) { $0.formUnion($1) }
        onSubscribers?(unique.count)
    }
}
