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

    /// Word indices of every occurrence of a phrase, or nil if it is not there.
    ///
    /// Matching is on normalised words, so punctuation and case do not stop a quote matching what
    /// was said. EVERY occurrence is returned, not the first: a phrase said twice is two beats, and
    /// silently cutting only one of them would leave the caller believing both were gone.
    public func locate(_ phrase: String) -> [Int]? {
        func norm(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
        }
        let needle = phrase.split(separator: " ").map(String.init).map(norm).filter { !$0.isEmpty }
        guard !needle.isEmpty else { return nil }
        let haystack = words.map { norm($0.text) }
        var found: [Int] = []
        guard haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle {
                found.append(contentsOf: (start..<(start + needle.count)).map { words[$0].index })
            }
        }
        return found.isEmpty ? nil : found
    }

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
    /// Align two transcripts of the same audio and set each word's confidence from whether the
    /// engines agreed.
    ///
    /// Alignment is by **sequence**, not by time overlap. Time overlap is the obvious approach and
    /// it fails badly: measured on real narration, WhisperKit and Apple place the same words up to
    /// a few hundred milliseconds apart, so a word smears across two of its neighbours, the joined
    /// text never matches, and 197 of 263 words came back "disputed" — a 75 % false-disagreement
    /// rate that would make the confidence floor useless by holding everything.
    ///
    /// So this computes a longest common subsequence over the normalised words. A primary word on
    /// that subsequence was said the same way by both engines; one that is not is a substitution,
    /// insertion or deletion — a genuine disagreement.
    ///
    /// The DP is windowed by time rather than run over the whole transcript, because a full
    /// alignment of an hour of speech is ~9 000 × 9 000 cells. Both transcripts describe the same
    /// audio, so time is a reliable way to cut the problem into independent pieces.
    ///
    /// `primary` supplies the words and timings; `secondary` only votes.
    public static func agree(primary: Transcript, secondary: Transcript,
                             agreeing: Rational = Rational(95, 100),
                             disagreeing: Rational = Rational(55, 100),
                             windowSeconds: Double = 30,
                             slackSeconds: Double = 2) -> Transcript {
        guard !primary.words.isEmpty else { return primary }
        var agreed = Set<Int>()

        let end = primary.words.last!.range.end.seconds.doubleValue
        var windowStart = 0.0
        while windowStart < end + windowSeconds {
            let windowEnd = windowStart + windowSeconds
            let mine = primary.words.filter {
                let t = $0.range.start.seconds.doubleValue
                return t >= windowStart && t < windowEnd
            }
            if mine.isEmpty { windowStart = windowEnd; continue }
            // Slack either side, so a word near a window edge still finds its counterpart.
            let theirs = secondary.words.filter {
                let t = $0.range.start.seconds.doubleValue
                return t >= windowStart - slackSeconds && t < windowEnd + slackSeconds
            }
            for index in matchedIndices(mine: mine, theirs: theirs) { agreed.insert(index) }
            windowStart = windowEnd
        }

        let merged = primary.words.map { w in
            let matched = agreed.contains(w.index)
            return Word(index: w.index, text: w.text, range: w.range,
                        // Never raise a word above what the primary engine itself claimed: two
                        // engines agreeing on a word one of them was unsure of is still unsure.
                        confidence: matched ? min(agreeing, w.confidence == .zero ? agreeing : max(w.confidence, agreeing)) : disagreeing,
                        speaker: w.speaker,
                        sources: matched ? primary.engines + secondary.engines : primary.engines)
        }
        return Transcript(asset: primary.asset, words: merged,
                          engines: primary.engines + secondary.engines, language: primary.language)
    }

    /// Indices (in the primary transcript's own numbering) of words on the longest common
    /// subsequence of the two normalised token streams.
    static func matchedIndices(mine: [Word], theirs: [Word]) -> [Int] {
        let a = mine.map(\.normalised)
        let b = theirs.map(\.normalised)
        guard !a.isEmpty, !b.isEmpty else { return [] }

        // Classic LCS table. Windowed, so this stays small.
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1
                                           : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var out: [Int] = []
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { out.append(mine[i].index); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        return out
    }
}
