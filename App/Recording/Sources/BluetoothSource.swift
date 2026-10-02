import CoreBluetooth
import Foundation
import SensorstormCore
import UIKit

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
///
/// **Scanner and explorer.** The same central serves two screens that need no recording: a
/// scanner that lists every device in range with its signal and its packets, and an explorer
/// that connects to one device and lists its services and characteristics. They hold the
/// scan by counting (``acquireScanner()``), so closing one does not stop the other, and
/// recording does not depend on either being open. Which characteristics are recorded is
/// ``GATTSubscription``; they become streams of their own like any decoded value.
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

    private static let restoreIdentifier = "ch.sensorstorm.bluetooth.central"

    private let queue = DispatchQueue(label: "ch.sensorstorm.bluetooth")
    private let lock = NSLock()

    /// Newest RSSI per peripheral, cleared after every emitted sample.
    private var recent: [UUID: Double] = [:]
    private var central: CBCentralManager?
    /// Set for the duration of a recording, and only when the raw log is switched on.
    private var log: AdvertisementLog?
    private var timer: DispatchSourceTimer?
    /// The Bluetooth stream is armed: the record screen is open and the sensor is on.
    private var isArmed = false
    /// How many screens want the scan — the scanner and the explorer. Counted, so the one
    /// that closes last is the one that stops it.
    private var scanHolders = 0
    private var isBackground = false
    /// Resumed once from `centralManagerDidUpdateState`, which is the first moment the
    /// system's answer to the permission prompt is knowable.
    private var authorizationContinuation: CheckedContinuation<Void, Never>?

    // Decoding. All guarded by `lock`; read on the scan queue.
    private var decodesAdvertisements = false
    private var scriptDecoders: [ScriptDecoders] = []
    private var paired: Set<UUID> = []
    private var subscriptions: [GATTSubscription] = []
    private var readings: [UUID: DeviceReading] = [:]
    private var connectables: [UUID: Connectable] = [:]
    private var readingLog: BLEReadingLog?
    /// Strong references: CoreBluetooth drops a peripheral nobody holds, connection and all.
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var cadence: [UUID: CSCTracker] = [:]
    /// Which stream a decoded packet belongs to. A decoder may return other names after a
    /// firmware update; a different set of names is a different stream, not a crooked row.
    private var registry = ExternalStreamRegistry()
    /// Time of the newest heartbeat handed on per strap, so a strap that repeats the last
    /// interval in the next packet does not write the same beat twice.
    private var lastBeat: [UUID: Double] = [:]

    // The scanner's table, filled only while a screen holds the scan.
    private var table = DeviceTable()

    // Characteristics that do not notify are asked for on a timer.
    private struct PollTarget {
        let peripheral: CBPeripheral
        let characteristic: CBCharacteristic
        let interval: Double
        var lastRead: Double
    }
    private var pollTargets: [String: PollTarget] = [:]
    private var pollTimer: DispatchSourceTimer?

    // The explorer's connection.
    private var explorerPeripheral: CBPeripheral?
    private var explorerCharacteristics: [String: CBCharacteristic] = [:]
    private var explorerInfo: [GATTServiceInfo] = []
    private var explorerValueTimes: [String: Double] = [:]
    /// Set by the explorer model; called on the Bluetooth queue.
    var onExplorerEvent: (@Sendable (GATTExplorerEvent) -> Void)?

    init(sink: SampleSink) {
        self.sink = sink
        super.init()
        // iOS only lets a background app scan for devices that advertise a service it names;
        // an unfiltered scan returns nothing there. Switching on the way in and out keeps the
        // scan useful when the screen locks during a recording.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.applicationStateChanged(background: true) }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.applicationStateChanged(background: false) }
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

    /// Whether the scanner and the explorer can run on this device at all.
    var isSupported: Bool { !availableSensors.isEmpty }

    /// What the central can do right now. `.unknown` until something has asked for it.
    var availability: BluetoothAvailability {
        switch CBManager.authorization {
        case .denied, .restricted: return .unauthorized
        default: break
        }
        return lock.withLock { central.map { BluetoothAvailability($0.state) } } ?? .unknown
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
                central = makeCentral()
            }
        }
    }

    private func makeCentral() -> CBCentralManager {
        CBCentralManager(delegate: self, queue: queue,
                         options: [CBCentralManagerOptionShowPowerAlertKey: false,
                                   CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier])
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

    /// Set before ``start(sensors:)``; takes effect with the next scan — and, for
    /// characteristics newly chosen for recording, immediately.
    func configureDecoding(enabled: Bool, decoders: [ScriptDecoders], paired: Set<UUID>,
                           subscriptions: [GATTSubscription] = []) {
        lock.withLock {
            decodesAdvertisements = enabled
            scriptDecoders = decoders
            self.paired = paired
            self.subscriptions = subscriptions
        }
        queue.async { [weak self] in self?.connectWantedDevices() }
    }

    var latestReadings: [DeviceReading] {
        lock.withLock { readings.values.sorted { ($0.name ?? "") < ($1.name ?? "") } }
    }

    var connectableDevices: [Connectable] {
        lock.withLock { connectables.values.sorted { ($0.name ?? "~") < ($1.name ?? "~") } }
    }

    /// Everything the scanner has seen, strongest signal first.
    func scannedDevices() -> [ScannedDevice] {
        lock.withLock { table.devices.values.sorted { $0.rssi > $1.rssi } }
    }

    func scannedDevice(_ id: UUID) -> ScannedDevice? {
        lock.withLock { table.devices[id] }
    }

    func clearScannedDevices() {
        lock.withLock { table.removeAll() }
    }

    // MARK: - Lifecycle

    func start(sensors: Set<SensorID>) {
        guard sensors.contains(.bluetooth), isSupported else { return }
        let wasArmed = lock.withLock { () -> Bool in
            let was = isArmed
            isArmed = true
            return was
        }
        guard !wasArmed else { return }
        ensureRunning()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.emit() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        let wasArmed = lock.withLock { () -> Bool in
            let was = isArmed
            isArmed = false
            return was
        }
        guard wasArmed else { return }
        timer?.cancel()
        timer = nil
        recentClear()
        teardownIfIdle()
    }

    /// The scanner or the explorer opened. Starts the scan if nothing else has.
    func acquireScanner() {
        guard isSupported else { return }
        lock.withLock { scanHolders += 1 }
        ensureRunning()
    }

    func releaseScanner() {
        lock.withLock { scanHolders = max(scanHolders - 1, 0) }
        teardownIfIdle()
    }

    private var wantsScan: Bool {
        lock.withLock { isArmed || scanHolders > 0 }
    }

    private func recentClear() {
        lock.withLock { recent.removeAll() }
    }

    private func ensureRunning() {
        // Created here rather than in `init`: constructing a central is what triggers the
        // system permission prompt, and asking for Bluetooth on first launch — before the
        // user has armed the sensor — is how an app earns a "why does it want that".
        queue.async { [self] in
            if let existing = central {
                if existing.state == .poweredOn { beginScan(existing) }
            } else {
                central = makeCentral()
            }
        }
    }

    private func beginScan(_ central: CBCentralManager) {
        guard wantsScan else { return }
        let background = lock.withLock { isBackground }
        if central.isScanning { central.stopScan() }
        // Duplicates on: without them a device that stays in range is reported once and its
        // signal never changes again, which is the opposite of a stream.
        central.scanForPeripherals(withServices: background ? backgroundServices() : nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        connectWantedDevices()
    }

    /// The services worth waiting for while the screen is off: the broadcast formats this app
    /// decodes, the sport profiles, and whatever the user chose to record.
    private func backgroundServices() -> [CBUUID] {
        var uuids = ["FCD2", "181A", "FEAA"] + BLEDecoders.Profile.allCases.map(\.rawValue)
        let chosen = lock.withLock { subscriptions.map(\.service) }
        uuids.append(contentsOf: chosen)
        return Array(Set(uuids.map { BluetoothNames.shortForm($0) })).map { CBUUID(string: $0) }
    }

    private func applicationStateChanged(background: Bool) {
        queue.async { [self] in
            lock.withLock { isBackground = background }
            if let central, central.state == .poweredOn, wantsScan { beginScan(central) }
        }
    }

    /// Everything that was needed is gone: stop scanning and let the central go.
    private func teardownIfIdle() {
        queue.async { [self] in
            let idle = lock.withLock { !isArmed && scanHolders == 0 && explorerPeripheral == nil }
            guard idle else { return }
            central?.stopScan()
            let connected = lock.withLock { () -> [CBPeripheral] in
                defer {
                    peripherals.removeAll()
                    readings.removeAll()
                    connectables.removeAll()
                    cadence.removeAll()
                    lastBeat.removeAll()
                    pollTargets.removeAll()
                    table.removeAll()
                }
                recent.removeAll()
                return Array(peripherals.values)
            }
            pollTimer?.cancel()
            pollTimer = nil
            for peripheral in connected { central?.cancelPeripheralConnection(peripheral) }
            central?.delegate = nil
            central = nil
        }
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
        guard central.state == .poweredOn, wantsScan else { return }
        beginScan(central)
    }

    /// iOS relaunched the app for a Bluetooth event and hands back what the central held.
    /// The connections are taken over as they were, so a strap that stayed connected keeps
    /// delivering instead of being found again from scratch.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        lock.withLock {
            for peripheral in restored {
                peripherals[peripheral.identifier] = peripheral
                peripheral.delegate = self
            }
        }
    }

    /// Paired devices and devices with a chosen characteristic are reached by identifier, not
    /// by waiting for an advertisement: a strap already connected to the phone for another
    /// app stops advertising.
    private func connectWantedDevices() {
        guard let central, central.state == .poweredOn, wantsScan else { return }
        let wanted = lock.withLock { Array(paired.union(subscriptions.map(\.device))) }
        guard !wanted.isEmpty else { return }
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

    private func wantsConnection(_ id: UUID) -> Bool {
        lock.withLock { paired.contains(id) || subscriptions.contains { $0.device == id } }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // 127 is CoreBluetooth's "RSSI unavailable"; a value that is not a measurement has
        // no business being averaged into one.
        let rssi = RSSI.doubleValue
        guard rssi < 0 else { return }
        let now = HostClock.now
        let (log, decodes, decoders, shouldConnect, showsDevices) = lock.withLock {
            if isArmed { recent[peripheral.identifier] = rssi }
            return (self.log, decodesAdvertisements, scriptDecoders,
                    paired.contains(peripheral.identifier)
                        || subscriptions.contains { $0.device == peripheral.identifier },
                    scanHolders > 0)
        }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name

        let serviceData = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data])?
            .reduce(into: [String: Data]()) { $0[$1.key.uuidString] = $1.value } ?? [:]
        let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let serviceUUIDs = ((advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? [])
            + ((advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]) ?? [])

        // Decoded for the screen whenever a screen is looking, and for the recording only with
        // the setting: reading a neighbour's thermometer is a choice, showing it is not.
        var reading: BLEReading?
        var beacon: BeaconInfo?
        if decodes || showsDevices {
            let advertisement = BLEAdvertisement(name: name, manufacturerData: manufacturer,
                                                 serviceData: serviceData)
            beacon = BeaconDecoder.decode(advertisement)
            // The user's own decoders first: someone who wrote one for a device the app also
            // knows wants theirs.
            reading = (decodes ? decoders.lazy.compactMap({ $0.decode(advertisement) }).first : nil)
                ?? BLEDecoders.decode(advertisement) ?? beacon?.reading
            if decodes, let reading {
                record(reading, from: peripheral.identifier, name: name)
            }
        }

        if showsDevices {
            let packet = ScannedAdvertisement(
                name: name, manufacturerData: manufacturer,
                serviceUUIDs: serviceUUIDs.map(\.uuidString), serviceData: serviceData,
                txPower: (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.doubleValue,
                isConnectable: (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue,
                beacon: beacon, reading: reading)
            lock.withLock {
                table.record(id: peripheral.identifier, time: now, rssi: rssi, advertisement: packet)
            }
        }

        if decodes {
            let profiles = serviceUUIDs.compactMap { BLEDecoders.Profile(rawValue: $0.uuidString) }
            if !profiles.isEmpty {
                lock.withLock {
                    connectables[peripheral.identifier] = Connectable(
                        id: peripheral.identifier, name: name, profiles: profiles)
                }
            }
        }
        if shouldConnect { connect(peripheral) }

        guard let log else { return }
        log.append(hostTime: now,
                   address: peripheral.identifier,
                   rssi: rssi,
                   name: name,
                   manufacturerData: manufacturer,
                   services: serviceUUIDs.map(\.uuidString))
    }

    // MARK: - Decoded readings

    private func record(_ reading: BLEReading, from device: UUID, name: String?,
                        streamBase: String? = nil, title: String? = nil,
                        unit: ((String) -> String)? = nil) {
        let now = HostClock.now
        let log = lock.withLock { () -> BLEReadingLog? in
            readings[device] = DeviceReading(id: device, name: name ?? readings[device]?.name,
                                             reading: reading, hostTime: now)
            return readingLog
        }
        log?.append(hostTime: now, device: device, name: name, reading: reading)
        ingestStream(reading, from: device, name: name, at: now,
                     streamBase: streamBase, title: title, unit: unit)
    }

    /// The same values as a stream of their own, so they reach the dashboard, the rules, the
    /// playback and every export like any other sensor — not only a CSV on the side.
    private func ingestStream(_ reading: BLEReading, from device: UUID, name: String?, at now: Double,
                              streamBase: String? = nil, title: String? = nil,
                              unit: ((String) -> String)? = nil) {
        guard !reading.fields.isEmpty else { return }
        let short = String(device.uuidString.prefix(8)).lowercased()
        let label = name.flatMap { $0.isEmpty ? nil : $0 } ?? String(device.uuidString.prefix(4))
        let base = streamBase ?? "ble.\(short).\(ExternalStreamInfo.slug(reading.decoder))"
        let variant = lock.withLock {
            registry.resolve(base: base, fields: reading.fields.map(\.name))
        }
        let info = ExternalStreamInfo(
            id: variant.id, source: .bluetooth,
            title: title ?? "\(label) · \(reading.decoder)",
            channels: variant.fields,
            channelUnits: variant.fields.map { unit?($0) ?? BLEUnits.unit(for: $0, decoder: reading.decoder) })
        var named: [String: Double] = [:]
        for field in reading.fields { named[field.name] = field.value }
        sink.ingestExternal(info, time: now,
                            values: ExternalStreamRegistry.values(named, in: variant))

        // Every heartbeat of the packet as its own sample at its own time: the interval
        // between beats is the whole point of a heart rate strap, and one value per
        // notification throws half of them away.
        guard !reading.beats.isEmpty else { return }
        let beatInfo = ExternalStreamInfo(
            id: "ble.\(short).rr", source: .bluetooth, title: "\(label) · RR",
            channels: ["rr"], channelUnits: ["s"])
        for beat in HeartBeats.times(receivedAt: now, beats: reading.beats) {
            let isNew = lock.withLock { () -> Bool in
                guard beat.time > (lastBeat[device] ?? -.infinity) else { return false }
                lastBeat[device] = beat.time
                return true
            }
            if isNew { sink.ingestExternal(beatInfo, time: beat.time, values: [beat.interval]) }
        }
    }

    // MARK: - GATT connections

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let (isSensor, isExplorer, services) = lock.withLock {
            (peripherals[peripheral.identifier] != nil,
             explorerPeripheral?.identifier == peripheral.identifier,
             subscriptions.filter { $0.device == peripheral.identifier }.map(\.service))
        }
        if isExplorer {
            // Everything: the explorer lists what the device has, not what this app knows.
            onExplorerEvent?(.connected)
            peripheral.discoverServices(nil)
            peripheral.readRSSI()
        } else if isSensor {
            let wanted = BLEDecoders.Profile.allCases.map(\.rawValue) + services
            peripheral.discoverServices(Array(Set(wanted.map { BluetoothNames.shortForm($0) }))
                .map { CBUUID(string: $0) })
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        let wasExplorer = lock.withLock { () -> Bool in
            _ = peripherals.removeValue(forKey: peripheral.identifier)
            return explorerPeripheral?.identifier == peripheral.identifier
        }
        if wasExplorer {
            lock.withLock { explorerPeripheral = nil }
            onExplorerEvent?(.failed(error?.localizedDescription ?? "—"))
        }
    }

    /// A strap that drops out mid-ride comes back by itself: `connect` has no timeout and
    /// completes whenever the device is in range again.
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        let wasExplorer = lock.withLock { () -> Bool in
            pollTargets = pollTargets.filter { $0.value.peripheral.identifier != peripheral.identifier }
            guard explorerPeripheral?.identifier == peripheral.identifier else { return false }
            explorerPeripheral = nil
            explorerCharacteristics = [:]
            explorerInfo = []
            return true
        }
        if wasExplorer { onExplorerEvent?(.disconnected(error?.localizedDescription)) }
        guard wantScanning, wantsConnection(peripheral.identifier) else {
            _ = lock.withLock { peripherals.removeValue(forKey: peripheral.identifier) }
            return
        }
        central.connect(peripheral)
    }

    private var wantScanning: Bool { wantsScan }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let (isExplorer, mine) = lock.withLock {
            (explorerPeripheral?.identifier == peripheral.identifier,
             subscriptions.filter { $0.device == peripheral.identifier })
        }
        for service in peripheral.services ?? [] {
            if isExplorer {
                peripheral.discoverCharacteristics(nil, for: service)
                continue
            }
            let key = BluetoothNames.shortForm(service.uuid.uuidString)
            if let profile = BLEDecoders.Profile(rawValue: key) {
                peripheral.discoverCharacteristics([CBUUID(string: profile.measurement)], for: service)
            } else {
                let chosen = mine.filter { BluetoothNames.shortForm($0.service) == key }
                    .map { CBUUID(string: BluetoothNames.shortForm($0.characteristic)) }
                if !chosen.isEmpty { peripheral.discoverCharacteristics(chosen, for: service) }
            }
        }
        if isExplorer { publishExplorer(peripheral) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        let serviceKey = BluetoothNames.shortForm(service.uuid.uuidString)
        let (isExplorer, mine) = lock.withLock {
            (explorerPeripheral?.identifier == peripheral.identifier,
             subscriptions.filter { $0.device == peripheral.identifier
                && BluetoothNames.shortForm($0.service) == serviceKey })
        }
        for characteristic in service.characteristics ?? [] {
            let key = BluetoothNames.shortForm(characteristic.uuid.uuidString)
            // Only what this app wants: with the explorer open every characteristic of the
            // service is discovered, and switching on notifications for all of them would
            // subscribe to control points that cannot notify.
            if let profile = BLEDecoders.Profile(rawValue: serviceKey),
               BluetoothNames.shortForm(profile.measurement) == key {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            if let subscription = mine.first(where: { BluetoothNames.shortForm($0.characteristic) == key }) {
                activate(subscription, characteristic: characteristic, on: peripheral)
            }
            if isExplorer {
                peripheral.discoverDescriptors(for: characteristic)
                if characteristic.properties.contains(.read), Self.autoRead.contains(key) {
                    peripheral.readValue(for: characteristic)
                }
            }
        }
        if isExplorer { publishExplorer(peripheral) }
    }

    /// Strings every device carries and a battery level — harmless to read, and what makes a
    /// list of anonymous services recognisable. Everything else is read on request: a read
    /// of an encrypted characteristic opens the system pairing dialog.
    private static let autoRead: Set<String> = ["2A00", "2A19", "2A24", "2A25", "2A26", "2A27", "2A28", "2A29"]

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard lock.withLock({ explorerPeripheral?.identifier == peripheral.identifier }) else { return }
        for descriptor in characteristic.descriptors ?? [] {
            let key = descriptor.uuid.uuidString
            if key == "2901" || key == "2904" { peripheral.readValue(for: descriptor) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        guard lock.withLock({ explorerPeripheral?.identifier == peripheral.identifier }) else { return }
        publishExplorer(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil, let data = characteristic.value else {
            if lock.withLock({ explorerPeripheral?.identifier == peripheral.identifier }) {
                publishExplorer(peripheral)
            }
            return
        }
        let serviceKey = characteristic.service.map { BluetoothNames.shortForm($0.uuid.uuidString) } ?? ""
        let characteristicKey = BluetoothNames.shortForm(characteristic.uuid.uuidString)

        if let profile = BLEDecoders.Profile(rawValue: serviceKey),
           BluetoothNames.shortForm(profile.measurement) == characteristicKey,
           var reading = BLEDecoders.decode(profile, data) {
            if profile == .cyclingSpeedCadence {
                reading = lock.withLock {
                    var tracker = cadence[peripheral.identifier] ?? CSCTracker()
                    defer { cadence[peripheral.identifier] = tracker }
                    return tracker.update(reading)
                }
            }
            record(reading, from: peripheral.identifier, name: peripheral.name)
        }

        let subscription = lock.withLock {
            subscriptions.first { $0.device == peripheral.identifier
                && BluetoothNames.shortForm($0.service) == serviceKey
                && BluetoothNames.shortForm($0.characteristic) == characteristicKey }
        }
        if let subscription, let reading = subscription.decode(data) {
            record(reading, from: peripheral.identifier, name: subscription.deviceName,
                   streamBase: subscription.streamBase,
                   title: "\(subscription.deviceName) · \(subscription.characteristicName)",
                   unit: { subscription.unit(forField: $0, decoder: reading.decoder) })
        }

        if lock.withLock({ explorerPeripheral?.identifier == peripheral.identifier }) {
            noteExplorerValue(of: characteristic)
            publishExplorer(peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if lock.withLock({ explorerPeripheral?.identifier == peripheral.identifier }) {
            publishExplorer(peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let id = explorerID(of: characteristic) else { return }
        onExplorerEvent?(.written(characteristic: id, error: error?.localizedDescription))
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil, lock.withLock({ explorerPeripheral?.identifier == peripheral.identifier }) else { return }
        onExplorerEvent?(.rssi(RSSI.doubleValue))
    }

    // MARK: - Chosen characteristics

    /// Subscribes to a characteristic the user chose to record: notifications where the device
    /// sends them, a read on a timer where it only answers when asked.
    private func activate(_ subscription: GATTSubscription, characteristic: CBCharacteristic,
                          on peripheral: CBPeripheral) {
        let notifies = characteristic.properties.contains(.notify)
            || characteristic.properties.contains(.indicate)
        if subscription.pollSeconds == nil, notifies {
            peripheral.setNotifyValue(true, for: characteristic)
            if characteristic.properties.contains(.read) { peripheral.readValue(for: characteristic) }
        } else if characteristic.properties.contains(.read) {
            let interval = max(subscription.pollSeconds ?? 5, 1)
            lock.withLock {
                pollTargets[subscription.id] = PollTarget(peripheral: peripheral, characteristic: characteristic,
                                                          interval: interval, lastRead: HostClock.now)
            }
            peripheral.readValue(for: characteristic)
            startPollTimer()
        }
    }

    private func startPollTimer() {
        guard pollTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.pollDueCharacteristics() }
        timer.resume()
        pollTimer = timer
    }

    private func pollDueCharacteristics() {
        let now = HostClock.now
        let due = lock.withLock { () -> [PollTarget] in
            var due: [PollTarget] = []
            for (key, target) in pollTargets where now - target.lastRead >= target.interval {
                pollTargets[key]?.lastRead = now
                due.append(target)
            }
            return due
        }
        for target in due where target.peripheral.state == .connected {
            target.peripheral.readValue(for: target.characteristic)
        }
    }

    // MARK: - Explorer

    /// Connects to one device and lists what it offers. The central has to be running — the
    /// explorer screen holds the scan for as long as it is open.
    func explorerConnect(_ id: UUID) {
        queue.async { [self] in
            guard let central, central.state == .poweredOn else {
                onExplorerEvent?(.failed("Bluetooth"))
                return
            }
            guard let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first else {
                onExplorerEvent?(.failed("—"))
                return
            }
            lock.withLock {
                explorerPeripheral = peripheral
                explorerCharacteristics = [:]
                explorerInfo = []
            }
            peripheral.delegate = self
            if peripheral.state == .connected {
                onExplorerEvent?(.connected)
                peripheral.discoverServices(nil)
                peripheral.readRSSI()
            } else {
                central.connect(peripheral)
            }
        }
    }

    func explorerDisconnect() {
        queue.async { [self] in
            let peripheral = lock.withLock { () -> CBPeripheral? in
                defer {
                    explorerPeripheral = nil
                    explorerCharacteristics = [:]
                    explorerInfo = []
                }
                return explorerPeripheral
            }
            // A connection that a paired sensor or a chosen characteristic still needs stays.
            if let peripheral, !wantsConnection(peripheral.identifier) {
                central?.cancelPeripheralConnection(peripheral)
            }
            teardownIfIdle()
        }
    }

    func explorerRead(_ id: String) {
        queue.async { [self] in
            guard let (peripheral, characteristic) = explorerTarget(id),
                  characteristic.properties.contains(.read) else { return }
            peripheral.readValue(for: characteristic)
        }
    }

    func explorerWrite(_ id: String, data: Data, withResponse: Bool) {
        queue.async { [self] in
            guard let (peripheral, characteristic) = explorerTarget(id) else { return }
            peripheral.writeValue(data, for: characteristic, type: withResponse ? .withResponse : .withoutResponse)
            // Without a response there is no callback to wait for.
            if !withResponse { onExplorerEvent?(.written(characteristic: id, error: nil)) }
        }
    }

    func explorerSetNotify(_ id: String, on: Bool) {
        queue.async { [self] in
            guard let (peripheral, characteristic) = explorerTarget(id) else { return }
            peripheral.setNotifyValue(on, for: characteristic)
        }
    }

    func explorerReadRSSI() {
        queue.async { [self] in
            lock.withLock { explorerPeripheral }?.readRSSI()
        }
    }

    /// The largest value a write can carry without a response, for the write sheet.
    func explorerMaximumWriteLength(withResponse: Bool) -> Int? {
        lock.withLock { explorerPeripheral }?
            .maximumWriteValueLength(for: withResponse ? .withResponse : .withoutResponse)
    }

    private func explorerTarget(_ id: String) -> (CBPeripheral, CBCharacteristic)? {
        lock.withLock {
            guard let peripheral = explorerPeripheral, let characteristic = explorerCharacteristics[id] else {
                return nil
            }
            return (peripheral, characteristic)
        }
    }

    private func explorerID(of characteristic: CBCharacteristic) -> String? {
        lock.withLock { explorerCharacteristics.first { $0.value === characteristic }?.key }
    }

    private func noteExplorerValue(of characteristic: CBCharacteristic) {
        guard let id = explorerID(of: characteristic) else { return }
        lock.withLock { explorerValueTimes[id] = HostClock.now }
    }

    /// Rebuilds the list of services from what CoreBluetooth currently knows, keeping what was
    /// learned earlier, and hands it to the screen.
    private func publishExplorer(_ peripheral: CBPeripheral) {
        let snapshot = lock.withLock { () -> [GATTServiceInfo] in
            var previous: [String: GATTCharacteristicInfo] = [:]
            for service in explorerInfo {
                for info in service.characteristics { previous[info.id] = info }
            }
            var characteristics: [String: CBCharacteristic] = [:]
            var result: [GATTServiceInfo] = []
            for service in peripheral.services ?? [] {
                var infos: [GATTCharacteristicInfo] = []
                for (index, characteristic) in (service.characteristics ?? []).enumerated() {
                    let id = "\(service.uuid.uuidString)/\(characteristic.uuid.uuidString)#\(index)"
                    var info = previous[id] ?? GATTCharacteristicInfo(
                        id: id, serviceUUID: service.uuid.uuidString, uuid: characteristic.uuid.uuidString,
                        properties: GATTCharacteristicInfo.properties(of: characteristic.properties))
                    info.isNotifying = characteristic.isNotifying
                    if let value = characteristic.value {
                        info.value = value
                        info.valueTime = explorerValueTimes[id]
                    }
                    for descriptor in characteristic.descriptors ?? [] {
                        if descriptor.uuid.uuidString == "2901", let text = descriptor.value as? String {
                            info.userDescription = text
                        }
                        if descriptor.uuid.uuidString == "2904", let data = descriptor.value as? Data {
                            info.presentation = PresentationFormat(data)
                        }
                    }
                    characteristics[id] = characteristic
                    infos.append(info)
                }
                result.append(GATTServiceInfo(uuid: service.uuid.uuidString,
                                              isPrimary: service.isPrimary, characteristics: infos))
            }
            explorerCharacteristics = characteristics
            explorerInfo = result
            return result
        }
        onExplorerEvent?(.services(snapshot))
    }
}
