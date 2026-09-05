// Five takes of the same thing. Which sentence from which one?
//
// This is the job the person actually does by hand: record the piece five or six times, watch them
// all, keep the best run of each line, stitch. It is slow, it is the reason they run out of time,
// and — unlike most editing — it is largely a comparison between things that are *supposed* to be
// identical. That makes it measurable.
//
// The takes share a script, so they align by TRANSCRIPT rather than by time: the same sentence sits
// at 0:12 in one take and 0:19 in another, and nothing about the clock relates them. Once aligned,
// each take's rendition of a sentence can be compared with every other take's on axes that are
// actually measured:
//
//   fluency    fillers, restarts, and mid-sentence stalls — the things that make a line sound
//              unsure, counted rather than judged
//   clarity    the ASR engines' own per-word confidence. Two independent models hesitating on the
//              same word is good evidence it was mumbled
//   audio      speech-to-room separation over that sentence, and whether it clipped
//   framing    whether the subject is in frame, steady, and the same size as elsewhere
//
// What this deliberately does NOT do is claim to judge confidence, warmth or charisma. It measures
// four proxies and says which one drove each choice, so a person disagreeing with a pick can see
// exactly what it was reasoning from and overrule it. A tool that said "take 3 sounded more
// confident" would be inventing an authority it does not have.

import Foundation
import SharpyEngine
import SharpyRender

public struct Take: Sendable {
    public let index: Int
    public let url: URL
    public let transcript: Transcript
    public let vision: VisionIndex?
    public let speech: SpeechProfile?

    public init(index: Int, url: URL, transcript: Transcript,
                vision: VisionIndex? = nil, speech: SpeechProfile? = nil) {
        self.index = index; self.url = url; self.transcript = transcript
        self.vision = vision; self.speech = speech
    }
}

/// One sentence, as rendered by one take.
public struct Rendition: Sendable {
    public let takeIndex: Int
    public let range: TimeRange
    public let words: [Word]

    /// 0…1, higher is better on each axis.
    public let fluency: Double
    public let clarity: Double
    public let audio: Double
    public let framing: Double?

    /// Why this rendition scored as it did, in words. Present whether it wins or loses, because
    /// "why not the one I liked" is the question a person actually asks.
    public let notes: [String]

    /// Framing is optional — a take with no Vision pass is not penalised for it, it simply has one
    /// fewer axis. Scoring a missing measurement as zero would quietly rank takes by which ones
    /// happened to be indexed.
    public var score: Double {
        var parts = [fluency, clarity, audio]
        if let framing { parts.append(framing) }
        return parts.reduce(0, +) / Double(parts.count)
    }
}

public struct SentenceChoice: Sendable {
    public let text: String
    public let chosen: Rendition
    public let alternatives: [Rendition]
    /// The axis that actually decided it, and by how much.
    public let decidedBy: String

    public var description: String {
        var lines = [String(format: "take %d  %.2f–%.2f  \"%@\"",
                            chosen.takeIndex, chosen.range.start.seconds.doubleValue,
                            chosen.range.end.seconds.doubleValue,
                            text.count > 68 ? String(text.prefix(68)) + "…" : text)]
        lines.append("     chosen on \(decidedBy)")
        for note in chosen.notes.prefix(2) { lines.append("     · " + note) }
        if let runnerUp = alternatives.first {
            lines.append(String(format: "     next best take %d at %.2f (this one %.2f)",
                                runnerUp.takeIndex, runnerUp.score, chosen.score))
        }
        return lines.joined(separator: "\n")
    }
}

public struct TakeSelection: Sendable {
    public let choices: [SentenceChoice]
    /// Sentences that appear in some takes and not others. Reported rather than silently dropped:
    /// a line only one take has may be the best thing in the piece, or a fluff nobody meant to keep.
    public let inconsistent: [String]
    public let takeCount: Int

    public var takesUsed: Set<Int> { Set(choices.map(\.chosen.takeIndex)) }

    public var summary: String {
        guard !choices.isEmpty else { return "takes: nothing aligned across \(takeCount) take(s)" }
        var lines = ["takes: \(choices.count) sentence(s) across \(takeCount) take(s), "
                     + "drawing on \(takesUsed.count) of them"]
        var perTake: [Int: Int] = [:]
        for choice in choices { perTake[choice.chosen.takeIndex, default: 0] += 1 }
        lines.append("  " + perTake.sorted { $0.key < $1.key }
            .map { "take \($0.key): \($0.value)" }.joined(separator: ", "))
        for choice in choices { lines.append("  " + choice.description) }
        if !inconsistent.isEmpty {
            lines.append("  \(inconsistent.count) line(s) are not in every take — check these yourself:")
            for line in inconsistent.prefix(5) { lines.append("     · \"\(line.prefix(60))\"") }
        }
        return lines.joined(separator: "\n")
    }
}

public enum TakeSelector {
    /// Words compared after normalising, so punctuation and case do not split one sentence into two.
    static func key(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
            .split(separator: " ").joined(separator: " ")
    }

