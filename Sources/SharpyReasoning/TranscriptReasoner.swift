// Reading a transcript for MEANING, where string comparison runs out.
//
// The user's description of what they do: "I say it wrong, then I keep going saying the wrong
// thing, then I say the right thing without pausing." Word-window similarity cannot find that, and
// no threshold fixes it — the abandoned version and the replacement may share almost no words. The
// question is not "do these look alike" but "did he give up on that thought", which is meaning.
//
// So a local language model reads it. The discipline that makes that acceptable is the one already
// established for the VLM: THE MODEL PROPOSES, THE SYSTEM VERIFIES.
//
//   · it is given the transcript with every word NUMBERED, and may only answer in word indices —
//     so a proposal is checkable against the transcript rather than being prose to be believed
//   · every span it returns is verified to exist, to be contiguous, and to be inside the piece
//   · a proposal it cannot justify by quoting the words is discarded
//   · what survives carries `structuralInference` — the agent's reading, ranked below every
//     measurement, and held for review rather than shipped
//
// It runs locally, on weights already on the machine. Nothing is sent anywhere.

import Foundation
import SharpyEngine

public struct AbandonedSpan: Sendable, Equatable {
    public init(firstWord: Int, lastWord: Int, reason: String, text: String, range: TimeRange) {
        self.firstWord = firstWord; self.lastWord = lastWord
        self.reason = reason; self.text = text; self.range = range
    }
    /// Inclusive word indices to remove.
    public let firstWord: Int, lastWord: Int
    /// The model's reason, kept verbatim so a person can disagree with the reasoning.
    public let reason: String
    /// The words themselves, filled in by verification — never taken from the model, which could
    /// otherwise quote something that was never said.
    public let text: String
    public let range: TimeRange
}

public struct ReasonedEdit: Sendable {
    public init(abandoned: [AbandonedSpan], rejected: [String], modelName: String, wallSeconds: Double) {
        self.abandoned = abandoned; self.rejected = rejected
        self.modelName = modelName; self.wallSeconds = wallSeconds
    }
    public let abandoned: [AbandonedSpan]
    /// Proposals thrown out, and why. Kept because a model that keeps proposing the same
    /// unverifiable thing is telling you where its reading is weak.
    public let rejected: [String]
    public let modelName: String
    public let wallSeconds: Double

    public var secondsRemoved: Double {
        abandoned.reduce(0) { $0 + $1.range.duration.seconds.doubleValue }
    }

    public var summary: String {
        var lines = [String(format: "reasoned edit (%@, %.1f s): %d abandoned stretch(es), %.1f s to cut",
                            modelName, wallSeconds, abandoned.count, secondsRemoved)]
        for span in abandoned {
            lines.append(String(format: "  %6.2f–%6.2f s  words %d–%d  \"%@\"",
                                span.range.start.seconds.doubleValue, span.range.end.seconds.doubleValue,
                                span.firstWord, span.lastWord, span.text.prefix(52) as CVarArg))
            lines.append("      because: \(span.reason)")
        }
        if !rejected.isEmpty {
            lines.append("  \(rejected.count) proposal(s) rejected:")
            for r in rejected.prefix(6) { lines.append("     · \(r)") }
        }
        return lines.joined(separator: "\n")
    }
}

public enum ReasonerError: Error, CustomStringConvertible {
    case modelUnavailable(String)
    case noAnswer
    public var description: String {
        switch self {
        case .modelUnavailable(let m): return "local model unavailable: \(m)"
        case .noAnswer: return "the model returned nothing usable"
        }
    }
}

public enum TranscriptReasoner {

    /// The transcript with every word numbered, which is what makes an answer checkable.
    public static func numbered(_ transcript: Transcript, from: Int = 0, to: Int? = nil) -> String {
        let words = transcript.words.sorted { $0.index < $1.index }
        let end = to ?? words.count
        return words[max(0, from)..<min(end, words.count)]
            .map { "\($0.index):\($0.text)" }
            .joined(separator: " ")
    }

