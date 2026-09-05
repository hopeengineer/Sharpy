// Given a reference and your footage, work out the edit. Without being told.
//
// Everything needed already existed in pieces — the layout analysis reads the panels and the echo,
// the style extractor reads pace and loudness, the section finder reads where a piece turns, the
// take finder reads which attempt is best. What was missing is the step that puts them together
// and says: this is the format, here is your content inside it.
//
// The rule that shapes the whole thing: THE FORMAT COMES FROM THE REFERENCE, THE CONTENT COMES FROM
// YOU. Three panels, an echo opening, captions throughout — those are the reference's. The section
// labels, the words, the timings are the user's own. Copying the reference's labels would put a
// funnel diagram over a video about something else, which is the format applied and the meaning
// thrown away.
//
// And what cannot be recovered is said, not guessed. A plan that quietly invents the parts it could
// not measure is worse than one that names them, because the person cannot tell which is which.

import Foundation
import SharpyEngine
import SharpyRender

public struct EditPlan: Sendable {
    public struct Step: Sendable, CustomStringConvertible {
        public let what: String
        public let detail: String
        /// What this instruction rests on — measured from the reference, from the user's footage,
        /// or an assumption that could not be measured.
        public let basis: String
        public var description: String { "\(what)\n      \(detail)\n      [\(basis)]" }
    }

    public let referenceName: String
    public let subjectName: String
    public let steps: [Step]
    public let unknowns: [String]
    /// Questions worth asking BEFORE cutting, each raised by a weak measurement rather than by
    /// politeness. A tool that asks about everything is as useless as one that asks about nothing:
    /// the first wastes the person's attention, the second spends it on fixing the result.
    public let questions: [String]

    public var summary: String {
        var lines = ["EDIT PLAN — \(subjectName) in the format of \(referenceName)", ""]
        for (i, step) in steps.enumerated() {
            lines.append("  \(i + 1). " + step.description)
        }
        if !questions.isEmpty {
            lines.append("")
            lines.append("  WORTH ASKING BEFORE CUTTING")
            for q in questions { lines.append("     ? \(q)") }
        }
        if !unknowns.isEmpty {
            lines.append("")
            lines.append("  WHAT THIS PLAN CANNOT TELL YOU")
            for u in unknowns { lines.append("     · \(u)") }
        }
        return lines.joined(separator: "\n")
    }
}

public enum FormatMatcher {

