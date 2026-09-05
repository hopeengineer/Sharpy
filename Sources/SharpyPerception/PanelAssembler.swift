// Three panels that PAUSE, rather than three sequences of clips.
//
// The distinction the user drew, and it changes the whole construction. When the edit moves from
// one panel to another the first does not end — it FREEZES on the frame it reached, and when the
// edit comes back it carries on from exactly there. You can see it in the hands: a gesture stops
// mid-air and completes several seconds later.
//
// Built as clips-per-visit that would be wrong in a way nobody could name but everybody would feel,
// because each return would restart the panel somewhere arbitrary and the gesture would jump.
//
// So each panel keeps a PLAYHEAD into its own take. A visit plays that panel forward from where it
// stopped; the other panels hold a single frame — which is `Clip.freeze`, the one-frame source
// stretched over the hold that retiming already provides.
//
// It also fits how the material was recorded: the user shot one continuous take per panel, all the
// top lines, then all the centre, then all the bottom. Each panel's playhead simply walks through
// its own take.

import Foundation
import SharpyEngine
import SharpyRender

public struct PanelPlan: Sendable {
    public struct Beat: Sendable {
        /// Which panel talks. Nil for the opening, where they all do.
        public let panel: Int?
        public let text: String
        /// Where this comes from in the recording.
        public let source: TimeRange
        /// Where it lands in the finished piece.
        public let timeline: TimeRange
        /// How far behind each panel runs during the opening, per step down the stack.
        ///
        /// The hook is not three copies of one frame — the panels say the same words a beat apart,
        /// which is what makes it read as an echo rather than as a rendering mistake. Rendered with
        /// no offset it came out as three identical bands, which looks like a bug even though every
        /// check passed.
        public let echoStep: TimeValue
        /// What each panel shows: playing this source range, or frozen at this instant.
        public let frozenAt: [Int: TimeValue]
    }

    public let panels: Int
    public let beats: [Beat]
    public let duration: TimeValue
    public let unmatched: [String]

    public var summary: String {
        var lines = [String(format: "panel plan: %d panels, %d beat(s), %.1f s finished",
                            panels, beats.count, duration.seconds.doubleValue)]
        for beat in beats.prefix(20) {
            let who = beat.panel.map { "panel \($0 + 1)" } ?? "all panels"
            lines.append(String(format: "  %6.2f–%6.2f  %-8@ ← source %6.2f–%6.2f  \"%@\"",
                                beat.timeline.start.seconds.doubleValue,
                                beat.timeline.end.seconds.doubleValue,
                                who as CVarArg,
                                beat.source.start.seconds.doubleValue,
                                beat.source.end.seconds.doubleValue,
                                beat.text.prefix(36) as CVarArg))
        }
        if beats.count > 20 { lines.append("  … \(beats.count - 20) more") }
        if !unmatched.isEmpty {
            lines.append("  \(unmatched.count) scripted line(s) could not be placed:")
            for u in unmatched.prefix(4) { lines.append("     · \"\(u.prefix(48))\"") }
        }
        return lines.joined(separator: "\n")
    }
}

public enum PanelAssembler {

