import Foundation
import simd

/// Turns a recording into a bundle a 3D application can consume: one camera pose per video
/// frame, in metres, in a named world frame, next to the video it belongs to.
///
/// The hard part is not the file writing — it is being explicit about which frame every
/// number lives in. Everything here comes out in the export frame described by
/// ``SceneManifest/CoordinateSystem``: metres east/north/up from the anchor, cameras looking
/// down their local −Z. That is Blender's convention for a Z-up scene, so the importer has no
/// swizzling left to do and no chance to get it wrong a second time.
public struct SceneBundleExporter: Sendable {
    private let store: RecordingStore

    public init(store: RecordingStore) {
        self.store = store
    }

    /// Everything the writers need, computed once.
    struct Scene {
        var anchor: Geodetic?
        var anchorSource: GeodeticAnchor?
        var poses: [CameraPose]
        var poseSource: PoseSource
        var timingSource: FrameTimingSource
        var alignment: GroundAlignment?
        var track: [TrackPoint]
    }

    // MARK: - Entry point

    public func write(_ metadata: RecordingMetadata, into folder: URL,
                      progress: (@Sendable (Double) -> Void)? = nil) throws {
        let scene = buildScene(for: metadata)
        progress?(0.3)

        try writeFramesCSV(scene, metadata: metadata,
                           to: folder.appendingPathComponent("frames.csv"))
        progress?(0.6)

        let manifest = self.manifest(for: scene, metadata: metadata)
        try RecordingStore.encoder.encode(manifest)
            .write(to: folder.appendingPathComponent("scene.json"), options: .atomic)

        if !scene.track.isEmpty {
            try Data(TrackExporter.gpx(scene.track, metadata: metadata).utf8)
                .write(to: folder.appendingPathComponent("track.gpx"), options: .atomic)
            try Data(TrackExporter.kml(scene.track, metadata: metadata).utf8)
                .write(to: folder.appendingPathComponent("track.kml"), options: .atomic)
        }
        progress?(0.8)

        try RecordingStore.encoder.encode(metadata)
            .write(to: folder.appendingPathComponent("metadata.json"), options: .atomic)
        try Data(readme(for: scene, metadata: metadata).utf8)
            .write(to: folder.appendingPathComponent("README.txt"), options: .atomic)

        if let videoURL = store.videoURL(for: metadata), let video = metadata.video {
            try FileManager.default.copyItem(
                at: videoURL, to: folder.appendingPathComponent(video.fileName))
        }
        progress?(1)
    }

    // MARK: - Building the scene

    func buildScene(for metadata: RecordingMetadata) -> Scene {
        let track = store.reader(for: .location, recording: metadata.id)
            .map(TrackExporter.track(from:)) ?? []

        let anchorSource = metadata.geodeticAnchor ?? track.first.map {
            GeodeticAnchor(latitude: $0.position.latitude,
                           longitude: $0.position.longitude,
                           altitude: $0.orthometricHeight,
                           ellipsoidalAltitude: $0.position.height,
                           horizontalAccuracy: $0.horizontalAccuracy,
                           verticalAccuracy: .nan,
                           hostTime: $0.hostTime)
        }
        let anchor = anchorSource.map {
            Geodetic(latitude: $0.latitude, longitude: $0.longitude,
                     height: $0.ellipsoidalAltitude)
        }

        let (frames, timingSource) = frameSamples(for: metadata)
        guard !frames.isEmpty else {
            return Scene(anchor: anchor, anchorSource: anchorSource, poses: [],
                         poseSource: .none, timingSource: timingSource,
                         alignment: nil, track: track)
        }

        // The GPS position at each frame time, in the export frame. Used as the pose itself
        // on the classic path and as the alignment target on the ARKit one.
        let gpsAtFrames: [ENU?] = anchor.map { anchor in
            let sampled = resample(track: track, at: frames.map(\.hostTime))
            return sampled.map { $0.map { Geodesy.enu(of: $0, from: anchor) } }
        } ?? Array(repeating: nil, count: frames.count)

        if metadata.captureEngine == .arkit, frames.contains(where: { $0.hasPosition }) {
            let (poses, alignment) = arkitPoses(frames: frames, gpsAtFrames: gpsAtFrames)
            return Scene(anchor: anchor, anchorSource: anchorSource, poses: poses,
                         poseSource: .arkitVIO, timingSource: timingSource,
                         alignment: alignment, track: track)
        }

        // Classic path: real timing, real intrinsics, GPS position, no viewing direction.
        // Writing a guessed orientation here would look like data and behave like noise.
        let poses = zip(frames, gpsAtFrames).map { frame, gps in
            CameraPose(hostTime: frame.hostTime,
                       position: gps ?? ENU(east: .nan, north: .nan, up: .nan),
                       orientation: simd_quatd(vector: SIMD4(.nan, .nan, .nan, .nan)),
                       intrinsics: frame.intrinsics,
                       trackingState: .notAvailable,
                       trackingReason: .none)
        }
        return Scene(anchor: anchor, anchorSource: anchorSource, poses: poses,
                     poseSource: anchor == nil ? .none : .gpsPositionOnly,
                     timingSource: timingSource, alignment: nil, track: track)
    }

