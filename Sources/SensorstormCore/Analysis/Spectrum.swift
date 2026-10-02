import Foundation

/// A short stretch of sound reduced to what a person asks of it: which pitch dominates, and
/// how loud each octave is. A noise record that says only "78 dB" cannot tell a ventilation
/// hum at 100 Hz from a squealing brake at 4 kHz; ten numbers can.
///
/// Plain radix-2 FFT in Swift. The buffers are 4096 samples a few times a second, which a
/// phone does without noticing, and a pure function can be tested against a sine wave.
public enum Spectrum {
    /// Octave band centres, Hz. Each band runs from centre/√2 up to centre·√2.
    public static let octaveCentres: [Double] = [31.5, 63, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]

    public struct Result: Sendable, Equatable {
        public var dominantHz: Double
        /// One level per octave band, in dB relative to a full-scale sine. A full-scale sine
        /// alone in a band reads about −3 dB; silence reads −120.
        public var bandLevels: [Double]
    }

    /// `nil` when there are fewer than 256 samples, or the signal is silent: a dominant
    /// frequency of digital zero is not a measurement.
    public static func analyse(_ samples: [Float], sampleRate: Double) -> Result? {
        var n = 1
        while n * 2 <= samples.count { n *= 2 }
        guard n >= 256, sampleRate > 0 else { return nil }

        let amplitudes = magnitudes(of: Array(samples.suffix(n)))
        guard let peak = amplitudes.enumerated().dropFirst().max(by: { $0.element < $1.element }),
              peak.element > 1e-7 else { return nil }

        // Parabolic interpolation: the peak is rarely exactly on a bin, and at 48 kHz / 4096
        // a bin is 11.7 Hz wide — wider than the difference between two musical notes at
        // the low end.
        let k = peak.offset
        var offset = 0.0
        if k > 1, k < amplitudes.count - 1 {
            let a = Double(amplitudes[k - 1]), b = Double(amplitudes[k]), c = Double(amplitudes[k + 1])
            let denominator = a - 2 * b + c
            if denominator != 0 { offset = max(-0.5, min(0.5, 0.5 * (a - c) / denominator)) }
        }
        let binWidth = sampleRate / Double(n)
        let dominant = (Double(k) + offset) * binWidth

        let levels = octaveCentres.map { centre -> Double in
            let low = centre / 2.0.squareRoot()
            let high = centre * 2.0.squareRoot()
            guard low < sampleRate / 2 else { return -120 }
            var power = 0.0
            for (bin, amplitude) in amplitudes.enumerated().dropFirst() {
                let frequency = Double(bin) * binWidth
                if frequency >= low, frequency < high {
                    power += Double(amplitude) * Double(amplitude) / 2
                }
            }
            return power > 1e-12 ? max(10 * log10(power), -120) : -120
        }
        return Result(dominantHz: dominant, bandLevels: levels)
    }

    /// Amplitude spectrum of a Hann-windowed block, bins 0 … n/2. A sine of amplitude 1 on a
    /// bin reads 1. `samples.count` must be a power of two.
    public static func magnitudes(of samples: [Float]) -> [Float] {
        let n = samples.count
        precondition(n >= 2 && n & (n - 1) == 0, "length must be a power of two")
        var real = [Float](repeating: 0, count: n)
        var imaginary = [Float](repeating: 0, count: n)
        for index in 0..<n {
            let window = 0.5 - 0.5 * Float(cos(2 * Double.pi * Double(index) / Double(n - 1)))
            real[index] = samples[index] * window
        }
        transform(&real, &imaginary)
        // The Hann window's mean is 0.5, so a unit sine peaks at n/2 · 0.5 = n/4.
        let scale = 4 / Float(n)
        return (0...(n / 2)).map { (real[$0] * real[$0] + imaginary[$0] * imaginary[$0]).squareRoot() * scale }
    }

    /// In-place iterative radix-2 FFT.
    static func transform(_ real: inout [Float], _ imaginary: inout [Float]) {
        let n = real.count
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if i < j {
                real.swapAt(i, j)
                imaginary.swapAt(i, j)
            }
        }
        var length = 2
        while length <= n {
            let angle = -2 * Double.pi / Double(length)
            let stepReal = Float(cos(angle)), stepImaginary = Float(sin(angle))
            var start = 0
            while start < n {
                var wReal: Float = 1, wImaginary: Float = 0
                for k in 0..<(length / 2) {
                    let even = start + k, odd = start + k + length / 2
                    let tReal = real[odd] * wReal - imaginary[odd] * wImaginary
                    let tImaginary = real[odd] * wImaginary + imaginary[odd] * wReal
                    real[odd] = real[even] - tReal
                    imaginary[odd] = imaginary[even] - tImaginary
                    real[even] += tReal
                    imaginary[even] += tImaginary
                    let nextReal = wReal * stepReal - wImaginary * stepImaginary
                    wImaginary = wReal * stepImaginary + wImaginary * stepReal
                    wReal = nextReal
                }
                start += length
            }
            length <<= 1
        }
    }
}
