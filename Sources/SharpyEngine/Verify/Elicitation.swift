// Every question the agent asks a human, logged as a defect.
//
// If the destination is an agent that edits without help, then each interruption is a bug with a
// burn-down, not a feature with a UI. That reframing only works if it is instrumented from the
// first version: you cannot drive to zero what you never counted. This is the cheapest thing in
// the project and the only way to know whether the autonomy claim is true.
//
// The categories are not decoration — four of the five collapse into artefacts authored once,
// which is the actual mechanism for autonomy. It is not "a better model"; it is moving the
// human's input from *during* the edit to *before* it:
//
//   taste        → learnable. Every human pick is a preference pair. Converges with use.
//   intent       → stated up front in the brief instead of asked mid-edit.
//   groundTruth  → enrolled once (this face, this logo) and reused across every project.
//   permission   → declared as policy once ("never cut the CTA").
//   failure      → the hard residue. Does not collapse.
//
// The last measurement matters most: whether a resolution *compiled into a rule*. The set of
// question classes that never compile is the definition of what still needs a person.

import Foundation

public enum ElicitationCategory: String, Sendable, Codable, CaseIterable {
    case taste, intent, groundTruth, permission, failure

    /// The artefact that would stop this class of question being asked again.
    public var collapsesInto: String? {
        switch self {
        case .taste: return "style profile (learned from picks)"
        case .intent: return "the brief"
        case .groundTruth: return "the enrollment registry"
        case .permission: return "policy"
        case .failure: return nil
        }
    }
    public var canCollapse: Bool { collapsesInto != nil }
}

public struct Elicitation: Sendable, Codable, Identifiable {
    public let id: String
    public let category: ElicitationCategory
    /// What was asked, in the words the human saw.
    public let question: String
    /// Where in the material, when the question is about a moment.
    public let at: TimeValue?
    /// Which asset it concerned.
    public let asset: NodeID?
    public let askedAt: Date

    /// What the human said. Nil while still open.
    public var answer: String?
    public var answeredAt: Date?
    /// The durable artefact this answer became, if any — a rule, a brief field, an enrolment.
    /// **This is the field the whole log exists for.** An answer that changes nothing durable
    /// means the same question gets asked again.
    public var compiledInto: String?

    public init(id: String = UUID().uuidString, category: ElicitationCategory, question: String,
                at: TimeValue? = nil, asset: NodeID? = nil, askedAt: Date = Date(),
                answer: String? = nil, answeredAt: Date? = nil, compiledInto: String? = nil) {
        self.id = id; self.category = category; self.question = question
        self.at = at; self.asset = asset; self.askedAt = askedAt
        self.answer = answer; self.answeredAt = answeredAt; self.compiledInto = compiledInto
    }

    public var isOpen: Bool { answer == nil }
    public var isResidue: Bool { answer != nil && compiledInto == nil }
}

/// What the log says about progress toward not needing a person.
public struct AutonomyReport: Sendable {
    public let totalAsked: Int
    public let open: Int
    /// Questions per hour of footage handled — the headline metric.
    public let questionsPerHour: Double
    public let byCategory: [ElicitationCategory: Int]
    /// Answered questions that produced no durable artefact, by category. These are the ones that
    /// will be asked again.
    public let residueByCategory: [ElicitationCategory: Int]
    public let hoursOfFootage: Double

    /// The honest read: which categories still need a person, and which have been closed out.
    public var stillNeedsAHuman: [ElicitationCategory] {
        ElicitationCategory.allCases.filter { (residueByCategory[$0] ?? 0) > 0 }
    }

    public var summary: String {
        guard totalAsked > 0 else { return "no questions asked over \(String(format: "%.1f", hoursOfFootage)) h of footage" }
        var lines = [String(format: "%d questions over %.1f h of footage — %.1f per hour (%d still open)",
                            totalAsked, hoursOfFootage, questionsPerHour, open)]
        for c in ElicitationCategory.allCases {
            let asked = byCategory[c] ?? 0
            guard asked > 0 else { continue }
            let residue = residueByCategory[c] ?? 0
            let note = residue == 0
                ? (c.canCollapse ? "all collapsed into \(c.collapsesInto!)" : "none outstanding")
                : "\(residue) produced nothing durable — will be asked again"
            lines.append("  \(c.rawValue): \(asked) asked, \(note)")
        }
        if !stillNeedsAHuman.isEmpty {
            lines.append("  still needs a human: \(stillNeedsAHuman.map(\.rawValue).joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}

public final class ElicitationLog {
    public private(set) var entries: [Elicitation]
    /// Footage handled, so the rate has a denominator. Without it the count is meaningless — ten
    /// questions over ten hours and ten over ten minutes are different products.
    public private(set) var secondsOfFootage: Double
    private let url: URL?

    public init(url: URL? = nil) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            entries = stored.entries
            secondsOfFootage = stored.secondsOfFootage
        } else {
            entries = []
            secondsOfFootage = 0
        }
    }

    private struct Stored: Codable {
        var entries: [Elicitation]
        var secondsOfFootage: Double
    }

    private func persist() {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try? encoder.encode(Stored(entries: entries, secondsOfFootage: secondsOfFootage)).write(to: url, options: .atomic)
    }

    /// Record a question. Returns its id so the answer can be attached later.
    @discardableResult
    public func ask(_ category: ElicitationCategory, _ question: String,
                    at: TimeValue? = nil, asset: NodeID? = nil) -> String {
        let e = Elicitation(category: category, question: question, at: at, asset: asset)
        entries.append(e)
        persist()
        return e.id
    }

    /// Attach an answer, and say what durable artefact it became. Passing `compiledInto: nil` is
    /// allowed and is the honest thing to do when the answer changed nothing — it is exactly what
    /// the residue metric counts.
    public func answer(_ id: String, with answer: String, compiledInto: String? = nil) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].answer = answer
        entries[i].answeredAt = Date()
        entries[i].compiledInto = compiledInto
        persist()
    }

    public func recordFootage(seconds: Double) {
        secondsOfFootage += seconds
        persist()
    }

    public var open: [Elicitation] { entries.filter(\.isOpen) }

    public func report() -> AutonomyReport {
        var byCategory: [ElicitationCategory: Int] = [:]
        var residue: [ElicitationCategory: Int] = [:]
        for e in entries {
            byCategory[e.category, default: 0] += 1
            if e.isResidue { residue[e.category, default: 0] += 1 }
        }
        let hours = secondsOfFootage / 3600
        return AutonomyReport(totalAsked: entries.count,
                              open: entries.filter(\.isOpen).count,
                              questionsPerHour: hours > 0 ? Double(entries.count) / hours : 0,
                              byCategory: byCategory,
                              residueByCategory: residue,
                              hoursOfFootage: hours)
    }
}
