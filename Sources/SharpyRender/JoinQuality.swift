// Does this join sound like one person talking?
//
// Cutting two pieces of speech together either sounds like a person or sounds like an edit, and the
// difference is measurable. Four things carry it:
//
//   LEVEL      a step in loudness across the join is heard as a bump even when nothing else is wrong
//   PITCH      voices glide; a jump in fundamental frequency is the single most audible tell
//   ROOM       the noise floor either side must match, or the room seems to change mid-sentence
//   CADENCE    the outgoing side should have FINISHED something. A join after a completed phrase
//              works; a join mid-phrase leaves the listener waiting for a word that never comes.
//
// The reason this exists rather than a threshold: whether a line is better taken as one segment or
// two is not a property of the line, it is a property of how the result sounds. So the assembler
// generates candidates and asks this which one to keep — which is the whole point of automating it,
// rather than making somebody choose a similarity number.
//
// Everything here is measured on the actual audio. Nothing is a preference.

import Foundation
import Accelerate
import SharpyEngine

public struct JoinMeasurement: Sendable {
    /// Loudness step across the join, dB. Zero is seamless.
    public let levelStepDb: Double
    /// Fundamental frequency either side, Hz. Nil when the side is unvoiced — a join on silence or
    /// a consonant has no pitch to match, which is a good place to cut rather than a missing
    /// measurement.
    public let pitchBefore: Double?
    public let pitchAfter: Double?
    /// Noise floor difference, dB — whether the room changes across the join.
    public let roomStepDb: Double
    /// Whether the outgoing side falls away, the way a finished phrase does.
    public let outgoingSettles: Bool

    /// Semitones between the two pitches, when both are voiced.
    public var pitchStepSemitones: Double? {
        guard let a = pitchBefore, let b = pitchAfter, a > 0, b > 0 else { return nil }
        return abs(12 * log2(b / a))
    }

    /// Cost of this join, 0 = seamless. Weighted by audibility rather than by convenience:
    /// a pitch jump is the most obvious tell, room change next, level last — a level step is the
    /// one thing that can also be fixed afterwards.
    public var cost: Double {
        var total = 0.0
        total += min(abs(levelStepDb) / 6.0, 1.5)                    // 6 dB is very audible
        total += min(abs(roomStepDb) / 4.0, 1.5)                     // 4 dB of room change is obvious
        if let semitones = pitchStepSemitones {
            total += min(semitones / 2.0, 3.0)                       // 2 semitones is a clear jump
        }
        if !outgoingSettles { total += 1.0 }                         // cutting mid-phrase
        return total
    }

    public var description: String {
        var parts = [String(format: "level %+.1f dB", levelStepDb),
                     String(format: "room %+.1f dB", roomStepDb)]
        if let s = pitchStepSemitones { parts.append(String(format: "pitch %.1f semitones", s)) }
        else { parts.append("pitch n/a (unvoiced — a good place to cut)") }
        if !outgoingSettles { parts.append("cuts mid-phrase") }
        return parts.joined(separator: ", ") + String(format: "  cost %.2f", cost)
    }
}

public enum JoinQuality {
    /// How much audio either side of the join is examined. Long enough to have a pitch period at a
    /// low male fundamental (~70 Hz needs 14 ms), short enough that it is about the JOIN rather
    /// than about the sentence.
    public static let window = 0.12

