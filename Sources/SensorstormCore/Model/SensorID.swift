import Foundation

/// Stable identifier of a recorded stream. The raw value is the on-disk file name, so
/// these strings must never change once a build has shipped.
public enum SensorID: String, CaseIterable, Sendable, Codable, Hashable {
    // Raw IMU — straight from the hardware, no filtering.
    case accelerometer
    case gyroscope
    case magnetometer

    // Sensor-fused (CMDeviceMotion).
    case userAcceleration
    case gravity
    case rotationRate
    case orientation
    case magneticField

    // Position & environment.
    case compass
    case barometer
    case location

    // Audio.
    case loudness

    // Activity.
    case pedometer

    // Device state.
    case battery
    case brightness
    case network

    // Accessories.
    case headphoneOrientation
}

public enum SensorCategory: String, CaseIterable, Sendable, Codable, Hashable {
    case motion
    case position
    case environment
    case audio
    case activity
    case device
}

/// Everything the app needs to know about a stream without touching the sensor itself:
/// how many columns it has, what they are called, what unit they are in.
public struct SensorDescriptor: Sendable, Hashable, Identifiable {
    public let id: SensorID
    public let category: SensorCategory
    /// Unit of the primary channels, for display. Channels with a deviating unit are
    /// documented in ``channelUnits``.
    public let unit: String
    public let channels: [String]
    public let channelUnits: [String]
    /// Whether the stream is armed by default on a fresh install.
    public let defaultEnabled: Bool
    /// `true` for streams that only emit on change rather than at the configured rate.
    public let isEventDriven: Bool

    public var channelCount: Int { channels.count }

    public func unit(forChannel index: Int) -> String {
        guard channelUnits.indices.contains(index) else { return unit }
        return channelUnits[index]
    }
}

public extension SensorID {
    var descriptor: SensorDescriptor { SensorCatalog.descriptor(for: self) }
}

public enum SensorCatalog {
    public static let all: [SensorDescriptor] = SensorID.allCases.map(descriptor(for:))

    public static func descriptors(in category: SensorCategory) -> [SensorDescriptor] {
        all.filter { $0.category == category }
    }

    public static func descriptor(for id: SensorID) -> SensorDescriptor {
        switch id {
        case .accelerometer:
            return .init(id: id, category: .motion, unit: "g",
                         channels: ["x", "y", "z"], channelUnits: ["g", "g", "g"],
                         defaultEnabled: true, isEventDriven: false)
        case .gyroscope:
            return .init(id: id, category: .motion, unit: "rad/s",
                         channels: ["x", "y", "z"], channelUnits: ["rad/s", "rad/s", "rad/s"],
                         defaultEnabled: true, isEventDriven: false)
        case .magnetometer:
            return .init(id: id, category: .motion, unit: "µT",
                         channels: ["x", "y", "z"], channelUnits: ["µT", "µT", "µT"],
                         defaultEnabled: false, isEventDriven: false)
        case .userAcceleration:
            return .init(id: id, category: .motion, unit: "g",
                         channels: ["x", "y", "z"], channelUnits: ["g", "g", "g"],
                         defaultEnabled: true, isEventDriven: false)
        case .gravity:
            return .init(id: id, category: .motion, unit: "g",
                         channels: ["x", "y", "z"], channelUnits: ["g", "g", "g"],
                         defaultEnabled: true, isEventDriven: false)
        case .rotationRate:
            return .init(id: id, category: .motion, unit: "rad/s",
                         channels: ["x", "y", "z"], channelUnits: ["rad/s", "rad/s", "rad/s"],
                         defaultEnabled: true, isEventDriven: false)
        case .orientation:
            return .init(id: id, category: .motion, unit: "°",
                         channels: ["roll", "pitch", "yaw", "qx", "qy", "qz", "qw"],
                         channelUnits: ["°", "°", "°", "", "", "", ""],
                         defaultEnabled: true, isEventDriven: false)
        case .magneticField:
            return .init(id: id, category: .motion, unit: "µT",
                         channels: ["x", "y", "z", "accuracy"],
                         channelUnits: ["µT", "µT", "µT", ""],
                         defaultEnabled: true, isEventDriven: false)
        case .compass:
            return .init(id: id, category: .position, unit: "°",
                         channels: ["true", "magnetic", "accuracy"],
                         channelUnits: ["°", "°", "°"],
                         defaultEnabled: true, isEventDriven: true)
        case .barometer:
            return .init(id: id, category: .environment, unit: "kPa",
                         channels: ["pressure", "relativeAltitude"],
                         channelUnits: ["kPa", "m"],
                         defaultEnabled: true, isEventDriven: true)
        case .location:
            return .init(id: id, category: .position, unit: "°",
                         channels: ["latitude", "longitude", "altitude", "ellipsoidalAltitude",
                                    "speed", "speedAccuracy", "course", "courseAccuracy",
                                    "horizontalAccuracy", "verticalAccuracy"],
                         channelUnits: ["°", "°", "m", "m", "m/s", "m/s", "°", "°", "m", "m"],
                         defaultEnabled: true, isEventDriven: true)
        case .loudness:
            return .init(id: id, category: .audio, unit: "dBFS",
                         channels: ["average", "peak"], channelUnits: ["dBFS", "dBFS"],
                         defaultEnabled: true, isEventDriven: false)
        case .pedometer:
            return .init(id: id, category: .activity, unit: "",
                         channels: ["steps", "distance", "cadence", "pace",
                                    "floorsAscended", "floorsDescended"],
                         channelUnits: ["", "m", "steps/s", "s/m", "", ""],
                         defaultEnabled: true, isEventDriven: true)
        case .battery:
            return .init(id: id, category: .device, unit: "%",
                         channels: ["level", "state"], channelUnits: ["%", ""],
                         defaultEnabled: true, isEventDriven: true)
        case .brightness:
            return .init(id: id, category: .device, unit: "%",
                         channels: ["level"], channelUnits: ["%"],
                         defaultEnabled: true, isEventDriven: true)
        case .network:
            return .init(id: id, category: .device, unit: "",
                         channels: ["type", "expensive", "constrained"],
                         channelUnits: ["", "", ""],
                         defaultEnabled: true, isEventDriven: true)
        case .headphoneOrientation:
            return .init(id: id, category: .motion, unit: "°",
                         channels: ["roll", "pitch", "yaw", "ax", "ay", "az"],
                         channelUnits: ["°", "°", "°", "g", "g", "g"],
                         defaultEnabled: false, isEventDriven: false)
        }
    }
}
