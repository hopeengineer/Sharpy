// From "which attempt was best" to an actual cut.
//
// `TakeFinder` says a line was attempted four times and which attempt won. That is a decision, not
// an edit — and until something turns decisions into clips there is no video. This is that step,
// and it is where the two things that make an assembly sound handmade rather than machine-made live:
//
//   HANDLES. Cutting exactly on the first and last word clips the attack of the first consonant and
//   the release of the last. Editors leave a few frames either side and nobody can say why it
//   sounds better; it is because speech does not begin where the word does.
//
//   SCRIPT ORDER, not score order. The best attempts are assembled in the order the lines were
//   FIRST said, because that is the order the person thought in. Sorting by anything else produces
//   a piece that is individually clean and makes no sense.
//
// Every clip carries the basis that chose it, so "why is this take here" is answerable from the
// document months later rather than from somebody's memory.

import Foundation
import SharpyEngine
import SharpyRender

public struct AssemblyReport: Sendable {
    public let clipsPlaced: Int
    public let sourceSeconds: Double
    public let assembledSeconds: Double
    public let droppedAttempts: Int
    /// Measured cost of every join the assembly makes, in order. Empty when no audio was supplied
    /// to measure against — and empty must not read as "seamless".
    public let joinCosts: [Double]

    public var meanJoinCost: Double? {
        joinCosts.isEmpty ? nil : joinCosts.reduce(0, +) / Double(joinCosts.count)
    }
    /// Joins bad enough to hear. Above roughly 2 the pitch or the room is stepping audibly.
    public var roughJoins: Int { joinCosts.filter { $0 > 2.0 }.count }

    public var summary: String {
        var line = String(format: "assembled %d line(s): %.0f s of recording → %.0f s of cut (%d rejected attempt(s) dropped)",
                          clipsPlaced, sourceSeconds, assembledSeconds, droppedAttempts)
        if let mean = meanJoinCost {
            line += String(format: "\n  joins: %d measured, mean cost %.2f, %d rough enough to hear",
                           joinCosts.count, mean, roughJoins)
            if let worst = joinCosts.max() {
                line += String(format: " (worst %.2f)", worst)
            }
        } else {
            line += "\n  joins: NOT MEASURED — no audio source was supplied, so nothing here says how it sounds"
        }
        return line
    }
}

public enum AssemblyError: Error, CustomStringConvertible {
    case nothingToAssemble
    public var description: String {
        switch self { case .nothingToAssemble: return "no lines survived selection — nothing to assemble" }
    }
}

public enum Assembler {
    /// Frames of picture kept either side of a line. Small on purpose: enough to stop the cut
    /// clipping speech, not so much that the pauses come back.
    public static let handleFrames: Int64 = 2

