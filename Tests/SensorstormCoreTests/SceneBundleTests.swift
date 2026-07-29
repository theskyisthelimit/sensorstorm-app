import Foundation
import Testing
import simd
@testable import SensorstormCore

@Suite("Scene bundle")
struct SceneBundleTests {

    // MARK: - Fixture

    /// A synthetic recording: the camera walks due east at 2 m/s for ten seconds, one metre
    /// off the ground, looking where it goes. GPS agrees, but the ARKit world is turned 20°
    /// off — exactly the error `.gravityAndHeading` makes when the compass is out.
    struct Fixture {
        static let anchor = Geodetic(latitude: 46.9480, longitude: 7.4474, height: 590)
        static let startHostTime = 1_000.0
        static let frameRate = 30.0
        static let frameCount = 300
        static let speed = 2.0
        static let gpsFixCount = 11
        static let arkitYawError = 20.0 * .pi / 180
        /// Geoid separation baked into the fixture, so the two height systems stay
        /// distinguishable in the assertions.
        static let geoidSeparation = 50.0

        let store: RecordingStore
        var metadata: RecordingMetadata

        static func frameTime(_ index: Int) -> Double {
            startHostTime + 0.25 + Double(index) / frameRate
        }

        /// Ground truth as a continuous function of time, so GPS fixes and video frames are
        /// samples of one motion rather than two approximations of it.
        static func truePosition(atHostTime time: Double) -> ENU {
            ENU(east: (time - frameTime(0)) * speed, north: 0, up: 1)
        }

        static func truePosition(frame index: Int) -> ENU {
            truePosition(atHostTime: frameTime(index))
        }

