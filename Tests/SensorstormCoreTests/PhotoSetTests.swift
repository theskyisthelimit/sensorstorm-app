import Foundation
import Testing
import simd
@testable import SensorstormCore

@Suite("Bilder für Fotogrammetrie")
struct PhotoSetTests {

    /// Writes a placeholder byte per image and hands back canned scores. Everything except
    /// the pixels is covered by this; the pixels are covered by exporting a real recording
    /// on a device, which no CI machine can do.
    final class StubProvider: PhotogrammetryImageProvider, @unchecked Sendable {
        /// Sharpness as a function of frame index, so a test can decide who should win.
        let score: @Sendable (Int) -> Double
        private(set) var exifByName: [String: ExifAttributes] = [:]

        init(score: @escaping @Sendable (Int) -> Double = { _ in 1 }) {
            self.score = score
        }

        func sharpness(of refs: [PhotoFrameRef]) async throws -> [Double] {
            refs.map { score($0.videoFrameIndex) }
        }

        func write(_ requests: [PhotoWriteRequest]) async throws -> [WrittenImage] {
            try requests.map { request in
                exifByName[request.url.lastPathComponent] = request.exif
                try Data("jpeg".utf8).write(to: request.url, options: .atomic)
                return WrittenImage(fileName: request.url.lastPathComponent,
                                    pixelWidth: 1920, pixelHeight: 1440)
            }
        }
    }

    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensorstorm-photos-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Auswahl

    @Test("Das Bündel enthält Bilder, die Tabelle und das COLMAP-Modell")
    func bundleContents() async throws {
        let fixture = try SceneBundleTests.Fixture(engine: .arkit)
        defer { fixture.cleanUp() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try await PhotoSetExporter(store: fixture.store).write(
            fixture.metadata, options: PhotoSetOptions(targetCount: 20, subject: .terrain),
            provider: StubProvider(), into: folder)

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names.contains("images"))
        #expect(names.contains(PhotoSetCSV.fileName))
        #expect(names.contains("colmap"))
        #expect(names.contains("README.txt"))
        #expect(names.contains("metadata.json"))
        #expect(names.contains("track.gpx"))

        let images = try FileManager.default
            .contentsOfDirectory(atPath: folder.appendingPathComponent("images").path)
        #expect(!images.isEmpty)
        #expect(images.allSatisfy { $0.hasSuffix(".jpg") })

        let colmap = try FileManager.default
            .contentsOfDirectory(atPath: folder.appendingPathComponent("colmap").path).sorted()
        #expect(colmap == ["cameras.txt", "images.txt", "points3D.txt"])
    }

