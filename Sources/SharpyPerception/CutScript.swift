// The one thing no measurement can recover: which panel says what.
//
// Everything else about the format is in the reference and can be measured — how many panels, that
// they carry the same person, that the opening runs them together and the body takes turns. Which
// PANEL a given line belongs to is a decision the editor made, and it leaves no trace that
// analysis can read back. The user writes it down; this reads it.
//
// The format is the one they already write by hand:
//
//   [hook- that makes the echo]Every vibecoder must know these 3 things.
//   [1st cut - top]First folders.
//   [2nd cut- center]Second: instruction files.
//
// Deliberately forgiving about its own syntax — spacing, "botom" for "bottom", the marker running
// straight into the line. A script is written by a person mid-thought, and a parser that rejects it
// for a typo makes them do the computer's job.

import Foundation
import SharpyEngine

public struct ScriptCut: Sendable, Equatable {
    public enum Panel: String, Sendable, Equatable {
        case top, centre, bottom, all
        /// Row index for a stacked layout of `count` panels.
        public func row(of count: Int) -> Int? {
            switch self {
            case .top: return 0
            case .centre: return count > 2 ? 1 : nil
            case .bottom: return count - 1
            case .all: return nil
            }
        }
    }
    /// 0 for the hook, then 1, 2, 3… in the order written.
    public let order: Int
    public let panel: Panel
    /// What is said, joined into one string.
    public let text: String
    public let isHook: Bool
    /// The marker exactly as written, kept so a person can find the line they wrote.
    public let marker: String
}

public struct ParsedScript: Sendable {
    public let cuts: [ScriptCut]
    /// Markers that could not be understood, reported rather than skipped — a cut silently dropped
    /// is a piece of the video that quietly goes missing.
    public let unrecognised: [String]

    public var hook: ScriptCut? { cuts.first(where: \.isHook) }
    public var body: [ScriptCut] { cuts.filter { !$0.isHook } }
    public var panelsUsed: Int {
        Set(body.map(\.panel)).subtracting([.all]).count
    }