    /// ARKit poses moved into the export frame, then yawed onto the GPS track.
    ///
    /// `.gravityAndHeading` takes its initial heading from the magnetometer, which is good to
    /// a few degrees and does not drift afterwards. A single rigid yaw correction is therefore
    /// the right shape of fix — anything per-frame would be fighting the odometry.
    private func arkitPoses(frames: [FrameSample],
                            gpsAtFrames: [ENU?]) -> ([CameraPose], GroundAlignment?) {
        var poses = frames.map { frame in
            CameraPose(hostTime: frame.hostTime,
                       position: ARWorldFrame.position(fromARKit: frame.position),
                       orientation: ARWorldFrame.orientation(fromARKit: frame.orientation),
                       intrinsics: frame.intrinsics,
                       trackingState: frame.trackingState,
                       trackingReason: frame.trackingReason)
        }

        // Only frames that are trustworthy on both sides may steer the fit.
        var source: [ENU] = []
        var target: [ENU] = []
        for (pose, gps) in zip(poses, gpsAtFrames) {
            guard let gps, pose.trackingState == .normal, pose.position.simd.x.isFinite else {
                continue
            }
            source.append(pose.position)
            target.append(gps)
        }

        guard source.count >= 8, spread(of: source) > 5 else {
            // Standing still, or barely moving: there is no heading in the GPS track to fit
            // to, and forcing one would rotate the whole scene by an arbitrary angle.
            return (poses, nil)
        }

        let alignment = TrajectoryAlignment.horizontal(source: source, target: target)
        poses = poses.map {
            CameraPose(hostTime: $0.hostTime,
                       position: alignment.apply(to: $0.position),
                       orientation: alignment.apply(to: $0.orientation),
                       intrinsics: $0.intrinsics,
                       trackingState: $0.trackingState,
                       trackingReason: $0.trackingReason)
        }
        return (poses, alignment)
    }

    /// Largest distance from the centroid — how much of a heading the track actually contains.
    private func spread(of points: [ENU]) -> Double {
        guard !points.isEmpty else { return 0 }
        var mean = SIMD2<Double>.zero
        for p in points { mean += SIMD2(p.east, p.north) }
        mean /= Double(points.count)
        return points.reduce(0) {
            max($0, simd_distance(SIMD2($1.east, $1.north), mean))
        }
    }

    // MARK: - Frame samples

    struct FrameSample {
        var hostTime: Double
        var position: SIMD3<Double>
        var orientation: simd_quatd
        var intrinsics: CameraIntrinsics
        var trackingState: CameraTrackingState
        var trackingReason: CameraTrackingReason

        var hasPosition: Bool { position.x.isFinite && position.y.isFinite && position.z.isFinite }
    }

