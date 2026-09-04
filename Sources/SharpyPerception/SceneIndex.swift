// What is happening in the frame — the questions Apple Vision cannot answer.
//
// Vision is measured and better at faces, hands and on-screen text (22/22, 21/21, 89/90 lines on
// the labelled reel, at 0.63 s/frame). It has nothing to say about shot size, activity or setting,
// and those are what an agent needs to choose a cutaway or honour "keep the wide shots".
//
// So a VLM answers only what Vision cannot, and every answer it gives is treated as the weakest
// class of claim the document recognises — `Basis.structuralInference`, rank 7, below every
// measured fact. That is not modesty, it is the rule: a model's opinion must never outrank a
// measurement, so a scene claim can never justify a cut that a measured fact contradicts.
//
// AGREEMENT, NOT TRUST. Where Vision can contradict the model, it does, and Vision wins. The check
// is deliberately LOGICAL rather than statistical: "the model says nobody is on screen but Vision
// found a face" is a contradiction at any threshold, on any footage. The alternative — deriving
// shot-size thresholds from face-box geometry — was rejected because the labelled set contains
// exactly 2 split-layout frames, and a rule fitted to 2 examples is a rule fitted to a fixture.
// That mistake has been made three times in this repo already.

import Foundation
import SharpyEngine

/// How much of the subject the frame holds. Deliberately coarse: an agent choosing a cutaway needs
/// "is this a close-up or a wide", not a focal length the model cannot know.
public enum ShotSize: String, Sendable, Codable, CaseIterable {
    case closeUp, medium, wide
    /// A graphic fills the frame, no person.
    case card
    /// Graphic and person share the frame.
    case split
    case other
}

/// How much a scene claim can be relied on, decided by what Vision could check.
public enum ClaimStanding: String, Sendable, Codable {
    /// A measured fact is consistent with the claim. Still an inference, but not a free one.
    case corroborated
    /// Vision had nothing to say about it. The claim stands alone.
    case unchecked
    /// A measured fact contradicts the claim. The claim is retained for the record and must not
    /// be acted on; `usable` is false.
    case contradicted

    public var usable: Bool { self != .contradicted }
}

public struct SceneObservation: Sendable, Codable {
    public let time: TimeValue
    public let shot: ShotSize
    /// One short phrase. Free text because the space of activities is not enumerable; short
    /// because a paragraph invites the model to narrate rather than observe.
    public let activity: String
    public let setting: String
    public let standing: ClaimStanding
    /// Why the standing is what it is, in words, so a rejected claim explains itself.
    public let reason: String

    public init(time: TimeValue, shot: ShotSize, activity: String, setting: String,
                standing: ClaimStanding, reason: String) {
        self.time = time; self.shot = shot; self.activity = activity
        self.setting = setting; self.standing = standing; self.reason = reason
    }

    /// The basis this observation can supply. Never stronger than `structuralInference`, and a
    /// contradicted claim supplies none at all — which is what stops it reaching a render.
    public func basis(evidence: [String]) -> Basis? {
        guard standing.usable else { return nil }
        return .structuralInference(evidence: evidence,
                                    confidence: standing == .corroborated ? Rational(7, 10)
                                                                          : Rational(5, 10))
    }
}

public struct SceneIndex: Sendable, Codable {
    public let asset: NodeID
    public let observations: [SceneObservation]
    /// The model that produced it, so a changed model invalidates its own layer.
    public let model: String

    public init(asset: NodeID, observations: [SceneObservation], model: String) {
        self.asset = asset; self.observations = observations; self.model = model
    }

    public func observation(at t: TimeValue) -> SceneObservation? {
        observations.min { abs(($0.time - t).seconds.doubleValue) < abs(($1.time - t).seconds.doubleValue) }
    }

    /// Contiguous runs of one shot size, from usable claims only. This is what "keep the wide
    /// shots" resolves against, and a contradicted frame must not extend a run.
    public func runs(of shot: ShotSize, tolerance: TimeValue) -> [TimeRange] {
        var out: [TimeRange] = []
        var start: TimeValue?
        var last: TimeValue?
        for o in observations.sorted(by: { $0.time < $1.time }) {
            let matches = o.shot == shot && o.standing.usable
            if matches {
                if start == nil { start = o.time }
                last = o.time
            } else if let s = start, let l = last {
                out.append(TimeRange(start: s, end: l + tolerance)); start = nil; last = nil
            }
        }
        if let s = start, let l = last { out.append(TimeRange(start: s, end: l + tolerance)) }
        return out
    }

    /// Claims Vision contradicted. Surfaced rather than hidden: a model that keeps being wrong
    /// about this footage is a fact the editor should know.
    public var contradicted: [SceneObservation] { observations.filter { $0.standing == .contradicted } }

    /// Fraction of frames the model declined to classify.
    ///
    /// This is the loophole in the cross-check, made visible. `.other` and `.wide` assert nothing
    /// Vision can refute, so a model that answered `other` everywhere would post a perfect zero
    /// contradictions and look flawless. Abstention is the right behaviour on a genuinely
    /// ambiguous frame — the reel has a near-blank one at 40 s where "other" is the correct
    /// answer — but a HIGH rate means the model is not doing the job, and that must be a visible
    /// number rather than an absence of complaints.
    public var abstentionRate: Double {
        guard !observations.isEmpty else { return 0 }
        return Double(observations.filter { $0.shot == .other }.count) / Double(observations.count)
    }

    public var corroborationRate: Double {
        guard !observations.isEmpty else { return 0 }
        return Double(observations.filter { $0.standing == .corroborated }.count) / Double(observations.count)
    }
}

/// The cross-check itself, kept out of the MLX target so it is testable under `swift test`.
public enum SceneCrossCheck {
    /// Decides a claim's standing against what Vision measured in the same frame.
    ///
    /// Only contradictions that hold at ANY threshold are used. Anything requiring a tuned
    /// constant is left `unchecked` on purpose.
    public static func standing(shot: ShotSize, vision: FrameObservation?) -> (ClaimStanding, String) {
        guard let vision else { return (.unchecked, "no Vision observation for this frame") }
        let faces = vision.faceCount
        switch shot {
        case .card where faces > 0:
            return (.contradicted, "claimed a card with no person, but Vision found \(faces) face(s)")
        case .closeUp where faces == 0:
            return (.contradicted, "claimed a close-up, but Vision found no face")
        case .split where faces == 0:
            return (.contradicted, "claimed a split with a person, but Vision found no face")
        case .card:
            return (.corroborated, "no face, consistent with a card")
        case .closeUp, .medium, .split:
            return faces > 0 ? (.corroborated, "Vision found \(faces) face(s), consistent")
                             : (.unchecked, "no face; shot size not decidable from Vision alone")
        case .wide, .other:
            // A wide shot may legitimately contain no detectable face, and `other` asserts nothing.
            return (.unchecked, "Vision cannot confirm or deny this shot size")
        }
    }
}
