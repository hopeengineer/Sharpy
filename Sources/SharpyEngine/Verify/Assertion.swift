// Assertions that gate a render.
//
// This is the cheapest component in the whole system and it prevents the most, because it turns
// "be careful" into something a machine checks every time. Under the project's autonomy goal it
// stops being a helper and becomes the entire QC department: when nobody reviews the output, an
// assertion is the only thing standing between a fault and a viewer.
//
// Three outcomes, and the third is the one people leave out:
//   block — the render does not happen
//   warn  — it happens, and the report says what is wrong
//   hold  — everything passed, but confidence is too low to ship unattended
//
// `hold` exists because "no assertion failed" and "this is fit to publish" are different claims.
// An autonomous system needs the right to abstain; without it, the only options are ship-anyway
// and fail-loudly, and the first is what actually happens.

import Foundation

public enum AssertionMode: String, Sendable, Codable, CaseIterable {
    case block, warn, hold
}

public enum AssertionCategory: String, Sendable, Codable, CaseIterable {
    case structural, spatial, audio, legibility, provenance, safety
}

public struct AssertionFailure: Sendable, Equatable {
    public let assertion: String
    public let category: AssertionCategory
    public let mode: AssertionMode
    public let detail: String
    /// Where it went wrong, when it is localised — an assertion that cannot say *where* costs more
    /// to act on than it saves.
    public let at: TimeValue?

    public init(assertion: String, category: AssertionCategory, mode: AssertionMode, detail: String, at: TimeValue?) {
        self.assertion = assertion; self.category = category; self.mode = mode
        self.detail = detail; self.at = at
    }

    public var description: String {
        let when = at.map { String(format: " at %.2fs", $0.seconds.doubleValue) } ?? ""
        return "[\(mode.rawValue)] \(assertion)\(when): \(detail)"
    }
}

public struct VerificationResult: Sendable {
    public let failures: [AssertionFailure]
    public let checked: Int

    public init(failures: [AssertionFailure], checked: Int) { self.failures = failures; self.checked = checked }

    public var blocking: [AssertionFailure] { failures.filter { $0.mode == .block } }
    public var warnings: [AssertionFailure] { failures.filter { $0.mode == .warn } }
    public var holds: [AssertionFailure] { failures.filter { $0.mode == .hold } }

    /// True when nothing blocks and nothing holds. Warnings do not stop a render.
    public var canRender: Bool { blocking.isEmpty && holds.isEmpty }

    public var summary: String {
        if failures.isEmpty { return "\(checked) assertions, all passed" }
        return "\(checked) assertions: \(blocking.count) blocking, \(holds.count) holds, \(warnings.count) warnings"
    }
}

/// One check. `evaluate` returns the failures it found; an empty array is a pass.
public protocol Assertion: Sendable {
    var name: String { get }
    var category: AssertionCategory { get }
    var mode: AssertionMode { get }
    func evaluate(_ context: VerificationContext) -> [AssertionFailure]
}

/// Everything an assertion may look at. Perception layers are optional: an assertion that needs a
/// layer which was never produced must say so rather than silently passing — a check that cannot
/// run is not a check that succeeded.
public struct VerificationContext: Sendable {
    public let document: Document
    /// Integrated loudness of the mix, when it has been measured.
    public let integratedLoudness: Double?
    public let truePeak: Double?
    /// Platform requirements in force.
    public let loudnessTarget: (integrated: Double, truePeakCeiling: Double)?
    /// Minimum shot length below which a cut reads as an error rather than an edit.
    public let minimumShotDuration: TimeValue
    /// Confidence below which a decision must not ship unattended.
    public let shipConfidence: Rational

    public init(document: Document,
                integratedLoudness: Double? = nil,
                truePeak: Double? = nil,
                loudnessTarget: (integrated: Double, truePeakCeiling: Double)? = nil,
                minimumShotDuration: TimeValue = TimeValue(seconds: Rational(1, 5)),
                shipConfidence: Rational = Rational(85, 100)) {
        self.document = document
        self.integratedLoudness = integratedLoudness
        self.truePeak = truePeak
        self.loudnessTarget = loudnessTarget
        self.minimumShotDuration = minimumShotDuration
        self.shipConfidence = shipConfidence
    }
}

public struct Verifier: Sendable {
    public let assertions: [any Assertion]
    public init(assertions: [any Assertion]) { self.assertions = assertions }


    /// The set every project gets. A project adds its own; it cannot remove a `safety` one.
    public static let standard: Verifier = Verifier(assertions: [
        EveryDecisionHasABasis(),
        NoDecisionBelowTheConfidenceFloor(),
        SafetyConstraintsAreNotOverridden(),
        ClipsDoNotOverlap(),
        ClipsAreOnTheirTrackGrid(),
        NoShotShorterThanMinimum(),
        SourceRangesAreWithinTheirAsset(),
        TimelineIsNotEmpty(),
        LoudnessWithinTarget(),
        TruePeakBelowCeiling(),
        LowConfidenceDecisionsHoldTheRender(),
    ])

