// "Edit mine like that one" — and, harder and more useful, "what do I need to record?"
//
// The person this is for is not an editor and does not want to become one. They can record. So the
// agent has to close the rest of the gap, and the hardest part is not the cutting — it is that a
// reference edit usually cannot be made from the footage they shot. Six cutaways cannot be cut from
// a single continuous take, and no amount of cleverness recovers a second angle that was never
// filmed.
//
// So a reference video is measured twice, for two different questions:
//
//   EditStyle       what the reference DID — pace, shot mix, caption density, pause discipline.
//                   These become targets for cutting the user's own footage.
//   RecordingBrief  what somebody would have to SHOOT to make that edit possible at all.
//                   This is the answer that saves the person a wasted afternoon.
//
// Both are measurements of ONE video, and that is stated rather than hidden. A style extracted from
// a single reference describes that reference; calling it "the TikTok style" would be inventing a
// population from a sample of one.

import Foundation
import SharpyEngine
import SharpyRender

public struct EditStyle: Sendable, Codable {
    public let sourceName: String
    public let duration: TimeValue
    public let width: Int, height: Int
    public let frameRate: Double

    /// Cutting.
    public let shotCount: Int
    public let medianShotSeconds: Double
    public let cutsPerMinute: Double
    /// Proportion of screen time at each shot size, when a scene pass has run.
    public let shotSizeMix: [String: Double]

    /// Speaking.
    public let wordCount: Int
    public let wordsPerMinute: Double
    public let speakerCount: Int?
    /// Fraction of the piece with no speech — pause discipline, which is most of what "pacy" means.
    public let silenceFraction: Double

    /// On-screen text.
    public let framesWithText: Double        // 0…1 of sampled frames
    public let distinctTextLines: Int
    public let textLinesPerMinute: Double

    /// Sound.
    public let integratedLUFS: Double?

    public var isVertical: Bool { height > width }
    public var minutes: Double { max(duration.seconds.doubleValue / 60, 0.001) }

    public var summary: String {
        var lines = ["style of \(sourceName) — \(width)×\(height)\(isVertical ? " vertical" : ""), "
                     + String(format: "%.1f s at %.0f fps", duration.seconds.doubleValue, frameRate)]
        lines.append(String(format: "  cutting: %d shots, median %.1f s, %.1f cuts per minute",
                            shotCount, medianShotSeconds, cutsPerMinute))
        if !shotSizeMix.isEmpty {
            let mix = shotSizeMix.sorted { $0.value > $1.value }
                .map { String(format: "%@ %.0f%%", $0.key, $0.value * 100) }.joined(separator: ", ")
            lines.append("  framing: \(mix)")
        }
        lines.append(String(format: "  speech: %d words at %.0f wpm, %.0f%% of the piece is pause",
                            wordCount, wordsPerMinute, silenceFraction * 100))
        if let speakerCount { lines.append("  voices: \(speakerCount)") }
        lines.append(String(format: "  text on screen in %.0f%% of frames, %d distinct lines (%.1f per minute)",
                            framesWithText * 100, distinctTextLines, textLinesPerMinute))
        if let integratedLUFS { lines.append(String(format: "  loudness: %.1f LUFS", integratedLUFS)) }
        return lines.joined(separator: "\n")
    }
}

/// What somebody has to record for that edit to be possible.
public struct RecordingBrief: Sendable {
    public let style: EditStyle
    /// Distinct camera setups the reference appears to use.
    public let setups: Int
    /// Seconds of cutaway/B-roll the reference spends away from the main framing.
    public let cutawaySeconds: Double
    /// How many separate cutaway moments.
    public let cutawayCount: Int
    /// Words to write, to fill the runtime at the reference's pace.
    public let wordBudget: Int
    /// What could NOT be determined, said plainly.
    public let unknowns: [String]

    /// Shoot more than the edit uses. Some takes will be unusable, and a cutaway you did not shoot
    /// cannot be recovered later — whereas one you did not use costs nothing but disk.
    public static let overshootFactor = 1.6

    public var script: String {
        var lines: [String] = []
        lines.append("TO MAKE THIS EDIT, RECORD:")
        lines.append("")
        lines.append(String(format: "  Runtime      about %.0f seconds finished",
                            style.duration.seconds.doubleValue))
        lines.append("  Orientation  " + (style.isVertical
            ? "vertical, \(style.width)×\(style.height) — shoot vertically, do not crop later"
            : "horizontal, \(style.width)×\(style.height)"))
        lines.append(String(format: "  Script       about %d words. At %.0f words per minute that fills the runtime; "
                            + "write it out and read it, because that pace is not conversational.",
                            wordBudget, style.wordsPerMinute))
        lines.append("")
        lines.append("  MAIN PIECE TO CAMERA")
        if let dominant = style.shotSizeMix.max(by: { $0.value < $1.value })?.key {
            lines.append("    Framing    \(dominant) — the reference holds this for "
                         + String(format: "%.0f%% of its screen time",
                                  (style.shotSizeMix[dominant] ?? 0) * 100))
        }
        lines.append("    Take it in one continuous run if you can. Cutting a single take is easy; "
                     + "matching two takes of the same framing is not.")
        lines.append("")
        if cutawayCount > 0 {
            lines.append("  CUTAWAYS — this is the part people forget, and without it the edit cannot be made")
            lines.append(String(format: "    The reference cuts away %d times, %.0f seconds in total.",
                                cutawayCount, cutawaySeconds))
            lines.append(String(format: "    Shoot at least %d separate cutaways of a few seconds each.",
                                Int((Double(cutawayCount) * RecordingBrief.overshootFactor).rounded(.up))))
            lines.append("    More than the edit needs, on purpose: some will be unusable, and one you "
                         + "did not shoot cannot be recovered.")
            lines.append("")
        }
        if style.framesWithText > 0.2 {
            lines.append(String(format: "  ON-SCREEN TEXT — %.0f%% of the reference has text up, %d distinct lines.",
                                style.framesWithText * 100, style.distinctTextLines))
            lines.append("    Nothing to record for this; it is added in the edit. Do leave the frame "
                         + "uncluttered where it will sit.")
            lines.append("")
        }
        lines.append("  SOUND")
        lines.append("    One voice, close to the mic, in the quietest room you have. Room tone is the "
                     + "one thing that cannot be fixed convincingly afterwards.")
        if !unknowns.isEmpty {
            lines.append("")
            lines.append("  WHAT THIS BRIEF CANNOT TELL YOU")
            for u in unknowns { lines.append("    · \(u)") }
        }
        return lines.joined(separator: "\n")
    }
}

