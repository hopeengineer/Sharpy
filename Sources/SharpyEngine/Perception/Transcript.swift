// The transcript is the spine of text-based editing, and its addressing rule is the whole point:
// **the agent names words, never frames.** `remove(words: 41...47)` survives an upstream re-cut;
// `rippleDelete(300...420)` does not. Frame arithmetic is the tool's job, not the agent's.
//
// Words carry a confidence, and where two engines disagree that confidence drops — measured on
// real speech, every adjudicated ASR error sat on a word where whisper-turbo and parakeet
// disagreed, and on every word they agreed about, both were right. So agreement is not a nicety;
// it is the only per-word signal available without a human listening.

import Foundation

public struct Word: Hashable, Sendable, Codable {
    /// Stable, zero-based position in the transcript. The agent's addressing unit.
    public let index: Int
    public let text: String
    /// Where the word sits in the *source asset*, not the timeline.
    public let range: TimeRange
    /// 0…1. Below the project floor, a decision may not rest on this word.
    public let confidence: Rational
    /// Speaker label from diarization, when available.
    public let speaker: String?
    /// Engines that produced this word, for provenance.
    public let sources: [String]

    public init(index: Int, text: String, range: TimeRange, confidence: Rational,
                speaker: String? = nil, sources: [String] = []) {
        self.index = index; self.text = text; self.range = range
        self.confidence = confidence; self.speaker = speaker; self.sources = sources
    }

    /// Normalised for comparison: lowercase, no surrounding punctuation.
    public var normalised: String {
        text.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    /// Fillers a disfluency pass removes by default. "like" and "so" are deliberately absent:
    /// they are usually load-bearing, and cutting them changes meaning.
    public static let fillerWords: Set<String> = ["um", "uh", "erm", "hmm", "mm", "eh", "ah"]
    public var isFiller: Bool { Word.fillerWords.contains(normalised) }
}

/// A gap between words. Dead air is a `measured_material` fact, not a threshold guess.
public struct Pause: Hashable, Sendable, Codable {
    /// Index of the word before the gap; -1 for a gap at the very start.
    public let afterWord: Int
    public let range: TimeRange
    public var duration: TimeValue { range.duration }
}

public struct Transcript: Sendable, Codable {
    public let asset: NodeID
    public let words: [Word]
    /// Which engines contributed, for the decision record.
    public let engines: [String]
    /// Sample rate the timings were computed against.
    public let language: String

    public init(asset: NodeID, words: [Word], engines: [String], language: String = "en-US") {
        self.asset = asset; self.words = words; self.engines = engines; self.language = language
    }

    public var text: String { words.map(\.text).joined(separator: " ") }
    public var isEmpty: Bool { words.isEmpty }

    /// The word containing an instant, if any.
    public func word(at t: TimeValue) -> Word? { words.first { $0.range.contains(t) } }

    /// Words whose span overlaps a range.
    public func words(in range: TimeRange) -> [Word] { words.filter { $0.range.overlaps(range) } }

    /// Gaps longer than `minimum` — candidate dead air.
    public func pauses(longerThan minimum: TimeValue) -> [Pause] {
        var out: [Pause] = []
        for (i, w) in words.enumerated() where i + 1 < words.count {
            let gap = TimeRange(start: w.range.end, end: words[i + 1].range.start)
            if !gap.isEmpty, minimum < gap.duration { out.append(Pause(afterWord: w.index, range: gap)) }
        }
        return out
    }

    public var fillers: [Word] { words.filter(\.isFiller) }

    /// Words below a confidence floor — where the agent must not act without escalating.
    public func lowConfidence(below floor: Rational) -> [Word] { words.filter { $0.confidence < floor } }

    /// The source range covering a run of words, padded outward to the given amount.
    public func span(_ indices: ClosedRange<Int>, pad: TimeValue = .zero) -> TimeRange? {
        let selected = words.filter { indices.contains($0.index) }
        guard let first = selected.first, let last = selected.last else { return nil }
        let start = first.range.start.seconds < pad.seconds ? TimeValue.zero : first.range.start - pad
        return TimeRange(start: start, end: last.range.end + pad)
    }

    /// Sentence-ish segments, for cheap reading without spending the whole word list.
    /// Splits on terminal punctuation, or on a pause longer than `pauseSplit`.
    public func segments(pauseSplit: TimeValue = TimeValue(seconds: Rational(6, 10))) -> [(firstWord: Int, text: String, range: TimeRange)] {
        var out: [(Int, String, TimeRange)] = []
        var current: [Word] = []
        func flush() {
            guard let f = current.first, let l = current.last else { return }
            out.append((f.index, current.map(\.text).joined(separator: " "), TimeRange(start: f.range.start, end: l.range.end)))
            current = []
        }
        for (i, w) in words.enumerated() {
            current.append(w)
            let endsSentence = w.text.hasSuffix(".") || w.text.hasSuffix("?") || w.text.hasSuffix("!")
            let longGap = i + 1 < words.count && pauseSplit < (words[i + 1].range.start - w.range.end)
            if endsSentence || longGap { flush() }
        }
        flush()
        return out
    }
}

// MARK: - Two-engine agreement

public enum TranscriptMerge {
    /// Align two transcripts of the same audio and produce one whose per-word confidence reflects
    /// whether the engines agreed. Alignment is by time overlap rather than by sequence position,
    /// because the engines tokenise differently — parakeet emits sub-word pieces that must be
    /// glued back into words before they can be compared at all.
    ///
    /// `primary` supplies the words and timings; `secondary` only votes.
    public static func agree(primary: Transcript, secondary: Transcript,
                             agreeing: Rational = Rational(95, 100),
                             disagreeing: Rational = Rational(55, 100)) -> Transcript {
        var merged: [Word] = []
        merged.reserveCapacity(primary.words.count)
        for w in primary.words {
            let overlapping = secondary.words.filter { $0.range.overlaps(w.range) }
            // Join, then require equality. Joining handles the real tokenisation difference —
            // parakeet emits "tod" + "ay" for "today", which concatenates back to the word.
            // Substring matching would be a disaster here: "did" is a prefix of "didn't", so a
            // containment test marks the one meaning-inverting error we measured as *agreement*.
            // Where the secondary tokenises more coarsely this yields a false disagreement, which
            // is the safe direction — it lowers confidence and invites a check, rather than
            // asserting a correctness the engines never established.
            let joined = overlapping.map(\.normalised).joined()
            let matched = !overlapping.isEmpty && joined == w.normalised
            merged.append(Word(index: w.index, text: w.text, range: w.range,
                               confidence: matched ? agreeing : disagreeing,
                               speaker: w.speaker,
                               sources: matched ? primary.engines + secondary.engines : primary.engines))
        }
        return Transcript(asset: primary.asset, words: merged,
                          engines: primary.engines + secondary.engines, language: primary.language)
    }
}