    public func verify(_ context: VerificationContext) -> VerificationResult {
        var failures: [AssertionFailure] = []
        for a in assertions { failures.append(contentsOf: a.evaluate(context)) }
        return VerificationResult(failures: failures, checked: assertions.count)
    }
}

// MARK: - Provenance

/// The spec's central rule, checked rather than trusted. `Decision.init` already makes a
/// basis-less decision unrepresentable, so this catches the other half: a decision that reached
/// the record without going through `apply`.
public struct EveryDecisionHasABasis: Assertion {
    public init() {}
    public let name = "every decision has a basis"
    public let category = AssertionCategory.provenance
    public let mode = AssertionMode.block
    public func evaluate(_ c: VerificationContext) -> [AssertionFailure] {
        c.document.decisionOrder.compactMap { id in
            guard c.document.decisions[id] == nil else { return nil }
            return AssertionFailure(assertion: name, category: category, mode: mode,
                                    detail: "decision \(id) is referenced in the record but has no entry", at: nil)
        }
    }
}

public struct NoDecisionBelowTheConfidenceFloor: Assertion {
    public init() {}
    public let name = "no decision rests on a fact below the confidence floor"
    public let category = AssertionCategory.provenance
    public let mode = AssertionMode.block
    public func evaluate(_ c: VerificationContext) -> [AssertionFailure] {
        c.document.decisionOrder.compactMap { id in
            guard let d = c.document.decisions[id], d.basis.confidence < c.document.confidenceFloor else { return nil }
            return AssertionFailure(assertion: name, category: category, mode: mode,
                                    detail: "\(d.kind.rawValue) rests on \(d.basis.confidence) against a floor of \(c.document.confidenceFloor)",
                                    at: d.at)
        }
    }
}

/// A client rule may override craft, norms and preferences. It may not override a safety
/// constraint — flash limits and loudness ceilings are not preferences, and a tool that let a
/// standing instruction switch them off would be the most dangerous kind of configurable.
public struct SafetyConstraintsAreNotOverridden: Assertion {
    public init() {}
    public let name = "no safety constraint is overridden by a lower-authority basis"
    public let category = AssertionCategory.safety
    public let mode = AssertionMode.block
    public func evaluate(_ c: VerificationContext) -> [AssertionFailure] {
        // A decision that supersedes a safety-constrained one must itself be safety-constrained.
        c.document.decisionOrder.compactMap { id in
            guard let d = c.document.decisions[id], let supersededID = d.supersedes,
                  let superseded = c.document.decisions[supersededID] else { return nil }
            guard case .safetyConstraint = superseded.basis else { return nil }
            if case .safetyConstraint = d.basis { return nil }
            return AssertionFailure(assertion: name, category: category, mode: mode,
                                    detail: "a \(d.basis.rank == 1 ? "client rule" : "lower-authority") decision supersedes a safety constraint",
                                    at: d.at)
        }
    }
}

// MARK: - Structure

public struct ClipsDoNotOverlap: Assertion {
    public init() {}
    public let name = "clips on a track do not overlap"
    public let category = AssertionCategory.structural
    public let mode = AssertionMode.block
    public func evaluate(_ c: VerificationContext) -> [AssertionFailure] {
        var out: [AssertionFailure] = []
        for (i, track) in c.document.timeline.tracks.enumerated() {
            let sorted = track.clips.sorted { $0.start < $1.start }
            for (a, b) in zip(sorted, sorted.dropFirst()) where a.range.overlaps(b.range) {
                out.append(AssertionFailure(assertion: name, category: category, mode: mode,
                                            detail: "track \(i) (\(track.name)): \(a.range) overlaps \(b.range)", at: b.start))
            }
        }
        return out
    }
}

public struct ClipsAreOnTheirTrackGrid: Assertion {
    public init() {}
    public let name = "every clip sits on its track's own grid"
    public let category = AssertionCategory.structural
    public let mode = AssertionMode.block
    public func evaluate(_ c: VerificationContext) -> [AssertionFailure] {
        var out: [AssertionFailure] = []
        let timeline = c.document.timeline
        for (i, track) in timeline.tracks.enumerated() {
            for clip in track.clips {
                let grid = timeline.grid(for: track.kind)
                for (label, t) in [("start", clip.start), ("end", clip.end)] {
                    if (t.seconds / grid).den != 1 {
                        out.append(AssertionFailure(assertion: name, category: category, mode: mode,
                                                    detail: "track \(i) (\(track.kind.rawValue)) clip \(label) is off the \(track.kind == .video ? "frame" : "sample") grid",
                                                    at: t))
                    }
                }
            }
        }
        return out
    }
}

