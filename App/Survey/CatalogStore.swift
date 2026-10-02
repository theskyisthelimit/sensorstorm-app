import CoreMotion
import Foundation
import Observation
import SensorstormCore
import UIKit

/// The catalogs a walk can use: the four that ship with the app and any the person loaded.
///
/// Loaded ones live as JSON files in `Documents/Catalogs/`, next to the surveys, so they are
/// visible in the Files app and can be edited there with a text editor — a depot's
/// vocabulary is a file it already has, not something to retype into a phone.
@MainActor @Observable
final class CatalogStore {
    private(set) var custom: [FindingCatalog] = []
    private let directory: URL

    init(directory: URL? = nil) {
        let base = directory ?? (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                              appropriateFor: nil, create: true))?
            .appendingPathComponent("Catalogs", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Catalogs", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        reload()
    }

    var all: [FindingCatalog] { FindingCatalog.builtIn + custom }

    func catalog(_ id: String?) -> FindingCatalog? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    func isBuiltIn(_ catalog: FindingCatalog) -> Bool {
        FindingCatalog.builtIn.contains { $0.id == catalog.id }
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        custom = files.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? FindingCatalog.decode(Data(contentsOf: $0)) }
            .filter { loaded in !FindingCatalog.builtIn.contains { $0.id == loaded.id } }
    }

    /// Reads, checks and keeps a catalog file chosen in Files.
    @discardableResult
    func importCatalog(from url: URL) throws -> FindingCatalog {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let catalog = try FindingCatalog.decode(data)
        guard !FindingCatalog.builtIn.contains(where: { $0.id == catalog.id }) else {
            throw FindingCatalog.CatalogError.duplicateKey(catalog.id)
        }
        try data.write(to: file(for: catalog), options: .atomic)
        reload()
        return catalog
    }

    func remove(_ catalog: FindingCatalog) {
        guard !isBuiltIn(catalog) else { return }
        try? FileManager.default.removeItem(at: file(for: catalog))
        reload()
    }

    private func file(for catalog: FindingCatalog) -> URL {
        directory.appendingPathComponent("\(RecordingExporter.sanitize(catalog.id)).json")
    }

    /// The language the interface is in, as the catalog's texts want it.
    static var language: String {
        Bundle.main.preferredLocalizations.first ?? "de"
    }
}

/// Reads how steep the phone is lying, from gravity — for a slope measured by laying the
/// phone on the surface, or against a wall.
@MainActor @Observable
final class InclinationMeter {
    /// Degrees from horizontal, 0 for a phone lying flat, 90 for one standing on its edge.
    private(set) var tilt: Double?
    /// Degrees along the phone's long axis (positive: top higher) and across it.
    private(set) var pitch: Double?
    private(set) var roll: Double?
    private(set) var isAvailable = true
    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable else {
            isAvailable = false
            return
        }
        manager.deviceMotionUpdateInterval = 0.1
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let gravity = motion.gravity
            MainActor.assumeIsolated {
                // Gravity points down in the device frame: a flat phone reads z = −1.
                self?.tilt = acos(min(abs(gravity.z), 1)) * 180 / .pi
                self?.pitch = asin(max(min(gravity.y, 1), -1)) * 180 / .pi
                self?.roll = asin(max(min(gravity.x, 1), -1)) * 180 / .pi
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}
