import Foundation

/// What „Sensorstorm Pro" unlocks.
///
/// Deliberately free of `StoreKit`. *What* is gated is product policy — a decision that
/// wants tests and a diff when it changes. *Whether this device has paid* is a fact only
/// the App Store can state, and only the app target can ask it. `App/Store/ProEntitlement`
/// answers the second question and hands the answer in here as a ``ProAccess``.
public enum ProFeature: String, Sendable, Hashable, CaseIterable, Identifiable {
    /// Motion sampling above ``ProAccess/freeMaximumRateHz``.
    case highRate
    /// 4K video. 720p and 1080p stay free.
    case video4K
    /// The ARKit capture engine — per-frame camera pose and intrinsics.
    case arkitPose
    /// Exporting a recording as its raw `.ssbin` folder.
    case rawExport
    /// Exporting a recording as a 3D scene bundle for Blender.
    case sceneExport
    /// The Sensor Logger and Gyroflow interop exports.
    case interopExport
    /// Every sensor in one table: combined CSV, JSON, SQLite.
    case tableExport
    /// Starting a walk beyond ``ProAccess/freeSurveyAllowance``.
    case additionalSurveys
    /// Exporting a walk as GeoJSON, GPX, KML or a media bundle.
    case surveyGeoExport
    /// The device-wide archive with its manifest.
    case archiveExport

    /// So one sheet at the root can be driven by „which lock was tapped".
    public var id: String { rawValue }
}

/// Whether this device may use a given feature.
///
/// A value, not a singleton: the gating rules are then testable without StoreKit, and a
/// SwiftUI preview can show both states by passing a different one.
public struct ProAccess: Sendable, Hashable {

    // MARK: - Policy

    /// How many walks can be started without Pro.
    ///
    /// One, not zero, on purpose. A field tool cannot be judged from a settings screen —
    /// the walk someone actually records is both the honest trial and the reason to buy.
    public static let freeSurveyAllowance = 1

    /// The highest motion rate available without Pro. Covers every sensor's own native
    /// cadence; above it is the regime that only exists for vibration work.
    public static let freeMaximumRateHz: Double = 200

    /// The one export that is never gated, in either direction.
    ///
    /// A measurement tool that can lock someone out of their own measurements has no
    /// business calling itself one. What Pro sells is the professional formats — the ones
    /// that drop straight into QGIS, Blender or Gyroflow — never access to your own data.
    /// Refunding Pro therefore re-locks the formats but never strands a recording.
    public static let freeRecordingFormats: Set<RecordingExporter.Format> = [.csvBundle]
    public static let freeSurveyFormats: Set<SurveyExporter.Format> = [.csv]

    // MARK: - State

    public let isPro: Bool

    public init(isPro: Bool) {
        self.isPro = isPro
    }

    public static let free = ProAccess(isPro: false)
    public static let pro = ProAccess(isPro: true)

    // MARK: - Questions the UI asks

    public func allows(_ feature: ProFeature) -> Bool { isPro }

    public func allowsStartingSurvey(existingCount: Int) -> Bool {
        isPro || existingCount < Self.freeSurveyAllowance
    }

    public func allowsRate(_ hz: Double) -> Bool {
        isPro || hz <= Self.freeMaximumRateHz
    }

    // A `nil` ``ProFeature`` means the thing is free, so each of these is the same two
    // lines. Spelled out rather than folded into an `allows(_: ProFeature?)` overload: that
    // overload sits next to `allows(_: ProFeature)` and makes `allows(.arkitPose)` a
    // question for the type checker rather than for the reader.

    public func allows(recordingFormat: RecordingExporter.Format) -> Bool {
        guard let feature = recordingFormat.proFeature else { return true }
        return allows(feature)
    }

    public func allows(surveyFormat: SurveyExporter.Format) -> Bool {
        guard let feature = surveyFormat.proFeature else { return true }
        return allows(feature)
    }

    public func allows(captureEngine: CaptureEngine) -> Bool {
        guard let feature = captureEngine.proFeature else { return true }
        return allows(feature)
    }
}

// MARK: - One table per gated enum

// The mapping lives next to the policy rather than in the views, so „is this free?" has a
// single answer that a test can read. `nil` means free.

extension RecordingExporter.Format {
    public var proFeature: ProFeature? {
        switch self {
        case .csvBundle: nil
        case .rawBundle: .rawExport
        case .sceneBundle: .sceneExport
        case .sensorLoggerBundle, .gyroflowLog: .interopExport
        case .combinedCSV, .json, .sqlite: .tableExport
        }
    }
}

extension SurveyExporter.Format {
    public var proFeature: ProFeature? {
        switch self {
        case .csv: nil
        case .geoJSON, .gpx, .kml, .bundle: .surveyGeoExport
        }
    }
}

extension CaptureEngine {
    public var proFeature: ProFeature? {
        switch self {
        case .classic: nil
        case .arkit: .arkitPose
        }
    }
}
