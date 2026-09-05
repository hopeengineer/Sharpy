// Listening to the finished edit, against the script it was cut from.
//
// The first three-panel render passed every check it had and was wrong in six places that anyone
// listening for thirty seconds would have caught: a line heard twice, four lines chopped mid-word,
// the second panel's intro after the third's. The checks looked at pixels. This one listens.
//
// It transcribes the OUTPUT and asks, beat by beat in script order: is the line there, where the
// plan put it; do the closing words of one beat turn up again at the start of the next; do the
// closing words the speaker actually said make it to the end of the beat. It is the check a person
// does by watching, made automatic so it runs every time rather than when somebody remembers.

import Foundation
import SharpyEngine

public struct ReadbackReport: Sendable {
    public struct Line: Sendable {
        public let order: Int
        public let text: String
        public let heard: Bool
        public let similarity: Double
        public let repeatedAtJoin: [String]
        public let chopped: [String]
    }
    public let lines: [Line]
    public let hookHeard: Int
    public let outputWords: Int

    public var problems: [String] {
        var out: [String] = []
        for l in lines {
            if !l.heard { out.append(String(format: "cut %d not heard where the plan put it (%.0f%% alike): \"%@\"", l.order, l.similarity * 100, l.text.prefix(40) as CVarArg)) }
            if !l.repeatedAtJoin.isEmpty { out.append("cut \(l.order) ends with \"\(l.repeatedAtJoin.joined(separator: " "))\" and the next beat begins with it again — heard twice") }
            if !l.chopped.isEmpty { out.append("cut \(l.order) is chopped: the speaker said \"…\(l.chopped.joined(separator: " "))\" and the output does not") }
        }
        if hookHeard != 1 { out.append("the hook was heard \(hookHeard) time(s); once is expected — an echo of a few tens of milliseconds reads as one voice") }
        return out
    }

    public var summary: String {
        let heard = lines.filter(\.heard).count
        var s = ["readback: \(heard)/\(lines.count) lines heard in order, "
                 + "\(lines.filter { !$0.repeatedAtJoin.isEmpty }.count) repeated at a join, "
                 + "\(lines.filter { !$0.chopped.isEmpty }.count) chopped, hook heard \(hookHeard)×  (\(outputWords) words in the output)"]
        s += problems.map { "  ✗ " + $0 }
        if problems.isEmpty { s.append("  the edit says what the script says, once each, in order") }
        return s.joined(separator: "\n")
    }
}

public enum ScriptReadback {
    /// - Parameter output: the transcript OF THE RENDERED FILE.
    /// - Parameter source: the transcript of the recording, to know what the speaker actually said
    ///   at the end of each span — the script's last words are not always theirs.
    public static func check(output: Transcript, source: Transcript, plan: PanelPlan,
                             hook: String?, slack: Double = 0.6) -> ReadbackReport {
        let outWords = output.words.sorted { $0.index < $1.index }
        let srcWords = source.words.sorted { $0.index < $1.index }
        func key(_ w: Word) -> String { TakeSelector.key(w.text) }
        func tokens(_ text: String) -> [String] { TakeSelector.key(text).split(separator: " ").map(String.init) }
        func midpoint(_ w: Word) -> TimeValue { w.range.start + TimeValue(seconds: w.range.duration.seconds / Rational(2)) }
        /// Fraction of `want` found, in order, among `heard`.
        func containment(_ want: [String], in heard: [String]) -> Double {
            guard !want.isEmpty, !heard.isEmpty else { return 0 }
            let ratio = TakeSelector.similarity(want, heard, match: CutScript.sameWord)
            return ratio * Double(max(want.count, heard.count)) / Double(want.count)
        }
        func within(_ words: [Word], _ range: TimeRange, pad: Double) -> [Word] {
            let padT = TimeValue(seconds: Rational(Int64(pad * 1000), 1000))
            let from = range.start.seconds.doubleValue < pad ? TimeValue.zero : range.start - padT
            let wide = TimeRange(start: from, end: range.end + padT)
            return words.filter { $0.range.overlaps(wide) }
        }

        var lines: [ReadbackReport.Line] = []
        let ordered = plan.beats
        for (i, beat) in ordered.enumerated() where beat.panel != nil {
            let want = tokens(beat.text)
            let heardWords = within(outWords, beat.timeline, pad: slack)
            let heardTokens = heardWords.map(key)
            // How much of the LINE is present, not how alike the two lists are. The window carries
            // slack on both sides and so holds neighbouring words; a two-word line that is entirely
            // there scored 2/7 against a seven-word window and was reported missing.
            let sim = containment(want, in: heardTokens)
            // What the speaker actually said at the end of this span, in the recording — words whose
            // MIDDLE is inside the span. A word that merely touches the boundary belongs to the next
            // line: "Second" starts at the instant "notes." ends and was being read as cut 10's tail.
            let saidTail = srcWords.filter { midpoint($0) >= beat.source.start && midpoint($0) < beat.source.end }
                .suffix(2).map(key)
            // The output's words in the last second of the beat.
            let tailWindow = TimeRange(start: beat.timeline.end - TimeValue(seconds: Rational(1)), end: beat.timeline.end)
            let outTail = within(outWords, tailWindow, pad: 0.3).map(key)
            let chopped = saidTail.filter { said in !outTail.contains { CutScript.sameWord(said, $0) } }
            // The start of the NEXT beat: does it begin with this beat's last words?
            var repeated: [String] = []
            if i + 1 < ordered.count {
                let next = ordered[i + 1]
                // Words that BEGIN after the join. The transcriber's end time for the last word of
                // a beat lands a few frames past the cut, and read by overlap that same word was
                // counted as the next beat's first — "hook" heard twice, when it was heard once.
                let joinAt = next.timeline.start + TimeValue(seconds: Rational(1, 5))
                let head = outWords.filter { $0.range.start >= joinAt && $0.range.start < joinAt + TimeValue(seconds: Rational(3, 2)) }
                    .prefix(5).map(key)
                let last = saidTail.filter { $0.count >= 4 }   // "a", "it", "to" recur legitimately
                repeated = last.filter { said in head.contains { CutScript.sameWord(said, $0) } }
                if repeated.count < last.count { repeated = [] }  // both closing words, or it is coincidence
            }
            lines.append(.init(order: i, text: beat.text, heard: sim >= 0.45, similarity: sim,
                               repeatedAtJoin: repeated, chopped: chopped.count == saidTail.count && !saidTail.isEmpty ? chopped : []))
        }

        var hookCount = 0
        if let hook {
            let want = tokens(hook)
            let all = outWords.map(key)
            var i = 0
            while i + want.count <= all.count {
                let sim = TakeSelector.similarity(want, Array(all[i..<(i + want.count)]), match: CutScript.sameWord)
                if sim >= 0.6 { hookCount += 1; i += want.count } else { i += 1 }
            }
        } else { hookCount = 1 }
        return ReadbackReport(lines: lines, hookHeard: hookCount, outputWords: outWords.count)
    }
}

