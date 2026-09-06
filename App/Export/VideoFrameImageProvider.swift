import AVFoundation
import CoreImage
import Foundation
import ImageIO
import SensorstormCore
import UniformTypeIdentifiers

/// Reads still images out of a recording's movie: the pixel half of the photogrammetry
/// export, kept out of ``SensorstormCore`` so that package stays free of AVFoundation and
/// the derivations above it stay testable without a device.
///
/// **Sequential reads, not random access.** `AVAssetImageGenerator` would be the obvious
/// tool and the wrong one: every seek into HEVC pays a decode from the preceding keyframe,
/// so scoring a few hundred candidates one at a time costs far more than reading the track
/// through twice. Pass one scores, pass two encodes only the winners.
///
/// **Frames are matched by presentation time, never by index.** `ARPoseRecorder` starts the
/// writer session at the first frame's host time, so a sample's presentation time maps back
/// onto a pose exactly. The `frame_index` in the tables is derived from a nominal rate and
/// stops being contiguous the moment ARKit drops a frame — fine as a human-readable label,
/// useless as a join key.
final class VideoFrameImageProvider: PhotogrammetryImageProvider, @unchecked Sendable {
    private let videoURL: URL
    /// `assetTime = hostTime - videoStartHostTime`.
    private let videoStartHostTime: Double
    private let tolerance: Double
    private let quality: Double

    init(videoURL: URL, metadata: RecordingMetadata, quality: Double = 0.92) {
        self.videoURL = videoURL
        self.videoStartHostTime = metadata.video?.startHostTime ?? metadata.startHostTime
        // Half a frame: the closest sample to a requested time, and never the neighbour.
        let rate = metadata.video?.nominalFrameRate ?? 30
        self.tolerance = 0.5 / Double(rate > 0 ? rate : 30)
        self.quality = quality
    }

    // MARK: - Scoring

    func sharpness(of refs: [PhotoFrameRef]) async throws -> [Double] {
        let targets = refs.map { $0.hostTime - videoStartHostTime }
        let url = videoURL
        let tolerance = self.tolerance
        return try await Task.detached(priority: .userInitiated) {
            var scores = [Double](repeating: .nan, count: targets.count)
            try Self.readThrough(url: url) { time, pixelBuffer in
                guard let slot = Self.match(time, in: targets, tolerance: tolerance) else { return }
                let score = Self.laplacianVariance(of: pixelBuffer)
                // The closest sample wins if two land inside the tolerance.
                if scores[slot].isNaN { scores[slot] = score }
            }
            return scores
        }.value
    }

    // MARK: - Writing

    func write(_ requests: [PhotoWriteRequest]) async throws -> [WrittenImage] {
        let targets = requests.map { $0.ref.hostTime - videoStartHostTime }
        let source = videoURL
        let tolerance = self.tolerance
        let quality = self.quality

        return try await Task.detached(priority: .userInitiated) { () -> [WrittenImage] in
            var written = [WrittenImage?](repeating: nil, count: requests.count)
            // One context for the whole batch. Building a `CIContext` is expensive and it
            // is the object that owns the GPU pipeline — one per image would spend more
            // time setting up than encoding.
            let context = CIContext(options: [.useSoftwareRenderer: false])

            try Self.readThrough(url: source) { time, pixelBuffer in
                guard let slot = Self.match(time, in: targets, tolerance: tolerance),
                      written[slot] == nil else { return }
                let image = CIImage(cvPixelBuffer: pixelBuffer)
                guard let cgImage = context.createCGImage(image, from: image.extent) else { return }
                let request = requests[slot]
                Self.encode(cgImage, exif: request.exif, quality: quality, to: request.url)
                written[slot] = WrittenImage(fileName: request.url.lastPathComponent,
                                             pixelWidth: cgImage.width,
                                             pixelHeight: cgImage.height)
            }
            let result = written.compactMap { $0 }
            guard !result.isEmpty else { throw CocoaError(.fileNoSuchFile) }
            return result
        }.value
    }

    // MARK: - Reading