    public var summary: String {
        var lines = ["script: \(cuts.count) cut(s) across \(panelsUsed) panel(s)"]
        if let hook { lines.append("  hook (all panels): \"\(hook.text.prefix(60))\"") }
        for cut in body.prefix(20) {
            lines.append(String(format: "  %2d %-6@ \"%@\"", cut.order,
                                cut.panel.rawValue as CVarArg, cut.text.prefix(52) as CVarArg))
        }
        if body.count > 20 { lines.append("  … \(body.count - 20) more") }
        if !unrecognised.isEmpty {
            lines.append("  NOT UNDERSTOOD: \(unrecognised.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}

public enum CutScript {
    static func panel(from marker: String) -> ScriptCut.Panel? {
        let m = marker.lowercased()
        // Typos included on purpose: "botom" appears twice in the user's own script, and refusing
        // it would make them proofread for the parser's benefit.
        if m.contains("top") { return .top }
        if m.contains("cent") || m.contains("middle") || m.contains("mid") { return .centre }
        if m.contains("bottom") || m.contains("botom") || m.contains("bot") { return .bottom }
        if m.contains("all") || m.contains("echo") || m.contains("hook") { return .all }
        return nil
    }

    public static func parse(_ source: String) -> ParsedScript {
        var cuts: [ScriptCut] = []
        var unrecognised: [String] = []
        // Split on the markers, keeping them.
        let pattern = try! NSRegularExpression(pattern: "\\[([^\\]]*)\\]", options: [])
        let full = source as NSString
        let matches = pattern.matches(in: source, range: NSRange(location: 0, length: full.length))
        guard !matches.isEmpty else { return ParsedScript(cuts: [], unrecognised: []) }

        for (i, match) in matches.enumerated() {
            let marker = full.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let textStart = match.range.location + match.range.length
            let textEnd = i + 1 < matches.count ? matches[i + 1].range.location : full.length
            let raw = full.substring(with: NSRange(location: textStart, length: textEnd - textStart))
            // Asterisks and stray markdown are how a script arrives from a notes app.
            let text = raw
                .replacingOccurrences(of: "*", with: "")
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard let panel = CutScript.panel(from: marker) else {
                unrecognised.append(marker)
                continue
            }
            guard !text.isEmpty else { continue }
            let isHook = marker.lowercased().contains("hook") || marker.lowercased().contains("echo")
            cuts.append(ScriptCut(order: isHook ? 0 : cuts.filter { !$0.isHook }.count + 1,
                                  panel: isHook ? .all : panel,
                                  text: text, isHook: isHook, marker: marker))
        }
        return ParsedScript(cuts: cuts, unrecognised: unrecognised)
    }

    /// Where each scripted line actually falls in the recording.
    ///
    /// Matched WITHOUT assuming the recording follows the script's order, because it does not. On
    /// the user's own footage the lines are grouped BY PANEL — every "top" line recorded together,
    /// then every "centre", then every "bottom" — which is exactly how somebody shoots a
    /// three-panel video: one continuous take per panel.
    ///
    /// Two earlier attempts failed on that, and both failed quietly rather than loudly:
    ///
    ///   A greedy forward cursor cascaded. One missed line left the cursor behind, the next line
    ///   matched a later mention 60 seconds away, and everything after it was wrong.
    ///
    ///   A global sequence alignment fixed the cascade and still assumed one order. It placed the
    ///   lines it could and reported seven of fourteen missing from a recording containing all
    ///   fourteen.
    ///
    /// So each line is searched for across the WHOLE recording, and the assignment is then checked
    /// for collisions — two script lines resolving to the same moment is a real ambiguity worth
    /// reporting rather than a tie to break silently.
    /// Do two spoken words count as the same word?
    ///
    /// Exact equality lost "Second: instruction files." to "Second instructions file" — one exact
    /// match in three, a score of 0.33 against a floor of 0.45, and a line said plainly at 30.7 s
    /// was reported as never recorded. People inflect as they speak: files and file, test and
    /// tests, instruction and instructions are the same word said slightly differently. And an
    /// ASR mishears: "bclot.md" is "CLAUDE.md" as the engine heard it.
    ///
    /// So words match when they share a stem, or when they are within one edit per four letters of
    /// each other. Short words must match exactly — "a", "it", "to" are one edit from too much.
    static func sameWord(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        func stem(_ w: String) -> String {
            for suffix in ["ing", "ed", "es", "s"] where w.hasSuffix(suffix) && w.count - suffix.count >= 3 {
                return String(w.dropLast(suffix.count))
            }
            return w
        }
        if stem(a) == stem(b) { return true }
        guard a.count >= 4, b.count >= 4 else { return false }
        let allowed = max(1, max(a.count, b.count) / 4)
        guard abs(a.count - b.count) <= allowed else { return false }
        return editDistance(a, b) <= allowed
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        var row = Array(0...y.count)
        for i in 1...max(x.count, 1) where i <= x.count {
            var previous = row[0]; row[0] = i
            for j in 1...max(y.count, 1) where j <= y.count {
                let temp = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (x[i - 1] == y[j - 1] ? 0 : 1))
                previous = temp
            }
        }
        return row[y.count]
    }

    /// Where each scripted line actually falls in the recording.
    ///
    /// Matched WITHOUT assuming the recording follows the script's order, because it does not. On
    /// the user's own footage the lines are grouped BY PANEL — every "top" line recorded together,
    /// then every "centre", then every "bottom" — which is exactly how somebody shoots a
    /// three-panel video: one continuous take per panel.
    ///
    /// Two earlier attempts failed on that, and both failed quietly rather than loudly:
    ///
    ///   A greedy forward cursor cascaded. One missed line left the cursor behind, the next line
    ///   matched a later mention 60 seconds away, and everything after it was wrong.
    ///
    ///   A global sequence alignment fixed the cascade and still assumed one order. It placed the
    ///   lines it could and reported seven of fourteen missing from a recording containing all
    ///   fourteen.
    ///
    /// A third failure was found by listening to the finished edit rather than looking at it. The
    /// matched span was the best-scoring WINDOW of words, and a window is a fixed length. Where the
    /// speaker said "Automate it with a hook" and the window ended at "a", the cut ended at "a";
    /// where they added words the script did not have, the window started early to keep its score
    /// and the cut opened on the tail of the previous line. Four lines were chopped and two were
    /// heard twice. So the window is now only the ANCHOR: the span then extends to the edge of the
    /// breath group the anchor sits in — outward until a pause, or until it reaches words that
    /// belong to another line's anchor, whichever is first.
    public static func locate(_ script: ParsedScript, in transcript: Transcript,
                              minimumSimilarity: Double = 0.45)
    -> [(cut: ScriptCut, range: TimeRange?, similarity: Double)] {
        let words = transcript.words.sorted { $0.index < $1.index }
        let spoken = words.map { TakeSelector.key($0.text) }
        guard !spoken.isEmpty else { return script.cuts.map { ($0, nil, 0) } }

        // Pass one: the anchor for every line, trimmed to words that are actually in it.
        //
        // Windows of one length tie across several starts when the spoken line is shorter than the
        // window, and the earliest tying start was kept — which is why every cut opened on the tail
        // of the line before it. Trimming to matched words at both ends removes the tie: an anchor
        // begins on the first word of the line and ends on its last.
        var anchors: [(cut: ScriptCut, start: Int, end: Int, score: Double)?] = []
        for cut in script.cuts {
            let wanted = TakeSelector.key(cut.text).split(separator: " ").map(String.init)
            guard !wanted.isEmpty else { anchors.append(nil); continue }
            var best: (start: Int, end: Int, score: Double)?
            let lengths = Set([wanted.count, Int(Double(wanted.count) * 1.5) + 1,
                               max(Int(Double(wanted.count) * 0.7), 2)])
            for start in 0..<spoken.count {
                for length in lengths {
                    let end = min(start + length, spoken.count)
                    guard end - start >= 2 else { continue }
                    let score = TakeSelector.similarity(wanted, Array(spoken[start..<end]), match: sameWord)
                    if score > (best?.score ?? 0) { best = (start, end, score) }
                }
            }
            guard var found = best else { anchors.append(nil); continue }
            if found.score >= minimumSimilarity {
                func inLine(_ w: Int) -> Bool { wanted.contains { sameWord($0, spoken[w]) } }
                func closesSentence(_ w: Int) -> Bool {
                    guard let last = words[w].text.last(where: { !$0.isWhitespace }) else { return false }
                    return last == "." || last == "?" || last == "!"
                }
                // A line does not begin on a word that ends the previous sentence. "First folders."
                // then "…random folders…": both lines contain the word, and the second line's anchor
                // was opening on the first line's full stop.
                while found.end - found.start > 1,
                      !inLine(found.start) || closesSentence(found.start) { found.start += 1 }
                while found.end - found.start > 1, !inLine(found.end - 1) { found.end -= 1 }
            }
            anchors.append((cut, found.start, found.end, found.score))
        }

        // Pass two: extend each anchor to the edge of its sentence.
        //
        // Three stops, any of which ends the extension: a word another line already holds; a pause
        // longer than a breath; the punctuation the transcriber put at a sentence end. The last one
        // matters most — the speaker ran "practical AI advice." straight into "Third hooks." with
        // no measurable gap, so silence alone cannot separate them, and the full stop can.
        var claimed = [Int: Int]()
        for (i, anchor) in anchors.enumerated() {
            guard let anchor, anchor.score >= minimumSimilarity else { continue }
            for w in anchor.start..<anchor.end { claimed[w] = i }
        }
        func gapBefore(_ w: Int) -> Double {
            (words[w].range.start - words[w - 1].range.end).seconds.doubleValue
        }
        func endsSentence(_ w: Int) -> Bool {
            guard let last = words[w].text.last(where: { !$0.isWhitespace }) else { return false }
            return last == "." || last == "?" || last == "!"
        }
        var spans = [Int: (Int, Int)]()
        for (i, anchor) in anchors.enumerated() {
            guard let anchor, anchor.score >= minimumSimilarity else { continue }
            var start = anchor.start, end = anchor.end
            var steps = 0
            while end < words.count, steps < breathWords, claimed[end] == nil,
                  gapBefore(end) < breathSeconds, !endsSentence(end - 1) {
                claimed[end] = i; end += 1; steps += 1
            }
            steps = 0
            while start > 0, steps < breathWords, claimed[start - 1] == nil,
                  gapBefore(start) < breathSeconds, !endsSentence(start - 1) {
                start -= 1; claimed[start] = i; steps += 1
            }
            spans[i] = (start, end)
        }

        var out: [(ScriptCut, TimeRange?, Double)] = []
        for (i, anchor) in anchors.enumerated() {
            guard let anchor else { out.append((script.cuts[i], nil, 0)); continue }
            guard anchor.score >= minimumSimilarity, let (start, end) = spans[i] else {
                out.append((anchor.cut, nil, anchor.score)); continue
            }
            out.append((anchor.cut, TimeRange(start: words[start].range.start,
                                              end: words[end - 1].range.end), anchor.score))
        }
        return out
    }

    /// Longest silence that still counts as the same breath. Measured on the recording: words
    /// inside a sentence follow each other within 0.2 s; the gap before a new line is 0.4 s and up.
    public static let breathSeconds = 0.35
    /// How far a line may grow past its anchor on either side, in words.
    public static let breathWords = 8

    /// The nearest thing in the recording to a line that could not be placed — so the question put
    /// to the person is "did you mean this?" rather than "it is missing".
    public static func bestCandidate(for cut: ScriptCut, in transcript: Transcript)
    -> (text: String, range: TimeRange, score: Double)? {
        let words = transcript.words.sorted { $0.index < $1.index }
        let spoken = words.map { TakeSelector.key($0.text) }
        let wanted = TakeSelector.key(cut.text).split(separator: " ").map(String.init)
        guard !wanted.isEmpty, !spoken.isEmpty else { return nil }
        var best: (start: Int, end: Int, score: Double)?
        for start in 0..<spoken.count {
            let end = min(start + wanted.count, spoken.count)
            guard end - start >= 1 else { continue }
            let score = TakeSelector.similarity(wanted, Array(spoken[start..<end]), match: sameWord)
            if score > (best?.score ?? 0) { best = (start, end, score) }
        }
        guard let best else { return nil }
        return (words[best.start..<best.end].map(\.text).joined(separator: " "),
                TimeRange(start: words[best.start].range.start, end: words[best.end - 1].range.end),
                best.score)
    }

    /// A lone word at the edge of a line that is not in the script and is fenced by silence.
    ///
    /// Heard in the finished edit as "Pinklot": the speaker said "Claude—", stopped for half a
    /// second, and then said the line properly. The word is in the recording, the line's span
    /// reached it because there was no full stop and the pause before it was short, and nothing in
    /// the script matches it. That pattern — not in the script, alone, a pause on the far side, at
    /// the edge of a span — is a false start more often than it is anything else. It is asked about,
    /// not cut on sight, because a word the script does not have is sometimes the best word in it.
    public struct Stumble: Sendable {
        public let cut: ScriptCut
        public let text: String
        public let range: TimeRange
        /// True when it sits at the end of the span, where cutting it is a trim; false when it
        /// begins the span.
        public let trailing: Bool
    }

    public static func stumbles(_ located: [(cut: ScriptCut, range: TimeRange?, similarity: Double)],
                                in transcript: Transcript, pause: Double = 0.3) -> [Stumble] {
        let words = transcript.words.sorted { $0.index < $1.index }
        var out: [Stumble] = []
        for entry in located {
            guard let range = entry.range else { continue }
            let inside = words.enumerated().filter { $0.element.range.overlaps(range)
                && $0.element.range.start >= range.start && $0.element.range.end <= range.end }
            guard inside.count >= 2 else { continue }
            let wanted = TakeSelector.key(entry.cut.text).split(separator: " ").map(String.init)
            func scripted(_ w: Word) -> Bool { wanted.contains { sameWord($0, TakeSelector.key(w.text)) } }
            func gapAfter(_ i: Int) -> Double {
                i + 1 < words.count ? (words[i + 1].range.start - words[i].range.end).seconds.doubleValue : .infinity
            }
            func gapBefore(_ i: Int) -> Double {
                i > 0 ? (words[i].range.start - words[i - 1].range.end).seconds.doubleValue : .infinity
            }
            if let last = inside.last, !scripted(last.element), gapAfter(last.offset) >= pause,
               inside.count >= 2, scripted(inside[inside.count - 2].element) || gapBefore(last.offset) >= 0.15 {
                out.append(Stumble(cut: entry.cut, text: last.element.text, range: last.element.range, trailing: true))
            }
            // A word that opens a span is a stumble only if the speaker paused AFTER it as well —
            // the reset. "bclot.md" is CLAUDE.md as the transcriber heard it: not in the script by
            // spelling, alone after a pause, and followed 0.16 s later by "or AGENTS.md". Cutting
            // it removed the first word of the line. A false start is followed by silence; a
            // garbled real word is followed by the rest of its sentence.
            if let first = inside.first, !scripted(first.element), gapBefore(first.offset) >= pause,
               gapAfter(first.offset) >= pause {
                out.append(Stumble(cut: entry.cut, text: first.element.text, range: first.element.range, trailing: false))
            }
        }
        return out
    }

    /// The located script with stumbles trimmed off the edges of their spans.
    public static func trimming(_ stumbles: [Stumble],
                                from located: [(cut: ScriptCut, range: TimeRange?, similarity: Double)])
    -> [(cut: ScriptCut, range: TimeRange?, similarity: Double)] {
        located.map { entry in
            guard var range = entry.range else { return entry }
            for stumble in stumbles where stumble.cut == entry.cut {
                if stumble.trailing, stumble.range.end == range.end, stumble.range.start > range.start {
                    range = TimeRange(start: range.start, end: stumble.range.start)
                } else if !stumble.trailing, stumble.range.start == range.start, stumble.range.end < range.end {
                    range = TimeRange(start: stumble.range.end, end: range.end)
                }
            }
            return (entry.cut, range, entry.similarity)
        }
    }

    /// Everything that must be true of a located script before it is cut.
    ///
    /// Each of these was, at some point, allowed through: a line dropped without a word, two lines
    /// resolving to overlapping moments so the same words played twice. The check for the second
    /// existed and was never on the path that rendered. It is here now, and the assembler calls it.
    public static func problems(_ located: [(cut: ScriptCut, range: TimeRange?, similarity: Double)],
                                in transcript: Transcript) -> [String] {
        var out: [String] = []
        for entry in located where entry.range == nil {
            if let candidate = bestCandidate(for: entry.cut, in: transcript) {
                out.append(String(format: "cut %d \"%@\" was not found. Nearest: \"%@\" at %.2f s (%.0f%% alike). Did you mean that?",
                                  entry.cut.order, entry.cut.text.prefix(40) as CVarArg,
                                  candidate.text.prefix(40) as CVarArg,
                                  candidate.range.start.seconds.doubleValue, candidate.score * 100))
            } else {
                out.append("cut \(entry.cut.order) \"\(entry.cut.text.prefix(40))\" was not found and nothing in the recording resembles it.")
            }
        }
        for (a, b) in collisions(located) {
            out.append("cut \(a.order) and cut \(b.order) resolve to overlapping moments — the same words would play twice.")
        }
        for s in stumbles(located, in: transcript) {
            out.append(String(format: "\"%@\" at %.2f s is not in the script and stands alone before a pause at the %@ of cut %d — a false start? (--cut-stumbles removes it)",
                              s.text as CVarArg, s.range.start.seconds.doubleValue, s.trailing ? "end" : "start", s.cut.order))
        }
        return out
    }

    /// Script lines that resolved to overlapping moments — a genuine ambiguity, since one moment
    /// cannot be two cuts. Reported so a person decides, rather than broken silently by whichever
    /// scored a hundredth higher.
    public static func collisions(_ located: [(cut: ScriptCut, range: TimeRange?, similarity: Double)])
    -> [(ScriptCut, ScriptCut)] {
        var out: [(ScriptCut, ScriptCut)] = []
        let placed = located.compactMap { entry -> (ScriptCut, TimeRange)? in
            entry.range.map { (entry.cut, $0) }
        }
        for i in 0..<placed.count {
            for j in (i + 1)..<placed.count where placed[i].1.overlaps(placed[j].1) {
                out.append((placed[i].0, placed[j].0))
            }
        }
        return out
    }
}