extension ScriptReadback {
    /// Captions whose words are not heard in the output while they are on screen.
    public static func captionsNotHeard(_ captions: [(text: String, range: TimeRange)],
                                        in output: Transcript, slack: Double = 0.7) -> [String] {
        let words = output.words.sorted { $0.index < $1.index }
        let pad = TimeValue(seconds: Rational(Int64(slack * 1000), 1000))
        var out: [String] = []
        for caption in captions {
            let want = TakeSelector.key(caption.text).split(separator: " ").map(String.init)
            guard !want.isEmpty else { continue }
            let from = caption.range.start.seconds.doubleValue < slack ? TimeValue.zero : caption.range.start - pad
            let window = TimeRange(start: from, end: caption.range.end + pad)
            let heard = words.filter { $0.range.overlaps(window) }.map { TakeSelector.key($0.text) }
            let lcs = TakeSelector.similarity(want, heard, match: CutScript.sameWord) * Double(max(want.count, heard.count))
            if lcs / Double(want.count) < 0.5 {
                out.append(String(format: "caption \"%@\" shown %.2f–%.2f s but not heard then", caption.text as CVarArg,
                                  caption.range.start.seconds.doubleValue, caption.range.end.seconds.doubleValue))
            }
        }
        return out
    }
}

// MARK: - Against the reference

public enum ReferenceComparison {
    /// Every way the output fails to look like the reference, in the reference's own measurements.
    public static func compare(reference: ReferenceStyle, output: ReferenceStyle) -> [String] {
        var out: [String] = []
        for panel in 0..<reference.panels {
            let refLabels = reference.labels.filter { $0.panel == panel }
            let outLabels = output.labels.filter { $0.panel == panel }
            if !refLabels.isEmpty && outLabels.isEmpty {
                out.append("band \(panel + 1): the reference carries a label on every frame; the output has none")
            }
            if let r = reference.faces[panel], let o = output.faces[panel] {
                let ratio = o.heightInBand / max(r.heightInBand, 0.001)
                if ratio < 0.7 || ratio > 1.4 {
                    out.append(String(format: "band %d: face is %.0f%% of the band height, reference %.0f%%", panel + 1, o.heightInBand * 100, r.heightInBand * 100))
                }
            } else if reference.faces[panel] != nil && output.faces[panel] == nil {
                out.append("band \(panel + 1): no face found in the output")
            }
            let refRun = reference.longestFacelessRun[panel] ?? 0
            let outRun = output.longestFacelessRun[panel] ?? 0
            if outRun > max(refRun, 1.0) + 0.5 {
                out.append(String(format: "band %d: no face for %.1f s at a stretch — the reference never loses the speaker for more than %.1f s", panel + 1, outRun, refRun))
            }
        }
        if let rc = reference.captions, rc.coverage > 0.5 {
            if let oc = output.captions {
                if oc.coverage < rc.coverage * 0.5 {
                    out.append(String(format: "captions on %.0f%% of frames, reference %.0f%%", oc.coverage * 100, rc.coverage * 100))
                }
            } else {
                out.append(String(format: "the reference captions %.0f%% of its frames; the output has no captions", rc.coverage * 100))
            }
        }
        return out
    }
}