    /// One entry per stored video frame, from the `cameraPose` stream when it exists and from
    /// the nominal frame rate when it does not.
    func frameSamples(for metadata: RecordingMetadata) -> ([FrameSample], FrameTimingSource) {
        guard let video = metadata.video else { return ([], .perFrame) }

        let storedIntrinsicsNeedRotation = !video.isSensorNative
        let rotation = video.appliedRotationAngle ?? 0

        if let reader = store.reader(for: .cameraPose, recording: metadata.id),
           reader.sampleCount > 0, reader.channelCount >= 13 {
            var samples: [FrameSample] = []
            samples.reserveCapacity(reader.sampleCount)

            reader.forEachSample { hostTime, v in
                var intrinsics = CameraIntrinsics(fx: v[7], fy: v[8], cx: v[9], cy: v[10],
                                                  imageWidth: video.width,
                                                  imageHeight: video.height)
                // The classic path's intrinsics describe the sensor; the connection rotated
                // the pixels underneath them. ARKit stores its video unrotated, so this is a
                // no-op there.
                if storedIntrinsicsNeedRotation, rotation != 0 {
                    intrinsics = intrinsics.rotatedCounterClockwise(by: rotation)
                }
                samples.append(FrameSample(
                    hostTime: hostTime,
                    position: SIMD3(v[0], v[1], v[2]),
                    orientation: simd_quatd(ix: v[3], iy: v[4], iz: v[5], r: v[6]),
                    intrinsics: intrinsics,
                    trackingState: CameraTrackingState(rawValue: v[11]) ?? .notAvailable,
                    trackingReason: CameraTrackingReason(rawValue: v[12]) ?? .none))
            }
            return (samples, .perFrame)
        }

        // No pose stream: reconstruct the timeline from the nominal rate. Good enough to see
        // the track, wrong by one frame interval wherever the camera dropped a frame.
        guard video.nominalFrameRate > 0, video.duration > 0 else { return ([], .nominalRate) }
        let count = Int((video.duration * video.nominalFrameRate).rounded())
        let nan = Double.nan
        let samples = (0..<max(count, 0)).map { index in
            FrameSample(hostTime: video.startHostTime + Double(index) / video.nominalFrameRate,
                        position: SIMD3(nan, nan, nan),
                        orientation: simd_quatd(vector: SIMD4(nan, nan, nan, nan)),
                        intrinsics: CameraIntrinsics(fx: nan, fy: nan, cx: nan, cy: nan,
                                                     imageWidth: video.width,
                                                     imageHeight: video.height),
                        trackingState: .notAvailable,
                        trackingReason: .none)
        }
        return (samples, .nominalRate)
    }

    /// GPS positions interpolated onto arbitrary times.
    ///
    /// Linear between the bracketing fixes, and `nil` outside the track rather than clamped —
    /// a frame recorded before the first fix has no position, and pretending it sits at the
    /// first one would plant a whole run of frames on top of each other.
    func resample(track: [TrackPoint], at times: [Double]) -> [Geodetic?] {
        guard !track.isEmpty else { return Array(repeating: nil, count: times.count) }
        guard track.count > 1 else {
            return times.map { _ in track[0].position }
        }

        var result: [Geodetic?] = []
        result.reserveCapacity(times.count)
        var cursor = 0

        for time in times {
            guard time >= track.first!.hostTime, time <= track.last!.hostTime else {
                result.append(nil)
                continue
            }
            while cursor + 1 < track.count - 1, track[cursor + 1].hostTime <= time {
                cursor += 1
            }
            let a = track[cursor], b = track[cursor + 1]
            let span = b.hostTime - a.hostTime
            let t = span > 0 ? min(max((time - a.hostTime) / span, 0), 1) : 0
            result.append(Geodetic(
                latitude: a.position.latitude + (b.position.latitude - a.position.latitude) * t,
                longitude: a.position.longitude + (b.position.longitude - a.position.longitude) * t,
                height: a.position.height + (b.position.height - a.position.height) * t))
        }
        return result
    }

    // MARK: - frames.csv

    static let framesHeader = [
        "frame_index", "host_time", "seconds_elapsed", "epoch",
        "x_enu", "y_enu", "z_enu",
        "qx", "qy", "qz", "qw",
        "fx", "fy", "cx", "cy", "image_width", "image_height",
        "tracking_state", "tracking_reason",
        "lat", "lon", "alt_msl", "alt_ellipsoidal",
        "e_lv95", "n_lv95", "h_lv95"
    ].joined(separator: ",")