    /// Ask about ONE candidate the measurement already found, rather than asking the model to
    /// search.
    ///
    /// Measured: asked to find abandoned stretches across 1197 words unaided, the local model
    /// proposed 2 and the string matcher found 14, several of them plainly right. Open-ended
    /// extraction is too much for a 2B model; judging a specific passage in context is not, and it
    /// is the part string matching genuinely cannot do — deciding whether a speaker gave up on a
    /// thought or simply repeated themselves for emphasis.
    ///
    /// So the measurement proposes the candidates and the model adjudicates them. Each does the
    /// half it is good at.
    public static func adjudication(before: String, candidate: String, after: String,
                                    reverseOptions: Bool = false) -> String {
        // Asked as a yes/no question — "did the speaker abandon this?" — the model answered yes 12
        // times out of 12, including on plain enumeration. 50% on the controls, which is what
        // always-cut scores. A leading question got a leading answer.
        //
        // So it is asked as a choice between named alternatives instead, each described in the same
        // amount of detail, with no option marked as the expected one. The order is swappable
        // because a model picking by position rather than by meaning gives a different answer when
        // the options move, and that disagreement is the tell.
        let falseStart = """
        FALSE START — they lost the thread and started the same point over. The version afterwards         replaces this one; keeping both would say the same thing twice by accident.
        """
        let onPurpose = """
        ON PURPOSE — they meant to say it this way. Repeating for emphasis, counting items off,         naming a thing before explaining it, or pointing at two things in turn. Removing it would         take away something they chose to say.
        """
        let options = reverseOptions
            ? "A) \(onPurpose)\n\nB) \(falseStart)"
            : "A) \(falseStart)\n\nB) \(onPurpose)"
        let cutLetter = reverseOptions ? "B" : "A"
        let keepLetter = reverseOptions ? "A" : "B"
        return """
        Someone is talking to camera. Read the marked part in context.

        …\(before)
        >>> \(candidate) <<<
        \(after)…

        Which describes the marked part?

        \(options)

        Answer with the letter only, then a dash and a short reason.         \(cutLetter) means it was a false start; \(keepLetter) means they meant it.
        """
    }

    /// Extend a word range outwards to the nearest sentence edge.
    ///
    /// A fixed count of words drops the model into the middle of a sentence at both ends. On clean
    /// sentence-aligned controls it contradicted itself on order-swap 2 times in 12; on real
    /// candidates cut to a fixed 18/26 words, 8 times in 18. Meaning lives in sentences, so the
    /// context is cut at sentences.
    ///
    /// The limit is a word budget, not a sentence count, so one rambling sentence cannot push the
    /// passage past what the model can hold.
    public static func sentenceAligned(words: [String], around range: Range<Int>,
                                       budget: Int) -> (before: Range<Int>, after: Range<Int>) {
        func endsSentence(_ word: String) -> Bool {
            guard let last = word.last(where: { !$0.isWhitespace }) else { return false }
            return last == "." || last == "?" || last == "!"
        }
        var start = range.lowerBound
        while start > 0, start > range.lowerBound - budget, !endsSentence(words[start - 1]) { start -= 1 }
        var end = range.upperBound
        while end < words.count, end < range.upperBound + budget, !endsSentence(words[end]) { end += 1 }
        if end < words.count { end += 1 }  // include the word carrying the full stop
        return (start..<range.lowerBound, range.upperBound..<min(end, words.count))
    }

    /// What the model is allowed to do with its answer.
    ///
    /// Measured on 12 controls, two passes each, Gemma 4 E2B at temperature 0:
    ///
    ///   asked as yes/no   — 6/12, and every single answer was CUT. No information at all.
    ///   asked as a choice — 6/12, but 4 of 6 deliberate repetitions correctly kept,
    ///                       and wrongly-cut keepers fell from 6 to 1.
    ///
    /// Same score, opposite behaviour. The model is good at recognising speech somebody meant to
    /// say and poor at recognising a fumble, so it is given the half it is good at: it may VETO a
    /// cut the measurement proposed, and it may not propose one. A wrong veto leaves a stumble in
    /// the video, which is visible on review; a wrong cut deletes words the speaker chose, which is
    /// not. The cheap mistake is the one it is allowed to make.
    public static func vetoes(_ verdict: Verdict) -> Bool { verdict == .keep }

    /// Whether a veto is allowed to stand, given how strong the measurement behind the candidate is.
    ///
    /// The project's basis hierarchy already settles this: the gap and similarity are
    /// `measuredMaterial`, the model's reading is `structuralInference`, and the weaker basis does
    /// not overturn the stronger one. It only speaks where the stronger one is quiet.
    ///
    /// A retry that lands within a second and repeats two thirds of the words is somebody catching
    /// themselves — the timing says so, and no reading of the text should overrule it. A retry four
    /// words alike and two seconds later could be anything, and there the model's opinion is the
    /// best evidence available.
    ///
    /// Measured on the 10-minute recording: 18 candidates, of which 5 are weakly measured. Letting
    /// the veto apply only there costs nothing on the 13 strong ones and keeps the model's 4-in-6
    /// accuracy pointed at the cases that are actually ambiguous.
    public static func vetoStands(gapSeconds: Double, similarity: Double) -> Bool {
        !(gapSeconds <= 1.0 && similarity >= 0.65)
    }

    /// The two passes ask the same question with the options swapped. A judgement that changes when
    /// the options move was made by position, not by meaning, so it is discarded.
    public static func agreed(first: Verdict, second: Verdict) -> Verdict {
        guard first == second, first != .unclear else { return .unclear }
        return first
    }

    public enum Verdict: String, Sendable { case cut, keep, unclear }