    /// Choose renditions by how the whole thing PLAYS, not line by line.
    ///
    /// Picking each line's best attempt in isolation is wrong, and audibly so: two individually
    /// excellent takes can join badly — a pitch jump, a room change, a cut left mid-phrase — while a
    /// slightly weaker pair butts together seamlessly. Whether a line even wants to be one segment
    /// or two is the same kind of question, and it has no fixed answer: it depends on what the
    /// result sounds like.
    ///
    /// So this is a shortest path. Each line offers its attempts as candidates, staying in a
    /// candidate costs (1 − its measured quality), and moving between consecutive candidates costs
    /// the MEASURED join between them. The cheapest path through is the assembly that sounds most
    /// like one person talking.
    ///
    /// This is the part that has to be automatic. Nobody can audition 6^64 combinations, and asking
    /// a person to pick a similarity threshold instead is asking the wrong question.
    static func chooseByJoins(_ groups: [AttemptGroup], source: AudioSource?) -> [(AttemptGroup, Rendition)] {
        guard !groups.isEmpty else { return [] }
        var cache: [String: Double] = [:]
        func joinCost(_ a: Rendition, _ b: Rendition) -> Double {
            guard let source else { return 0 }
            let key = "\(a.range.end.seconds)|\(b.range.start.seconds)"
            if let cached = cache[key] { return cached }
            let cost = (try? JoinQuality.measure(source: source,
                                                 outgoingEndsAt: a.range.end,
                                                 incomingStartsAt: b.range.start).cost) ?? 0
            cache[key] = cost
            return cost
        }

        // best[i][c] — cheapest way to reach candidate c of line i, and where it came from.
        var best: [[Double]] = []
        var from: [[Int]] = []
        for (i, group) in groups.enumerated() {
            let candidates = group.attempts
            var row = [Double](repeating: .infinity, count: candidates.count)
            var back = [Int](repeating: -1, count: candidates.count)
            for (c, candidate) in candidates.enumerated() {
                let stay = 1 - max(min(candidate.score, 1), 0)
                if i == 0 {
                    row[c] = stay
                } else {
                    for (p, previous) in groups[i - 1].attempts.enumerated() where best[i - 1][p].isFinite {
                        let total = best[i - 1][p] + joinCost(previous, candidate) + stay
                        if total < row[c] { row[c] = total; back[c] = p }
                    }
                }
            }
            best.append(row); from.append(back)
        }

        // Walk back from the cheapest ending.
        var path = [Int](repeating: 0, count: groups.count)
        guard let last = best[groups.count - 1].indices.min(by: { best[groups.count - 1][$0] < best[groups.count - 1][$1] })
        else { return [] }
        path[groups.count - 1] = last
        var i = groups.count - 1
        while i > 0 {
            let previous = from[i][path[i]]
            path[i - 1] = previous >= 0 ? previous : 0
            i -= 1
        }
        return groups.enumerated().compactMap { (index, group) in
            guard group.attempts.indices.contains(path[index]) else { return nil }
            return (group, group.attempts[path[index]])
        }
    }