        init(engine: CaptureEngine, includeGPS: Bool = true, includePoseStream: Bool = true) throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("sensorstorm-scene-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = RecordingStore(root: root)

            let id = UUID()
            let directory = try store.prepareDirectory(for: id)
            var streams: [StreamInfo] = []

            if includePoseStream {
                let writer = try StreamWriter(sensor: .cameraPose, channelCount: 13,
                                              directory: directory)
                for index in 0..<Self.frameCount {
                    let truth = Self.truePosition(frame: index)
                    // Undo the export frame's rotation to get back to ARKit's (east, up,
                    // south) world, then add the heading error the fit has to find.
                    let c = cos(-Self.arkitYawError), s = sin(-Self.arkitYawError)
                    let east = c * truth.east - s * truth.north
                    let north = s * truth.east + c * truth.north
                    let arkit = SIMD3(east, truth.up, -north)

                    // Looking along the direction of travel: yaw the identity camera
                    // (which faces ARKit −Z, i.e. north) round to face east.
                    let q = simd_quatd(angle: -(.pi / 2) - Self.arkitYawError,
                                       axis: SIMD3(0, 1, 0))

                    writer.append(time: Self.frameTime(index), values: [
                        arkit.x, arkit.y, arkit.z,
                        q.vector.x, q.vector.y, q.vector.z, q.vector.w,
                        1500, 1500, 960, 540,
                        CameraTrackingState.normal.rawValue,
                        CameraTrackingReason.none.rawValue
                    ])
                }
                streams.append(writer.close())
            }

            if includeGPS {
                let writer = try StreamWriter(sensor: .location, channelCount: 10,
                                              directory: directory)
                // 1 Hz, spanning the whole video.
                for step in 0..<Self.gpsFixCount {
                    let time = Self.frameTime(0) + Double(step)
                    let truth = Self.truePosition(atHostTime: time)
                    let position = Geodesy.geodetic(fromENU: truth, anchor: Self.anchor)
                    writer.append(time: time, values: [
                        position.latitude, position.longitude,
                        position.height - Self.geoidSeparation,
                        position.height,
                        Self.speed, 1, 90, 5, 4, 6
                    ])
                }
                streams.append(writer.close())
            }

            metadata = RecordingMetadata(
                id: id,
                name: "Szene",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                startHostTime: Self.startHostTime,
                duration: 0.25 + Double(Self.frameCount) / Self.frameRate,
                device: DeviceInfo(model: "iPhone17,1", systemName: "iOS",
                                   systemVersion: "26.0", appVersion: "1.0.0 (1)"),
                streams: streams,
                video: VideoInfo(fileName: "video.mov",
                                 startHostTime: Self.frameTime(0),
                                 duration: Double(Self.frameCount) / Self.frameRate,
                                 width: 1920, height: 1080,
                                 nominalFrameRate: Self.frameRate,
                                 hasAudio: false, isFrontCamera: false,
                                 appliedRotationAngle: 0, isMirrored: false),
                requestedRateHz: 100,
                captureEngine: engine,
                attitudeReferenceFrame: .trueNorth,
                geodeticAnchor: includeGPS ? GeodeticAnchor(
                    latitude: Self.anchor.latitude, longitude: Self.anchor.longitude,
                    altitude: Self.anchor.height - Self.geoidSeparation,
                    ellipsoidalAltitude: Self.anchor.height,
                    horizontalAccuracy: 4, verticalAccuracy: 6,
                    hostTime: Self.startHostTime) : nil)

            try store.save(metadata)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: store.root)
        }
    }

    // MARK: - ARKit path

    @Test("ARKit poses land on the GPS track after the yaw fit")
    func arkitPosesAlignToGPS() throws {
        let fixture = try Fixture(engine: .arkit)
        defer { fixture.cleanUp() }

        let scene = SceneBundleExporter(store: fixture.store).buildScene(for: fixture.metadata)

        #expect(scene.poseSource == .arkitVIO)
        #expect(scene.timingSource == .perFrame)
        #expect(scene.poses.count == Fixture.frameCount)

        let alignment = try #require(scene.alignment)
        #expect(abs(alignment.yawDegrees - 20) < 0.5,
                "should have recovered the 20° heading error, got \(alignment.yawDegrees)")
        #expect(alignment.rmsResidual < 0.5)

        // Every frame should now sit on the straight eastward walk it was built from.
        for (index, pose) in scene.poses.enumerated() {
            let truth = Fixture.truePosition(frame: index)
            #expect(abs(pose.position.east - truth.east) < 0.5,
                    "frame \(index) east: \(pose.position.east) vs \(truth.east)")
            #expect(abs(pose.position.north - truth.north) < 0.5)
            #expect(abs(pose.position.up - truth.up) < 0.01)
        }
    }

    @Test("The corrected camera looks the way it was walking")
    func arkitOrientationIsCorrectedToo() throws {
        let fixture = try Fixture(engine: .arkit)
        defer { fixture.cleanUp() }

        let scene = SceneBundleExporter(store: fixture.store).buildScene(for: fixture.metadata)
        let pose = try #require(scene.poses.first)

        // Rotating the positions without rotating the orientations is the classic way to end
        // up with a track that is right and cameras that face the wrong way.
        let forward = pose.orientation.act(SIMD3(0, 0, -1))
        #expect(abs(forward.x - 1) < 0.02, "should look east, got \(forward)")
        #expect(abs(forward.y) < 0.02)
        #expect(abs(forward.z) < 0.02)
    }

    @Test("A stationary recording is left unrotated rather than spun at random")
    func stationaryRecordingIsNotAligned() throws {
        let fixture = try Fixture(engine: .arkit, includeGPS: false)
        defer { fixture.cleanUp() }

        let scene = SceneBundleExporter(store: fixture.store).buildScene(for: fixture.metadata)
        #expect(scene.alignment == nil)
        #expect(scene.anchor == nil)
    }

    // MARK: - Classic path

    @Test("The classic path writes positions but refuses to invent an orientation")
    func classicPathHasNoOrientation() throws {
        let fixture = try Fixture(engine: .classic)
        defer { fixture.cleanUp() }

        let scene = SceneBundleExporter(store: fixture.store).buildScene(for: fixture.metadata)
        #expect(scene.poseSource == .gpsPositionOnly)

        let pose = try #require(scene.poses.first)
        #expect(pose.position.east.isFinite)
        #expect(pose.orientation.vector.x.isNaN)
        #expect(pose.isReliable == false)
        // Intrinsics are real on this path and are what make it worth exporting at all.
        #expect(pose.intrinsics.isUsable)
    }

    @Test("Without a pose stream the timeline falls back to the nominal rate")
    func nominalRateFallback() throws {
        let fixture = try Fixture(engine: .classic, includePoseStream: false)
        defer { fixture.cleanUp() }

        let exporter = SceneBundleExporter(store: fixture.store)
        let (frames, timing) = exporter.frameSamples(for: fixture.metadata)
        #expect(timing == .nominalRate)
        #expect(frames.count == Fixture.frameCount)
        #expect(frames[0].intrinsics.isUsable == false)
    }

    // MARK: - Frame matching

    /// The first real recording exposed this: the movie is armed before the pose writer (an
    /// audio engine starts up in between) and keeps receiving frames while the file is
    /// finalised. On that recording the movie held 281 frames and the pose stream 283 rows,
    /// overlapping by only 266 — so row N was frame N+15, and a naive mapping slid the whole
    /// camera animation a quarter second against the footage.
    @Test("Poses are matched to video frames by time, not by row number")
    func framesAreMatchedByTime() throws {
        let fixture = try Fixture(engine: .arkit)
        defer { fixture.cleanUp() }

        // Pretend the movie opened four frames after the first pose and closed three frames
        // before the last — the same shape as the real recording, in both directions.
        var metadata = fixture.metadata
        let rate = Fixture.frameRate
        let video = try #require(metadata.video)
        metadata.video = VideoInfo(
            fileName: video.fileName,
            startHostTime: Fixture.frameTime(4),
            duration: Double(Fixture.frameCount - 1 - 4 - 3) / rate,
            width: video.width, height: video.height,
            nominalFrameRate: rate,
            hasAudio: false, isFrontCamera: false,
            appliedRotationAngle: 0, isMirrored: false)

        let exporter = SceneBundleExporter(store: fixture.store)
        let (frames, timing) = exporter.frameSamples(for: metadata)

        #expect(timing == .perFrame)
        // 300 poses, minus 4 before the movie opened and 3 after it closed.
        #expect(frames.count == Fixture.frameCount - 7)

        // The first surviving pose is the movie's frame 0, not the file's row 0.
        #expect(frames.first?.videoFrameIndex == 0)
        #expect(frames.last?.videoFrameIndex == Fixture.frameCount - 1 - 4 - 3)

        // Indices are contiguous and strictly increasing — a gap would desynchronise
        // everything after it.
        for (offset, frame) in frames.enumerated() {
            #expect(frame.videoFrameIndex == offset)
        }

        // And the pose that ends up at movie frame 0 is genuinely the one recorded then.
        #expect(abs((frames.first?.hostTime ?? 0) - Fixture.frameTime(4)) < 1e-9)
    }

    @Test("The frame index reaches frames.csv rather than the row counter")
    func csvCarriesTheVideoFrameIndex() throws {
        let fixture = try Fixture(engine: .arkit)
        defer { fixture.cleanUp() }

        var metadata = fixture.metadata
        let video = try #require(metadata.video)
        metadata.video = VideoInfo(
            fileName: video.fileName,
            startHostTime: Fixture.frameTime(10),
            duration: video.duration,
            width: video.width, height: video.height,
            nominalFrameRate: Fixture.frameRate,
            hasAudio: false, isFrontCamera: false,
            appliedRotationAngle: 0, isMirrored: false)

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("scene-idx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }

        try SceneBundleExporter(store: fixture.store).write(metadata, into: output)

        let csv = try String(contentsOf: output.appendingPathComponent("frames.csv"),
                             encoding: .utf8)
        let rows = csv.split(separator: "\n").dropFirst()
        // Ten poses fell before the movie opened, so the file starts at frame 0 and holds
        // ten rows fewer than the pose stream.
        #expect(rows.count == Fixture.frameCount - 10)
        #expect(rows.first?.split(separator: ",").first == "0")
        #expect(rows.dropFirst().first?.split(separator: ",").first == "1")
    }

    // MARK: - Resampling

    @Test("Frames outside the GPS track get no position instead of a clamped one")
    func resampleDoesNotClamp() throws {
        let fixture = try Fixture(engine: .arkit)
        defer { fixture.cleanUp() }

        let exporter = SceneBundleExporter(store: fixture.store)
        let reader = try #require(fixture.store.reader(for: .location, recording: fixture.metadata.id))
        let track = TrackExporter.track(from: reader)

        let sampled = exporter.resample(track: track, at: [
            track.first!.hostTime - 10,     // before
            track.first!.hostTime,          // exactly the first fix
            (track.first!.hostTime + track.last!.hostTime) / 2,
            track.last!.hostTime + 10       // after
        ])

        #expect(sampled[0] == nil)
        #expect(sampled[1] != nil)
        #expect(sampled[2] != nil)
        #expect(sampled[3] == nil)

        // Halfway through a straight constant-speed walk is halfway along it.
        let midpoint = try #require(sampled[2])
        let expected = (track.first!.position.longitude + track.last!.position.longitude) / 2
        #expect(abs(midpoint.longitude - expected) < 1e-12)
    }

    // MARK: - Files

    @Test("The bundle writes the files a 3D tool needs")
    func bundleContents() throws {
        let fixture = try Fixture(engine: .arkit)
        defer { fixture.cleanUp() }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("scene-out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }

        try SceneBundleExporter(store: fixture.store).write(fixture.metadata, into: output)

        // The Blender importer parses these files in Python. Setting SS_BUNDLE_OUT drops a
        // real bundle where Tools/blender/check_bundle.py can read it, so the contract
        // between the two languages is checked against output rather than against a guess.
        if let dump = ProcessInfo.processInfo.environment["SS_BUNDLE_OUT"] {
            let target = URL(fileURLWithPath: dump, isDirectory: true)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: output, to: target)
        }

        for name in ["frames.csv", "scene.json", "track.gpx", "track.kml",
                     "metadata.json", "README.txt"] {
            #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent(name).path),
                    "missing \(name)")
        }

        let csv = try String(contentsOf: output.appendingPathComponent("frames.csv"),
                             encoding: .utf8)
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
        #expect(lines.count == Fixture.frameCount + 1)
        #expect(lines[0] == SceneBundleExporter.framesHeader)

        let columns = lines[1].split(separator: ",", omittingEmptySubsequences: false)
        #expect(columns.count == SceneBundleExporter.framesHeader
            .split(separator: ",", omittingEmptySubsequences: false).count)
        #expect(columns[0] == "0")

        // Every row has to carry the same number of columns, or the file is unparseable the
        // moment a value goes missing.
        for line in lines.dropFirst() {
            #expect(line.split(separator: ",", omittingEmptySubsequences: false).count
                    == columns.count)
        }
    }

    @Test("The manifest states which frame every number lives in")
    func manifestIsExplicit() throws {
        let fixture = try Fixture(engine: .arkit)
        defer { fixture.cleanUp() }

        let exporter = SceneBundleExporter(store: fixture.store)
        let manifest = exporter.manifest(for: exporter.buildScene(for: fixture.metadata),
                                         metadata: fixture.metadata)

        #expect(manifest.format == SceneManifest.format)
        #expect(manifest.frames.poseSource == PoseSource.arkitVIO.rawValue)
        #expect(manifest.frames.count == Fixture.frameCount)
        #expect(manifest.frames.reliableCount == Fixture.frameCount)
        #expect(manifest.recording.captureEngine == "arkit")
        #expect(manifest.recording.attitudeReferenceFrame == "trueNorth")
        #expect(manifest.coordinateSystem.quaternionOrder == "xyzw")

        let anchor = try #require(manifest.anchor)
        #expect(anchor.lv95IsInRange)
        #expect(abs(anchor.lv95East - 2_600_600) < 1_500)
        // The two heights must not be the same number, or something has collapsed them.
        #expect(anchor.altitudeEllipsoidal - anchor.altitudeOrthometric == Fixture.geoidSeparation)

        // A 1920×1080 frame at fx 1500 is a normal phone lens.
        let fov = try #require(manifest.camera.medianHorizontalFovDegrees)
        #expect(fov > 55 && fov < 75)

        let alignment = try #require(manifest.alignment)
        #expect(abs(alignment.yawDegrees - 20) < 0.5)
        // A noiseless fixture leaves no residual, so the fit reports itself as certain.
        #expect(alignment.trackSpreadMetres > 5)
        #expect(alignment.yawUncertaintyDegrees < 0.1)
    }

    @Test("The GPS track exports as valid-looking GPX and KML")
    func trackFormats() throws {
        let fixture = try Fixture(engine: .arkit)
        defer { fixture.cleanUp() }

        let reader = try #require(fixture.store.reader(for: .location, recording: fixture.metadata.id))
        let track = TrackExporter.track(from: reader)
        #expect(track.count == Fixture.gpsFixCount)

        let gpx = TrackExporter.gpx(track, metadata: fixture.metadata)
        #expect(gpx.hasPrefix("<?xml"))
        #expect(gpx.contains("<gpx version=\"1.1\""))
        #expect(gpx.contains("</gpx>"))
        #expect(gpx.components(separatedBy: "<trkpt").count == track.count + 1)

        // Ellipsoidal height must not leak into <ele>, which is orthometric by convention.
        // Checked numerically: a substring match would pass on a value that merely starts
        // with the right digits.
        let elevations = gpx.components(separatedBy: "<ele>").dropFirst()
            .compactMap { Double($0.prefix(while: { $0 != "<" })) }
        #expect(elevations.count == track.count)
        let ellipsoidal = Fixture.anchor.height + 1
        for elevation in elevations {
            #expect(abs(elevation - (ellipsoidal - Fixture.geoidSeparation)) < 0.01,
                    "expected orthometric height, got \(elevation)")
        }

        let kml = TrackExporter.kml(track, metadata: fixture.metadata)
        #expect(kml.contains("<altitudeMode>absolute</altitudeMode>"))
        #expect(kml.contains("</kml>"))
    }

    @Test("A fix CoreLocation could not resolve is dropped rather than placed at null island")
    func invalidFixesAreSkipped() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensorstorm-track-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = RecordingStore(root: root)
        let id = UUID()
        let directory = try store.prepareDirectory(for: id)
        let writer = try StreamWriter(sensor: .location, channelCount: 10, directory: directory)
        // Accuracy -1 is CoreLocation's "I have nothing".
        writer.append(time: 1, values: [0, 0, 0, 0, -1, -1, -1, -1, -1, -1])
        writer.append(time: 2, values: [46.9, 7.4, 500, 550, 1, 1, 90, 5, 5, 5])
        _ = writer.close()

        let reader = try #require(store.reader(for: .location, recording: id))
        let track = TrackExporter.track(from: reader)
        #expect(track.count == 1)
        #expect(track[0].position.latitude == 46.9)
    }
}
