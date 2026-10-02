import CoreBluetooth
import Foundation
import SensorstormCore

/// How much Bluetooth is around: how many distinct devices advertised in the last second,
/// and how strong the strongest and the average signal were.
///
/// The stream is a summary rather than a device list, and deliberately so. A stream is a
/// fixed-width row of `Double`s — that is exactly what makes scrubbing a half-hour recording
/// instant — while a BLE advertisement is a UUID, a name and a bag of manufacturer bytes.
/// Bending the storage format around one sensor would cost every other stream its random
/// access. What is plotted is therefore the part that actually plots: a crowd getting
/// denser, a beacon getting closer, a room emptying out.
///
/// The raw advertisements go somewhere else, into ``AdvertisementLog``, and only when that
/// is switched on separately. Counting how much Bluetooth is around and writing down which
/// devices those were are two different things to ask for, and the second one is the reason
/// a RuuviTag's temperature can be recovered from a recording.
///
/// Scanning needs the app in the foreground. iOS refuses a service-less background scan, and
/// a scan filtered to known services would only find beacons someone already knew to look
/// for — which is not what „was in the area" means.
///
/// **Decoded sensors.** With decoding on, every advertisement also goes past the built-in
/// decoders and the user's decoder files, and devices the user paired are connected over
/// GATT — heart rate, cycling power, speed and cadence, running foot pods. What comes out
/// is shown live and, during a recording, written to ``BLEReadingLog``.
final class BluetoothSource: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {

    /// The newest decoded values of one device.
    struct DeviceReading: Sendable, Identifiable {
        let id: UUID
        var name: String?
        var reading: BLEReading
        var hostTime: Double
    }

    /// A device advertising one of the standard GATT profiles, offered for pairing.
    struct Connectable: Sendable, Identifiable, Hashable {
        let id: UUID
        var name: String?
        var profiles: [BLEDecoders.Profile]
    }

    private let sink: SampleSink

    private let queue = DispatchQueue(label: "ch.sensorstorm.bluetooth")
    private let lock = NSLock()

    /// Newest RSSI per peripheral, cleared after every emitted sample.
    private var recent: [UUID: Double] = [:]
    private var central: CBCentralManager?
    /// Set for the duration of a recording, and only when the raw log is switched on.
    private var log: AdvertisementLog?
    private var timer: DispatchSourceTimer?
    private var isRunning = false
    /// Resumed once from `centralManagerDidUpdateState`, which is the first moment the
    /// system's answer to the permission prompt is knowable.
    private var authorizationContinuation: CheckedContinuation<Void, Never>?

    // Decoding. All guarded by `lock`; read on the scan queue.
    private var decodesAdvertisements = false
    private var scriptDecoders: [ScriptDecoders] = []
    private var paired: Set<UUID> = []
    private var readings: [UUID: DeviceReading] = [:]
    private var connectables: [UUID: Connectable] = [:]
    private var readingLog: BLEReadingLog?
    /// Strong references: CoreBluetooth drops a peripheral nobody holds, connection and all.
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var cadence: [UUID: CSCTracker] = [:]

    init(sink: SampleSink) {
        self.sink = sink
        super.init()
    }

    /// Every iPhone has BLE; the Simulator has none, and instantiating a central there only
    /// produces a `.unsupported` state and a log line.
    var availableSensors: Set<SensorID> {
        #if targetEnvironment(simulator)
        []
        #else
        [.bluetooth]
        #endif
    }

    /// Triggers the Bluetooth prompt without scanning.
    ///
    /// Constructing a central is what asks; the delegate callback is what tells us the
    /// answer arrived. Kept around afterwards so a later ``start(sensors:)`` reuses it
    /// rather than building a second one.
    func requestAuthorization() async {
        guard CBManager.authorization == .notDetermined else { return }
        await withCheckedContinuation { continuation in
            lock.withLock { authorizationContinuation = continuation }
            if central == nil {
                central = CBCentralManager(delegate: self, queue: queue,
                                           options: [CBCentralManagerOptionShowPowerAlertKey: false])
            }
        }
    }

    /// Attaches the raw log for one recording. Separate from ``start(sensors:)`` because
    /// scanning runs while the record screen is open, and writing down who was in the room
    /// should only happen while something is actually being recorded.
    func beginLogging(_ log: AdvertisementLog?) {
        lock.withLock { self.log = log }
    }

    func endLogging() {
        let (log, readingLog) = lock.withLock { () -> (AdvertisementLog?, BLEReadingLog?) in
            defer { self.log = nil; self.readingLog = nil }
            return (self.log, self.readingLog)
        }
        log?.close()
        readingLog?.close()
    }

    /// Decoded values go to their own file, and only while recording.
    func beginReadingLog(_ log: BLEReadingLog?) {
        lock.withLock { readingLog = log }
    }

    /// Set before ``start(sensors:)``; takes effect with the next scan.
    func configureDecoding(enabled: Bool, decoders: [ScriptDecoders], paired: Set<UUID>) {
        lock.withLock {
            decodesAdvertisements = enabled
            scriptDecoders = decoders
            self.paired = paired
        }
    }

    var latestReadings: [DeviceReading] {
        lock.withLock { readings.values.sorted { ($0.name ?? "") < ($1.name ?? "") } }
    }

    var connectableDevices: [Connectable] {
        lock.withLock { connectables.values.sorted { ($0.name ?? "~") < ($1.name ?? "~") } }
    }

