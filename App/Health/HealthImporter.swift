import Foundation
import HealthKit
import SensorstormCore

/// What the Health app knows about the hour of a recording: heart rate, its variability,
/// breathing, blood oxygen, steps, and — from a watch — the running metrics.
///
/// Imported afterwards, never during: a watch writes its samples to Health in batches, minutes
/// after they were taken, so asking at the moment the recording stops would get an empty
/// answer for a walk that has a perfectly good pulse. The person asks when they are looking
/// at the recording, and the samples for that window become streams of the recording.
///
/// Read access only. Sensorstorm writes nothing into Health, and the entitlement says so.
@MainActor
final class HealthImporter {
    enum Metric: String, CaseIterable, Sendable {
        case heartRate, heartRateVariability, respiratoryRate, oxygenSaturation, steps
        case runningPower, runningStride, runningOscillation, runningContact

        var identifier: HKQuantityTypeIdentifier {
            switch self {
            case .heartRate: .heartRate
            case .heartRateVariability: .heartRateVariabilitySDNN
            case .respiratoryRate: .respiratoryRate
            case .oxygenSaturation: .oxygenSaturation
            case .steps: .stepCount
            case .runningPower: .runningPower
            case .runningStride: .runningStrideLength
            case .runningOscillation: .runningVerticalOscillation
            case .runningContact: .runningGroundContactTime
            }
        }

        var unit: HKUnit {
            switch self {
            case .heartRate, .respiratoryRate: HKUnit.count().unitDivided(by: .minute())
            case .heartRateVariability, .runningContact: HKUnit.secondUnit(with: .milli)
            case .oxygenSaturation: HKUnit.percent()
            case .steps: HKUnit.count()
            case .runningPower: HKUnit.watt()
            case .runningStride: HKUnit.meter()
            case .runningOscillation: HKUnit.meterUnit(with: .centi)
            }
        }

        /// The unit as the recording's exports print it.
        var unitSymbol: String {
            switch self {
            case .heartRate: "1/min"
            case .respiratoryRate: "1/min"
            case .heartRateVariability, .runningContact: "ms"
            case .oxygenSaturation: "%"
            case .steps: ""
            case .runningPower: "W"
            case .runningStride: "m"
            case .runningOscillation: "cm"
            }
        }

        /// `HKUnit.percent()` is a fraction, 0…1; the recording says 98, not 0.98.
        var scale: Double { self == .oxygenSaturation ? 100 : 1 }

        var title: String {
            switch self {
            case .heartRate: String(localized: "Herzfrequenz (Health)")
            case .heartRateVariability: String(localized: "Herzfrequenzvariabilität (Health)")
            case .respiratoryRate: String(localized: "Atemfrequenz (Health)")
            case .oxygenSaturation: String(localized: "Sauerstoffsättigung (Health)")
            case .steps: String(localized: "Schritte (Health)")
            case .runningPower: String(localized: "Laufleistung (Health)")
            case .runningStride: String(localized: "Schrittlänge beim Laufen (Health)")
            case .runningOscillation: String(localized: "Vertikale Oszillation (Health)")
            case .runningContact: String(localized: "Bodenkontaktzeit (Health)")
            }
        }

        var streamID: String { "health.\(rawValue)" }
    }

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private let store = HKHealthStore()

    /// Asks for read access to everything it may import. iOS shows the sheet once; after that
    /// the call returns at once, and whether a type was allowed is not something an app is
    /// told — a refusal looks exactly like a window without samples.
    func requestAccess() async throws {
        let types = Set(Metric.allCases.map { HKQuantityType($0.identifier) })
        try await store.requestAuthorization(toShare: [], read: types)
    }

    /// The samples of the recording's window, one stream per metric that has any.
    func streams(for metadata: RecordingMetadata) async throws -> [ExtraStream] {
        let start = metadata.startedAt
        let end = start.addingTimeInterval(max(metadata.duration, 1))
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
        var streams: [ExtraStream] = []

        for metric in Metric.allCases {
            let descriptor = HKSampleQueryDescriptor(
                predicates: [.quantitySample(type: HKQuantityType(metric.identifier), predicate: predicate)],
                sortDescriptors: [SortDescriptor(\.startDate)])
            let samples = try await descriptor.result(for: store)
            guard !samples.isEmpty else { continue }

            let rows: [(time: Double, values: [Double])] = samples.map { sample in
                (RecordingExtender.hostTime(for: sample.startDate, in: metadata),
                 [sample.quantity.doubleValue(for: metric.unit) * metric.scale])
            }
            let info = ExternalStreamInfo(id: metric.streamID, source: .health, title: metric.title,
                                          channels: ["value"], channelUnits: [metric.unitSymbol])
            streams.append(ExtraStream(info: info, samples: rows))
        }
        return streams
    }
}
