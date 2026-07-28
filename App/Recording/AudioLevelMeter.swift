import AVFoundation
import Accelerate
import Foundation

/// Turns a block of PCM into an average (RMS) and peak level in dBFS.
///
/// Two entry points because the microphone reaches us two different ways: through
/// `AVAudioEngine` when only audio is recorded, and through the capture session's audio
/// output when a video is running. Both end up in the same `loudness` stream, so the unit
/// and the reference level must match exactly — hence one implementation.
enum AudioLevelMeter {
    struct Level: Sendable {
        var average: Double
        var peak: Double
    }

    /// Anything quieter than this is reported as this. Full-scale silence would be -∞ dB,
    /// which no chart can plot.
    static let floorDB: Double = -120

    static func level(from buffer: AVAudioPCMBuffer) -> Level? {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        let frames = vDSP_Length(buffer.frameLength)

        var sumOfSquares: Float = 0
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            var rms: Float = 0
            vDSP_rmsqv(channels[channel], 1, &rms, frames)
            sumOfSquares += rms * rms

            var channelPeak: Float = 0
            vDSP_maxmgv(channels[channel], 1, &channelPeak, frames)
            peak = max(peak, channelPeak)
        }

        let channelCount = max(Int(buffer.format.channelCount), 1)
        let rms = (sumOfSquares / Float(channelCount)).squareRoot()
        return Level(average: decibels(rms), peak: decibels(peak))
    }

    static func level(from sampleBuffer: CMSampleBuffer) -> Level? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        else { return nil }

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, blockBuffer != nil else { return nil }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInt = asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let bitsPerChannel = asbd.mBitsPerChannel

        let buffers = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        var sumOfSquares: Double = 0
        var peak: Double = 0
        var measuredBuffers = 0

        for buffer in buffers {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }

            var rms: Float = 0
            var bufferPeak: Float = 0

            if isFloat, bitsPerChannel == 32 {
                let count = vDSP_Length(buffer.mDataByteSize / 4)
                let pointer = data.assumingMemoryBound(to: Float.self)
                vDSP_rmsqv(pointer, 1, &rms, count)
                vDSP_maxmgv(pointer, 1, &bufferPeak, count)
            } else if isSignedInt, bitsPerChannel == 16 {
                let count = vDSP_Length(buffer.mDataByteSize / 2)
                let pointer = data.assumingMemoryBound(to: Int16.self)
                var floats = [Float](repeating: 0, count: Int(count))
                vDSP_vflt16(pointer, 1, &floats, 1, count)
                var scale = Float(Int16.max)
                vDSP_vsdiv(floats, 1, &scale, &floats, 1, count)
                vDSP_rmsqv(floats, 1, &rms, count)
                vDSP_maxmgv(floats, 1, &bufferPeak, count)
            } else {
                // Unknown PCM layout — better no loudness samples than wrong ones.
                continue
            }

            sumOfSquares += Double(rms) * Double(rms)
            peak = max(peak, Double(bufferPeak))
            measuredBuffers += 1
        }

        guard measuredBuffers > 0 else { return nil }
        let rms = (sumOfSquares / Double(measuredBuffers)).squareRoot()
        return Level(average: decibels(rms), peak: decibels(peak))
    }

    static func decibels(_ amplitude: some BinaryFloatingPoint) -> Double {
        let value = Double(amplitude)
        guard value > 0 else { return floorDB }
        return max(floorDB, 20 * log10(value))
    }
}