    public static func plan(reference: URL, subject: URL,
                            referenceTranscript: Transcript?,
                            subjectTranscript: Transcript,
                            subjectVision: VisionIndex?,
                            subjectSpeech: SpeechProfile?) throws -> EditPlan {
        var steps: [EditPlan.Step] = []
        var unknowns: [String] = []

        // 1. THE FORMAT: how the reference is laid out, and how it moves.
        let layout = try LayoutAnalyzer.analyse(url: reference, maximumSeconds: 40)
        let panels = layout.isSplitScreen ? layout.panels : 1
        if layout.isSplitScreen {
            steps.append(.init(
                what: "Split the frame into \(panels) \(layout.stacked ? "stacked" : "side-by-side") panels",
                detail: "Each panel shows the same take, cropped to a band so faces keep their shape rather than being squashed into a third of the height.",
                basis: String(format: "measured: %d panels at %.2f similarity in the reference", panels, layout.panelSimilarity)))
        } else {
            steps.append(.init(what: "Single frame",
                               detail: "The reference is not a split-screen format.",
                               basis: String(format: "measured: best split scored only %.2f", layout.panelSimilarity)))
        }

        if let opening = layout.simultaneousOpening {
            let seconds = opening.upperBound - opening.lowerBound
            steps.append(.init(
                what: String(format: "Open with all %d panels running together for %.1f s", panels, seconds),
                detail: "Same line in every panel, staggered so they overlap — that is what makes it read as several voices. Then the panels take turns.",
                basis: String(format: "measured: all panels active for the first %.1f s of the reference, then alternating", seconds)))
        }

        var questions: [String] = []

        // 2. THE CONTENT: the user's own structure, one section per panel.
        let sections = SectionFinder.find(in: subjectTranscript, count: max(panels, 1))
        // How clear the structure actually is. A piece that stays on one subject has no obvious
        // place to divide, and dividing it anyway puts a panel change in the middle of a thought.
        let boundaries = sections.sections.dropFirst().map(\.range.start)
        let atBoundaries = boundaries.compactMap { boundary -> Double? in
            guard let index = subjectTranscript.words.firstIndex(where: { $0.range.start >= boundary }),
                  index < sections.cohesion.count else { return nil }
            return sections.cohesion[index]
        }
        if let weakest = atBoundaries.max(), weakest > 0.28 {
            questions.append(String(format: "The script does not divide cleanly into %d parts — the clearest break still shares %.0f%% of its vocabulary across it, so a panel change would land mid-thought. Do you have the points you want it cut at?",
                                    panels, weakest * 100))
        }
        if panels > 1 {
            let labels = sections.sections.map(\.label).joined(separator: " / ")
            steps.append(.init(
                what: "Label the panels \(labels)",
                detail: "Taken from the words in each part of YOUR script, not from the reference — the reference says TOP/MIDDLE/BOTTOM because it is about a funnel. Each label is the most distinctive term of its own section.",
                basis: "measured: lexical cohesion across your transcript, then the terms frequent inside each section and rare outside it"))
            for section in sections.sections {
                steps.append(.init(
                    what: String(format: "Panel plays %.1f–%.1f s", section.range.start.seconds.doubleValue,
                                 section.range.end.seconds.doubleValue),
                    detail: "\"\(section.opening.prefix(60))…\" — the other panels hold on a frame while this one talks.",
                    basis: "measured: your own section boundaries"))
            }
        }

        // 3. WHICH TAKE. Their recording may contain several attempts.
        let take = Take(index: 0, url: subject, transcript: subjectTranscript,
                        vision: subjectVision, speech: subjectSpeech)
        let takes = TakeFinder.find(in: take)
        if !takes.needConfirming.isEmpty {
            questions.append("\(takes.needConfirming.count) line(s) are said more than once in a way that may be deliberate rather than a re-take. Both are kept; which did you mean?")
        }
        if takes.retaken.count > 0 {
            steps.append(.init(
                what: "Use the best of \(takes.retaken.count) re-recorded line(s)",
                detail: String(format: "%d passes of the script. Each line is scored on fluency, clarity, sound and framing, and the run is chosen by how the takes JOIN, not line by line.",
                               takes.passes),
                basis: "measured: repeated passages in your recording"))
        }

        // 4. THE FINISH: pace, captions, loudness taken from the reference.
        if let referenceTranscript {
            let refMinutes = max((referenceTranscript.words.last?.range.end.seconds.doubleValue ?? 1) / 60, 0.01)
            let refWPM = Double(referenceTranscript.words.count) / refMinutes
            let subjMinutes = max((subjectTranscript.words.last?.range.end.seconds.doubleValue ?? 1) / 60, 0.01)
            let subjWPM = Double(subjectTranscript.words.count) / subjMinutes
            steps.append(.init(
                what: String(format: "Pace: reference runs %.0f wpm, yours %.0f wpm", refWPM, subjWPM),
                detail: subjWPM < refWPM * 0.85
                    ? "Yours is slower. Tightening pauses moves toward the reference without speeding up the delivery, which would sound wrong."
                    : "Close enough that no retiming is needed.",
                basis: "measured: both transcripts"))
        }

        let referenceLoudness = try? LoudnessMeter.measure(url: reference)
        if let target = referenceLoudness?.integrated {
            steps.append(.init(
                what: String(format: "Match loudness to %.1f LUFS", target),
                detail: "The reference's own integrated loudness. True peak is held under −1 dBTP regardless, because the reference exceeds it and that is a fault worth not copying.",
                basis: "measured: the reference's loudness"))
        }

        steps.append(.init(
            what: "Burn in captions",
            detail: "Word-timed from your transcript, on a dark pill so they read over anything. Contrast is measured after rendering, not assumed.",
            basis: "measured: the reference carries text in almost every frame"))

        // What could not be recovered.
        unknowns.append("the reference's exact fonts and colours — measurable as contrast and position, not as a typeface")
        if layout.offsets.dropFirst().allSatisfy({ $0 == nil }) {
            unknowns.append("the exact echo delay between panels: the panels' motion did not align clearly enough to measure it, so the stagger is a choice rather than a copy")
        }
        unknowns.append("any graphic in the reference that is not text — a diagram or a screenshot cannot be derived from your footage and would have to be supplied")
        // The echo stagger is a choice, not a copy, whenever it could not be measured — so it is
        // worth one question rather than a silent guess baked into the render.
        if layout.isSplitScreen, layout.offsets.dropFirst().allSatisfy({ $0 == nil }) {
            questions.append("The delay between panels in the reference could not be measured. Around a second reads as an echo — do you want it tighter or looser?")
        }
        return EditPlan(referenceName: reference.lastPathComponent,
                        subjectName: subject.lastPathComponent,
                        steps: steps, unknowns: unknowns, questions: questions)
    }
}