    /// Read the adjudication. An answer that is neither CUT nor KEEP is `unclear` and the candidate
    /// is kept — when the model cannot decide, removing somebody's words on its say-so is the wrong
    /// way to be wrong.
    public static func verdict(_ answer: String, reverseOptions: Bool = false) -> (Verdict, String) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        let reason = firstLine.split(separator: "-", maxSplits: 1).dropFirst().first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        // The first A or B that appears as a word on its own; letters inside words are not answers.
        var letter: Character?
        var previous: Character = " "
        for (offset, character) in firstLine.enumerated() {
            let next = offset + 1 < firstLine.count
                ? Array(firstLine)[offset + 1] : " "
            let standsAlone = !previous.isLetter && !next.isLetter
            if standsAlone, character == "A" || character == "B" { letter = character; break }
            previous = character
        }
        guard let letter else { return (.unclear, firstLine) }
        let cutLetter: Character = reverseOptions ? "B" : "A"
        return (letter == cutLetter ? .cut : .keep, reason)
    }

    /// The instruction. Written to make the failure modes hard rather than the success easy:
    /// answering in indices means a wrong answer is caught, and demanding a quote means a proposal
    /// that describes nothing real cannot survive verification.
    public static func prompt(for numbered: String) -> String {
        """
        Below is a spoken transcript. Every word is written as INDEX:WORD.

        The speaker sometimes starts saying something, gets it wrong, keeps going for a while, and \
        then says the correct version — usually without pausing. The wrong run should be cut and \
        the correct one kept.

        Find every run of words that the speaker ABANDONED because they said it again correctly \
        afterwards. Only the abandoned run, never the correct one that follows it.

        Rules:
        - answer ONLY with lines of the form: FIRST-LAST | reason
        - FIRST and LAST are word indices from the transcript
        - the reason must say what the correct version is
        - if nothing was abandoned, answer exactly: NONE
        - never invent indices that are not in the transcript

        TRANSCRIPT:
        \(numbered)
        """
    }

    /// Parse the model's answer. Deliberately strict: anything not of the expected shape is
    /// rejected and reported rather than salvaged, because salvaging a malformed answer means
    /// guessing what the model meant.
    public static func parse(_ answer: String, transcript: Transcript)
    -> (spans: [AbandonedSpan], rejected: [String]) {
        let words = transcript.words.sorted { $0.index < $1.index }
        let byIndex = Dictionary(uniqueKeysWithValues: words.map { ($0.index, $0) })
        var spans: [AbandonedSpan] = []
        var rejected: [String] = []

        for rawLine in answer.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.uppercased() == "NONE" { continue }
            let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { rejected.append("not 'first-last | reason': \(line)"); continue }
            let bounds = parts[0].split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard bounds.count == 2, bounds[0] <= bounds[1] else {
                rejected.append("unreadable range: \(parts[0])"); continue
            }
            // Every index must exist. A model that answers about words nobody said is answering
            // about a transcript it imagined.
            guard let first = byIndex[bounds[0]], let last = byIndex[bounds[1]] else {
                rejected.append("indices \(bounds[0])–\(bounds[1]) are not in the transcript"); continue
            }
            let inside = words.filter { $0.index >= bounds[0] && $0.index <= bounds[1] }
            guard inside.count == bounds[1] - bounds[0] + 1 else {
                rejected.append("range \(bounds[0])–\(bounds[1]) is not contiguous"); continue
            }
            // A span covering most of the piece is not a correction, it is the model losing track.
            guard Double(inside.count) < Double(words.count) * 0.4 else {
                rejected.append("range \(bounds[0])–\(bounds[1]) covers \(inside.count) of \(words.count) words — too much of the piece to be a fumble")
                continue
            }
            spans.append(AbandonedSpan(
                firstWord: bounds[0], lastWord: bounds[1], reason: parts[1],
                // The words come from the TRANSCRIPT, never from the model.
                text: inside.map(\.text).joined(separator: " "),
                range: TimeRange(start: first.range.start, end: last.range.end)))
        }
        // Overlapping spans cannot both be cut. Reported rather than silently merged.
        var kept: [AbandonedSpan] = []
        for span in spans.sorted(by: { $0.firstWord < $1.firstWord }) {
            if let previous = kept.last, span.firstWord <= previous.lastWord {
                rejected.append("range \(span.firstWord)–\(span.lastWord) overlaps \(previous.firstWord)–\(previous.lastWord)")
                continue
            }
            kept.append(span)
        }
        return (kept, rejected)
    }

    /// The basis a reasoned cut carries: the agent's own reading, never a measurement.
    public static func basis(for span: AbandonedSpan) -> Basis {
        .structuralInference(evidence: ["words \(span.firstWord)–\(span.lastWord)", span.reason],
                             confidence: Rational(3, 5))
    }
}
