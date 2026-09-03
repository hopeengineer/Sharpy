// Dead air, measured from the signal — an L1 fact, not a transcript artefact.
//
// This exists because the obvious shortcut does not work. Apple's SpeechAnalyzer returns word
// timings that tile the audio continuously: measured on 88 s of real narration, every gap between
// its words was exactly 0.06 s or 0.12 s — the analyzer's quantisation, not silence — totalling
// 2.0 s across the whole reel. Deriving pauses from word gaps would therefore find nothing, or
// worse, find 28 imaginary ones. Silence is a property of the waveform and has to be measured there.
//
// The level reference follows the project spec: frame at 25 ms, keep frames above −45 dB, take the
// 55th percentile. Using the recording's *own* speech level rather than an absolute threshold is
// what makes this work on a quiet phone recording and a loud studio one without retuning.

import Foundation
import SharpyEngine

public struct SilenceRun: Sendable, Equatable {
    public let range: TimeRange
    /// Mean level of the run, dBFS.
    public let level: Double
    public var duration: TimeValue { range.duration }
}

public struct SpeechProfile: Sendable {
    /// 55th percentile of speech-frame levels, dBFS. The reference every other level is set against.
    public let speechLevel: Double
    /// 10th percentile of all frames — an estimate of the room.
    public let noiseFloor: Double
    /// The threshold silence was judged against.
    public let threshold: Double
    public let runs: [SilenceRun]

    public var totalSilence: TimeValue { runs.reduce(TimeValue.zero) { $0 + $1.duration } }
}

public enum SilenceDetector {
    /// Analyse `url` for dead air.
    ///
    /// - Parameters:
    ///   - belowSpeechLevel: how far under the measured speech level a frame must sit to count as
    ///     silence. 25 dB is conservative: breaths and room tone stay, only real gaps go.
    ///   - minimumDuration: shorter gaps are the rhythm of speech, not dead air.
    ///   - padding: kept either side of every detected run, so cuts never clip a breath or a
    ///     consonant onset. This is why the removed range is narrower than the detected one.
    public static func analyse(url: URL,
                               sampleRate: Int = 48_000,
                               belowSpeechLevel: Double = 25,
                               minimumDuration: TimeValue = TimeValue(seconds: Rational(4, 10)),
                               padding: TimeValue = TimeValue(seconds: Rational(1, 10))) throws -> SpeechProfile {
        let src = try AudioSource(url: url, sampleRate: sampleRate, channels: 1)
        let frameSeconds = Rational(25, 1000)                       // 25 ms, per the spec
        let frameSamples = Int((frameSeconds * Rational(Int64(sampleRate))).rounded)
        let total = src.duration

        // One pass, in one-second reads, collecting per-frame RMS in dBFS.
        var levels: [Double] = []
        var at = TimeValue.zero
        let step = TimeValue(seconds: Rational(1))
        var carry: [Float] = []
        while at < total {
            let end = min(at + step, total)
            carry += try src.read(TimeRange(start: at, end: end))
            while carry.count >= frameSamples {
                var sum = 0.0
                for i in 0..<frameSamples { let v = Double(carry[i]); sum += v * v }
                let rms = sqrt(sum / Double(frameSamples))
                levels.append(rms > 0 ? 20 * log10(rms) : -120)
                carry.removeFirst(frameSamples)
            }
            at = end
        }
        guard !levels.isEmpty else {
            return SpeechProfile(speechLevel: -120, noiseFloor: -120, threshold: -120, runs: [])
        }

        // Speech level: 55th percentile of frames above −45 dB.
        let speechFrames = levels.filter { $0 > -45 }.sorted()
        let speechLevel = speechFrames.isEmpty ? -120 : speechFrames[Int(Double(speechFrames.count - 1) * 0.55)]
        let allSorted = levels.sorted()
        let noiseFloor = allSorted[Int(Double(allSorted.count - 1) * 0.10)]
        let threshold = speechLevel - belowSpeechLevel

        // Contiguous runs under the threshold.
        var runs: [SilenceRun] = []
        var runStart: Int? = nil
        var runSum = 0.0
        func closeRun(_ endFrame: Int) {
            guard let s = runStart else { return }
            let start = TimeValue(seconds: frameSeconds * Rational(Int64(s)))
            let end = TimeValue(seconds: frameSeconds * Rational(Int64(endFrame)))
            let raw = TimeRange(start: start, end: end)
            if minimumDuration < raw.duration {
                // Pad inward: never cut right up to speech.
                let ps = raw.start + padding
                let pe = raw.end.seconds < padding.seconds ? raw.end : raw.end - padding
                if ps < pe {
                    runs.append(SilenceRun(range: TimeRange(start: ps, end: pe),
                                           level: runSum / Double(endFrame - s)))
                }
            }
            runStart = nil; runSum = 0
        }
        for (i, l) in levels.enumerated() {
            if l < threshold {
                if runStart == nil { runStart = i; runSum = 0 }
                runSum += l
            } else {
                closeRun(i)
            }
        }
        closeRun(levels.count)

        return SpeechProfile(speechLevel: speechLevel, noiseFloor: noiseFloor, threshold: threshold, runs: runs)
    }

    /// Ranges to remove to cap every silence at `maximum`, keeping the head of each gap.
    public static func tighteningPlan(_ profile: SpeechProfile, cappingAt maximum: TimeValue) -> [TimeRange] {
        profile.runs.compactMap { run in
            let keepUntil = run.range.start + maximum
            return keepUntil < run.range.end ? TimeRange(start: keepUntil, end: run.range.end) : nil
        }
    }
}
