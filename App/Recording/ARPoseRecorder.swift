import ARKit
import AVFoundation
import CoreLocation
import Foundation
import SensorstormCore
import simd
import os

/// The capture path that produces a camera pose, not just a picture.
///
/// `AVCaptureSession` can tell you when a frame arrived and what the lens was doing; it cannot
/// tell you where the camera was. ARKit's visual-inertial odometry can, to centimetres, at
/// frame rate, in metres — which is the whole difference between a video with sensor data
/// attached and a video you can place in a 3D scene.
///
/// Three decisions here are load-bearing:
///
/// - `worldAlignment = .gravityAndHeading` puts the world at **+X east, +Y up, +Z south**, so
///   the poses are georeferenceable without a calibration step. The initial heading comes from
///   the magnetometer and can be several degrees out, but it does not drift afterwards, which
///   is exactly the error a single rigid yaw fit against the GPS track can remove later.
/// - The movie is written from `ARFrame.capturedImage` **unrotated**. `frame.camera.intrinsics`
///   describes that buffer; rotating it on the way to disk would silently invalidate every
///   focal length in the file. Display rotation is a playback concern and stays in metadata.
/// - `frame.timestamp` is already `mach_absolute_time` seconds — the same clock
///   `CMLogItem.timestamp` uses — so the app's synchronisation story survives untouched.
final class ARPoseRecorder: NSObject, @unchecked Sendable {
    let session = ARSession()

    private let sink: SampleSink
    private let sessionQueue = DispatchQueue(label: "ch.sensorstorm.arkit.session")

    // Writer state — only ever touched on `sessionQueue`, which is also the session's
    // delegate queue, so frames and writer lifecycle are serialised against each other.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var hasStartedSession = false
    private var firstFrameHostTime: Double?
    private var lastFrameHostTime: Double?

    private struct State {
        var isRunning = false
        var width = 0
        var height = 0
        var frameRate: Double = 60
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(sink: SampleSink) {
        self.sink = sink
        super.init()
        session.delegate = self
        session.delegateQueue = sessionQueue
    }

    // MARK: - Availability

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.isSupported
    }

    /// `.gravityAndHeading` needs a compass reading, and without location authorisation
    /// ARKit falls back to an arbitrary heading — which produces a scene rotated by an
    /// unknown amount rather than one rotated by a few degrees.
    static var canAlignToHeading: Bool {
        isSupported && CLLocationManager.headingAvailable()
    }

    var isRunning: Bool { state.withLock { $0.isRunning } }

    var videoSize: (width: Int, height: Int) {
        state.withLock { ($0.width, $0.height) }
    }

    // MARK: - Session lifecycle

    func start(quality: VideoQuality) {
        guard Self.isSupported else { return }

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravityAndHeading
        configuration.planeDetection = []
        configuration.environmentTexturing = .none
        // Nothing here renders anything, and both cost frame time that the odometry wants.
        configuration.isLightEstimationEnabled = false

        if let format = Self.videoFormat(for: quality) {
            configuration.videoFormat = format
        }

        // `withLock` takes a `@Sendable` closure, so nothing non-Sendable may cross into it.
        let resolution = configuration.videoFormat.imageResolution
        let width = Int(resolution.width)
        let height = Int(resolution.height)
        let frameRate = Double(configuration.videoFormat.framesPerSecond)
        state.withLock {
            $0.width = width
            $0.height = height
            $0.frameRate = frameRate
            $0.isRunning = true
        }

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        session.pause()
        state.withLock { $0.isRunning = false }
    }

    /// Highest supported format that does not exceed the requested height. ARKit's format
    /// list is device-specific and short, so picking from it beats asking for a preset that
    /// may not exist.
    private static func videoFormat(for quality: VideoQuality) -> ARConfiguration.VideoFormat? {
        let wanted = quality.pixelSize.height
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        let fitting = formats.filter { Int($0.imageResolution.height) <= wanted }
        return (fitting.isEmpty ? formats : fitting)
            .max { $0.imageResolution.height < $1.imageResolution.height }
    }

    // MARK: - Writing