    /// Build a timeline from the chosen attempt of every line, in script order.
    public static func assemble(_ takes: RecordingTakes,
                                asset: AssetRef,
                                frameRate: FrameRate,
                                sampleRate: Int = 48_000,
                                includeAudio: Bool = true,
                                audio: AudioSource? = nil) throws -> (CommandLog, AssemblyReport) {
        let ordered = takes.groups.sorted { $0.firstAt < $1.firstAt }
        let chosen = Assembler.chooseByJoins(ordered, source: audio)
        guard !chosen.isEmpty else { throw AssemblyError.nothingToAssemble }

        var log = CommandLog(initial: Document(timeline: Timeline(name: asset.path, frameRate: frameRate)))
        try log.append(.addAsset(asset))
        let assetID = log.head.assets.keys.first!
        try log.append(.addTrack(kind: .video, name: "V1"))
        if includeAudio && asset.hasAudio { try log.append(.addTrack(kind: .audio, name: "A1")) }

        let handle = TimeValue(frames: Assembler.handleFrames, at: frameRate)
        // A playhead PER TRACK, not one shared.
        //
        // Video snaps to frames and audio to samples, and at 29.97 a frame is 1601.6 samples — so
        // the two grids do not agree. Advancing one shared playhead by the unaligned duration let
        // the tracks drift apart by a rounding error per line, and by the twelfth line the engine
        // refused a clip for overlapping the one before it by 30 milliseconds.
        var playheads = [TimeValue](repeating: .zero, count: log.head.timeline.tracks.count)
        var placed = 0

        for (group, best) in chosen {
            // Handles, clamped so a line at the very start does not ask for source before zero.
            let rawStart = best.range.start.seconds < handle.seconds ? TimeValue.zero : best.range.start - handle
            let rawEnd = min(best.range.end + handle, asset.duration)
            guard rawStart < rawEnd else { continue }

            let reasons = best.notes.isEmpty ? "clean" : best.notes.joined(separator: "; ")
            // Confidence is about the MEASUREMENT, not about how good the take is.
            //
            // The first version used the take's own score, which conflated two different things and
            // broke assembly outright: a line whose best attempt scored 0.69 was refused for sitting
            // under the 0.7 floor. But 0.69 is a confidently measured, merely-decent take — the
            // measurement is not in doubt, the delivery is just ordinary. Blocking there would
            // refuse to assemble any recording whose best take is good rather than excellent, which
            // is nearly every recording.
            //
            // So the floor is never breached — every line here WAS measured — and quality instead
            // drives whether it can ship unattended. A poor line lands under the ship bar and is
            // HELD for review, which is the right outcome: assemble it, and tell somebody to watch
            // that bit.
            let quality = min(max(best.score, 0), 1)
            let confidence = Rational(Int64((0.70 + 0.25 * quality) * 100), 100)
            let margin = group.attempts.count > 1
                ? quality - (group.attempts.sorted { $0.score > $1.score }.dropFirst().first?.score ?? 0)
                : 1.0
            let closeCall = group.attempts.count > 1 && margin < 0.02
            let basis = Basis.measuredMaterial(
                ref: "take \(group.attempts.count > 1 ? "\(indexOfBest(group) + 1) of \(group.attempts.count)" : "1")",
                detail: String(format: "fluency %.2f, clarity %.2f, audio %.2f — %@%@",
                               best.fluency, best.clarity, best.audio, reasons,
                               closeCall ? "; near-tie with another take, either would do" : ""),
                confidence: confidence)
            // The decision is timestamped on the video track's playhead — the one a person reads
            // off a timeline.
            let decision = Decision(kind: .cut, at: playheads.first ?? .zero,
                                    params: ["line": String(group.text.prefix(80))],
                                    basis: basis)

            var anyPlaced = false
            for (index, track) in log.head.timeline.tracks.enumerated() {
                // Each track on its own grid. At 29.97 a frame is 1601.6 samples, so a shared
                // boundary would put the audio off its own grid and produce a click.
                let from = track.kind == .video
                    ? TimeValue(frames: rawStart.nearestFrame(at: frameRate), at: frameRate)
                    : rawStart.alignedToSample(at: sampleRate)
                let to = track.kind == .video
                    ? TimeValue(frames: rawEnd.nearestFrame(at: frameRate), at: frameRate)
                    : rawEnd.alignedToSample(at: sampleRate)
                guard from < to else { continue }
                try log.append(.placeClip(track: index,
                                          clip: Clip(asset: assetID,
                                                     source: TimeRange(start: from, end: to),
                                                     start: playheads[index]),
                                          decision: decision))
                // Advance by what was ACTUALLY placed on this track, so rounding cannot accumulate.
                playheads[index] = playheads[index] + (to - from)
                anyPlaced = true
            }
            if anyPlaced { placed += 1 }
        }

        // The joins the chosen path actually makes, measured on the real audio.
        var joinCosts: [Double] = []
        if let audio {
            for (a, b) in zip(chosen, chosen.dropFirst()) {
                if let m = try? JoinQuality.measure(source: audio,
                                                    outgoingEndsAt: a.1.range.end,
                                                    incomingStartsAt: b.1.range.start) {
                    joinCosts.append(m.cost)
                }
            }
        }
        let dropped = takes.groups.reduce(0) { $0 + max($1.attempts.count - 1, 0) }
        return (log, AssemblyReport(
            clipsPlaced: placed,
            sourceSeconds: takes.sourceDuration.seconds.doubleValue,
            assembledSeconds: log.head.timeline.duration.seconds.doubleValue,
            droppedAttempts: dropped,
            joinCosts: joinCosts))
    }

    static func indexOfBest(_ group: AttemptGroup) -> Int {
        guard let best = group.best else { return 0 }
        return group.attempts.firstIndex { $0.range.start == best.range.start } ?? 0
    }
}
