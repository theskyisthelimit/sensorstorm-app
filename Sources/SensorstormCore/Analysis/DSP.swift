import Foundation

/// A second-order filter section, direct form II transposed — the building block of every
/// filter here. Cascading a few of them makes anything from a high-pass to the A-weighting.
public struct Biquad: Sendable, Equatable {
    public var b0: Double
    public var b1: Double
    public var b2: Double
    public var a1: Double
    public var a2: Double
    private var z1 = 0.0
    private var z2 = 0.0

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    public mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    public mutating func reset() {
        z1 = 0
        z2 = 0
    }

    /// Gain at `frequency` for a stream sampled at `rate`, as a plain factor.
    public func magnitude(at frequency: Double, rate: Double) -> Double {
        let w = 2 * Double.pi * frequency / rate
        let (c1, s1) = (cos(w), -sin(w))
        let (c2, s2) = (cos(2 * w), -sin(2 * w))
        let numeratorRe = b0 + b1 * c1 + b2 * c2
        let numeratorIm = b1 * s1 + b2 * s2
        let denominatorRe = 1 + a1 * c1 + a2 * c2
        let denominatorIm = a1 * s1 + a2 * s2
        let numerator = (numeratorRe * numeratorRe + numeratorIm * numeratorIm).squareRoot()
        let denominator = (denominatorRe * denominatorRe + denominatorIm * denominatorIm).squareRoot()
        return denominator == 0 ? 0 : numerator / denominator
    }

    // MARK: - Designs

    /// A 2nd-order Butterworth high-pass.
    public static func highPass(cutoff: Double, rate: Double) -> Biquad {
        let k = tan(Double.pi * cutoff / rate)
        let q = 1 / 2.0.squareRoot()
        let norm = 1 / (1 + k / q + k * k)
        return Biquad(b0: norm, b1: -2 * norm, b2: norm,
                      a1: 2 * (k * k - 1) * norm, a2: (1 - k / q + k * k) * norm)
    }

    /// A 2nd-order Butterworth low-pass.
    public static func lowPass(cutoff: Double, rate: Double) -> Biquad {
        let k = tan(Double.pi * cutoff / rate)
        let q = 1 / 2.0.squareRoot()
        let norm = 1 / (1 + k / q + k * k)
        return Biquad(b0: k * k * norm, b1: 2 * k * k * norm, b2: k * k * norm,
                      a1: 2 * (k * k - 1) * norm, a2: (1 - k / q + k * k) * norm)
    }
}

/// A chain of sections applied in order.
public struct FilterChain: Sendable, Equatable {
    public var sections: [Biquad]

    public init(_ sections: [Biquad]) {
        self.sections = sections
    }

    public mutating func process(_ x: Double) -> Double {
        var value = x
        for index in sections.indices { value = sections[index].process(value) }
        return value
    }

    public mutating func reset() {
        for index in sections.indices { sections[index].reset() }
    }

    public func magnitude(at frequency: Double, rate: Double) -> Double {
        sections.reduce(1) { $0 * $1.magnitude(at: frequency, rate: rate) }
    }

    /// Band-pass as a high-pass and a low-pass in series. Two sections each, so the slopes are
    /// 24 dB per octave — steep enough that a 0.3 Hz sway does not leak into a vibration figure.
    public static func bandPass(low: Double, high: Double, rate: Double) -> FilterChain {
        FilterChain([Biquad.highPass(cutoff: low, rate: rate), Biquad.highPass(cutoff: low, rate: rate),
                     Biquad.lowPass(cutoff: min(high, rate * 0.45), rate: rate),
                     Biquad.lowPass(cutoff: min(high, rate * 0.45), rate: rate)])
    }

    /// Runs the chain over a series. The filter starts from rest, so the first second or so
    /// carries a start-up transient; the analyses skip it.
    public func apply(to series: TimeSeries) -> TimeSeries {
        var chain = self
        chain.reset()
        return TimeSeries(times: series.times, values: series.values.map { chain.process($0.isFinite ? $0 : 0) })
    }
}

/// The A-weighting curve of IEC 61672, as a digital filter.
///
/// What a sound level meter reports in dB(A): low frequencies are discounted heavily (a
/// 100 Hz tone counts for 19 dB less than the same energy at 1 kHz), because that is how the
/// ear weighs them. Built from the analogue prototype — four zeros at DC, poles at 20.6 Hz
/// (twice), 107.7 Hz, 737.9 Hz and 12.2 kHz (twice) — through a bilinear transform whose
/// poles are pre-warped onto their frequencies, then scaled to 0 dB at 1 kHz.
public enum AWeighting {

    public static func filter(rate: Double) -> FilterChain {
        let c = 2 * rate
        func warped(_ frequency: Double) -> Double {
            // The analogue frequency that lands on `frequency` after the bilinear transform.
            2 * rate * tan(Double.pi * frequency / rate)
        }
        let p1 = warped(20.598997)
        let p2 = warped(107.65265)
        let p3 = warped(737.86223)
        let p4 = warped(12_194.217)

        // s² / ((s + pa)(s + pb)) — two zeros at DC.
        func highSection(_ pa: Double, _ pb: Double) -> Biquad {
            let a0 = (c + pa) * (c + pb)
            let a1 = ((c + pa) * (pb - c) + (pa - c) * (c + pb)) / a0
            let a2 = (pa - c) * (pb - c) / a0
            return Biquad(b0: c * c / a0, b1: -2 * c * c / a0, b2: c * c / a0, a1: a1, a2: a2)
        }
        // p² / (s + p)² — two zeros at Nyquist.
        func lowSection(_ p: Double) -> Biquad {
            let a0 = (c + p) * (c + p)
            let a1 = 2 * (c + p) * (p - c) / a0
            let a2 = (p - c) * (p - c) / a0
            return Biquad(b0: p * p / a0, b1: 2 * p * p / a0, b2: p * p / a0, a1: a1, a2: a2)
        }

        var chain = FilterChain([highSection(p1, p1), highSection(p2, p3), lowSection(p4)])
        // Unity at 1 kHz, which is what „0 dB" means for a weighting curve.
        let gain = chain.magnitude(at: 1_000, rate: rate)
        if gain > 0 {
            chain.sections[2].b0 /= gain
            chain.sections[2].b1 /= gain
            chain.sections[2].b2 /= gain
        }
        return chain
    }

    /// The weighting in dB at `frequency` — what the filter does, for checking it against the
    /// standard's table.
    public static func decibels(at frequency: Double, rate: Double) -> Double {
        20 * log10(filter(rate: rate).magnitude(at: frequency, rate: rate))
    }
}