    private func writeFramesCSV(_ scene: Scene, metadata: RecordingMetadata, to url: URL) throws {
        let epochAtStart = metadata.startedAt.timeIntervalSince1970
        var out = Self.framesHeader + "\n"
        out.reserveCapacity(1 << 16)

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        for (index, pose) in scene.poses.enumerated() {
            let elapsed = pose.hostTime - metadata.startHostTime
            var row = "\(index),\(num(pose.hostTime)),\(num(elapsed)),\(num(epochAtStart + elapsed))"

            row += ",\(num(pose.position.east)),\(num(pose.position.north)),\(num(pose.position.up))"

            let q = pose.orientation.vector
            row += ",\(num(q.x)),\(num(q.y)),\(num(q.z)),\(num(q.w))"

            let k = pose.intrinsics
            row += ",\(num(k.fx)),\(num(k.fy)),\(num(k.cx)),\(num(k.cy))"
            row += ",\(k.imageWidth),\(k.imageHeight)"
            row += ",\(Int(pose.trackingState.rawValue)),\(Int(pose.trackingReason.rawValue))"

            // The same position again in geodetic and Swiss coordinates, so the file is
            // usable without an anchor and without reimplementing the projection.
            if let anchor = scene.anchor, pose.position.east.isFinite {
                let geodetic = Geodesy.geodetic(fromENU: pose.position, anchor: anchor)
                let swiss = Geodesy.lv95(from: geodetic)
                let orthometric = geodetic.height - (anchor.height - anchorOrthometric(scene))
                row += ",\(num(geodetic.latitude)),\(num(geodetic.longitude))"
                row += ",\(num(orthometric)),\(num(geodetic.height))"
                row += ",\(num(swiss.east)),\(num(swiss.north)),\(num(swiss.height))"
            } else {
                row += ",,,,,,,"
            }

            out += row
            out += "\n"

            if index % 2048 == 0, !out.isEmpty {
                try handle.write(contentsOf: Data(out.utf8))
                out.removeAll(keepingCapacity: true)
            }
        }

        if !out.isEmpty {
            try handle.write(contentsOf: Data(out.utf8))
        }
    }

    /// The anchor's orthometric height, so per-frame heights can be reported in both systems
    /// using the geoid separation measured at the anchor.
    private func anchorOrthometric(_ scene: Scene) -> Double {
        scene.anchorSource?.altitude ?? scene.anchor?.height ?? 0
    }

    private func num(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        return String(format: "%.12g", value)
    }

    // MARK: - scene.json

    func manifest(for scene: Scene, metadata: RecordingMetadata) -> SceneManifest {
        let usable = scene.poses.compactMap {
            $0.intrinsics.isUsable ? $0.intrinsics.horizontalFieldOfView : nil
        }.sorted()

        var anchor: SceneManifest.Anchor?
        if let source = scene.anchorSource {
            let geodetic = Geodetic(latitude: source.latitude, longitude: source.longitude,
                                    height: source.ellipsoidalAltitude)
            let swiss = Geodesy.lv95(from: geodetic)
            anchor = SceneManifest.Anchor(
                latitude: source.latitude,
                longitude: source.longitude,
                altitudeOrthometric: source.altitude,
                altitudeEllipsoidal: source.ellipsoidalAltitude,
                horizontalAccuracy: source.horizontalAccuracy,
                verticalAccuracy: source.verticalAccuracy,
                lv95East: swiss.east,
                lv95North: swiss.north,
                lv95Height: swiss.height,
                lv95IsInRange: Self.isWithinSwitzerland(geodetic))
        }

        var video: SceneManifest.Video?
        if let source = metadata.video {
            video = SceneManifest.Video(
                fileName: source.fileName,
                width: source.width,
                height: source.height,
                nominalFrameRate: source.nominalFrameRate,
                startOffsetSeconds: source.offset(from: metadata.startHostTime),
                appliedRotationAngle: source.appliedRotationAngle,
                isMirrored: source.isMirrored,
                intrinsicsMatchStoredPixels: true)
        }

        return SceneManifest(
            recording: .init(
                id: metadata.id.uuidString,
                name: metadata.name,
                startedAt: metadata.startedAt,
                durationSeconds: metadata.duration,
                deviceModel: metadata.device.model,
                systemVersion: "\(metadata.device.systemName) \(metadata.device.systemVersion)",
                appVersion: metadata.device.appVersion,
                captureEngine: (metadata.captureEngine ?? .classic).rawValue,
                attitudeReferenceFrame: metadata.attitudeReferenceFrame?.rawValue),
            coordinateSystem: .init(),
            anchor: anchor,
            video: video,
            camera: .init(
                intrinsicsArePerFrame: scene.timingSource == .perFrame,
                medianHorizontalFovDegrees: usable.isEmpty ? nil : usable[usable.count / 2]),
            frames: .init(
                count: scene.poses.count,
                reliableCount: scene.poses.count(where: \.isReliable),
                poseSource: scene.poseSource.rawValue,
                timingSource: scene.timingSource.rawValue),
            alignment: scene.alignment.map {
                .init(yawDegrees: $0.yawDegrees,
                      rmsResidualMetres: $0.rmsResidual,
                      trackSpreadMetres: $0.rmsSpread,
                      yawUncertaintyDegrees: $0.yawUncertaintyDegrees,
                      sampleCount: $0.sampleCount)
            })
    }

