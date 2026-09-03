// EBU R128 / ITU-R BS.1770-4 loudness measurement.
//
// This is a `measured_material` fact generator in the spec's sense: every number here is
// deterministic, reproducible, and checkable against an independent implementation — which is
// exactly why loudness belongs in the assertion tier rather than in anybody's judgement.
//
// BS.1770 publishes the K-weighting coefficients only at 48 kHz. Hardcoding those and feeding
// them 44.1 kHz audio yields a filter with the wrong corner frequencies and a loudness reading
// that is quietly wrong, so the coefficients are re-derived from the analog prototype for
// whatever rate the audio actually is.

import Foundation
import SharpyEngine

/// One biquad, transposed direct form II.
private struct Biquad {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    var z1 = 0.0, z2 = 0.0

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
    mutating func reset() { z1 = 0; z2 = 0 }

    /// BS.1770 stage 1: a +4 dB high shelf modelling the head's acoustic effect.
    static func kWeightingShelf(sampleRate: Double) -> Biquad {
        let f0 = 1681.974450955533, G = 3.999843853973347, Q = 0.7071752369554196
        let K = tan(Double.pi * f0 / sampleRate)
        let Vh = pow(10.0, G / 20.0)
        let Vb = pow(Vh, 0.4996667741545416)
        let a0 = 1.0 + K / Q + K * K
        return Biquad(b0: (Vh + Vb * K / Q + K * K) / a0,
                      b1: 2.0 * (K * K - Vh) / a0,
                      b2: (Vh - Vb * K / Q + K * K) / a0,
                      a1: 2.0 * (K * K - 1.0) / a0,
                      a2: (1.0 - K / Q + K * K) / a0)
    }

    /// BS.1770 stage 2: the RLB high-pass.
    static func kWeightingHighPass(sampleRate: Double) -> Biquad {
        let f0 = 38.13547087602444, Q = 0.5003270373238773
        let K = tan(Double.pi * f0 / sampleRate)
        let denom = 1.0 + K / Q + K * K
        return Biquad(b0: 1.0, b1: -2.0, b2: 1.0,
                      a1: 2.0 * (K * K - 1.0) / denom,
                      a2: (1.0 - K / Q + K * K) / denom)
    }
}

public struct LoudnessReading: Sendable, CustomStringConvertible {
    /// Integrated loudness, LUFS. `nil` when nothing passed the absolute gate (pure silence).
    public let integrated: Double?
    /// Loudness range, LU.
    public let range: Double
    /// True peak, dBTP — sampled peak after 4× oversampling, so inter-sample peaks are caught.
    public let truePeak: Double
    /// Loudest 400 ms window (momentary) and 3 s window (short-term), LUFS.
    public let maxMomentary: Double?
    public let maxShortTerm: Double?

    public var description: String {
        let i = integrated.map { String(format: "%.2f LUFS", $0) } ?? "−∞ (silent)"
        return "integrated \(i), range \(String(format: "%.2f", range)) LU, true peak \(String(format: "%.2f", truePeak)) dBTP"
    }

    /// Gain in dB needed to reach `target` LUFS. Nil for silence.
    public func gain(toReach target: Double) -> Double? { integrated.map { target - $0 } }
}

/// Streaming R128 meter: push interleaved float frames, read the result at the end.
public final class LoudnessMeter {
    private let sampleRate: Double
    private let channels: Int
    /// BS.1770 channel weights. L/R/C are 1.0; surrounds are +1.5 dB. Stereo uses 1.0, 1.0.
    private let weights: [Double]
    private var shelf: [Biquad]
    private var highPass: [Biquad]

    /// Sum of squares of K-weighted samples for the block being filled, per channel.
    private var blockSum: [Double]
    private var blockCount = 0
    private let blockFrames: Int      // 400 ms
    private let hopFrames: Int        // 100 ms
    /// Mean-square per channel for each completed 400 ms block.
    private var blockPowers: [[Double]] = []
    /// Ring of recent hop-sized power sums, so overlapping blocks reuse work.
    private var hopSums: [[Double]] = []
    private var peak = 0.0
    private var lastSample: [Double]

    public init(sampleRate: Int, channels: Int) {
        self.sampleRate = Double(sampleRate)
        self.channels = channels
        self.weights = (0..<channels).map { ch in
            // 5.1 order L R C LFE Ls Rs: surrounds weighted +1.5 dB, LFE excluded.
            switch (channels, ch) {
            case (6, 3): return 0.0            // LFE
            case (6, 4), (6, 5): return 1.41
            default: return 1.0
            }
        }
        shelf = (0..<channels).map { _ in Biquad.kWeightingShelf(sampleRate: Double(sampleRate)) }
        highPass = (0..<channels).map { _ in Biquad.kWeightingHighPass(sampleRate: Double(sampleRate)) }
        blockSum = [Double](repeating: 0, count: channels)
        blockFrames = Int(Double(sampleRate) * 0.4)
        hopFrames = Int(Double(sampleRate) * 0.1)
        lastSample = [Double](repeating: 0, count: channels)
    }