    @Test("Jede Zeile der Tabelle hat so viele Felder wie die Kopfzeile")
    func csvIsRectangular() async throws {
        let fixture = try SceneBundleTests.Fixture(engine: .arkit)
        defer { fixture.cleanUp() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try await PhotoSetExporter(store: fixture.store).write(
            fixture.metadata, options: PhotoSetOptions(targetCount: 20, subject: .terrain),
            provider: StubProvider(), into: folder)

        let text = try String(contentsOf: folder.appendingPathComponent(PhotoSetCSV.fileName),
                              encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.first.map(String.init) == PhotoSetCSV.header)
        let expected = PhotoSetCSV.header.split(separator: ",", omittingEmptySubsequences: false).count
        for line in lines.dropFirst() {
            #expect(line.split(separator: ",", omittingEmptySubsequences: false).count == expected)
        }
    }

    /// The camera walks 20 m in the fixture. At the terrain preset — 1.5 m between images —
    /// nothing like one image per frame may come out.
    @Test("Der Mindestabstand begrenzt die Zahl der Bilder")
    func baselineLimitsCount() async throws {
        let fixture = try SceneBundleTests.Fixture(engine: .arkit)
        defer { fixture.cleanUp() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try await PhotoSetExporter(store: fixture.store).write(
            fixture.metadata, options: PhotoSetOptions(targetCount: 300, subject: .terrain),
            provider: StubProvider(), into: folder)

        let images = try FileManager.default
            .contentsOfDirectory(atPath: folder.appendingPathComponent("images").path)
        // 20 m of travel at 1.5 m minimum spacing cannot yield more than ~14 images.
        #expect(images.count <= 15)
        #expect(images.count >= 5)
    }

    @Test("Ein nicht dekodierbares Bild wird übersprungen, nicht als unscharf gewertet")
    func undecodableIsSkipped() async throws {
        let fixture = try SceneBundleTests.Fixture(engine: .arkit)
        defer { fixture.cleanUp() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // Every candidate fails to decode: the export must refuse rather than write zero
        // images into a bundle that claims to contain some.
        await #expect(throws: PhotoSetExporter.PhotoSetError.self) {
            try await PhotoSetExporter(store: fixture.store).write(
                fixture.metadata, options: PhotoSetOptions(targetCount: 20),
                provider: StubProvider(score: { _ in .nan }), into: folder)
        }
    }

    // MARK: - EXIF

    /// The one that catches the classic ~50 m float: EXIF `GPSAltitude` is defined above sea
    /// level, and the fixture bakes in a 50 m geoid separation so the two heights cannot be
    /// confused by accident.
    @Test("GPSAltitude ist orthometrisch, nicht ellipsoidisch")
    func exifAltitudeIsOrthometric() async throws {
        let fixture = try SceneBundleTests.Fixture(engine: .arkit)
        defer { fixture.cleanUp() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let provider = StubProvider()
        try await PhotoSetExporter(store: fixture.store).write(
            fixture.metadata, options: PhotoSetOptions(targetCount: 10, subject: .terrain),
            provider: provider, into: folder)

        let exif = try #require(provider.exifByName.values.first)
        let altitude = try #require(exif.altitude)
        // The fixture walks one metre above the anchor's ellipsoidal height of 590 m, with
        // 50 m of separation — so orthometric lands near 541, ellipsoidal near 591.
        #expect(abs(altitude - 541) < 2)
    }

    @Test("Die 35-mm-Brennweite lässt sich zurückrechnen")
    func focal35RoundTrips() throws {
        let intrinsics = CameraIntrinsics(fx: 1500, fy: 1500, cx: 960, cy: 540,
                                          imageWidth: 1920, imageHeight: 1080)
        let f35 = try #require(ExifAttributes.focal35(intrinsics))
        #expect(f35 == 28)
        // What a consumer does with it: fx = f35 · längere Kante / 36.
        #expect(abs(Double(f35) * 1920 / 36 - 1500) < 30)
    }

    // MARK: - COLMAP, nachgerechnet

    /// The only assertion here that is a real check rather than a shape check.
    ///
    /// A world point is projected through exactly what `images.txt` and `cameras.txt` say,
    /// using COLMAP's own convention, and has to land where the camera is looking. A
    /// transposed rotation, the wrong axis flip and `T = C` instead of `T = −R·C` all fail
    /// this, and none of them is visible by reading the file.
    @Test("Ein Weltpunkt projiziert durch das COLMAP-Modell auf die erwartete Bildstelle")
    func colmapProjectionIsCorrect() {
        // Camera at the origin looking due east, level, upright, in an east/north/up world.
        // Written as its three axes rather than as a composition of turns, because the
        // point of this test is the exporter's convention, not mine.
        //   camera +X = image right  = south
        //   camera +Y = image up     = up
        //   camera +Z = behind it    = west   (the view direction is −Z)
        let q = simd_quatd(simd_double3x3(columns: (SIMD3<Double>(0, -1, 0),
                                                    SIMD3<Double>(0, 0, 1),
                                                    SIMD3<Double>(-1, 0, 0))))
        let intrinsics = CameraIntrinsics(fx: 1000, fy: 1000, cx: 500, cy: 400,
                                          imageWidth: 1000, imageHeight: 800)
        let pose = CameraPose(hostTime: 0, videoFrameIndex: 0,
                              position: ENU(east: 0, north: 0, up: 0),
                              orientation: q, intrinsics: intrinsics,
                              trackingState: .normal, trackingReason: .none)

        // Sanity: the camera really is looking east.
        let forward = q.act(SIMD3<Double>(0, 0, -1))
        #expect(abs(forward.x - 1) < 1e-9)

        let (rotation, translation) = ColmapModel.worldToCamera(pose)
        // Ten metres due east, dead ahead: must project onto the principal point.
        let world = SIMD3<Double>(10, 0, 0)
        let camera = rotation.act(world) + translation
        #expect(camera.z > 0)                       // COLMAP looks down +Z
        let u = intrinsics.fx * camera.x / camera.z + intrinsics.cx
        let v = intrinsics.fy * camera.y / camera.z + intrinsics.cy
        #expect(abs(u - intrinsics.cx) < 1e-6)
        #expect(abs(v - intrinsics.cy) < 1e-6)

        // And a point above the axis has to land *above* the centre, i.e. at a smaller v,
        // because COLMAP's +Y points down the image.
        let above = rotation.act(SIMD3<Double>(10, 0, 1)) + translation
        #expect(intrinsics.fy * above.y / above.z + intrinsics.cy < intrinsics.cy)
    }

    @Test("Das Quaternion des COLMAP-Modells ist normiert")
    func colmapQuaternionIsUnit() {
        let q = simd_quatd(angle: 0.7, axis: simd_normalize(SIMD3<Double>(0.2, 0.3, 0.9)))
        let pose = CameraPose(hostTime: 0, videoFrameIndex: 0,
                              position: ENU(east: 12, north: -3, up: 1.5),
                              orientation: q,
                              intrinsics: CameraIntrinsics(fx: 1500, fy: 1500, cx: 960, cy: 720,
                                                           imageWidth: 1920, imageHeight: 1440),
                              trackingState: .normal, trackingReason: .none)
        let (rotation, _) = ColmapModel.worldToCamera(pose)
        #expect(abs(simd_length(rotation.vector) - 1) < 1e-9)
    }

    // MARK: - Der klassische Pfad

    /// Without ARKit there is no observed viewing direction. The bundle still has to be
    /// useful — geotagged stills are perfectly good photogrammetry input — but it must not
    /// hand a solver a rotation nobody measured.
    @Test("Ohne ARKit gibt es Bilder und GPS, aber keine Posen-Vorgabe")
    func classicPathDegrades() async throws {
        let fixture = try SceneBundleTests.Fixture(engine: .classic)
        defer { fixture.cleanUp() }
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let provider = StubProvider()
        try await PhotoSetExporter(store: fixture.store).write(
            fixture.metadata, options: PhotoSetOptions(targetCount: 10),
            provider: provider, into: folder)

        let images = try FileManager.default
            .contentsOfDirectory(atPath: folder.appendingPathComponent("images").path)
        #expect(!images.isEmpty)

        let colmap = try FileManager.default
            .contentsOfDirectory(atPath: folder.appendingPathComponent("colmap").path).sorted()
        #expect(colmap == ["cameras.txt", "points3D.txt"])

        let exif = try #require(provider.exifByName.values.first)
        #expect(exif.latitude != nil)               // GPS is real on this path
        #expect(exif.imageDirection == nil)         // the viewing direction is not
    }
}
