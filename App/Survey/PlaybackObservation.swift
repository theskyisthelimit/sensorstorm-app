import AVFoundation
import Foundation
import SensorstormCore
import UIKit

/// A case written down afterwards, from the recording: the position the phone had at the moment
/// on the slider, and the video frame shown there.
///
/// What a pothole survey from a dashboard camera needs. Nobody stops the car for each one; they
/// drive, and at the desk scrub to the jolt the road analysis flagged and say „this one".
/// Because the case carries the recording's host time, it lines up with every sensor stream of
/// that recording from then on.
enum PlaybackObservation {

    static func makeDraft(metadata: RecordingMetadata, store: RecordingStore, playhead: TimeInterval) async -> FindingDraft? {
        let hostTime = metadata.startHostTime + playhead

        func channel(_ index: Int) -> Double? {
            guard let reader = store.reader(for: .location, recording: metadata.id), reader.channelCount > index else { return nil }
            return TimeSeries(reader: reader, channel: index).value(at: hostTime)
        }
        guard let latitude = channel(0), let longitude = channel(1) else { return nil }
        let coordinate = Coordinate2D(latitude: latitude, longitude: longitude)
        guard coordinate.isValid, !(latitude == 0 && longitude == 0) else { return nil }

        var draft = FindingDraft()
        draft.location = FindingLocation(latitude: latitude, longitude: longitude, altitude: channel(2),
                                         ellipsoidalAltitude: channel(3), horizontalAccuracy: channel(8) ?? -1,
                                         verticalAccuracy: channel(9) ?? -1)
        draft.positionSource = .gps
        draft.hostTime = hostTime
        draft.capturedAt = metadata.startedAt.addingTimeInterval(playhead)
        draft.recordingID = metadata.id

        if let still = await still(metadata: metadata, store: store, playhead: playhead) {
            draft.media = [still]
        }
        return draft
    }

    /// The video frame at `playhead`, as a photo waiting to be saved with the case.
    private static func still(metadata: RecordingMetadata, store: RecordingStore, playhead: TimeInterval) async -> PendingMedia? {
        guard let url = store.videoURL(for: metadata) else { return nil }
        let offset = metadata.video?.offset(from: metadata.startHostTime) ?? 0
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        let time = CMTime(seconds: max(playhead - offset, 0), preferredTimescale: 600)
        guard let (cgImage, _) = try? await generator.image(at: time) else { return nil }
        let image = UIImage(cgImage: cgImage)
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        let thumbnail = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160 * image.size.height / max(image.size.width, 1)))
            .image { _ in image.draw(in: CGRect(origin: .zero, size: CGSize(width: 160, height: 160 * image.size.height / max(image.size.width, 1)))) }
        return PendingMedia(photo: data, thumbnail: thumbnail)
    }
}