/// Below a few frames a cut reads as a mistake rather than an edit. This is a craft rule with a
/// documented justification, so it warns rather than blocks — a deliberate flash cut is legitimate.
public struct NoShotShorterThanMinimum: Assertion {
    public init() {}
    public let name = "no clip is shorter than the minimum shot length"
    public let category = AssertionCategory.structural
    public let mode = AssertionMode.warn
    public func evaluate(_ c: VerificationContext) -> [AssertionFailure] {
        var out: [AssertionFailure] = []
        for (i, track) in c.document.timeline.tracks.enumerated() where track.kind == .video {
            for clip in track.clips where clip.range.duration.seconds < c.minimumShotDuration.seconds {
                out.append(AssertionFailure(assertion: name, category: category, mode: mode,
                                            detail: String(format: "track %d: a %.3f s clip is below the %.2f s minimum", i,
                                                           clip.range.duration.seconds.doubleValue,
                                                           c.minimumShotDuration.seconds.doubleValue),
                                            at: clip.start))
            }
        }
        return out
    }
}

public struct SourceRangesAreWithinTheirAsset: Assertion {
    public init() {}
    public let name = "no clip reads past the end of its source"
    public let category = AssertionCategory.structural
    public let mode = AssertionMode.block
    public func evaluate(_ c: VerificationContext) -> [AssertionFailure] {
        var out: [AssertionFailure] = []
        for (i, track) in c.document.timeline.tracks.enumerated() {
            for clip in track.clips {
                guard let asset = c.document.assets[clip.asset] else {
                    out.append(AssertionFailure(assertion: name, category: category, mode: mode,
                                                detail: "track \(i): clip references missing asset \(clip.asset)", at: clip.start))
                    continue
                }
                if asset.duration.seconds < clip.source.end.seconds {
                    out.append(AssertionFailure(assertion: name, category: category, mode: mode,
                                                detail: String(format: "track %d: clip reads to %.3f s of a %.3f s source", i,
                                                               clip.source.end.seconds.doubleValue, asset.duration.seconds.doubleValue),
                                                at: clip.start))
                }
            }
        }
        return out
    }
}

public struct TimelineIsNotEmpty: Assertion {
    public init() {}
    public let name = "the timeline has something on it"
    public let category = AssertionCategory.structural
    public let mode = AssertionMode.block
    public func evaluate(_ c: VerificationContext) -> [AssertionFailure] {
        c.document.timeline.tracks.contains { !$0.clips.isEmpty } ? [] :
            [AssertionFailure(assertion: name, category: category, mode: mode,
                              detail: "no track carries a clip; the render would be empty", at: nil)]
    }
}

// MARK: - Audio

public struct LoudnessWithinTarget: Assertion {
    public init() {}
    public let name = "integrated loudness is within the platform target"
    public let category = AssertionCategory.audio
    public let mode = AssertionMode.block
    public func evaluate(_ c: VerificationContext) -> [AssertionFailure] {
        guard let target = c.loudnessTarget else { return [] }
        guard let measured = c.integratedLoudness else {
            return [AssertionFailure(assertion: name, category: category, mode: mode,
                                     detail: "a loudness target is set but the mix was never measured — the check could not run", at: nil)]
        }
        let delta = measured - target.integrated
        guard abs(delta) > 0.5 else { return [] }
        return [AssertionFailure(assertion: name, category: category, mode: mode,
                                 detail: String(format: "%.2f LUFS is %+.2f LU from the %.1f LUFS target", measured, delta, target.integrated), at: nil)]
    }
}

/// The ceiling is a platform requirement, not a preference: over it, a lossy encoder's
/// reconstruction clips on the listener's device even though the file itself never does.
public struct TruePeakBelowCeiling: Assertion {
    public init() {}
    public let name = "true peak is below the delivery ceiling"
    public let category = AssertionCategory.audio
    public let mode = AssertionMode.block
    public func evaluate(_ c: VerificationContext) -> [AssertionFailure] {
        guard let target = c.loudnessTarget, let peak = c.truePeak else { return [] }
        guard peak > target.truePeakCeiling else { return [] }
        return [AssertionFailure(assertion: name, category: category, mode: mode,
                                 detail: String(format: "%.2f dBTP exceeds the %.1f dBTP ceiling", peak, target.truePeakCeiling), at: nil)]
    }
}

// MARK: - Abstention

/// Everything passed, and that is still not enough. A decision resting on a fact the system is
/// only moderately sure of should not ship unattended, even when no rule was broken.
public struct LowConfidenceDecisionsHoldTheRender: Assertion {
    public init() {}
    public let name = "no decision ships unattended below the confidence bar"
    public let category = AssertionCategory.provenance
    public let mode = AssertionMode.hold
    public func evaluate(_ c: VerificationContext) -> [AssertionFailure] {
        c.document.decisionOrder.compactMap { id in
            guard let d = c.document.decisions[id] else { return nil }
            let conf = d.basis.confidence
            guard !(conf < c.document.confidenceFloor), conf < c.shipConfidence else { return nil }
            return AssertionFailure(assertion: name, category: category, mode: mode,
                                    detail: "\(d.kind.rawValue) rests on \(conf), under the \(c.shipConfidence) bar for shipping without review",
                                    at: d.at)
        }
    }
}
