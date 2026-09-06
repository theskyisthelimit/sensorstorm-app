import Foundation
import simd

/// Chooses which frames of a recording become photogrammetry input, and writes the bundle
/// around them.
///
/// Deliberately not a ``RecordingExporter/Format`` case: the whole-archive export calls the
/// synchronous `RecordingExporter.write`, and this one needs to decode images and needs an
/// options sheet. A case there would have to be either a throwing branch in a synchronous
/// path or an async infection of an export that gains nothing from it.
public struct PhotoSetExporter: Sendable {
    private let store: RecordingStore

    public init(store: RecordingStore) {
        self.store = store
    }

    public enum PhotoSetError: Error, LocalizedError {
        case noFrames

        public var errorDescription: String? {
            switch self {
            case .noFrames:
                String(localized: "Diese Aufnahme enthält keine auswertbaren Videobilder.")
            }
        }
    }

    // MARK: - Planning

    /// One frame that survived selection, with everything the writers need about it.
    public struct SelectedFrame: Sendable {
        public var ordinal: Int
        public var pose: CameraPose
        public var sharpness: Double
        /// Distance to the previously kept frame, in metres. `NaN` for the first, and
        /// wherever there is no position to measure it with.
        public var baseline: Double
        public var name: String
    }

    /// What the selection did, so the result is auditable rather than magic.
    public struct Selection: Sendable {
        public var frames: [SelectedFrame]
        public var candidateCount: Int
        public var windowCount: Int
        public var strategy: String
        public var rejectedTooClose: Int
        public var rejectedUndecodable: Int
    }

    /// Groups the admissible poses into windows.
    ///
    /// With ARKit positions the window closes once the camera has actually *moved* far
    /// enough or turned far enough — which is the whole trick, because photogrammetry wants
    /// baseline, not elapsed time, and somebody standing still for two minutes should
    /// produce one image rather than a hundred identical ones.
    ///
    /// Without them it closes on time instead. GPS at walking pace has metres of noise
    /// against decimetres of real motion, so an arc length integrated from it is integrated
    /// noise — it would look like a moving camera standing still.
    static func windows(_ poses: [CameraPose], options: PhotoSetOptions,
                        usesBaseline: Bool) -> [[Int]] {
        let admissible = poses.indices.filter { poses[$0].intrinsics.isUsable }
        guard !admissible.isEmpty else { return [] }

        var windows: [[Int]] = []
        var current: [Int] = []

        if usesBaseline {
            var travelled = 0.0
            var turned = 0.0
            var last: CameraPose?
            for index in admissible {
                let pose = poses[index]
                if let previous = last {
                    travelled += distance(previous.position, pose.position)
                    turned += angle(previous.orientation, pose.orientation)
                }
                last = pose
                current.append(index)
                if travelled >= options.subject.baselineMetres
                    || turned >= options.subject.rotationRadians {
                    windows.append(current)
                    current = []
                    travelled = 0
                    turned = 0
                }
            }
        } else {
            let times = admissible.map { poses[$0].hostTime }
            guard let first = times.first, let last = times.last, last > first else {
                return [admissible]
            }
            let step = (last - first) / Double(options.targetCount)
            var boundary = first + step
            for index in admissible {
                if poses[index].hostTime > boundary, !current.isEmpty {
                    windows.append(current)
                    current = []
                }
                // A `while`, not an `if`: a gap in the poses can span several boundaries,
                // and advancing only one per closed window would let everything after the
                // gap pile into a single oversized window.
                while poses[index].hostTime > boundary { boundary += step }
                current.append(index)
            }
        }
        if !current.isEmpty { windows.append(current) }

        // More windows than asked for: keep an evenly spaced subset rather than the first N,
        // so the images stay spread over the whole recording.
        guard windows.count > options.targetCount else { return windows }
        let stride = Double(windows.count) / Double(options.targetCount)
        return (0..<options.targetCount).map { windows[Int(Double($0) * stride)] }
    }

    /// Up to `perWindow` frames spread evenly inside each window — the frames that get
    /// decoded and scored.
    static func candidates(in windows: [[Int]], perWindow: Int) -> [[Int]] {
        windows.map { window in
            guard window.count > perWindow else { return window }
            let stride = Double(window.count) / Double(perWindow)
            return (0..<perWindow).map { window[Int(Double($0) * stride)] }
        }
    }

