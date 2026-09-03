// Turning "remove these words" into frame ranges — the translation the agent must never do itself.
//
// The subtlety that makes this worth its own file: removing a word's own span leaves the pause
// that surrounded it, so a filler cut out of "so — um — the thing" yields "so — — the thing" with
// a double gap where the word was. Survivors have to close up. How much they close is a taste
// setting, so it is named and explicit rather than a constant buried in the code.

import Foundation

public enum CutAggressiveness: String, Sendable, Codable, CaseIterable {
    /// Butt the survivors together. Snappy; can clip breaths.
    case tight
    /// Leave a natural beat. The default.
    case balanced
    /// Leave room to breathe.
    case loose

    /// Fraction of the surrounding pause to keep.
    var pauseRetention: Rational {
        switch self {
        case .tight: return Rational(0)
        case .balanced: return Rational(35, 100)
        case .loose: return Rational(70, 100)
        }
    }
}

public struct WordCutPlan: Sendable {
    /// Source ranges to remove, sorted, non-overlapping, merged.
    public let ranges: [TimeRange]
    /// Words the plan removes, in order.
    public let removedWords: [Word]
    /// Total time removed.
    public var removed: TimeValue { ranges.reduce(TimeValue.zero) { $0 + $1.duration } }
    /// Words the caller asked for that the transcript does not contain.
    public let unknownIndices: [Int]
}

public enum WordEdit {

    /// Plan the removal of `indices` from `transcript`.
    ///
    /// Each removed run takes its own span plus a share of the pause on either side, so the
    /// surviving words meet with one natural gap rather than two. Adjacent or overlapping runs
    /// merge, so removing words 10, 11, 12 is one cut, not three.
    public static func plan(removing indices: [Int], from transcript: Transcript,
                            aggressiveness: CutAggressiveness = .balanced) -> WordCutPlan {
        let byIndex = Dictionary(uniqueKeysWithValues: transcript.words.map { ($0.index, $0) })
        let wanted = Set(indices)
        let unknown = indices.filter { byIndex[$0] == nil }.sorted()
        let words = indices.compactMap { byIndex[$0] }.sorted { $0.index < $1.index }
        guard !words.isEmpty else { return WordCutPlan(ranges: [], removedWords: [], unknownIndices: unknown) }

        // Group into consecutive runs of transcript positions.
        var runs: [[Word]] = []
        for w in words {
            if let last = runs.last?.last, last.index + 1 == w.index { runs[runs.count - 1].append(w) }
            else { runs.append([w]) }
        }

        let retention = aggressiveness.pauseRetention
        var ranges: [TimeRange] = []
        for run in runs {
            guard let first = run.first, let last = run.last else { continue }
            var start = first.range.start
            var end = last.range.end

            // Absorb the share of the leading pause that is not being kept.
            if let previous = transcript.words.last(where: { $0.index < first.index && !wanted.contains($0.index) }) {
                let gap = TimeRange(start: previous.range.end, end: first.range.start)
                if !gap.isEmpty {
                    let keep = TimeValue(seconds: gap.duration.seconds * retention)
                    start = previous.range.end + keep
                }
            }
            // And the trailing pause, likewise — but only one side keeps a share, or the survivors
            // end up with 2× retention between them.
            if let next = transcript.words.first(where: { $0.index > last.index && !wanted.contains($0.index) }) {
                let gap = TimeRange(start: last.range.end, end: next.range.start)
                if !gap.isEmpty { end = next.range.start }
            }
            if start < end { ranges.append(TimeRange(start: start, end: end)) }
        }

        return WordCutPlan(ranges: merge(ranges), removedWords: words, unknownIndices: unknown)
    }

    /// Plan removal of every filler word.
    public static func planRemovingFillers(from transcript: Transcript,
                                           aggressiveness: CutAggressiveness = .balanced) -> WordCutPlan {
        plan(removing: transcript.fillers.map(\.index), from: transcript, aggressiveness: aggressiveness)
    }

    /// Plan the tightening of every pause longer than `maximum` down to `maximum`.
    /// Unlike word removal this removes no speech at all — only dead air.
    public static func planTighteningPauses(longerThan maximum: TimeValue, in transcript: Transcript) -> WordCutPlan {
        var ranges: [TimeRange] = []
        for pause in transcript.pauses(longerThan: maximum) {
            // Keep `maximum` at the start of the gap, remove the excess.
            let keepUntil = pause.range.start + maximum
            if keepUntil < pause.range.end { ranges.append(TimeRange(start: keepUntil, end: pause.range.end)) }
        }
        return WordCutPlan(ranges: merge(ranges), removedWords: [], unknownIndices: [])
    }

    /// Sort and coalesce touching or overlapping ranges.
    public static func merge(_ ranges: [TimeRange]) -> [TimeRange] {
        let sorted = ranges.sorted { $0.start < $1.start }
        var out: [TimeRange] = []
        for r in sorted {
            if let last = out.last, !(last.end < r.start) {
                out[out.count - 1] = TimeRange(start: last.start, end: max(last.end, r.end))
            } else {
                out.append(r)
            }
        }
        return out
    }
}

extension Document {
    /// Apply a word-cut plan to a track as ripple deletes, newest-first so earlier ranges are not
    /// invalidated by the shifts the later ones cause.
    ///
    /// The plan's ranges are in *source* time; on a track holding one clip that starts at zero and
    /// is untrimmed they are also timeline time. Anything more complex must map through the clip,
    /// which is why this refuses rather than guessing.
    public func commands(applying plan: WordCutPlan, toTrack index: Int, basis: Basis) throws -> [Command] {
        guard timeline.tracks.indices.contains(index) else { throw ApplyError.noSuchTrack(index) }
        let track = timeline.tracks[index]
        guard track.clips.count == 1, let clip = track.clips.first,
              clip.start == .zero, clip.source.start == .zero else {
            throw WordEditError.trackNotDirectlyAddressable(track: index)
        }
        return plan.ranges.reversed().map { range in
            .rippleDelete(track: index, range: range,
                          decision: Decision(kind: .cut, at: range.start,
                                             params: ["removed": "\(range.duration.seconds.doubleValue) s"],
                                             basis: basis))
        }
    }
}

public enum WordEditError: Error, CustomStringConvertible {
    case trackNotDirectlyAddressable(track: Int)
    public var description: String {
        switch self {
        case .trackNotDirectlyAddressable(let t):
            return "track \(t) is not a single untrimmed clip starting at zero, so transcript time is not timeline time. "
                 + "Map the words through the clip first — this refuses rather than cutting in the wrong place."
        }
    }
}