    /// Build the plan from a located script.
    ///
    /// - Parameter located: each scripted cut and where it falls in the recording.
    /// - Parameter panels: how many panels the format uses.
    /// - Parameter frameRate: the grid every time in the plan is snapped to.
    ///
    /// Word timings are arbitrary rationals — a boundary at 78/25 s is a real instant but not a
    /// frame at 30, and a plan that quotes times the renderer cannot use is a plan describing a
    /// different edit from the one that comes out. So the snapping happens here, where the numbers
    /// are decided, rather than in the renderer where it would silently disagree with what was
    /// printed. A beat never rounds to nothing: one frame is the floor.
    /// - Parameter echo: how far apart the panels run during the opening. Measured off a reference
    ///   when there is one; zero means the panels open in unison.
    public static func plan(located: [(cut: ScriptCut, range: TimeRange?, similarity: Double)],
                            panels: Int, frameRate: FrameRate,
                            echo: TimeValue = .zero) -> PanelPlan {
        func snap(_ time: TimeValue) -> TimeValue {
            TimeValue(frames: time.nearestFrame(at: frameRate), at: frameRate)
        }
        var beats: [PanelPlan.Beat] = []
        var unmatched: [String] = []
        // Where each panel has got to in its own take. A panel that has not spoken yet shows its
        // first frame, so the opening is not three black rectangles.
        var frozen: [Int: TimeValue] = [:]
        var playhead = TimeValue.zero

        for entry in located {
            guard let source = entry.range else {
                unmatched.append(entry.cut.text)
                continue
            }
            let from = snap(source.start)
            let length = max(snap(source.duration).frame(at: frameRate), 1)
            let onGrid = TimeRange(start: from, end: from + TimeValue(frames: length, at: frameRate))
            let duration = onGrid.duration
            let row = entry.cut.panel.row(of: panels)
            // The opening belongs to no panel: every one of them plays.
            let active: Int? = entry.cut.isHook ? nil : row
            if active == nil && !entry.cut.isHook {
                unmatched.append(entry.cut.text + "  (no panel for \"\(entry.cut.panel.rawValue)\")")
                continue
            }
            beats.append(PanelPlan.Beat(
                panel: active, text: entry.cut.text, source: onGrid,
                timeline: TimeRange(start: playhead, end: playhead + duration),
                echoStep: active == nil ? snap(echo) : .zero,
                frozenAt: frozen))
            // Only the panel that spoke advances. That is the pause: the others are exactly where
            // they were, and will carry on from there.
            if let active { frozen[active] = onGrid.end }
            else { for p in 0..<panels { frozen[p] = onGrid.end } }
            playhead = playhead + duration
        }
        return PanelPlan(panels: panels, beats: beats, duration: playhead, unmatched: unmatched)
    }

    /// Turn the plan into a document: one track per panel, each carrying playing clips and freezes.
    public static func assemble(_ plan: PanelPlan, asset: AssetRef, frameRate: FrameRate,
                                basis: Basis) throws -> CommandLog {
        var log = CommandLog(initial: Document(timeline: Timeline(name: asset.path, frameRate: frameRate)))
        try log.append(.addAsset(asset))
        let id = log.head.assets.keys.first!
        for panel in 0..<plan.panels { try log.append(.addTrack(kind: .video, name: "panel\(panel + 1)")) }
        if asset.hasAudio { try log.append(.addTrack(kind: .audio, name: "A1")) }

        let third = Rational(1, Int64(plan.panels))
        func placement(_ panel: Int) -> ClipPlacement {
            // Each band shows the MIDDLE of the source, cropped rather than scaled — squeezing a
            // whole frame into a third of the height would flatten every face.
            let keep = third
            let trim = (Rational(1, 1) - keep) / Rational(2, 1)
            return ClipPlacement(x: .zero, y: third * Rational(Int64(panel)), width: .one,
                                 height: third, cropTop: trim, cropBottom: trim)
        }

        let oneFrame = TimeValue(frames: 1, at: frameRate)
        for beat in plan.beats {
            let decision = Decision(kind: beat.panel == nil ? .graphic : .cut,
                                    at: beat.timeline.start,
                                    params: ["line": String(beat.text.prefix(60))],
                                    basis: basis)
            for panel in 0..<plan.panels {
                let plays = beat.panel == nil || beat.panel == panel
                let start = TimeValue(frames: beat.timeline.start.nearestFrame(at: frameRate), at: frameRate)
                let length = TimeValue(frames: max(beat.timeline.duration.nearestFrame(at: frameRate), 1), at: frameRate)
                if plays {
                    let from = TimeValue(frames: beat.source.start.nearestFrame(at: frameRate), at: frameRate)
                    try log.append(.placeClip(track: panel,
                        clip: Clip(asset: id, source: TimeRange(start: from, end: from + length),
                                   start: start, placement: placement(panel)),
                        decision: decision))
                } else {
                    // Held exactly where it stopped. A panel that has not spoken yet holds its
                    // first frame rather than nothing.
                    let at = beat.frozenAt[panel] ?? .zero
                    let held = TimeValue(frames: at.nearestFrame(at: frameRate), at: frameRate)
                    try log.append(.placeClip(track: panel,
                        clip: Clip.freeze(asset: id, at: held, frameDuration: oneFrame,
                                          start: start, duration: length,
                                          placement: placement(panel)),
                        decision: decision))
                }
            }
            if asset.hasAudio {
                let from = beat.source.start.alignedToSample(at: 48_000)
                let to = beat.source.end.alignedToSample(at: 48_000)
                if from < to {
                    try log.append(.placeClip(track: plan.panels,
                        clip: Clip(asset: id, source: TimeRange(start: from, end: to),
                                   start: beat.timeline.start.alignedToSample(at: 48_000)),
                        decision: decision))
                }
            }
        }
        return log
    }
}
