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

    public var summary: String {
        String(format: "assembled %d line(s): %.0f s of recording → %.0f s of cut (%d rejected attempt(s) dropped)",
               clipsPlaced, sourceSeconds, assembledSeconds, droppedAttempts)
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

    /// Build a timeline from the winning attempt of every line, in script order.
    public static func assemble(_ takes: RecordingTakes,
                                asset: AssetRef,
                                frameRate: FrameRate,
                                sampleRate: Int = 48_000,
                                includeAudio: Bool = true) throws -> (CommandLog, AssemblyReport) {
        let chosen = takes.groups.compactMap { group -> (AttemptGroup, Rendition)? in
            guard let best = group.best else { return nil }
            return (group, best)
        }.sorted { $0.0.firstAt < $1.0.firstAt }
        guard !chosen.isEmpty else { throw AssemblyError.nothingToAssemble }

        var log = CommandLog(initial: Document(timeline: Timeline(name: asset.path, frameRate: frameRate)))
        try log.append(.addAsset(asset))
        let assetID = log.head.assets.keys.first!
        try log.append(.addTrack(kind: .video, name: "V1"))
        if includeAudio && asset.hasAudio { try log.append(.addTrack(kind: .audio, name: "A1")) }

        let handle = TimeValue(frames: Assembler.handleFrames, at: frameRate)
        var playhead = TimeValue.zero
        var placed = 0

        for (group, best) in chosen {
            // Handles, clamped so a line at the very start does not ask for source before zero.
            let rawStart = best.range.start.seconds < handle.seconds ? TimeValue.zero : best.range.start - handle
            let rawEnd = min(best.range.end + handle, asset.duration)
            guard rawStart < rawEnd else { continue }

            let reasons = best.notes.isEmpty ? "clean" : best.notes.joined(separator: "; ")
            let basis = Basis.measuredMaterial(
                ref: "take \(group.attempts.count > 1 ? "\(indexOfBest(group) + 1) of \(group.attempts.count)" : "1")",
                detail: String(format: "fluency %.2f, clarity %.2f, audio %.2f — %@",
                               best.fluency, best.clarity, best.audio, reasons),
                confidence: Rational(Int64(min(max(best.score, 0), 1) * 100), 100))
            let decision = Decision(kind: .cut, at: playhead,
                                    params: ["line": String(group.text.prefix(80))],
                                    basis: basis)

            for (index, track) in log.head.timeline.tracks.enumerated() {
                // Each track on its own grid. At 29.97 a frame is 1601.6 samples, so a shared
                // boundary would put the audio off its own grid and produce a click.
                let from = track.kind == .video
                    ? TimeValue(frames: rawStart.nearestFrame(at: frameRate), at: frameRate)
                    : rawStart.alignedToSample(at: sampleRate)
                let to = track.kind == .video
                    ? TimeValue(frames: rawEnd.nearestFrame(at: frameRate), at: frameRate)
                    : rawEnd.alignedToSample(at: sampleRate)
                let at = track.kind == .video
                    ? TimeValue(frames: playhead.nearestFrame(at: frameRate), at: frameRate)
                    : playhead.alignedToSample(at: sampleRate)
                guard from < to else { continue }
                try log.append(.placeClip(track: index,
                                          clip: Clip(asset: assetID,
                                                     source: TimeRange(start: from, end: to),
                                                     start: at),
                                          decision: decision))
            }
            playhead = playhead + (rawEnd - rawStart)
            placed += 1
        }

        let dropped = takes.groups.reduce(0) { $0 + max($1.attempts.count - 1, 0) }
        return (log, AssemblyReport(
            clipsPlaced: placed,
            sourceSeconds: takes.sourceDuration.seconds.doubleValue,
            assembledSeconds: log.head.timeline.duration.seconds.doubleValue,
            droppedAttempts: dropped))
    }

    static func indexOfBest(_ group: AttemptGroup) -> Int {
        guard let best = group.best else { return 0 }
        return group.attempts.firstIndex { $0.range.start == best.range.start } ?? 0
    }
}
