import Foundation
import MapKit
import Observation
import SensorstormCore

/// swisstopo's WMTS as a map layer, with a folder on disk behind it.
///
/// A tile that is on disk is used without asking the network, which is the whole of „offline":
/// the same layer, the same tiles, whether they were fetched a minute ago by scrolling or last
/// week by pressing „Karte laden". Tiles are free to use with the source named, which the
/// map view prints in a corner.
final class SwisstopoTileOverlay: MKTileOverlay {
    static let mapLayer = "ch.swisstopo.pixelkarte-farbe"
    static let aerialLayer = "ch.swisstopo.swissimage"

    private let layer: String
    private let directory: URL

    init(layer: String, directory: URL = OfflineMapStore.defaultDirectory) {
        self.layer = layer
        self.directory = directory
        super.init(urlTemplate: nil)
        // Replaces Apple's map entirely rather than drawing over it.
        canReplaceMapContent = true
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 7
        maximumZ = 18
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        TileMath.swisstopoURL(layer: layer, tile: MapTile(z: path.z, x: path.x, y: path.y))
            ?? URL(fileURLWithPath: "/dev/null")
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        let tile = MapTile(z: path.z, x: path.x, y: path.y)
        let file = directory.appendingPathComponent(TileMath.cachePath(layer: layer, tile: tile))
        if let data = try? Data(contentsOf: file) {
            result(data, nil)
            return
        }
        let request = url(forTilePath: path)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let data, (response as? HTTPURLResponse)?.statusCode == 200 {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
                result(data, nil)
            } else {
                result(nil, error)
            }
        }.resume()
    }
}

/// The map tiles kept for use without a connection.
@MainActor @Observable
final class OfflineMapStore {
    struct Progress: Equatable {
        var done = 0
        var total = 0
        var deepestZoom = 0
        var isRunning = false
        var failed = 0

        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    /// Application Support, not Caches: iOS may empty a cache whenever it likes, and a map
    /// downloaded for a walk in the mountains must still be there when the signal is not.
    nonisolated static var defaultDirectory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("OfflineMaps", isDirectory: true)
    }

    /// The most tiles one download takes. At about 20 kB each, 1 500 is 30 MB.
    static let tileLimit = 1_500
    static let zooms = 12...17

    private(set) var progress = Progress()
    private(set) var bytes: Int64 = 0
    private var task: Task<Void, Never>?

    init() {
        refreshSize()
    }

    func refreshSize() {
        bytes = Self.size(of: Self.defaultDirectory)
    }

    /// Fetches every tile of `layer` covering `bounds` that is not on disk yet.
    func download(layer: String, bounds: GeoBounds) {
        guard !progress.isRunning else { return }
        let plan = TileMath.plan(bounds: bounds, zooms: Self.zooms, limit: Self.tileLimit)
        progress = Progress(done: 0, total: plan.tiles.count, deepestZoom: plan.deepest, isRunning: true)
        let directory = Self.defaultDirectory
        task = Task { [weak self] in
            guard let store = self else { return }
            let counter = Counter()
            let failures = Counter()
            _ = await concurrentMap(plan.tiles, limit: 6) { tile -> Bool in
                let file = directory.appendingPathComponent(TileMath.cachePath(layer: layer, tile: tile))
                if !FileManager.default.fileExists(atPath: file.path), let url = TileMath.swisstopoURL(layer: layer, tile: tile) {
                    do {
                        let (data, response) = try await URLSession.shared.data(from: url)
                        if (response as? HTTPURLResponse)?.statusCode == 200 {
                            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                                    withIntermediateDirectories: true)
                            try data.write(to: file, options: .atomic)
                        } else {
                            _ = failures.increment()
                        }
                    } catch {
                        _ = failures.increment()
                    }
                }
                let done = counter.increment()
                if done % 10 == 0 { await store.report(done: done) }
                return true
            }
            await store.finishDownload(failed: failures.value)
        }
    }

    func cancel() {
        task?.cancel()
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: Self.defaultDirectory)
        refreshSize()
    }

    private func report(done: Int) {
        progress.done = done
    }

    private func finishDownload(failed: Int) {
        progress.done = progress.total
        progress.failed = failed
        progress.isRunning = false
        refreshSize()
    }

    nonisolated static func size(of directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