    func startWriting(to url: URL) throws {
        var setupError: Error?
        sessionQueue.sync {
            do {
                try? FileManager.default.removeItem(at: url)
                let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
                let size = state.withLock { ($0.width, $0.height) }

                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.hevc,
                    AVVideoWidthKey: size.0,
                    AVVideoHeightKey: size.1
                ])
                input.expectsMediaDataInRealTime = true
                // No transform: the file is deliberately in the camera's native orientation,
                // because that is the orientation the recorded intrinsics describe.
                guard writer.canAdd(input) else { throw VideoRecorderError.cannotAddOutput }
                writer.add(input)

                self.adaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: input,
                    sourcePixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String:
                            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    ])
                self.writer = writer
                self.videoInput = input
                self.hasStartedSession = false
                self.firstFrameHostTime = nil
                self.lastFrameHostTime = nil
            } catch {
                setupError = error
            }
        }
        if let setupError { throw setupError }
    }

    /// Finishes the movie and returns what the metadata needs.
    func finishWriting() async -> VideoInfo? {
        let pending: (AVAssetWriter, AVAssetWriterInput, Double, Double)? = sessionQueue.sync {
            guard let writer, let videoInput, let start = firstFrameHostTime,
                  let last = lastFrameHostTime, writer.status == .writing else {
                self.writer?.cancelWriting()
                self.writer = nil
                self.videoInput = nil
                self.adaptor = nil
                return nil
            }
            self.writer = nil
            self.videoInput = nil
            self.adaptor = nil
            self.hasStartedSession = false
            return (writer, videoInput, start, last)
        }

        guard let (writer, videoInput, start, last) = pending else { return nil }

        videoInput.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else {
            RecordingLog.error("ARKit writer failed: \(writer.error?.localizedDescription ?? "unknown")")
            return nil
        }

        let current = state.withLock { $0 }
        return VideoInfo(fileName: writer.outputURL.lastPathComponent,
                         startHostTime: start,
                         duration: max(last - start, 0),
                         width: current.width,
                         height: current.height,
                         nominalFrameRate: current.frameRate,
                         hasAudio: false,
                         isFrontCamera: false,
                         appliedRotationAngle: 0,
                         isMirrored: false)
    }
}

// MARK: - Frame delivery

extension ARPoseRecorder: ARSessionDelegate {

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Pose is recorded whether or not a movie is being written: the live view wants it
        // too, and a pose without a frame is still a pose.
        ingestPose(from: frame)

        guard let writer, let videoInput, let adaptor else { return }

        let presentationTime = CMTime(seconds: frame.timestamp, preferredTimescale: 1_000_000_000)

        if writer.status == .unknown {
            guard writer.startWriting() else {
                RecordingLog.error("ARKit writer refused to start: \(writer.error?.localizedDescription ?? "?")")
                self.writer = nil
                return
            }
            writer.startSession(atSourceTime: presentationTime)
            hasStartedSession = true
            firstFrameHostTime = frame.timestamp
        }

        guard writer.status == .writing, hasStartedSession,
              videoInput.isReadyForMoreMediaData else { return }

        if adaptor.append(frame.capturedImage, withPresentationTime: presentationTime) {
            lastFrameHostTime = frame.timestamp
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        RecordingLog.error("ARKit session failed: \(error.localizedDescription)")
        state.withLock { $0.isRunning = false }
    }

    private func ingestPose(from frame: ARFrame) {
        let transform = frame.camera.transform
        let position = transform.columns.3
        // ARKit works in Float; everything downstream is Double, and widening here keeps the
        // conversion in one place instead of scattering casts through the exporter.
        let q = simd_quatf(transform).vector
        let rotation = simd_quatd(ix: Double(q.x), iy: Double(q.y),
                                  iz: Double(q.z), r: Double(q.w))
        let intrinsics = frame.camera.intrinsics
        let (trackingState, reason) = Self.tracking(frame.camera.trackingState)

        sink.ingest(.cameraPose, time: frame.timestamp, values: [
            Double(position.x), Double(position.y), Double(position.z),
            rotation.vector.x, rotation.vector.y, rotation.vector.z, rotation.vector.w,
            Double(intrinsics.columns.0.x),   // fx
            Double(intrinsics.columns.1.y),   // fy
            Double(intrinsics.columns.2.x),   // cx
            Double(intrinsics.columns.2.y),   // cy
            trackingState.rawValue,
            reason.rawValue
        ])
    }

    private static func tracking(
        _ state: ARCamera.TrackingState
    ) -> (CameraTrackingState, CameraTrackingReason) {
        switch state {
        case .normal:
            (.normal, .none)
        case .notAvailable:
            (.notAvailable, .none)
        case .limited(let reason):
            switch reason {
            case .initializing: (.limited, .initializing)
            case .excessiveMotion: (.limited, .excessiveMotion)
            case .insufficientFeatures: (.limited, .insufficientFeatures)
            case .relocalizing: (.limited, .relocalizing)
            @unknown default: (.limited, .none)
            }
        }
    }
}
