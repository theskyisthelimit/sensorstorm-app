import CoreBluetooth
import Foundation
import SensorstormCore

/// A second phone running Sensorstorm, seen from this one: found over Bluetooth, connected, its
/// clock measured, its sensors recorded as streams of this recording on this recording's clock.
///
/// Two phones have two clocks and no shared oscillator. The link asks the other phone what
/// time it is sixteen times, keeps the exchanges that were quickest, and takes their median
/// offset (see ``PeerClock``); the uncertainty goes into the recording next to the offset, so
/// a reader can see whether the alignment is good to two milliseconds or to twenty.
///
/// Both apps have to be in the foreground — iOS advertises only the service UUID from the
/// background, and a service nobody can read from is not a link.
final class PeerLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    struct Peer: Identifiable, Sendable, Equatable {
        var id: UUID
        var name: String
        var rssi: Int
    }

    enum Status: Sendable, Equatable {
        case idle, scanning
        case connecting(String)
        case syncing(String)
        case connected(String)
        case failed(String)
    }

    struct Connection: Sendable, Equatable {
        var name: String
        var identifier: UUID
        var clock: PeerClockEstimate
        /// What the other phone said about its own recording, as far as it said.
        var isRecording: Bool
    }

    private static let sampleRounds = 16

    private let sink: SampleSink
    private let queue = DispatchQueue(label: "ch.sensorstorm.peerlink")
    private var central: CBCentralManager?
    private var wantsScan = false
    private var discovered: [UUID: (peripheral: CBPeripheral, peer: Peer)] = [:]
    private var peripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var samples: [PeerClockSample] = []
    private var asked: Double?
    private var estimate: PeerClockEstimate?
    private var peerName = ""
    private var peerRecording = false
    private var streamPrefix = ""

    var onPeers: (@Sendable ([Peer]) -> Void)?
    var onStatus: (@Sendable (Status) -> Void)?
    var onConnection: (@Sendable (Connection?) -> Void)?
    /// The other phone's ultra-wideband token, read from its nearby characteristic.
    var onNearbyToken: (@Sendable (Data) -> Void)?

    init(sink: SampleSink) {
        self.sink = sink
    }

    // MARK: - Scanning and connecting

    func startScan() {
        queue.async { [self] in
            wantsScan = true
            guard let central else {
                central = CBCentralManager(delegate: self, queue: queue)
                return
            }
            if central.state == .poweredOn { beginScan(central) }
        }
    }

    func stopScan() {
        queue.async { [self] in
            wantsScan = false
            central?.stopScan()
            if peripheral == nil { onStatus?(.idle) }
        }
    }

    func connect(_ id: UUID) {
        queue.async { [self] in
            guard let central, let entry = discovered[id] else { return }
            central.stopScan()
            wantsScan = false
            peripheral = entry.peripheral
            peerName = entry.peer.name
            entry.peripheral.delegate = self
            onStatus?(.connecting(entry.peer.name))
            central.connect(entry.peripheral)
        }
    }

    func disconnect() {
        queue.async { [self] in
            if let peripheral, let central { central.cancelPeripheralConnection(peripheral) }
            reset()
            onStatus?(.idle)
        }
    }

    /// Measures the offset again, on the connection that is already open. Called when a
    /// recording starts, so the figure stored with it is minutes old at most, not an hour.
    func resync() {
        queue.async { [self] in
            guard peripheral != nil, characteristics[BLEPeripheralService.clockUUID] != nil else { return }
            beginSync()
        }
    }

    /// Starts or stops the other phone's recording. Works only if the other phone allowed
    /// control; otherwise its write is refused and nothing happens.
    func send(_ command: BLEPeripheralService.Command) {
        queue.async { [self] in
            guard let peripheral, let control = characteristics[BLEPeripheralService.controlUUID] else { return }
            peripheral.writeValue(Data([command.rawValue]), for: control, type: .withResponse)
        }
    }

    /// Swaps ultra-wideband tokens: writes this phone's and reads the other's. Needs the other
    /// phone to allow control, which is also what lets it start a ranging session.
    func exchangeNearbyToken(_ own: Data) {
        queue.async { [self] in
            guard let peripheral, let nearby = characteristics[BLEPeripheralService.nearbyUUID] else { return }
            peripheral.writeValue(own, for: nearby, type: .withResponse)
            peripheral.readValue(for: nearby)
        }
    }

    private func reset() {
        peripheral = nil
        characteristics = [:]
        samples = []
        asked = nil
        estimate = nil
        peerRecording = false
        onConnection?(nil)
    }

    private func beginScan(_ central: CBCentralManager) {
        discovered = [:]
        onPeers?([])
        central.scanForPeripherals(withServices: [BLEPeripheralService.serviceUUID], options: nil)
        onStatus?(.scanning)
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn, wantsScan {
            beginScan(central)
        } else if central.state != .poweredOn, central.state != .unknown, central.state != .resetting {
            onStatus?(.failed(String(localized: "Bluetooth ist aus oder nicht erlaubt.")))
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "Sensorstorm"
        discovered[peripheral.identifier] = (peripheral, Peer(id: peripheral.identifier, name: name,
                                                              rssi: RSSI.intValue))
        onPeers?(discovered.values.map(\.peer).sorted { $0.rssi > $1.rssi })
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([BLEPeripheralService.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        reset()
        onStatus?(.failed(error?.localizedDescription ?? String(localized: "Verbindung fehlgeschlagen.")))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        reset()
        onStatus?(error == nil ? .idle : .failed(String(localized: "Die Verbindung wurde getrennt.")))
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == BLEPeripheralService.serviceUUID {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for characteristic in service.characteristics ?? [] {
            characteristics[characteristic.uuid] = characteristic
        }
        guard characteristics[BLEPeripheralService.clockUUID] != nil else {
            onStatus?(.failed(String(localized: "Das Gerät bietet keine Uhr an.")))
            return
        }
        streamPrefix = "peer.\(String(peripheral.identifier.uuidString.prefix(8)).lowercased())"
        beginSync()
    }

    private func beginSync() {
        samples = []
        onStatus?(.syncing(peerName))
        askClock()
    }

    private func askClock() {
        guard let peripheral, let clock = characteristics[BLEPeripheralService.clockUUID] else { return }
        asked = HostClock.now
        peripheral.readValue(for: clock)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        let received = HostClock.now
        guard error == nil, let data = characteristic.value else { return }

        if characteristic.uuid == BLEPeripheralService.clockUUID {
            guard let asked, let remote = PeerPayload.decodeClock(data) else { return }
            self.asked = nil
            samples.append(PeerClockSample(asked: asked, remote: remote, answered: received))
            if samples.count < Self.sampleRounds {
                askClock()
            } else {
                finishSync(on: peripheral)
            }
        } else if characteristic.uuid == BLEPeripheralService.nearbyUUID {
            onNearbyToken?(data)
        } else if characteristic.uuid == BLEPeripheralService.stateUUID {
            peerRecording = data.first == 1
            publishConnection(peripheral)
        } else if let sensor = BLEPeripheralService.sensor(for: characteristic.uuid), let estimate,
                  let sample = PeerPayload.decode(data) {
            record(sensor, sample, using: estimate)
        }
    }

    private func finishSync(on peripheral: CBPeripheral) {
        guard let result = PeerClock.estimate(samples) else {
            onStatus?(.failed(String(localized: "Die Uhr des Geräts liess sich nicht messen.")))
            return
        }
        let firstTime = estimate == nil
        estimate = result
        publishConnection(peripheral)
        onStatus?(.connected(peerName))
        guard firstTime else { return }
        // Subscribed once: the offset is applied to whatever arrives, and a later `resync`
        // only replaces the number.
        for (uuid, characteristic) in characteristics
        where uuid == BLEPeripheralService.stateUUID || BLEPeripheralService.sensor(for: uuid) != nil {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    private func publishConnection(_ peripheral: CBPeripheral) {
        guard let estimate else { return }
        onConnection?(Connection(name: peerName, identifier: peripheral.identifier, clock: estimate,
                                 isRecording: peerRecording))
    }

    private func record(_ sensor: SensorID, _ sample: (time: Double, values: [Double]),
                        using estimate: PeerClockEstimate) {
        let descriptor = sensor.descriptor
        guard sample.values.count == descriptor.channelCount else { return }
        let info = ExternalStreamInfo(id: "\(streamPrefix).\(sensor.rawValue)", source: .bluetooth,
                                      title: "\(peerName) · \(sensor.rawValue)",
                                      channels: descriptor.channels, channelUnits: descriptor.channelUnits)
        sink.ingestExternal(info, time: PeerClock.local(from: sample.time, using: estimate), values: sample.values)
    }
}