    func start(sensors: Set<SensorID>) {
        guard sensors.contains(.bluetooth), !availableSensors.isEmpty, !isRunning else { return }
        isRunning = true

        // Created here rather than in `init`: constructing a central is what triggers the
        // system permission prompt, and asking for Bluetooth on first launch — before the
        // user has armed the sensor — is how an app earns a "why does it want that".
        central = CBCentralManager(delegate: self, queue: queue,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.emit() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.cancel()
        timer = nil
        central?.stopScan()
        let connected = lock.withLock { () -> [CBPeripheral] in
            defer {
                peripherals.removeAll()
                readings.removeAll()
                connectables.removeAll()
                cadence.removeAll()
            }
            recent.removeAll()
            return Array(peripherals.values)
        }
        for peripheral in connected { central?.cancelPeripheralConnection(peripheral) }
        central?.delegate = nil
        central = nil
    }

    // MARK: - Sampling

    private func emit() {
        let readings: [Double] = lock.withLock {
            let values = Array(recent.values)
            recent.removeAll(keepingCapacity: true)
            return values
        }
        // An empty second is still a measurement: zero devices in range is a fact about the
        // place. The RSSI columns stay empty rather than reporting a signal nobody heard.
        let count = Double(readings.count)
        let strongest = readings.max() ?? .nan
        let mean = readings.isEmpty ? Double.nan : readings.reduce(0, +) / count
        sink.ingest(.bluetooth, time: HostClock.now, values: [count, strongest, mean])
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // The first state that is not `.unknown` is also the first moment the permission
        // answer is knowable, whether it was yes or no.
        if central.state != .unknown {
            let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                let existing = authorizationContinuation
                authorizationContinuation = nil
                return existing
            }
            waiting?.resume()
        }
        guard central.state == .poweredOn, isRunning else { return }
        // Duplicates on: without them a device that stays in range is reported once and its
        // signal never changes again, which is the opposite of a stream.
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])

        // Paired devices are reached by identifier, not by waiting for an advertisement: a
        // strap already connected to the phone for another app stops advertising.
        let wanted = lock.withLock { Array(paired) }
        for peripheral in central.retrievePeripherals(withIdentifiers: wanted) {
            connect(peripheral)
        }
    }

    private func connect(_ peripheral: CBPeripheral) {
        let isNew = lock.withLock { () -> Bool in
            guard peripherals[peripheral.identifier] == nil else { return false }
            peripherals[peripheral.identifier] = peripheral
            return true
        }
        guard isNew else { return }
        peripheral.delegate = self
        central?.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // 127 is CoreBluetooth's "RSSI unavailable"; a value that is not a measurement has
        // no business being averaged into one.
        let rssi = RSSI.doubleValue
        guard rssi < 0 else { return }
        let (log, decodes, decoders, isPaired) = lock.withLock {
            recent[peripheral.identifier] = rssi
            return (self.log, decodesAdvertisements, scriptDecoders, paired.contains(peripheral.identifier))
        }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name

        if decodes {
            let serviceData = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data])?
                .reduce(into: [String: Data]()) { $0[$1.key.uuidString] = $1.value } ?? [:]
            let advertisement = BLEAdvertisement(
                name: name,
                manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
                serviceData: serviceData)
            // The user's own decoders first: someone who wrote one for a device the app also
            // knows wants theirs.
            if let reading = decoders.lazy.compactMap({ $0.decode(advertisement) }).first
                ?? BLEDecoders.decode(advertisement) {
                record(reading, from: peripheral.identifier, name: name)
            }

            let profiles = ((advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? [])
                .compactMap { BLEDecoders.Profile(rawValue: $0.uuidString) }
            if !profiles.isEmpty {
                lock.withLock {
                    connectables[peripheral.identifier] = Connectable(
                        id: peripheral.identifier, name: name, profiles: profiles)
                }
            }
        }
        if isPaired { connect(peripheral) }

        guard let log else { return }

        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map(\.uuidString) ?? []
        log.append(hostTime: HostClock.now,
                   address: peripheral.identifier,
                   rssi: rssi,
                   name: name,
                   manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
                   services: services)
    }

    // MARK: - Decoded readings

    private func record(_ reading: BLEReading, from device: UUID, name: String?) {
        let now = HostClock.now
        let log = lock.withLock { () -> BLEReadingLog? in
            readings[device] = DeviceReading(id: device, name: name ?? readings[device]?.name,
                                             reading: reading, hostTime: now)
            return readingLog
        }
        log?.append(hostTime: now, device: device, name: name, reading: reading)
    }

    // MARK: - GATT

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(BLEDecoders.Profile.allCases.map { CBUUID(string: $0.rawValue) })
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        lock.withLock { _ = peripherals.removeValue(forKey: peripheral.identifier) }
    }

    /// A strap that drops out mid-ride comes back by itself: `connect` has no timeout and
    /// completes whenever the device is in range again.
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        guard isRunning, lock.withLock({ paired.contains(peripheral.identifier) }) else { return }
        central.connect(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            guard let profile = BLEDecoders.Profile(rawValue: service.uuid.uuidString) else { continue }
            peripheral.discoverCharacteristics([CBUUID(string: profile.measurement)], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for characteristic in service.characteristics ?? [] {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let data = characteristic.value,
              let service = characteristic.service,
              let profile = BLEDecoders.Profile(rawValue: service.uuid.uuidString),
              var reading = BLEDecoders.decode(profile, data) else { return }
        if profile == .cyclingSpeedCadence {
            reading = lock.withLock {
                var tracker = cadence[peripheral.identifier] ?? CSCTracker()
                defer { cadence[peripheral.identifier] = tracker }
                return tracker.update(reading)
            }
        }
        record(reading, from: peripheral.identifier, name: peripheral.name)
    }
}