    /// The sharpest candidate per window, then a pass that drops anything too close to the
    /// frame actually kept before it — not to the window boundary, which is what would let
    /// two near-duplicates through at a window edge.
    static func resolve(candidates: [[Int]], poses: [CameraPose], scores: [Int: Double],
                        minimumBaseline: Double, usesBaseline: Bool) -> ([Int], [Double], Int, Int) {
        var kept: [Int] = []
        var baselines: [Double] = []
        var tooClose = 0
        var undecodable = 0

        for window in candidates {
            let usable = window.filter { (scores[$0] ?? .nan).isFinite }
            undecodable += window.count - usable.count
            guard let best = usable.max(by: { (scores[$0] ?? 0) < (scores[$1] ?? 0) }) else {
                continue
            }
            guard let previous = kept.last else {
                kept.append(best)
                baselines.append(.nan)
                continue
            }
            guard usesBaseline else {
                kept.append(best)
                baselines.append(distance(poses[previous].position, poses[best].position))
                continue
            }
            let gap = distance(poses[previous].position, poses[best].position)
            if gap.isFinite, gap < minimumBaseline {
                tooClose += 1
                continue
            }
            kept.append(best)
            baselines.append(gap)
        }
        return (kept, baselines, tooClose, undecodable)
    }

    private static func distance(_ a: ENU, _ b: ENU) -> Double {
        let de = b.east - a.east, dn = b.north - a.north, du = b.up - a.up
        let value = (de * de + dn * dn + du * du).squareRoot()
        return value.isFinite ? value : .nan
    }

    private static func angle(_ a: simd_quatd, _ b: simd_quatd) -> Double {
        guard a.vector.x.isFinite, b.vector.x.isFinite else { return 0 }
        let forwardA = a.act(SIMD3<Double>(0, 0, -1))
        let forwardB = b.act(SIMD3<Double>(0, 0, -1))
        let dot = max(-1, min(1, simd_dot(forwardA, forwardB)))
        let value = acos(dot)
        return value.isFinite ? value : 0
    }

    // MARK: - Export

    public func export(_ metadata: RecordingMetadata,
                       options: PhotoSetOptions,
                       provider: some PhotogrammetryImageProvider,
                       into destinationDirectory: URL,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let fileManager = FileManager.default
        let folderName = RecordingExporter.sanitize(metadata.name) + "-Fotos"
        let staging = destinationDirectory
            .appendingPathComponent("staging-photos-\(metadata.id.uuidString)", isDirectory: true)
        let payload = staging.appendingPathComponent(folderName, isDirectory: true)

        if fileManager.fileExists(atPath: staging.path) {
            try fileManager.removeItem(at: staging)
        }
        try fileManager.createDirectory(at: payload, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        try await write(metadata, options: options, provider: provider,
                        into: payload, progress: progress)

        let zipURL = destinationDirectory.appendingPathComponent("\(folderName).zip")
        if fileManager.fileExists(atPath: zipURL.path) {
            try fileManager.removeItem(at: zipURL)
        }
        try ZipPackager.zip(directory: payload, to: zipURL)
        progress?(1)
        return zipURL
    }

    public func write(_ metadata: RecordingMetadata,
                      options: PhotoSetOptions,
                      provider: some PhotogrammetryImageProvider,
                      into folder: URL,
                      progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let scene = SceneBundleExporter(store: store).buildScene(for: metadata)
        guard !scene.poses.isEmpty else { throw PhotoSetError.noFrames }

        let usesBaseline = scene.poseSource == .arkitVIO
        let windows = Self.windows(scene.poses, options: options, usesBaseline: usesBaseline)
        let candidateGroups = Self.candidates(in: windows, perWindow: options.candidatesPerWindow)
        let candidateIndices = candidateGroups.flatMap { $0 }
        guard !candidateIndices.isEmpty else { throw PhotoSetError.noFrames }

        let refs = candidateIndices.map {
            PhotoFrameRef(hostTime: scene.poses[$0].hostTime,
                          videoFrameIndex: scene.poses[$0].videoFrameIndex)
        }
        let values = try await provider.sharpness(of: refs)
        var scores: [Int: Double] = [:]
        for (position, index) in candidateIndices.enumerated() {
            scores[index] = position < values.count ? values[position] : .nan
        }
        progress?(0.5)

        let (kept, baselines, tooClose, undecodable) = Self.resolve(
            candidates: candidateGroups, poses: scene.poses, scores: scores,
            minimumBaseline: options.subject.baselineMetres, usesBaseline: usesBaseline)
        guard !kept.isEmpty else { throw PhotoSetError.noFrames }

        let selected: [SelectedFrame] = kept.enumerated().map { ordinal, index in
            let pose = scene.poses[index]
            return SelectedFrame(
                ordinal: ordinal + 1,
                pose: pose,
                sharpness: scores[index] ?? .nan,
                baseline: ordinal < baselines.count ? baselines[ordinal] : .nan,
                name: String(format: "%04d_f%06d.jpg", ordinal + 1, pose.videoFrameIndex))
        }

        let images = folder.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)

        let requests = selected.map { frame in
            PhotoWriteRequest(
                ref: PhotoFrameRef(hostTime: frame.pose.hostTime,
                                   videoFrameIndex: frame.pose.videoFrameIndex),
                exif: self.exif(for: frame, scene: scene, metadata: metadata),
                url: images.appendingPathComponent(frame.name))
        }
        let written = try await provider.write(requests)
        progress?(0.9)

        // Only the frames that actually became a file. A row in `cameras.csv` naming an
        // image that is not in `images/` makes a trajectory import fail on the whole set,
        // and the provider can legitimately come back with fewer — a frame it could not
        // decode is not a frame.
        let delivered = Set(written.map(\.fileName))
        let deliveredFrames = selected.filter { delivered.contains($0.name) }
        guard !deliveredFrames.isEmpty else { throw PhotoSetError.noFrames }

        let selection = Selection(frames: deliveredFrames, candidateCount: candidateIndices.count,
                                  windowCount: windows.count,
                                  strategy: usesBaseline ? "baseline" : "time",
                                  rejectedTooClose: tooClose,
                                  rejectedUndecodable: undecodable)

        try Data(PhotoSetCSV.text(selection.frames, scene: scene, metadata: metadata).utf8)
            .write(to: folder.appendingPathComponent(PhotoSetCSV.fileName), options: .atomic)

        if options.writesColmapModel {
            let colmap = folder.appendingPathComponent("colmap", isDirectory: true)
            try FileManager.default.createDirectory(at: colmap, withIntermediateDirectories: true)
            try Data(ColmapModel.camerasText(selection.frames).utf8)
                .write(to: colmap.appendingPathComponent("cameras.txt"), options: .atomic)
            // Poses only where they were observed. A prior with no rotation is worse than
            // no prior: the solver would start from a lie instead of from nothing.
            if usesBaseline {
                try Data(ColmapModel.imagesText(selection.frames).utf8)
                    .write(to: colmap.appendingPathComponent("images.txt"), options: .atomic)
            }
            try Data(ColmapModel.points3DText.utf8)
                .write(to: colmap.appendingPathComponent("points3D.txt"), options: .atomic)
        }

        if !scene.track.isEmpty {
            try Data(TrackExporter.gpx(scene.track, metadata: metadata).utf8)
                .write(to: folder.appendingPathComponent("track.gpx"), options: .atomic)
        }
        try RecordingStore.encoder.encode(metadata)
            .write(to: folder.appendingPathComponent("metadata.json"), options: .atomic)
        try Data(readme(selection: selection, scene: scene, images: written,
                        options: options).utf8)
            .write(to: folder.appendingPathComponent("README.txt"), options: .atomic)
        progress?(1)
    }