    /// Generous bounding box around Switzerland. The LV95 columns are written regardless —
    /// the projection has no idea it is out of area and will happily return a number — so the
    /// flag is what tells a reader whether to believe it.
    static func isWithinSwitzerland(_ position: Geodetic) -> Bool {
        (45.7...47.9).contains(position.latitude) && (5.7...10.6).contains(position.longitude)
    }

    // MARK: - README

    private func readme(for scene: Scene, metadata: RecordingMetadata) -> String {
        var text = """
        Sensorstorm scene bundle — \(metadata.name)
        \(metadata.startedAt.formatted(.iso8601))

        frames.csv holds one row per stored video frame.

          host_time         shared clock, the same one every .ssbin stream uses
          seconds_elapsed   host_time minus the recording start
          x_enu y_enu z_enu metres east / north / up from the anchor below
          qx qy qz qw       camera orientation, xyzw, camera-local -> world
          fx fy cx cy       pinhole intrinsics in pixels of the stored image

        World frame: +X east, +Y north, +Z up.
        Camera frame: -Z is the viewing direction, +Y is up in the image.
        Both are Blender's conventions for a Z-up scene, so nothing needs swizzling.

        Pose source: \(scene.poseSource.rawValue)
        Frame timing: \(scene.timingSource.rawValue)

        """

        switch scene.poseSource {
        case .arkitVIO:
            text += """
            Positions come from ARKit's visual-inertial odometry: metric, and accurate to
            centimetres over the length of a recording. The whole track was then rotated and
            shifted onto the GPS track as a rigid body, which corrects the initial compass
            heading without disturbing the odometry.

            """
        case .gpsPositionOnly:
            text += """
            Positions are interpolated GPS fixes — expect metres of error. The orientation
            columns are deliberately empty: this recording was made with the classic camera
            path, which does not observe a camera pose, and a value derived from the attitude
            stream alone would look like data without being it. Record in ARKit mode for
            frames you intend to place in 3D.

            """
        case .none:
            text += """
            No position could be derived: this recording has no usable GPS fix. Timing and
            intrinsics are still exact, which is enough to feed a photogrammetry solver.

            """
        }

        if let alignment = scene.alignment {
            text += """
            GPS alignment: yaw \(String(format: "%.2f", alignment.yawDegrees))° \
            ± \(String(format: "%.1f", alignment.yawUncertaintyDegrees))°, \
            RMS residual \(String(format: "%.2f", alignment.rmsResidual)) m \
            over \(alignment.sampleCount) frames spanning \
            \(String(format: "%.1f", alignment.rmsSpread)) m.
            A residual of a few metres is ordinary GPS noise. The uncertainty is what matters:
            it falls as the track gets longer, so a scene you want rotated correctly wants a
            recording that walked somewhere, not one that stood still and panned.

            """
        }

        if let anchor = scene.anchorSource {
            let swiss = Geodesy.lv95(from: Geodetic(latitude: anchor.latitude,
                                                    longitude: anchor.longitude,
                                                    height: anchor.ellipsoidalAltitude))
            text += """
            Anchor (origin of the ENU frame)
              WGS84   \(String(format: "%.7f", anchor.latitude)), \
            \(String(format: "%.7f", anchor.longitude))
              Height  \(String(format: "%.2f", anchor.ellipsoidalAltitude)) m ellipsoidal, \
            \(String(format: "%.2f", anchor.altitude)) m orthometric
              LV95    \(String(format: "%.2f", swiss.east)) / \
            \(String(format: "%.2f", swiss.north))
              Fix accuracy \(String(format: "%.1f", anchor.horizontalAccuracy)) m horizontal

            Heights: z_enu is ellipsoidal. Google 3D Tiles wants that one. swisstopo terrain
            wants the orthometric alt_msl column, which is about 46-52 m lower in Switzerland.

            """
        }
        return text
    }
}
