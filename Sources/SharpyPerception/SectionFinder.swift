// Where the piece changes subject, and what to call each part.
//
// A format says "three panels, each labelled". It does not say what the labels ARE. The reference
// reads TOP / MIDDLE / BOTTOM because that video is about a content funnel; copying those words
// onto somebody else's video would put a funnel diagram over a piece about something else — the
// format applied and the meaning discarded.
//
// So the sections come from the speaker's own words, by measurement rather than by a model:
//
//   BOUNDARIES  lexical cohesion, the TextTiling idea. Windows either side of a moment share a lot
//               of vocabulary while a subject continues, and share much less across a change of
//               subject. The valleys in that similarity are where the piece turns.
//   LABELS      the terms most distinctive to each section — frequent inside it, rare in the rest.
//               A word common to the whole piece describes none of its parts.
//
// Both are arithmetic over the transcript, which matters here: a label is going to be BURNED INTO
// the picture, and a label nobody can trace back to something the person said is a caption the tool
// invented and the viewer will believe.

import Foundation
import SharpyEngine

public struct Section: Sendable {
    public let range: TimeRange
    public let firstWord: Int, lastWord: Int
    /// Distinctive terms, most distinctive first.
    public let terms: [String]
    /// A short label from those terms.
    public let label: String
    /// The opening words, so a person can see what the section actually is.
    public let opening: String

    public var description: String {
        String(format: "%6.1f–%6.1f s  %@  — \"%@…\"",
               range.start.seconds.doubleValue, range.end.seconds.doubleValue,
               label, opening.prefix(46) as CVarArg)
    }
}

public struct SectionAnalysis: Sendable {
    public let sections: [Section]
    /// Cohesion at each candidate boundary, for seeing how clear the structure is.
    public let cohesion: [Double]

    public var summary: String {
        guard !sections.isEmpty else { return "sections: none found" }
        var lines = ["sections: \(sections.count) found from the speaker's own words"]
        for section in sections { lines.append("  " + section.description) }
        return lines.joined(separator: "\n")
    }
}

