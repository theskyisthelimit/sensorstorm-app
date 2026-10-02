import AVFoundation
import Foundation
import SensorstormCore
import SoundAnalysis

/// Names the sound: siren, drill, dog, engine, music — Apple's built-in classifier, on the
/// device, with no network and no recording of what was heard.
///
/// A level meter says how loud. For a noise complaint the next question is what, and "a
/// circular saw between 14:02 and 14:09" settles an argument that "81 dB" does not. Results
/// become notes in the recording, one when the sound changes, not one per second.
final class SoundClassifier: NSObject, SNResultsObserving, @unchecked Sendable {
    typealias Handler = @Sendable (_ time: Double, _ label: String, _ confidence: Double) -> Void

    /// Below this the classifier is guessing, and a note that says "siren (41 %)" is noise.
    static let minimumConfidence = 0.6
    /// The same sound again is repeated at most this often.
    static let repeatInterval = 30.0

    private let analyzer: SNAudioStreamAnalyzer
    private let handler: Handler
    private let lock = NSLock()
    private var lastLabel: String?
    private var lastTime = -Double.infinity

    init(format: AVAudioFormat, handler: @escaping Handler) throws {
        analyzer = SNAudioStreamAnalyzer(format: format)
        self.handler = handler
        super.init()
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        try analyzer.add(request, withObserver: self)
    }

    func analyze(_ buffer: AVAudioPCMBuffer, atFrame frame: AVAudioFramePosition) {
        analyzer.analyze(buffer, atAudioFramePosition: frame)
    }

    func finish() {
        analyzer.removeAllRequests()
    }

    /// Identifiers come as `snake_case` English: `speech`, `car_horn`. Readable, not translated —
    /// the classifier's own vocabulary is what a person can look up.
    static func readable(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: " ")
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult,
              let top = result.classifications.first,
              top.confidence >= Self.minimumConfidence,
              top.identifier != "silence" else { return }
        let now = HostClock.now
        let label = Self.readable(top.identifier)
        let emit = lock.withLock { () -> Bool in
            let changed = label != lastLabel
            guard changed || now - lastTime >= Self.repeatInterval else { return false }
            lastLabel = label
            lastTime = now
            return true
        }
        if emit { handler(now, label, top.confidence) }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        RecordingLog.warn("sound classification failed: \(error.localizedDescription)")
    }
}
