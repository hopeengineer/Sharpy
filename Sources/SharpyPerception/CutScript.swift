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
    public static func locate(_ script: ParsedScript, in transcript: Transcript,
                              minimumSimilarity: Double = 0.45)
    -> [(cut: ScriptCut, range: TimeRange?, similarity: Double)] {
        let words = transcript.words.sorted { $0.index < $1.index }
        let spoken = words.map { TakeSelector.key($0.text) }
        guard !spoken.isEmpty else { return script.cuts.map { ($0, nil, 0) } }

        var out: [(ScriptCut, TimeRange?, Double)] = []
        for cut in script.cuts {
            let wanted = TakeSelector.key(cut.text).split(separator: " ").map(String.init)
            guard !wanted.isEmpty else { out.append((cut, nil, 0)); continue }
            var best: (start: Int, end: Int, score: Double)?
            // Windows around the line's own length: delivery adds and drops words, so a window
            // fixed at exactly the script's length would miss every line that was not read verbatim.
            let lengths = Set([wanted.count, Int(Double(wanted.count) * 1.5) + 1,
                               max(Int(Double(wanted.count) * 0.7), 2)])
            for start in 0..<spoken.count {
                for length in lengths {
                    let end = min(start + length, spoken.count)
                    guard end - start >= 2 else { continue }
                    let score = TakeSelector.similarity(wanted, Array(spoken[start..<end]))
                    if score > (best?.score ?? 0) { best = (start, end, score) }
                }
            }
            if let best, best.score >= minimumSimilarity {
                out.append((cut, TimeRange(start: words[best.start].range.start,
                                           end: words[best.end - 1].range.end), best.score))
            } else {
                out.append((cut, nil, best?.score ?? 0))
            }
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
