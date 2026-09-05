// The half-line somebody abandons and says again.
//
// Different from a re-take, and it needs different treatment. A re-take is another attempt at a
// whole line, recorded later, and the job is to choose between them. A self-correction happens
// INSIDE the flow: the speaker starts, hears it come out wrong, and immediately says it again —
//
//     "Took me three rounds, took me eight rounds to work out…"
//     "So now there is one thing. So now there is one line I use."
//     "My best guess Claude couldn't my best guess Claude couldn't hear the audio."
//
// Every one of those is a single sentence in the transcript, so the take machinery never sees them.
// The abandoned half is not a worse take to be scored — it is not meant to be there at all, and
// leaving it in makes an otherwise fluent piece sound like a first rehearsal.
//
// The rule is always keep the LATER attempt. Somebody who restarts a line is correcting it, and the
// correction is the version they meant. Reversing that would keep the mistake and cut the fix.

import Foundation
import SharpyEngine

public struct Correction: Sendable {
    /// The abandoned attempt — this is what gets cut.
    public let abandoned: TimeRange
    public let abandonedWords: ClosedRange<Int>
    /// The attempt that replaces it.
    public let kept: TimeRange
    public let similarity: Double
    public let text: String

    public var seconds: Double { abandoned.duration.seconds.doubleValue }

    public var description: String {
        String(format: "%6.2f–%6.2f s  cut \"%@\" (%.0f%% match to the retry that follows)",
               abandoned.start.seconds.doubleValue, abandoned.end.seconds.doubleValue,
               text.prefix(46) as CVarArg, similarity * 100)
    }
}

public struct CorrectionReport: Sendable {
    public let corrections: [Correction]
    public let totalWords: Int
    public var secondsRemoved: Double { corrections.reduce(0) { $0 + $1.seconds } }

    public var summary: String {
        guard !corrections.isEmpty else { return "corrections: none — nothing was restarted" }
        var lines = [String(format: "corrections: %d restart(s), %.1f s to cut",
                            corrections.count, secondsRemoved)]
        for c in corrections.prefix(15) { lines.append("  " + c.description) }
        if corrections.count > 15 { lines.append("  … \(corrections.count - 15) more") }
        return lines.joined(separator: "\n")
    }
}

public enum SelfCorrectionFinder {
    /// How alike two adjacent stretches must be to read as one restarted.
    public static let defaultSimilarity = 0.7
    /// A restart follows immediately. A similar phrase a minute later is a callback, not a fumble.
    public static let maximumGap = 2.5

    public static func find(in transcript: Transcript,
                            minimumSimilarity: Double = defaultSimilarity,
                            maximumGap: Double = maximumGap,
                            shortest: Int = 2, longest: Int = 12) -> CorrectionReport {
        let words = transcript.words.sorted { $0.index < $1.index }
        let keys = words.map { TakeSelector.key($0.text) }
        var corrections: [Correction] = []
        var consumed = Set<Int>()

        var i = 0
        while i < words.count {
            if consumed.contains(i) { i += 1; continue }
            var best: (length: Int, score: Double, end: Int)?
            // The two attempts need not be the same LENGTH. The user's own description: "I say it
            // wrong, then I keep going saying the wrong thing, then I say the right thing without
            // pausing." The abandoned run can be longer or shorter than the fix, and comparing
            // equal windows only ever caught the tidy case where somebody repeats an exact phrase.
            //
            // LONGEST abandoned run first, so a fumble is cut whole rather than as a fragment
            // inside it, which would leave the rest of the wrong version in.
            for length in stride(from: longest, through: shortest, by: -1) {
                let firstEnd = i + length
                guard firstEnd < words.count else { continue }
                // No pause is required between them — that is the case being caught — but a long
                // silence means the speaker moved on rather than corrected themselves.
                let gap = words[firstEnd].range.start.seconds.doubleValue
                        - words[firstEnd - 1].range.end.seconds.doubleValue
                guard gap <= maximumGap else { continue }
                for retryLength in stride(from: longest, through: shortest, by: -1) {
                    let secondEnd = firstEnd + retryLength
                    guard secondEnd <= words.count else { continue }
                    let score = TakeSelector.similarity(Array(keys[i..<firstEnd]),
                                                        Array(keys[firstEnd..<secondEnd]))
                    // Length alone must not decide it: a longer window can score higher simply by
                    // covering more, so a clearly better match wins and ties go to the longer
                    // abandoned run.
                    if score >= minimumSimilarity, score > (best?.score ?? 0) + 0.001 {
                        best = (length, score, secondEnd)
                    }
                }
            }
            guard let best else { i += 1; continue }
            let firstEnd = i + best.length
            corrections.append(Correction(
                abandoned: TimeRange(start: words[i].range.start, end: words[firstEnd - 1].range.end),
                abandonedWords: words[i].index...words[firstEnd - 1].index,
                kept: TimeRange(start: words[firstEnd].range.start, end: words[best.end - 1].range.end),
                similarity: best.score,
                text: words[i..<firstEnd].map(\.text).joined(separator: " ")))
            for k in i..<firstEnd { consumed.insert(k) }
            // Resume at the KEPT attempt, not past it: it may itself have been restarted again, and
            // people do fumble a line three times.
            i = firstEnd
        }
        return CorrectionReport(corrections: corrections, totalWords: words.count)
    }
}
