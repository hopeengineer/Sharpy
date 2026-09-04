// Tier 4: the model proposes, the measurement decides.
//
// The specification's rule is that the agent must never be the source of a claim. A VLM is
// nevertheless the best thing available for NOTICING — "that caption looks hard to read against
// the background" is exactly the kind of observation a model is good at and a threshold is not.
//
// So a proposal can only ever cause a MEASUREMENT to happen. It is compiled into a deterministic
// check with named inputs and a stated threshold, or it is discarded with a reason. Nothing a
// model says reaches a verdict; at most it points somewhere and something exact looks.
//
// This is also why the compiler rejects loudly rather than approximating. A proposal it half
// understands would become a check that half means something, and the whole point of the tier is
// that the checks are exact even though their origin is not.

import Foundation
import SharpyEngine

/// What a model asked to have measured. Untrusted input: every field is validated before use.
public struct ProposedCheck: Sendable, Codable, Equatable {
    /// Which measurement to run. An unknown kind is a rejection, never a guess.
    public let kind: String
    /// Where in the piece, if the proposal is about a moment.
    public let at: TimeValue?
    /// The model's own words, kept for the record so a rejected proposal can be read back and the
    /// prompt improved. Never parsed.
    public let note: String

    public init(kind: String, at: TimeValue? = nil, note: String = "") {
        self.kind = kind; self.at = at; self.note = note
    }
}

public enum CheckCompilation: Sendable, Equatable {
    /// Compiled into a named, deterministic measurement.
    case compiled(check: String, detail: String)
    /// Discarded, with the reason. Rejections are kept: a model that keeps proposing something
    /// unmeasurable is telling you about a gap in the checks, not about the footage.
    case rejected(reason: String)

    public var isCompiled: Bool { if case .compiled = self { return true }; return false }
}

public struct CheckProposalResult: Sendable {
    public let proposal: ProposedCheck
    public let outcome: CheckCompilation
}

/// Compiles proposals into checks this system can actually run.
///
/// The set is deliberately small and grows only when a real measurement exists behind a name.
/// A compiler that accepted anything would let the model smuggle in verdicts by naming them.
public struct CheckCompiler: Sendable {
    /// Measurements that exist. Adding a name here without adding the measurement would be the
    /// worst possible bug in this file: proposals would compile and nothing would run.
    public static let known: Set<String> = [
        "textContrast",       // luminance contrast of a caption against what is behind it
        "textSafeArea",       // caption inside the title-safe box
        "textDuration",       // caption on screen long enough to read
        "subjectInFrame",     // the subject is not cropped out by a move
    ]

    public let perception: PerceptionContext

    public init(perception: PerceptionContext) { self.perception = perception }

    public func compile(_ proposal: ProposedCheck) -> CheckProposalResult {
        guard CheckCompiler.known.contains(proposal.kind) else {
            return CheckProposalResult(
                proposal: proposal,
                outcome: .rejected(reason: "no measurement named \"\(proposal.kind)\"; known: \(CheckCompiler.known.sorted().joined(separator: ", "))"))
        }
        // Every one of these reads on-screen text or subject boxes, so without a Vision pass the
        // proposal cannot be measured. Saying so beats compiling a check that silently sees nothing.
        guard let vision = perception.vision else {
            return CheckProposalResult(
                proposal: proposal,
                outcome: .rejected(reason: "\(proposal.kind) needs a Vision pass and none has been run"))
        }
        if let at = proposal.at {
            guard let observation = vision.observation(at: at) else {
                return CheckProposalResult(
                    proposal: proposal,
                    outcome: .rejected(reason: "nothing was observed at \(String(format: "%.2f", at.seconds.doubleValue)) s"))
            }
            let gap = abs((observation.time - at).seconds.doubleValue)
            if gap > 1.0 {
                return CheckProposalResult(
                    proposal: proposal,
                    outcome: .rejected(reason: String(format: "nearest observation is %.1f s away — too far to stand for that moment", gap)))
            }
            if proposal.kind.hasPrefix("text"), observation.text.isEmpty {
                return CheckProposalResult(
                    proposal: proposal,
                    outcome: .rejected(reason: "no on-screen text there to measure"))
            }
            if proposal.kind == "subjectInFrame", observation.faces.isEmpty {
                return CheckProposalResult(
                    proposal: proposal,
                    outcome: .rejected(reason: "no subject there to measure"))
            }
            return CheckProposalResult(
                proposal: proposal,
                outcome: .compiled(check: proposal.kind,
                                   detail: "at \(String(format: "%.2f", at.seconds.doubleValue)) s against \(observation.text.count) text line(s) and \(observation.faces.count) face(s)"))
        }
        return CheckProposalResult(
            proposal: proposal,
            outcome: .compiled(check: proposal.kind,
                               detail: "over the whole piece, \(vision.frames.count) observed frame(s)"))
    }

    public func compile(_ proposals: [ProposedCheck]) -> [CheckProposalResult] {
        proposals.map(compile)
    }
}

/// What a batch of proposals produced. The compile RATE is the number worth watching: the plan
/// calls for a "compile-rate residue report" in M4, and a model whose proposals mostly fail to
/// compile is describing things this system cannot check — which is a roadmap, not a failure.
public struct ProposalReport: Sendable {
    public let results: [CheckProposalResult]
    public var compiled: [CheckProposalResult] { results.filter { $0.outcome.isCompiled } }
    public var rejected: [CheckProposalResult] { results.filter { !$0.outcome.isCompiled } }
    public var compileRate: Double {
        results.isEmpty ? 0 : Double(compiled.count) / Double(results.count)
    }
    public var summary: String {
        results.isEmpty ? "no proposals"
            : String(format: "%d of %d proposals compiled (%.0f%%)", compiled.count, results.count, compileRate * 100)
    }
}