public enum SectionFinder {
    /// Words too common to distinguish one part of a piece from another.
    static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "if", "then", "so", "because", "as", "of", "to", "in",
        "on", "for", "with", "at", "by", "from", "up", "out", "is", "are", "was", "were", "be",
        "been", "being", "have", "has", "had", "do", "does", "did", "will", "would", "can", "could",
        "should", "i", "you", "he", "she", "it", "we", "they", "me", "him", "her", "us", "them",
        "my", "your", "his", "its", "our", "their", "this", "that", "these", "those", "there",
        "here", "what", "which", "who", "when", "where", "how", "why", "not", "no", "yes", "just",
        "like", "get", "got", "go", "going", "one", "all", "very", "really", "actually", "thing",
        "things", "now", "even", "also", "about", "into", "than", "them", "some", "any", "more",
    ]

    static func normalise(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func meaningful(_ words: [Word]) -> [String] {
        words.map { normalise($0.text) }.filter { $0.count > 2 && !stopWords.contains($0) }
    }

    /// Cosine similarity between two bags of words.
    static func cohesion(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var left: [String: Double] = [:], right: [String: Double] = [:]
        for w in a { left[w, default: 0] += 1 }
        for w in b { right[w, default: 0] += 1 }
        var dot = 0.0
        for (word, count) in left { dot += count * (right[word] ?? 0) }
        let magnitude = sqrt(left.values.reduce(0) { $0 + $1 * $1 })
                      * sqrt(right.values.reduce(0) { $0 + $1 * $1 })
        return magnitude > 0 ? dot / magnitude : 0
    }

    /// Split a transcript into `count` sections at the weakest points of lexical cohesion.
    ///
    /// - Parameter count: how many sections the FORMAT wants — three panels want three sections.
    ///   Asked for rather than discovered, because the format is a constraint the edit has to meet.
    public static func find(in transcript: Transcript, count: Int,
                            windowWords: Int = 40) -> SectionAnalysis {
        let words = transcript.words.sorted { $0.index < $1.index }
        guard words.count > windowWords * 2, count > 1 else {
            let terms = distinctive(Array(words.indices), words: words, others: [])
            let section = Section(range: TimeRange(start: words.first?.range.start ?? .zero,
                                                   end: words.last?.range.end ?? .zero),
                                  firstWord: words.first?.index ?? 0,
                                  lastWord: words.last?.index ?? 0,
                                  terms: terms, label: label(from: terms),
                                  opening: words.prefix(10).map(\.text).joined(separator: " "))
            return SectionAnalysis(sections: words.isEmpty ? [] : [section], cohesion: [])
        }

        // Cohesion across every gap: how much vocabulary the window before shares with the window
        // after. A subject continuing shares a lot; a subject changing shares little.
        var scores = [Double](repeating: 1, count: words.count)
        for i in windowWords..<(words.count - windowWords) {
            let before = meaningful(Array(words[(i - windowWords)..<i]))
            let after = meaningful(Array(words[i..<(i + windowWords)]))
            scores[i] = cohesion(before, after)
        }

        // The deepest valleys, kept apart so two boundaries cannot land in the same dip.
        let minimumApart = max(words.count / (count * 3), windowWords)
        var chosen: [Int] = []
        var candidates = (windowWords..<(words.count - windowWords)).sorted { scores[$0] < scores[$1] }
        while chosen.count < count - 1, let next = candidates.first {
            chosen.append(next)
            candidates.removeAll { abs($0 - next) < minimumApart }
        }
        chosen.sort()

        var sections: [Section] = []
        var bounds = [0] + chosen + [words.count]
        bounds = Array(Set(bounds)).sorted()
        for i in 0..<(bounds.count - 1) {
            let range = bounds[i]..<bounds[i + 1]
            guard !range.isEmpty else { continue }
            let others = (0..<(bounds.count - 1)).filter { $0 != i }
                .flatMap { Array(bounds[$0]..<bounds[$0 + 1]) }
            let terms = distinctive(Array(range), words: words, others: others)
            sections.append(Section(
                range: TimeRange(start: words[range.lowerBound].range.start,
                                 end: words[range.upperBound - 1].range.end),
                firstWord: words[range.lowerBound].index,
                lastWord: words[range.upperBound - 1].index,
                terms: terms, label: label(from: terms),
                opening: words[range].prefix(10).map(\.text).joined(separator: " ")))
        }
        return SectionAnalysis(sections: sections, cohesion: scores)
    }

    /// Terms frequent INSIDE a section and rare outside it.
    ///
    /// Frequency alone would return whatever the whole piece is about, which describes no part of
    /// it — the reference's every section would be labelled "content".
    static func distinctive(_ indices: [Int], words: [Word], others: [Int]) -> [String] {
        var inside: [String: Double] = [:], outside: [String: Double] = [:]
        for i in indices { for w in meaningful([words[i]]) { inside[w, default: 0] += 1 } }
        for i in others { for w in meaningful([words[i]]) { outside[w, default: 0] += 1 } }
        let insideTotal = max(inside.values.reduce(0, +), 1)
        let outsideTotal = max(outside.values.reduce(0, +), 1)
        return inside
            .filter { $0.value >= 2 }        // said once is a coincidence, not a subject
            .map { (word, count) -> (String, Double) in
                let here = count / insideTotal
                let elsewhere = (outside[word] ?? 0) / outsideTotal
                return (word, here / (elsewhere + here / 8))
            }
            .sorted { $0.1 > $1.1 }
            .prefix(6).map(\.0)
    }

    /// A short label from the distinctive terms. Their words, not a paraphrase — a label the person
    /// cannot recognise is one they cannot correct.
    static func label(from terms: [String]) -> String {
        guard !terms.isEmpty else { return "SECTION" }
        return terms.prefix(2).joined(separator: " ").uppercased()
    }
}
