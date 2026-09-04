// Where should a person look?
//
// "No human at all" is the target, and the honest interim is a human who looks at the right thirty
// seconds instead of the whole piece. A review queue that lists everything is the same as no queue:
// the reviewer skims, and skimming finds nothing.
//
// So this ranks, merges and BUDGETS. If the flagged material exceeds a fraction of the piece, the
// queue says so and stops pretending to be selective — an eleven-minute "selective review" of a
// twelve-minute video is a full review with extra steps, and saying that plainly is more useful
// than a long list.
//
// Every item carries a reason in words and the basis behind it, because a reviewer who cannot tell
// why they are being shown a moment cannot judge whether the system was right to flag it — and
// that judgement is the only feedback that makes the next queue shorter.

import Foundation

public struct ReviewItem: Sendable, Equatable, CustomStringConvertible {
    public enum Severity: Int, Sendable, Codable, Comparable, CaseIterable {
        /// Something is provably wrong; the render is blocked.
        case blocking = 3
        /// Passed, but too little confidence to ship unattended — the `hold` outcome.
        case hold = 2
        /// Worth an eye, not worth stopping for.
        case advisory = 1
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public let range: TimeRange
    public let severity: Severity
    /// Why, in words a person can act on.
    public let reason: String
    /// What produced the flag, so a reviewer can weigh it. A model's guess and a measurement read
    /// very differently and must not look the same in a queue.
    public let basis: Basis?

    public init(range: TimeRange, severity: Severity, reason: String, basis: Basis? = nil) {
        self.range = range; self.severity = severity; self.reason = reason; self.basis = basis
    }

    public var description: String {
        String(format: "%7.2f–%7.2f  [%@] %@", range.start.seconds.doubleValue,
               range.end.seconds.doubleValue, String(describing: severity), reason)
    }
}

public struct ReviewQueue: Sendable {
    public let items: [ReviewItem]
    public let pieceDuration: TimeValue
    /// Above this fraction the queue is not selective and says so.
    public let budget: Double

    public var reviewSeconds: Double {
        items.reduce(0) { $0 + $1.range.duration.seconds.doubleValue }
    }
    public var fractionOfPiece: Double {
        let total = pieceDuration.seconds.doubleValue
        return total > 0 ? reviewSeconds / total : 0
    }
    public var isSelective: Bool { fractionOfPiece <= budget }
    public var blocking: [ReviewItem] { items.filter { $0.severity == .blocking } }

    public var summary: String {
        guard !items.isEmpty else {
            return String(format: "review: nothing flagged across %.1f s", pieceDuration.seconds.doubleValue)
        }
        let head = String(format: "review: %d moment(s), %.1f s of %.1f s (%.0f%%)",
                          items.count, reviewSeconds, pieceDuration.seconds.doubleValue,
                          fractionOfPiece * 100)
        guard isSelective else {
            return head + String(format: "\n  NOT SELECTIVE — more than %.0f%% of the piece is flagged. "
                                 + "Watch it through; a queue this long is a full review with extra steps.",
                                 budget * 100)
        }
        return head + "\n" + items.map { "  " + $0.description }.joined(separator: "\n")
    }
}

public enum SelectiveReview {
    /// Default budget: a fifth of the piece. Beyond that, skimming starts and the queue stops
    /// working as a queue.
    public static let defaultBudget = 0.2
    /// Flagged moments closer together than this are merged. Two findings a second apart are one
    /// place to look, and listing them separately doubles the apparent work without adding any.
    public static let mergeGap = 2.0

    /// Build a queue, merging neighbours and ordering by severity then time.
    public static func build(items: [ReviewItem], pieceDuration: TimeValue,
                             budget: Double = defaultBudget,
                             mergeGap: Double = mergeGap) -> ReviewQueue {
        guard !items.isEmpty else {
            return ReviewQueue(items: [], pieceDuration: pieceDuration, budget: budget)
        }
        // Merge within severity, not across it. Folding a blocking failure into a neighbouring
        // advisory would hide the thing that stops the render inside something optional.
        var merged: [ReviewItem] = []
        for severity in ReviewItem.Severity.allCases {
            let group = items.filter { $0.severity == severity }
                .sorted { $0.range.start < $1.range.start }
            var current: ReviewItem?
            for item in group {
                guard let running = current else { current = item; continue }
                let gap = item.range.start.seconds.doubleValue - running.range.end.seconds.doubleValue
                if gap <= mergeGap {
                    let end = max(running.range.end.seconds.doubleValue, item.range.end.seconds.doubleValue)
                    let reason = running.reason == item.reason
                        ? running.reason
                        : running.reason + "; " + item.reason
                    current = ReviewItem(
                        range: TimeRange(start: running.range.start,
                                         end: TimeValue(seconds: Rational(Int64(end * 1000), 1000))),
                        severity: severity, reason: reason, basis: running.basis ?? item.basis)
                } else {
                    merged.append(running)
                    current = item
                }
            }
            if let current { merged.append(current) }
        }
        merged.sort {
            $0.severity != $1.severity ? $0.severity > $1.severity : $0.range.start < $1.range.start
        }
        return ReviewQueue(items: merged, pieceDuration: pieceDuration, budget: budget)
    }

    /// Turn assertion failures into review items. A `block` is blocking, a `hold` is a hold, and a
    /// `warn` is advisory — the mapping the vocabulary already implies, made explicit so nothing
    /// silently changes severity on the way to a person.
    public static func items(from failures: [AssertionFailure],
                             window: TimeValue = TimeValue(seconds: Rational(2, 1))) -> [ReviewItem] {
        failures.compactMap { failure in
            guard let at = failure.at else { return nil }
            let severity: ReviewItem.Severity
            switch failure.mode {
            case .block: severity = .blocking
            case .hold: severity = .hold
            case .warn: severity = .advisory
            }
            let half = TimeValue(seconds: window.seconds / Rational(2, 1))
            let start = at.seconds < half.seconds ? TimeValue.zero : at - half
            return ReviewItem(range: TimeRange(start: start, end: at + half),
                              severity: severity,
                              reason: "\(failure.assertion): \(failure.detail)")
        }
    }
}