    /// Measure the join that would be made by butting `outgoing` up against `incoming`.
    public static func measure(source: AudioSource,
                               outgoingEndsAt: TimeValue,
                               incomingStartsAt: TimeValue,
                               sampleRate: Int = 48_000) throws -> JoinMeasurement {
        let w = TimeValue(seconds: Rational(Int64(window * 1000), 1000))
        let beforeStart = outgoingEndsAt.seconds < w.seconds ? TimeValue.zero : outgoingEndsAt - w
        let before = try source.read(TimeRange(start: beforeStart, end: outgoingEndsAt))
        let after = try source.read(TimeRange(start: incomingStartsAt, end: incomingStartsAt + w))
        // A little further back, to see whether the outgoing side was already falling away.
        let runUpStart = outgoingEndsAt.seconds < (w.seconds * Rational(3, 1))
            ? TimeValue.zero : outgoingEndsAt - TimeValue(seconds: w.seconds * Rational(3, 1))
        let runUp = try source.read(TimeRange(start: runUpStart, end: outgoingEndsAt))

        let levelBefore = JoinQuality.rmsDb(before)
        let levelAfter = JoinQuality.rmsDb(after)
        // The quietest tenth either side stands for the room under the speech.
        let roomBefore = JoinQuality.quietDb(before)
        let roomAfter = JoinQuality.quietDb(after)

        // A phrase that has finished falls away: the last third is quieter than the first.
        var settles = true
        if runUp.count >= 6 {
            let third = runUp.count / 3
            let head = JoinQuality.rmsDb(Array(runUp[0..<third]))
            let tail = JoinQuality.rmsDb(Array(runUp[(runUp.count - third)...]))
            settles = tail <= head + 1.0
        }

        return JoinMeasurement(
            levelStepDb: levelAfter - levelBefore,
            pitchBefore: JoinQuality.pitch(before, sampleRate: sampleRate),
            pitchAfter: JoinQuality.pitch(after, sampleRate: sampleRate),
            roomStepDb: roomAfter - roomBefore,
            outgoingSettles: settles)
    }

    static func rmsDb(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return -120 }
        var mean: Float = 0
        vDSP_measqv(samples, 1, &mean, vDSP_Length(samples.count))
        let rms = sqrt(Double(mean))
        return rms > 1e-9 ? 20 * log10(rms) : -120
    }

    /// The quietest tenth, which under speech is the room rather than the voice.
    static func quietDb(_ samples: [Float]) -> Double {
        guard samples.count >= 10 else { return rmsDb(samples) }
        let chunk = max(samples.count / 10, 1)
        var levels: [Double] = []
        var i = 0
        while i + chunk <= samples.count {
            levels.append(rmsDb(Array(samples[i..<(i + chunk)])))
            i += chunk
        }
        return levels.min() ?? rmsDb(samples)
    }

    /// Fundamental frequency by autocorrelation, or nil when the window is unvoiced.
    ///
    /// Autocorrelation rather than anything cleverer because the question is narrow: two windows of
    /// the same person, and whether their pitch matches. A voiced window has a strong periodic peak;
    /// an unvoiced one does not, and reporting nil there is right — a join on a consonant or a
    /// breath has no pitch to mismatch, which makes it a GOOD place to cut.
    static func pitch(_ samples: [Float], sampleRate: Int,
                      lowHz: Double = 65, highHz: Double = 400) -> Double? {
        guard samples.count > 64 else { return nil }
        let minLag = Int(Double(sampleRate) / highHz)
        let maxLag = min(Int(Double(sampleRate) / lowHz), samples.count - 1)
        guard maxLag > minLag else { return nil }

        var mean: Float = 0
        vDSP_meanv(samples, 1, &mean, vDSP_Length(samples.count))
        var centred = samples.map { $0 - mean }
        var energy: Float = 0
        vDSP_measqv(centred, 1, &energy, vDSP_Length(centred.count))
        guard energy > 1e-8 else { return nil }               // silence has no pitch

        var zeroLag: Float = 0
        vDSP_dotpr(centred, 1, centred, 1, &zeroLag, vDSP_Length(centred.count))
        guard zeroLag > 0 else { return nil }

        var bestLag = 0
        var bestValue: Float = 0
        for lag in minLag...maxLag {
            var correlation: Float = 0
            centred.withUnsafeBufferPointer { p in
                vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1,
                           &correlation, vDSP_Length(centred.count - lag))
            }
            if correlation > bestValue { bestValue = correlation; bestLag = lag }
        }
        // Below this the window is noise or a consonant, not a voice.
        let normalised = Double(bestValue / zeroLag)
        guard bestLag > 0, normalised > 0.3 else { return nil }
        return Double(sampleRate) / Double(bestLag)
    }
}
