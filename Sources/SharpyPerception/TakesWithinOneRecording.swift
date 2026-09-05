// Ten minutes of somebody saying the same thing over and over.
//
// The assumption in `TakeSelector` was that takes arrive as separate files. They do not. People
// press record once and go again after every fluff, so the "takes" are passages inside ONE
// continuous recording, and finding them is a prerequisite to choosing between them.
//
// Which turns out to make the problem easier, not harder. Within one recording the script is not
// known in advance, but it does not need to be: a line attempted four times appears as four
// near-identical passages, so the ATTEMPTS ARE DISCOVERABLE FROM THE REPETITION ITSELF. Group the
// near-duplicates, order the groups by where each was first said, and the script falls out of the
// transcript without anybody writing it down.
//
// The one thing this must not do is decide that a deliberate repetition is a fluff. "This hook goes
// here… and this hook goes here" is two beats, and a tool that collapsed them would delete the
// second. So proximity is part of the test: re-takes cluster — somebody fluffs a line and says it
// again within seconds — while a deliberate callback is separated by other material. Groups that
// are spread far apart are reported for a person to confirm rather than silently merged.

import Foundation
import SharpyEngine
import SharpyRender

public struct AttemptGroup: Sendable {
    /// Every attempt at this line, in the order it was said.
    public let attempts: [Rendition]
    public let text: String
    /// First time it was said — the group's place in the script.
    public let firstAt: TimeValue
    /// Attempts spread over more than `TakeFinder.clusterWindow`. Likely a deliberate repetition
    /// rather than a re-take, and reported rather than assumed either way.
    public let spreadOut: Bool

    public var best: Rendition? { attempts.max { $0.score < $1.score } }
}

public struct RecordingTakes: Sendable {
    public let groups: [AttemptGroup]
    public let totalSentences: Int
    public let sourceDuration: TimeValue

    /// Lines said only once — no choice to make, and they still belong in the cut.
    public var singles: [AttemptGroup] { groups.filter { $0.attempts.count == 1 } }
    public var retaken: [AttemptGroup] { groups.filter { $0.attempts.count > 1 } }
    public var needConfirming: [AttemptGroup] { groups.filter(\.spreadOut) }

    /// What the finished cut would run to, keeping the best of each group.
    public var keptSeconds: Double {
        groups.compactMap(\.best).reduce(0) { $0 + $1.range.duration.seconds.doubleValue }
    }

    public var summary: String {
        guard !groups.isEmpty else { return "takes: nothing found in this recording" }
        var lines = [String(format: "takes: %d line(s) from %d sentence(s) over %.0f s",
                            groups.count, totalSentences, sourceDuration.seconds.doubleValue)]
        lines.append(String(format: "  %d line(s) attempted more than once; keeping the best of each leaves %.0f s",
                            retaken.count, keptSeconds))
        let worst = retaken.max { $0.attempts.count < $1.attempts.count }
        if let worst {
            lines.append("  hardest line — \(worst.attempts.count) attempts: \"\(worst.text.prefix(60))\"")
        }
        if !needConfirming.isEmpty {
            lines.append("  \(needConfirming.count) repetition(s) are spread far apart and may be deliberate, "
                         + "not re-takes. Both kept; check these:")
            for g in needConfirming.prefix(4) {
                lines.append(String(format: "     · %.0f s  \"%@\"", g.firstAt.seconds.doubleValue, g.text.prefix(52) as CVarArg))
            }
        }
        return lines.joined(separator: "\n")
    }
}

public enum TakeFinder {
    /// Re-takes cluster. Somebody who fluffs a line says it again within seconds, whereas a
    /// deliberate callback comes back to it much later — so the gap between attempts is real
    /// evidence about which kind of repetition this is.
    public static let clusterWindow: Double = 90

    public static func find(in take: Take,
                            minimumSimilarity: Double = 0.72,
                            fillerPenalty: Double = 0.25,
                            stallSeconds: Double = 0.55) -> RecordingTakes {
        let lines = TakeSelector.lines(of: take)
        var used = Set<Int>()
        var groups: [AttemptGroup] = []

        for (i, line) in lines.enumerated() where !used.contains(i) {
            var members = [i]
            used.insert(i)
            for (j, other) in lines.enumerated() where j > i && !used.contains(j) {
                // Compared against the FIRST attempt, not the previous one. Chaining lets a group
                // drift — attempt 4 resembling attempt 3 resembling attempt 2 can end up saying
                // something else entirely, and the group would quietly stop being one line.
                guard TakeSelector.similarity(line.tokens, other.tokens) >= minimumSimilarity else { continue }
                members.append(j)
                used.insert(j)
            }
            let renditions = members.map { index in
                TakeSelector.score(words: lines[index].words, range: lines[index].range, take: take,
                                   fillerPenalty: fillerPenalty, stallSeconds: stallSeconds)
            }
            let first = lines[members[0]].range.start
            let last = lines[members[members.count - 1]].range.end
            let spread = last.seconds.doubleValue - first.seconds.doubleValue
            groups.append(AttemptGroup(
                attempts: renditions, text: lines[members[0]].text, firstAt: first,
                spreadOut: members.count > 1 && spread > TakeFinder.clusterWindow))
        }
        groups.sort { $0.firstAt < $1.firstAt }
        return RecordingTakes(groups: groups, totalSentences: lines.count,
                              sourceDuration: take.transcript.words.last?.range.end ?? .zero)
    }
}