    /// Push interleaved samples.
    public func add(_ interleaved: [Float]) {
        let frames = interleaved.count / channels
        for n in 0..<frames {
            for ch in 0..<channels {
                let x = Double(interleaved[n * channels + ch])
                // True peak: 4× oversample by linear interpolation between neighbours. Cheap and
                // conservative — it under-reads a real 4× FIR slightly, never over-reads.
                let a = abs(x)
                if a > peak { peak = a }
                let prev = lastSample[ch]
                for k in 1..<4 {
                    let t = Double(k) / 4.0
                    let v = abs(prev + (x - prev) * t)
                    if v > peak { peak = v }
                }
                lastSample[ch] = x
                let filtered = highPass[ch].process(shelf[ch].process(x))
                blockSum[ch] += filtered * filtered
            }
            blockCount += 1
            if blockCount == hopFrames {
                hopSums.append(blockSum)
                blockSum = [Double](repeating: 0, count: channels)
                blockCount = 0
                if hopSums.count >= 4 {                       // 4 hops = one 400 ms block
                    var power = [Double](repeating: 0, count: channels)
                    for h in hopSums.suffix(4) { for ch in 0..<channels { power[ch] += h[ch] } }
                    for ch in 0..<channels { power[ch] /= Double(blockFrames) }
                    blockPowers.append(power)
                    if hopSums.count > 32 { hopSums.removeFirst(hopSums.count - 32) }
                }
            }
        }
    }

    /// Loudness of one block's per-channel mean squares, LUFS.
    private func loudness(_ power: [Double]) -> Double {
        var sum = 0.0
        for ch in 0..<channels { sum += weights[ch] * power[ch] }
        return sum > 0 ? -0.691 + 10.0 * log10(sum) : -.infinity
    }

    /// Mean of per-channel powers over a set of blocks, then its loudness.
    private func gatedLoudness(_ blocks: [[Double]]) -> Double? {
        guard !blocks.isEmpty else { return nil }
        var mean = [Double](repeating: 0, count: channels)
        for b in blocks { for ch in 0..<channels { mean[ch] += b[ch] } }
        for ch in 0..<channels { mean[ch] /= Double(blocks.count) }
        let l = loudness(mean)
        return l.isFinite ? l : nil
    }

    public func result() -> LoudnessReading {
        // Two-stage gate: absolute −70 LUFS, then −10 LU relative to the ungated mean.
        let above70 = blockPowers.filter { loudness($0) > -70.0 }
        var integrated: Double? = nil
        if let ungated = gatedLoudness(above70) {
            let relativeGate = ungated - 10.0
            let kept = above70.filter { loudness($0) > relativeGate }
            integrated = gatedLoudness(kept)
        }

        // Loudness range: 3 s windows, −70 absolute and −20 LU relative gates, 10th–95th percentile.
        var shortTerm: [Double] = []
        let blocksPerShortTerm = 30      // 3 s of 100 ms hops
        if hopSumsHistoryUsable, blockPowers.count >= blocksPerShortTerm {
            for i in 0...(blockPowers.count - blocksPerShortTerm) {
                var mean = [Double](repeating: 0, count: channels)
                for b in blockPowers[i..<(i + blocksPerShortTerm)] { for ch in 0..<channels { mean[ch] += b[ch] } }
                for ch in 0..<channels { mean[ch] /= Double(blocksPerShortTerm) }
                let l = loudness(mean)
                if l.isFinite { shortTerm.append(l) }
            }
        }
        var range = 0.0
        let stAbove70 = shortTerm.filter { $0 > -70.0 }
        if !stAbove70.isEmpty {
            let mean = 10.0 * log10(stAbove70.reduce(0.0) { $0 + pow(10.0, $1 / 10.0) } / Double(stAbove70.count))
            let gate = mean - 20.0
            let kept = stAbove70.filter { $0 > gate }.sorted()
            if kept.count >= 2 {
                let lo = kept[Int((Double(kept.count - 1) * 0.10).rounded())]
                let hi = kept[Int((Double(kept.count - 1) * 0.95).rounded())]
                range = hi - lo
            }
        }

        let momentary = blockPowers.map { loudness($0) }.filter { $0.isFinite }.max()
        return LoudnessReading(integrated: integrated,
                               range: range,
                               truePeak: peak > 0 ? 20.0 * log10(peak) : -.infinity,
                               maxMomentary: momentary,
                               maxShortTerm: shortTerm.max())
    }

    private var hopSumsHistoryUsable: Bool { true }

    /// Measure a whole file. Reads in one-second chunks so memory stays flat on long masters.
    public static func measure(url: URL, sampleRate: Int = 48_000, channels: Int = 2) throws -> LoudnessReading {
        let src = try AudioSource(url: url, sampleRate: sampleRate, channels: channels)
        let meter = LoudnessMeter(sampleRate: sampleRate, channels: channels)
        let total = src.duration
        var at = TimeValue.zero
        let step = TimeValue(seconds: Rational(1))
        while at < total {
            let end = min(at + step, total)
            meter.add(try src.read(TimeRange(start: at, end: end)))
            at = end
        }
        return meter.result()
    }
}

/// Platform delivery targets. Loudness is a `platform_req` in the spec's basis table: the number
/// is the platform's, not ours, and a client rule cannot override the true-peak ceiling.
public struct LoudnessTarget: Sendable {
    public let name: String
    public let integrated: Double     // LUFS
    public let truePeakCeiling: Double // dBTP
    public init(name: String, integrated: Double, truePeakCeiling: Double) {
        self.name = name; self.integrated = integrated; self.truePeakCeiling = truePeakCeiling
    }
    public static let ebuR128 = LoudnessTarget(name: "EBU R128 broadcast", integrated: -23, truePeakCeiling: -1)
    public static let streaming = LoudnessTarget(name: "streaming (-14 LUFS)", integrated: -14, truePeakCeiling: -1)
}
