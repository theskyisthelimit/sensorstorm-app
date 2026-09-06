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
final class BluetoothSource: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
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

    /// Attaches the raw log for one recording. Separate from ``start(sensors:)`` because
    /// scanning runs while the record screen is open, and writing down who was in the room
    /// should only happen while something is actually being recorded.
    func beginLogging(_ log: AdvertisementLog?) {
        lock.withLock { self.log = log }
    }

    func endLogging() {
        let log = lock.withLock { () -> AdvertisementLog? in
            let existing = self.log
            self.log = nil
            return existing
        }
        log?.close()
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
        central?.delegate = nil
        central = nil
        lock.withLock { recent.removeAll() }
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
        guard central.state == .poweredOn, isRunning else { return }
        // Duplicates on: without them a device that stays in range is reported once and its
        // signal never changes again, which is the opposite of a stream.
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // 127 is CoreBluetooth's "RSSI unavailable"; a value that is not a measurement has
        // no business being averaged into one.
        let rssi = RSSI.doubleValue
        guard rssi < 0 else { return }
        let log = lock.withLock { () -> AdvertisementLog? in
            recent[peripheral.identifier] = rssi
            return self.log
        }
        guard let log else { return }

        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map(\.uuidString) ?? []
        log.append(hostTime: HostClock.now,
                   address: peripheral.identifier,
                   rssi: rssi,
                   name: advertisementData[CBAdvertisementDataLocalNameKey] as? String,
                   manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
                   services: services)
    }
}
