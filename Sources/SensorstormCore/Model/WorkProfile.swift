import Foundation

/// What a person has come to the app to do, as a starting configuration.
///
/// Sensorstorm has twenty-five streams and a screen for each. Nobody inspecting a road wants to
/// know that; they want the sensors a road inspection needs, armed, at a rate that suits it, with
/// the catalog for road damage already chosen. A profile is that and nothing more: it sets the
/// same switches the settings screen sets, and every one of them can be changed afterwards.
public enum WorkProfile: String, CaseIterable, Codable, Sendable, Identifiable {
    case general
    case roads
    case building
    case elevator
    case transit
    case construction
    case network
    case sound
    case research

    public var id: String { rawValue }

    /// The streams to arm. A profile arms exactly these: the person changing profile gets
    /// the new set, not the old one plus the new.
    public var sensors: Set<SensorID> {
        switch self {
        case .general:
            Set(SensorCatalog.all.filter(\.defaultEnabled).map(\.id))
        case .roads:
            [.userAcceleration, .verticalAcceleration, .gravity, .gyroscope, .location, .barometer, .thermal]
        case .building:
            [.location, .compass, .barometer, .orientation, .gravity, .thermal]
        case .elevator:
            [.userAcceleration, .verticalAcceleration, .gravity, .barometer, .gyroscope]
        case .transit:
            [.userAcceleration, .verticalAcceleration, .gravity, .rotationRate, .location, .barometer, .thermal]
        case .construction:
            [.userAcceleration, .accelerometer, .gyroscope, .location, .loudness, .loudnessA, .barometer]
        case .network:
            [.location, .network, .bluetooth, .barometer, .compass, .thermal]
        case .sound:
            [.loudness, .loudnessA, .location, .thermal]
        case .research:
            [.accelerometer, .gyroscope, .magnetometer, .userAcceleration, .gravity, .rotationRate, .orientation,
             .location, .barometer, .loudness, .pedometer, .activity, .battery, .thermal]
        }
    }

    /// One of ``availableRates``: motion sensors are sampled at a rate the hardware offers, and a
    /// profile asks for the one that does its job.
    public var motionRateHz: Double {
        switch self {
        case .general, .building, .network, .sound: 100
        case .roads, .elevator, .transit, .research: 100
        case .construction: 200
        }
    }

    /// The catalog whose entries a walk with this profile offers, if any.
    public var catalogID: String? {
        switch self {
        case .roads: FindingCatalog.road.id
        case .building: FindingCatalog.building.id
        case .general, .elevator, .transit, .construction, .network, .sound, .research: nil
        }
    }

    /// Ping the router and the internet during the recording.
    public var recordsNetworkQuality: Bool { self == .network }

    /// Blur faces and plates in exports: on for the profiles that photograph streets.
    public var anonymisesPhotos: Bool { self == .roads || self == .building }

    /// Which analysis the recording screen should lead with.
    public var suggestedAnalysis: String? {
        switch self {
        case .roads: "road"
        case .elevator: "elevator"
        case .transit: "comfort"
        case .construction: "vibration"
        case .network: "map"
        case .general, .building, .sound, .research: nil
        }
    }
}