    // MARK: - EXIF for one frame

    func exif(for frame: SelectedFrame, scene: SceneBundleExporter.Scene,
              metadata: RecordingMetadata) -> ExifAttributes {
        let elapsed = frame.pose.hostTime - metadata.startHostTime
        let date = metadata.startedAt.addingTimeInterval(elapsed)

        var latitude: Double?
        var longitude: Double?
        var altitude: Double?
        if let anchor = scene.anchor, frame.pose.position.east.isFinite {
            let geodetic = Geodesy.geodetic(fromENU: frame.pose.position, anchor: anchor)
            latitude = geodetic.latitude
            longitude = geodetic.longitude
            // Orthometric, because that is what EXIF GPSAltitude means. The separation is
            // the one measured at the anchor.
            let separation = anchor.height - (scene.anchorSource?.altitude ?? anchor.height)
            altitude = geodetic.height - separation
        }

        return ExifAttributes(
            make: "Apple",
            model: metadata.device.model,
            software: "Sensorstorm \(metadata.device.appVersion)",
            dateTimeOriginal: Self.exifDate.string(from: date),
            subSecondsOriginal: Self.subSeconds(of: date),
            focalLengthIn35mmFilm: ExifAttributes.focal35(frame.pose.intrinsics),
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            horizontalAccuracy: scene.anchorSource?.horizontalAccuracy,
            imageDirection: scene.poseSource == .arkitVIO
                ? CameraAngles.of(frame.pose)?.yaw : nil,
            imageUniqueID: "\(metadata.id.uuidString)-\(frame.pose.videoFrameIndex)")
    }

    /// UTC on purpose: the recording stores no capture time zone, and stamping the zone of
    /// whichever machine ran the export would be a lie about where the picture was taken.
    static let exifDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    static func subSeconds(of date: Date) -> String {
        let seconds = date.timeIntervalSince1970
        let fraction = seconds - seconds.rounded(.down)
        return String(format: "%03d", Int((fraction * 1000).rounded()) % 1000)
    }
}