    /// Walks the video track once, handing every decoded frame to `body` with its
    /// presentation time in seconds from the movie's start.
    private static func readThrough(url: URL,
                                    body: (Double, CVPixelBuffer) -> Void) throws {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ])
        // Nothing outlives the callback, so the copy AVFoundation would otherwise make is
        // pure cost — and this runs over every frame of the movie.
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? CocoaError(.fileReadUnknown)
        }
        defer { reader.cancelReading() }

        while let sample = output.copyNextSampleBuffer() {
            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            if let buffer = CMSampleBufferGetImageBuffer(sample) {
                body(time, buffer)
            }
        }
    }

    /// Index of the target this sample belongs to, if any. Targets are ascending, but a
    /// linear scan is not worth optimising: it runs once per decoded frame against a few
    /// hundred entries, next to a hardware decode.
    private static func match(_ time: Double, in targets: [Double], tolerance: Double) -> Int? {
        var best: Int?
        var bestGap = tolerance
        for (index, target) in targets.enumerated() {
            let gap = abs(time - target)
            if gap <= bestGap {
                bestGap = gap
                best = index
            }
        }
        return best
    }

    // MARK: - Sharpness

    /// Variance of the Laplacian over a centred crop of the luma plane, at full resolution.
    ///
    /// The crop rather than a downscale is the point: scaling an image down is itself a
    /// low-pass filter, and it would erase exactly the difference between a sharp frame and
    /// a slightly blurred one — the difference this is measuring. A quarter of the pixels
    /// costs a quarter of the time and keeps the high frequencies.
    ///
    /// The absolute number means nothing — a brick wall always outscores sky — so it is only
    /// ever compared between candidates inside one window, seconds apart, looking at the
    /// same thing. There is deliberately no global threshold.
    static func laplacianVariance(of pixelBuffer: CVPixelBuffer) -> Double {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return .nan
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return .nan }
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let fullWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let fullHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)

        let width = min(960, fullWidth)
        let height = min(720, fullHeight)
        guard width > 2, height > 2 else { return .nan }
        let originX = (fullWidth - width) / 2
        let originY = (fullHeight - height) / 2

        let luma = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0
        var sumOfSquares = 0.0
        var count = 0

        for y in 1..<(height - 1) {
            let row = luma + (originY + y) * bytesPerRow + originX
            let above = row - bytesPerRow
            let below = row + bytesPerRow
            for x in 1..<(width - 1) {
                let value = Double(Int(above[x]) + Int(below[x]) + Int(row[x - 1])
                                   + Int(row[x + 1]) - 4 * Int(row[x]))
                sum += value
                sumOfSquares += value * value
                count += 1
            }
        }
        guard count > 0 else { return .nan }
        let mean = sum / Double(count)
        return max(0, sumOfSquares / Double(count) - mean * mean)
    }

    // MARK: - Encoding

    /// JPEG rather than HEIC, chosen by the destination rather than by the source: on
    /// Windows RealityScan needs an extra HEIF extension, Metashape's support depends on the
    /// version, and Meshroom's depends on how its image library was built. At quality 0.92
    /// the artefacts sit below the noise floor of any feature detector.
    private static func encode(_ image: CGImage, exif: ExifAttributes,
                               quality: Double, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }

        var tiff: [CFString: Any] = [
            kCGImagePropertyTIFFMake: exif.make,
            kCGImagePropertyTIFFModel: exif.model,
            kCGImagePropertyTIFFSoftware: exif.software,
            // Always 1, and load-bearing: the movie is written without a transform so the
            // intrinsics describe the stored pixels. Any other value would have the reader
            // rotate the image while cx/cy stayed where they were.
            kCGImagePropertyTIFFOrientation: 1
        ]
        tiff[kCGImagePropertyTIFFDateTime] = exif.dateTimeOriginal

        var exifDictionary: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: exif.dateTimeOriginal,
            kCGImagePropertyExifPixelXDimension: image.width,
            kCGImagePropertyExifPixelYDimension: image.height,
            kCGImagePropertyExifImageUniqueID: exif.imageUniqueID
        ]
        if let focal = exif.focalLengthIn35mmFilm {
            exifDictionary[kCGImagePropertyExifFocalLenIn35mmFilm] = focal
        }

        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyTIFFDictionary: tiff,
            kCGImagePropertyExifDictionary: exifDictionary
        ]

        if let latitude = exif.latitude, let longitude = exif.longitude {
            var gps: [CFString: Any] = [
                // ImageIO wants the magnitude here and the hemisphere in the Ref.
                kCGImagePropertyGPSLatitude: abs(latitude),
                kCGImagePropertyGPSLatitudeRef: latitude >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(longitude),
                kCGImagePropertyGPSLongitudeRef: longitude >= 0 ? "E" : "W"
            ]
            if let altitude = exif.altitude, altitude.isFinite {
                gps[kCGImagePropertyGPSAltitude] = abs(altitude)
                gps[kCGImagePropertyGPSAltitudeRef] = altitude >= 0 ? 0 : 1
            }
            if let accuracy = exif.horizontalAccuracy, accuracy.isFinite, accuracy > 0 {
                gps[kCGImagePropertyGPSHPositioningError] = accuracy
            }
            if let direction = exif.imageDirection, direction.isFinite {
                gps[kCGImagePropertyGPSImgDirection] = direction
                gps[kCGImagePropertyGPSImgDirectionRef] = "T"
            }
            properties[kCGImagePropertyGPSDictionary] = gps
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
    }
}