    public static func select(takes: [Take],
                              fillerPenalty: Double = 0.25,
                              stallSeconds: Double = 0.55) -> TakeSelection {
        guard takes.count > 1 else {
            return TakeSelection(choices: [], inconsistent: [], takeCount: takes.count)
        }
        // Sentences per take, keyed by normalised text. A repeated sentence within one take keeps
        // only its LAST rendition — when somebody fluffs a line and says it again, the second one
        // is the one they meant.
        var byKey: [String: [Rendition]] = [:]
        var order: [String] = []
        var textForKey: [String: String] = [:]

        for take in takes {
            for segment in take.transcript.segments() {
                let k = key(segment.text)
                guard !k.isEmpty else { continue }
                if textForKey[k] == nil { textForKey[k] = segment.text; order.append(k) }
                let words = take.transcript.words.filter {
                    $0.index >= segment.firstWord && $0.range.start < segment.range.end
                }
                guard !words.isEmpty else { continue }
                let rendition = score(words: words, range: segment.range, take: take,
                                      fillerPenalty: fillerPenalty, stallSeconds: stallSeconds)
                byKey[k, default: []].removeAll { $0.takeIndex == take.index }
                byKey[k, default: []].append(rendition)
            }
        }

        var choices: [SentenceChoice] = []
        var inconsistent: [String] = []
        for k in order {
            guard let renditions = byKey[k], let text = textForKey[k] else { continue }
            if renditions.count < takes.count { inconsistent.append(text) }
            guard renditions.count > 1 else { continue }
            let ranked = renditions.sorted { $0.score > $1.score }
            let winner = ranked[0], runnerUp = ranked[1]
            choices.append(SentenceChoice(text: text, chosen: winner,
                                          alternatives: Array(ranked.dropFirst()),
                                          decidedBy: decidingAxis(winner, runnerUp)))
        }
        return TakeSelection(choices: choices, inconsistent: inconsistent, takeCount: takes.count)
    }

    /// The axis on which the winner beat the runner-up by most. Naming it matters: "chosen on
    /// clarity" is arguable and "chosen because it scored higher" is not.
    static func decidingAxis(_ winner: Rendition, _ runnerUp: Rendition) -> String {
        var gaps: [(String, Double)] = [
            ("fluency — fewer stumbles", winner.fluency - runnerUp.fluency),
            ("clarity — the engines were surer of the words", winner.clarity - runnerUp.clarity),
            ("sound — cleaner voice against the room", winner.audio - runnerUp.audio),
        ]
        if let a = winner.framing, let b = runnerUp.framing {
            gaps.append(("framing — better held in shot", a - b))
        }
        let best = gaps.max { $0.1 < $1.1 }!
        return best.1 <= 0.001 ? "a near tie — any of these would do" : best.0
    }

    static func score(words: [Word], range: TimeRange, take: Take,
                      fillerPenalty: Double, stallSeconds: Double) -> Rendition {
        var notes: [String] = []

        // Fluency: fillers, restarts (the same word twice running), and mid-sentence stalls.
        let fillers = words.filter(\.isFiller).count
        var restarts = 0
        for (a, b) in zip(words, words.dropFirst())
        where key(a.text) == key(b.text) && !key(a.text).isEmpty { restarts += 1 }
        var stalls = 0
        for (a, b) in zip(words, words.dropFirst()) {
            let gap = b.range.start.seconds.doubleValue - a.range.end.seconds.doubleValue
            if gap > stallSeconds { stalls += 1 }
        }
        let stumbles = Double(fillers + restarts + stalls)
        let fluency = max(0, 1 - stumbles * fillerPenalty)
        if fillers > 0 { notes.append("\(fillers) filler(s)") }
        if restarts > 0 { notes.append("\(restarts) repeated word(s) — a restart") }
        if stalls > 0 { notes.append("\(stalls) mid-sentence stall(s) over \(String(format: "%.2f", stallSeconds)) s") }

        // Clarity: the engines' own per-word confidence. Two independent models hesitating on the
        // same word is real evidence it was mumbled, and it costs nothing extra to read.
        let clarity = words.isEmpty ? 0
            : words.map { $0.confidence.doubleValue }.reduce(0, +) / Double(words.count)
        if clarity < 0.7 { notes.append(String(format: "the engines were unsure of these words (%.2f)", clarity)) }

        // Audio: separation over this sentence against the take's own room.
        var audio = 0.5
        if let profile = take.speech {
            let separation = profile.speechLevel - profile.noiseFloor
            audio = min(1, max(0, (separation - 10) / 25))     // 10 dB poor … 35 dB excellent
            if separation < 18 { notes.append(String(format: "only %.0f dB between voice and room", separation)) }
        }

        // Framing: is the subject actually in shot for this sentence, and steadily so.
        var framing: Double?
        if let vision = take.vision, !vision.frames.isEmpty {
            let inSentence = vision.frames.filter { range.contains($0.time) }
            if !inSentence.isEmpty {
                let withFace = inSentence.filter { !$0.faces.isEmpty }
                let presence = Double(withFace.count) / Double(inSentence.count)
                // Steadiness: how much the face box moves. A drifting frame reads as amateur even
                // when nothing is technically wrong.
                var drift = 0.0
                let centres = withFace.compactMap { f -> (Double, Double)? in
                    guard let face = f.faces.first else { return nil }
                    return (face.x + face.width / 2, face.y + face.height / 2)
                }
                if centres.count > 1 {
                    let meanX = centres.map(\.0).reduce(0, +) / Double(centres.count)
                    let meanY = centres.map(\.1).reduce(0, +) / Double(centres.count)
                    drift = centres.map { abs($0.0 - meanX) + abs($0.1 - meanY) }.reduce(0, +)
                        / Double(centres.count) / Double(max(vision.width, 1))
                }
                framing = max(0, min(1, presence * (1 - min(drift * 4, 1))))
                if presence < 0.9 { notes.append(String(format: "subject out of frame for %.0f%% of this line", (1 - presence) * 100)) }
                if drift > 0.05 { notes.append("the framing drifts through this line") }
            }
        }

        return Rendition(takeIndex: take.index, range: range, words: words,
                         fluency: fluency, clarity: clarity, audio: audio, framing: framing,
                         notes: notes)
    }
}