public enum EditStyleExtractor {
    /// Measure a reference. Every field comes from a layer that has actually run; layers that have
    /// not are reported as unknown rather than defaulted, because a brief that quietly guesses is
    /// worse than one that says it does not know.
    public static func extract(name: String,
                               duration: TimeValue, width: Int, height: Int, frameRate: Double,
                               shots: ShotIndex?, transcript: Transcript?, vision: VisionIndex?,
                               scenes: SceneIndex?, speakers: SpeakerIndex?,
                               speech: SpeechProfile?, loudness: LoudnessReading?) -> EditStyle {
        let minutes = max(duration.seconds.doubleValue / 60, 0.001)

        let shotList = shots?.shots ?? []
        let median = shotList.isEmpty ? duration.seconds.doubleValue
            : shots!.medianDuration.seconds.doubleValue
        let shotCount = shotList.isEmpty ? 1 : shotList.count

        var mix: [String: Double] = [:]
        if let scenes, !scenes.observations.isEmpty {
            let usable = scenes.observations.filter { $0.standing.usable }
            if !usable.isEmpty {
                for observation in usable {
                    mix[observation.shot.rawValue, default: 0] += 1
                }
                for key in mix.keys { mix[key]! /= Double(usable.count) }
            }
        }

        let words = transcript?.words.count ?? 0
        let textLines = Set((vision?.frames ?? []).flatMap { $0.text.map(\.text) })
        let framesWithText = (vision?.frames.isEmpty ?? true) ? 0
            : Double(vision!.frames.filter { !$0.text.isEmpty }.count) / Double(vision!.frames.count)
        let silenceFraction = speech.map {
            $0.totalSilence.seconds.doubleValue / max(duration.seconds.doubleValue, 0.001)
        } ?? 0

        return EditStyle(
            sourceName: name, duration: duration, width: width, height: height, frameRate: frameRate,
            shotCount: shotCount, medianShotSeconds: median,
            cutsPerMinute: Double(max(shotCount - 1, 0)) / minutes,
            shotSizeMix: mix,
            wordCount: words, wordsPerMinute: Double(words) / minutes,
            speakerCount: speakers?.speakerCount, silenceFraction: silenceFraction,
            framesWithText: framesWithText, distinctTextLines: textLines.count,
            textLinesPerMinute: Double(textLines.count) / minutes,
            integratedLUFS: loudness?.integrated)
    }

    /// Turn a measured style into instructions for a person holding a phone.
    public static func brief(for style: EditStyle, scenes: SceneIndex?) -> RecordingBrief {
        // A cutaway is screen time NOT at the dominant framing. Without a scene pass that cannot be
        // separated from an ordinary cut, and saying so beats inventing a number.
        var cutawaySeconds = 0.0
        var cutawayCount = 0
        var unknowns: [String] = []

        if let scenes, !scenes.observations.isEmpty,
           let dominant = style.shotSizeMix.max(by: { $0.value < $1.value })?.key {
            let usable = scenes.observations.filter { $0.standing.usable }.sorted { $0.time < $1.time }
            var inCutaway = false
            for observation in usable {
                let away = observation.shot.rawValue != dominant
                if away { cutawaySeconds += 1 }          // observations are sampled per second
                if away && !inCutaway { cutawayCount += 1 }
                inCutaway = away
            }
        } else {
            unknowns.append("how much of this is cutaway rather than the main framing — that needs a scene pass, which has not run on the reference")
        }

        // Two setups if there is meaningful time away from the dominant framing. This CANNOT
        // distinguish a second camera from a punch-in on the same one, and pretending otherwise
        // would send someone out to hire a camera they do not need.
        let setups = cutawaySeconds > 2 ? 2 : 1
        if setups > 1 {
            unknowns.append("whether the cutaways are a second camera or a punch-in on the same one — both look identical after the edit, and the punch-in is cheaper")
        }
        if style.speakerCount ?? 1 > 1 {
            unknowns.append("whether the extra voices are people in the room or added afterwards")
        }
        unknowns.append("anything the reference did that leaves no trace in the picture — music choice, and how much footage was thrown away to get this one")

        return RecordingBrief(
            style: style, setups: setups,
            cutawaySeconds: cutawaySeconds, cutawayCount: cutawayCount,
            wordBudget: Int((style.wordsPerMinute * style.minutes).rounded()),
            unknowns: unknowns)
    }
}
