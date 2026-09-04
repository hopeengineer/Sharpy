// What changed, said in a sentence.
//
// The command log records every edit exactly, which is what makes undo a pointer and provenance
// possible. It is also unreadable: "rippleDelete track 0 [1234, 1290)" tells a person nothing about
// whether the edit was right. A reviewer who cannot see what changed cannot approve it, and under
// the autonomy goal the whole point is that their attention is scarce.
//
// So this diffs two documents into moments, in SOURCE time. Timeline time is the wrong frame of
// reference for a diff: remove two seconds at the top and every later timecode shifts, so a
// timeline-based diff reports the whole piece as changed when one cut moved. Source time is stable
// — it is where the material actually is — and it is what a person recognises when they go and look.

import Foundation

public struct CutChange: Sendable, Equatable, CustomStringConvertible {
    public enum Kind: String, Sendable, Codable {
        /// Material present before and gone after.
        case removed
        /// Material absent before and present after.
        case added
        /// Same material, moved in the frame.
        case reframed
    }

    public let kind: Kind
    public let asset: NodeID
    /// Where in the SOURCE, which does not shift when something earlier is cut.
    public let sourceRange: TimeRange
    /// Where it landed on the timeline afterwards, when it is still there.
    public let timelineStart: TimeValue?
    /// The basis of the decision that caused it, when one can be attributed.
    public let basis: Basis?

    public var seconds: Double { sourceRange.duration.seconds.doubleValue }

    public var description: String {
        let where_ = String(format: "%.2f–%.2f s of source", sourceRange.start.seconds.doubleValue,
                            sourceRange.end.seconds.doubleValue)
        switch kind {
        case .removed: return String(format: "removed %.2f s (%@)", seconds, where_)
        case .added:   return String(format: "added %.2f s (%@)", seconds, where_)
        case .reframed: return "reframed \(where_)"
        }
    }
}

public struct CutDiff: Sendable {
    public let changes: [CutChange]
    public let durationBefore: TimeValue
    public let durationAfter: TimeValue

    public var removedSeconds: Double {
        changes.filter { $0.kind == .removed }.reduce(0) { $0 + $1.seconds }
    }
    public var addedSeconds: Double {
        changes.filter { $0.kind == .added }.reduce(0) { $0 + $1.seconds }
    }
    public var isEmpty: Bool { changes.isEmpty }

    public var summary: String {
        let before = durationBefore.seconds.doubleValue, after = durationAfter.seconds.doubleValue
        guard !changes.isEmpty else {
            return String(format: "no change (%.2f s)", after)
        }
        var lines = [String(format: "%.2f s → %.2f s (%+.2f s): %d change(s), %.2f s removed, %.2f s added",
                            before, after, after - before, changes.count, removedSeconds, addedSeconds)]
        for change in changes { lines.append("  " + change.description) }
        return lines.joined(separator: "\n")
    }
}

extension Document {
    /// Diff this document against a later one, per video and audio track.
    ///
    /// Compares the SET of source intervals a track uses, not the sequence of clips. A ripple
    /// delete splits one clip into two without changing a frame of what survives; a clip-by-clip
    /// diff would report that as "one clip removed, two added" and bury the two seconds that
    /// actually went.
    public func diff(to other: Document) -> CutDiff {
        var changes: [CutChange] = []
        let trackCount = max(timeline.tracks.count, other.timeline.tracks.count)
        for index in 0..<trackCount {
            let before = index < timeline.tracks.count ? timeline.tracks[index].clips : []
            let after = index < other.timeline.tracks.count ? other.timeline.tracks[index].clips : []
            changes += Document.diffClips(before: before, after: after)
        }
        // Largest first: a reviewer's attention should meet the two seconds that went before the
        // forty milliseconds that did.
        changes.sort { $0.seconds > $1.seconds }
        return CutDiff(changes: changes,
                       durationBefore: timeline.duration,
                       durationAfter: other.timeline.duration)
    }

    static func diffClips(before: [Clip], after: [Clip]) -> [CutChange] {
        var changes: [CutChange] = []
        let assets = Set(before.map(\.asset)).union(after.map(\.asset))
        for asset in assets.sorted(by: { $0.hex < $1.hex }) {
            let wasUsed = intervals(of: before.filter { $0.asset == asset })
            let isUsed = intervals(of: after.filter { $0.asset == asset })
            for gone in subtract(wasUsed, isUsed) {
                changes.append(CutChange(kind: .removed, asset: asset, sourceRange: gone,
                                         timelineStart: nil, basis: nil))
            }
            for new in subtract(isUsed, wasUsed) {
                let landed = after.first { $0.asset == asset && $0.source.overlaps(new) }
                changes.append(CutChange(kind: .added, asset: asset, sourceRange: new,
                                         timelineStart: landed?.start, basis: nil))
            }
            // Material kept but placed differently. Reported separately because "still there, moved"
            // is a different question for a reviewer than "gone".
            for clip in after where clip.asset == asset {
                guard let original = before.first(where: {
                    $0.asset == asset && $0.source == clip.source
                }) else { continue }
                if original.placement != clip.placement {
                    changes.append(CutChange(kind: .reframed, asset: asset, sourceRange: clip.source,
                                             timelineStart: clip.start, basis: nil))
                }
            }
        }
        return changes
    }

    /// Merge a track's clips into non-overlapping source intervals, so adjacent pieces of one take
    /// read as one span.
    static func intervals(of clips: [Clip]) -> [TimeRange] {
        let sorted = clips.map(\.source).sorted { $0.start < $1.start }
        var merged: [TimeRange] = []
        for range in sorted {
            if let last = merged.last, !(last.end < range.start) {
                merged[merged.count - 1] = TimeRange(start: last.start,
                                                     end: max(last.end, range.end))
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// a minus b, as intervals.
    static func subtract(_ a: [TimeRange], _ b: [TimeRange]) -> [TimeRange] {
        var out: [TimeRange] = []
        for range in a {
            var pieces = [range]
            for cut in b {
                var next: [TimeRange] = []
                for piece in pieces {
                    guard let overlap = piece.intersection(cut) else { next.append(piece); continue }
                    if piece.start < overlap.start {
                        next.append(TimeRange(start: piece.start, end: overlap.start))
                    }
                    if overlap.end < piece.end {
                        next.append(TimeRange(start: overlap.end, end: piece.end))
                    }
                }
                pieces = next
            }
            out += pieces
        }
        return out.filter { !$0.isEmpty }
    }
}
