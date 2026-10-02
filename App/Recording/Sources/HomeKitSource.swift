import Foundation
import HomeKit
import SensorstormCore

/// The sensors of the person's own home — thermometers, hygrometers, CO₂ and light sensors,
/// door contacts, motion detectors — as streams of the recording.
///
/// A building-physics survey wants the room's temperature and humidity next to the vibration
/// and the noise, and the house already has a sensor for it. HomeKit is the one door through
/// which iOS lets an app read those, and Matter devices arrive through it too.
///
/// The home manager is created only when this is switched on, because creating it is what
/// asks for permission.
final class HomeKitSource: NSObject, HMHomeManagerDelegate, HMAccessoryDelegate, @unchecked Sendable {
    private struct Kind {
        var label: String
        var key: String
        var unit: String
    }

    /// The characteristic types worth recording, by their HomeKit type string.
    private static var kinds: [String: Kind] {
        [
            HMCharacteristicTypeCurrentTemperature: Kind(label: String(localized: "Temperatur"), key: "temperature", unit: "°C"),
            HMCharacteristicTypeCurrentRelativeHumidity: Kind(label: String(localized: "Feuchte"), key: "humidity", unit: "%"),
            HMCharacteristicTypeCarbonDioxideLevel: Kind(label: "CO₂", key: "co2", unit: "ppm"),
            HMCharacteristicTypeCurrentLightLevel: Kind(label: String(localized: "Licht"), key: "light", unit: "lx"),
            HMCharacteristicTypeAirQuality: Kind(label: String(localized: "Luftqualität"), key: "airquality", unit: ""),
            HMCharacteristicTypeContactState: Kind(label: String(localized: "Kontakt"), key: "contact", unit: ""),
            HMCharacteristicTypeMotionDetected: Kind(label: String(localized: "Bewegung"), key: "motion", unit: "")
        ]
    }

    private let sink: SampleSink
    private let lock = NSLock()
    private var manager: HMHomeManager?
    private var running = false
    private var tracked: [HMAccessory] = []
    private var pollTimer: Timer?

    init(sink: SampleSink) {
        self.sink = sink
    }

    @MainActor
    func start() {
        let alreadyRunning = lock.withLock { () -> Bool in
            let was = running
            running = true
            return was
        }
        guard !alreadyRunning else { return }
        let manager = HMHomeManager()
        manager.delegate = self
        lock.withLock { self.manager = manager }
        // Homes load asynchronously; `homeManagerDidUpdateHomes` follows.
    }

    @MainActor
    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        let accessories = lock.withLock { () -> [HMAccessory] in
            let current = tracked
            tracked = []
            running = false
            manager = nil
            return current
        }
        for accessory in accessories {
            accessory.delegate = nil
            for service in accessory.services {
                for characteristic in service.characteristics where Self.kinds[characteristic.characteristicType] != nil {
                    characteristic.enableNotification(false) { _ in }
                }
            }
        }
    }

    // MARK: - HMHomeManagerDelegate

    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        var accessories: [HMAccessory] = []
        for home in manager.homes { accessories.append(contentsOf: home.accessories) }
        for accessory in accessories {
            accessory.delegate = self
            for service in accessory.services {
                for characteristic in service.characteristics where Self.kinds[characteristic.characteristicType] != nil {
                    characteristic.enableNotification(true) { _ in }
                    characteristic.readValue { _ in }
                    report(characteristic, of: accessory)
                }
            }
        }
        lock.withLock { tracked = accessories }
    }

    // MARK: - HMAccessoryDelegate

    nonisolated func accessory(_ accessory: HMAccessory, service: HMService,
                               didUpdateValueFor characteristic: HMCharacteristic) {
        report(characteristic, of: accessory)
    }

    private func report(_ characteristic: HMCharacteristic, of accessory: HMAccessory) {
        guard let kind = Self.kinds[characteristic.characteristicType],
              let number = characteristic.value as? NSNumber else { return }
        let short = String(accessory.uniqueIdentifier.uuidString.prefix(8)).lowercased()
        let room = accessory.room?.name
        let title = [accessory.name, room, kind.label].compactMap { $0 }.joined(separator: " · ")
        let info = ExternalStreamInfo(id: "home.\(short).\(kind.key)", source: .homeKit, title: title,
                                      channels: [kind.key], channelUnits: [kind.unit])
        sink.ingestExternal(info, time: HostClock.now, values: [number.doubleValue])
    }
}
