// The edit document: an immutable, content-addressed graph. Every state has an id (its hash);
// history is a log of commands; a branch is just another root hash. The agent and the human
// UI both operate through `apply(_:to:)` — there is no other way to change a document.
//
// The one rule (spec §0): a Decision carries a Basis, or it does not exist. `Decision.init`
// takes a non-optional Basis; there is no path to a basis-less decision at the type level.

import Foundation
import CryptoKit

// MARK: - Identity

/// SHA-256 of the canonical encoding of a node. Two nodes with equal content have equal ids.
public struct NodeID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let hex: String
    init(hashing data: Data) { hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    /// A stable id for arbitrary content — e.g. a media path, before the asset is in a document.
    public init(contentOf string: String) { self.init(hashing: Data(string.utf8)) }
    init(hex: String) { self.hex = hex }
    public var description: String { String(hex.prefix(12)) }

    // Encoded as a bare string rather than {"hex": …} so canonical JSON stays compact and
    // readable, and so an id is directly greppable in a stored document.
    public init(from decoder: Decoder) throws { hex = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(hex)
    }
}

/// Canonical JSON: sorted keys, no floats anywhere in the model, so encoding is deterministic.
enum Canonical {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    static let decoder = JSONDecoder()
    static func id<T: Encodable>(of value: T) -> NodeID { NodeID(hashing: try! encoder.encode(value)) }
}

// MARK: - Nodes

public struct AssetRef: Hashable, Sendable, Codable {
    /// Content hash of the media file itself — the same file imported twice is one asset.
    public let contentHash: String
    public let path: String
    public let duration: TimeValue
    public let frameRate: FrameRate?
    public let hasVideo: Bool
    public let hasAudio: Bool
    public init(contentHash: String, path: String, duration: TimeValue, frameRate: FrameRate?, hasVideo: Bool, hasAudio: Bool) {
        self.contentHash = contentHash; self.path = path; self.duration = duration
        self.frameRate = frameRate; self.hasVideo = hasVideo; self.hasAudio = hasAudio
    }
}

/// Where a clip sits in the frame, as fractions of the output — so a placement survives a change
/// of delivery resolution, which pixel offsets would not.
///
/// Exact rationals rather than floats, for the same reason time is: a placement that a document
/// round-trips must come back identical, and repeated float arithmetic on a scale drifts. The
/// conversion to Float happens once, at the compositor boundary.
public struct ClipPlacement: Hashable, Sendable, Codable {
    /// Top-left of the clip as a fraction of output width/height. (0,0) is the frame's corner.
    public let x: Rational
    public let y: Rational
    /// Fraction of the output's width the clip spans. 1 = full width.
    public let width: Rational
    /// 0…1 straight alpha, composited "over".
    public let opacity: Rational

    public init(x: Rational, y: Rational, width: Rational, opacity: Rational = .one) {
        self.x = x; self.y = y; self.width = width; self.opacity = opacity
    }

    /// Fill the frame — what a clip with no placement does.
    public static let full = ClipPlacement(x: .zero, y: .zero, width: .one)

    /// A corner inset, the common picture-in-picture case.
    public static func inset(width: Rational, margin: Rational) -> ClipPlacement {
        ClipPlacement(x: .one - width - margin, y: margin, width: width)
    }
}

public struct Clip: Hashable, Sendable, Codable {
    public let asset: NodeID
    /// Range within the source asset.
    public let source: TimeRange
    /// Position on the track. `duration` equals source.duration unless retimed.
    public let start: TimeValue
    /// Where it sits in the frame. `nil` means fit the whole frame, which is what every clip did
    /// before placement existed and remains the default so old documents decode unchanged.
    public let placement: ClipPlacement?
    public var end: TimeValue { start + source.duration }
    public var range: TimeRange { TimeRange(start: start, end: end) }
    public init(asset: NodeID, source: TimeRange, start: TimeValue, placement: ClipPlacement? = nil) {
        self.asset = asset; self.source = source; self.start = start; self.placement = placement
    }

    /// The same clip somewhere else in the frame.
    public func placed(_ placement: ClipPlacement?) -> Clip {
        Clip(asset: asset, source: source, start: start, placement: placement)
    }
}

public enum TrackKind: String, Sendable, Codable { case video, audio }

public struct Track: Hashable, Sendable, Codable {
    public let kind: TrackKind
    public let name: String
    /// Clips sorted by start, non-overlapping. Enforced by `apply`.
    public let clips: [Clip]
    public init(kind: TrackKind, name: String, clips: [Clip] = []) { self.kind = kind; self.name = name; self.clips = clips }
}

public struct Timeline: Hashable, Sendable, Codable {
    public let name: String
    public let frameRate: FrameRate
    /// Audio's own grid. Video edits land on frame boundaries; audio edits land on sample
    /// boundaries, which are ~2000x finer — a cut that must land inside a syllable cannot be
    /// quantised to 1/30 s without an audible click.
    public let sampleRate: Int
    public let tracks: [Track]
    public init(name: String, frameRate: FrameRate, sampleRate: Int = 48_000, tracks: [Track] = []) {
        precondition(sampleRate > 0, "sample rate must be positive")
        self.name = name; self.frameRate = frameRate; self.sampleRate = sampleRate; self.tracks = tracks
    }
    public var duration: TimeValue { tracks.flatMap(\.clips).map(\.end).max() ?? .zero }

    /// The grid a given track's edit points must land on.
    public func grid(for kind: TrackKind) -> Rational {
        switch kind {
        case .video: return frameRate.frameDuration
        case .audio: return Rational(1, Int64(sampleRate))
        }
    }
}

// MARK: - Basis and Decision (spec §0, §1 L5)

/// The fact or rule that produced a decision. Ordered by authority, highest first.
public enum Basis: Hashable, Sendable, Codable {
    /// Non-overridable: WCAG flash limits, loudness ceilings. Cites the standard.
    case safetyConstraint(standard: String, detail: String)
    /// A standing instruction from the person whose video it is, verbatim.
    case clientRule(rule: String)
    /// A hard requirement of the destination platform.
    case platformRequirement(platform: String, requirement: String)
    /// A fact measured from this footage (L1/L2), with the fact's own confidence.
    case measuredMaterial(ref: String, detail: String, confidence: Rational)
    /// A statistic from a reference corpus or the creator's catalogue.
    case measuredNorm(ref: String, detail: String, evidence: EvidenceClass, sampleSize: Int)
    /// A statistically inferred preference. Below norms; must state n and confidence.
    case learnedPreference(ref: String, occurrences: Int, confidence: Rational)
    /// A documented craft convention with a written justification.
    case craftRule(rule: String, why: String)
    /// L3 only: a structural inference citing the L2 evidence that produced it.
    case structuralInference(evidence: [String], confidence: Rational)

    public enum EvidenceClass: String, Sendable, Codable { case correlational, outcomeLinked }

    /// Lower rank = higher authority.
    public var rank: Int {
        switch self {
        case .safetyConstraint: return 0
        case .clientRule: return 1
        case .platformRequirement: return 2
        case .measuredMaterial: return 3
        case .measuredNorm: return 4
        case .learnedPreference: return 5
        case .craftRule: return 6
        case .structuralInference: return 7
        }
    }

    /// Confidence carried by the basis, if it is an inferred fact. 1 for rules and requirements.
    public var confidence: Rational {
        switch self {
        case .measuredMaterial(_, _, let c), .learnedPreference(_, _, let c), .structuralInference(_, let c): return c
        default: return .one
        }
    }
}

public enum DecisionKind: String, Sendable, Codable {
    case cut, camera, graphic, sound, speed, colour, transition, structure
}

/// One entry in the append-only decision record (L5). It cannot be constructed without a basis.
public struct Decision: Hashable, Sendable, Codable {
    public let kind: DecisionKind
    public let at: TimeValue
    public let params: [String: String]
    public let basis: Basis
    public let alternativesRejected: [RejectedAlternative]
    public let supersedes: NodeID?

    public init(kind: DecisionKind, at: TimeValue, params: [String: String] = [:], basis: Basis,
                alternativesRejected: [RejectedAlternative] = [], supersedes: NodeID? = nil) {
        self.kind = kind; self.at = at; self.params = params; self.basis = basis
        self.alternativesRejected = alternativesRejected; self.supersedes = supersedes
    }
}

public struct RejectedAlternative: Hashable, Sendable, Codable {
    public let params: [String: String]
    public let why: String
    public init(params: [String: String], why: String) { self.params = params; self.why = why }
}

// MARK: - Document

/// A snapshot of the whole project. Immutable; `apply` returns a new one.
public struct Document: Sendable, Codable, Equatable {
    public private(set) var assets: [NodeID: AssetRef]
    public private(set) var timeline: Timeline
    public private(set) var decisions: [NodeID: Decision]
    /// Decision ids in the order they were made.
    public private(set) var decisionOrder: [NodeID]
    /// The project's confidence floor (spec L2): no decision may rest on a basis below it.
    public let confidenceFloor: Rational

    public init(timeline: Timeline, confidenceFloor: Rational = Rational(7, 10)) {
        self.assets = [:]; self.timeline = timeline; self.decisions = [:]; self.decisionOrder = []
        self.confidenceFloor = confidenceFloor
    }

    /// Content id of this state. Equal documents have equal ids — always, not usually.
    public var id: NodeID { Canonical.id(of: self) }

    /// Distinct decisions in the order first made — the editorial history, with each act once.
    /// A cut applied to linked picture and sound is one act, so `decisionOrder` records it twice
    /// while this records it once, alongside how many tracks it touched.
    public var uniqueDecisions: [(id: NodeID, decision: Decision, applications: Int)] {
        var counts: [NodeID: Int] = [:]
        var order: [NodeID] = []
        for id in decisionOrder {
            if counts[id] == nil { order.append(id) }
            counts[id, default: 0] += 1
        }
        return order.compactMap { id in
            guard let d = decisions[id] else { return nil }
            return (id, d, counts[id] ?? 1)
        }
    }

    // MARK: canonical encoding
    //
    // `assets` and `decisions` are keyed by NodeID, not by String, so Codable's synthesised
    // conformance encodes them as *unkeyed* containers in Dictionary iteration order — which
    // Swift randomises per process and which differs between two equal dictionaries. That made
    // `id` a coin flip: the same document hashed to one of n! values, so replay integrity, undo,
    // branching and audit all broke intermittently, and a 2-entry test agreed half the time.
    //
    // Both maps are therefore encoded as arrays of {id, …} entries sorted by id, which is
    // deterministic by construction rather than by hoping the encoder cooperates. Everything
    // else here is already an ordered array or a scalar. `params` and other String-keyed maps
    // are safe because JSONEncoder's `.sortedKeys` applies to keyed containers.

    private struct AssetEntry: Codable { let id: NodeID; let asset: AssetRef }
    private struct DecisionEntry: Codable { let id: NodeID; let decision: Decision }

    private enum CodingKeys: String, CodingKey { case assets, timeline, decisions, decisionOrder, confidenceFloor }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(assets.map { AssetEntry(id: $0.key, asset: $0.value) }.sorted { $0.id.hex < $1.id.hex }, forKey: .assets)
        try c.encode(timeline, forKey: .timeline)
        try c.encode(decisions.map { DecisionEntry(id: $0.key, decision: $0.value) }.sorted { $0.id.hex < $1.id.hex }, forKey: .decisions)
        try c.encode(decisionOrder, forKey: .decisionOrder)
        try c.encode(confidenceFloor, forKey: .confidenceFloor)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assets = Dictionary(uniqueKeysWithValues: try c.decode([AssetEntry].self, forKey: .assets).map { ($0.id, $0.asset) })
        decisions = Dictionary(uniqueKeysWithValues: try c.decode([DecisionEntry].self, forKey: .decisions).map { ($0.id, $0.decision) })
        timeline = try c.decode(Timeline.self, forKey: .timeline)
        decisionOrder = try c.decode([NodeID].self, forKey: .decisionOrder)
        confidenceFloor = try c.decode(Rational.self, forKey: .confidenceFloor)
    }

    // Mutation is private: only `apply` builds new states.
    fileprivate func with(assets: [NodeID: AssetRef]? = nil, timeline: Timeline? = nil,
                          decisions: [NodeID: Decision]? = nil, decisionOrder: [NodeID]? = nil) -> Document {
        var d = self
        if let a = assets { d.assets = a }
        if let t = timeline { d.timeline = t }
        if let x = decisions { d.decisions = x }
        if let o = decisionOrder { d.decisionOrder = o }
        return d
    }
}

// MARK: - Commands

/// Everything that can change a document. Serialisable, replayable, the same for the agent and
/// the human UI.
public enum Command: Sendable, Codable, Equatable {
    case addAsset(AssetRef)
    case addTrack(kind: TrackKind, name: String)
    /// Place a clip on a track. Refused if it would overlap an existing clip.
    case placeClip(track: Int, clip: Clip, decision: Decision)
    /// Remove [range) from a track and close the gap (ripple). Linked tracks are the caller's
    /// concern at this layer; the engine's sync lock lives one level up.
    case rippleDelete(track: Int, range: TimeRange, decision: Decision)
    /// Move or resize a clip within the frame. Geometry in space rather than in time, but a
    /// decision all the same — a picture-in-picture that covers a face is an edit, and an edit
    /// without a basis does not render.
    case placeInFrame(track: Int, clipIndex: Int, placement: ClipPlacement?, decision: Decision)
    /// Record a decision that changes no clip geometry (colour, sound cue, graphic).
    case recordDecision(Decision)
}

public enum ApplyError: Error, Equatable, CustomStringConvertible {
    case noSuchTrack(Int)
    case noSuchClip(Int, Int)
    case notAVideoTrack(Int)
    case noSuchAsset(NodeID)
    case overlap(existing: TimeRange, new: TimeRange)
    case sourceOutOfRange(asset: NodeID, source: TimeRange, duration: TimeValue)
    case notFrameAligned(TimeValue, FrameRate)
    case notSampleAligned(TimeValue, Int)
    case belowConfidenceFloor(basis: Basis, floor: Rational)
    case emptyRange

    public var description: String {
        switch self {
        case .noSuchTrack(let i): return "no track at index \(i)"
        case .noSuchClip(let t, let c): return "no clip at index \(c) on track \(t)"
        case .notAVideoTrack(let i): return "track \(i) is not a video track; placement is picture-only"
        case .noSuchAsset(let id): return "no asset \(id)"
        case .overlap(let e, let n): return "clip \(n) overlaps existing clip \(e)"
        case .sourceOutOfRange(let a, let s, let d): return "source range \(s) exceeds asset \(a) duration \(d)"
        case .notFrameAligned(let t, let r): return "\(t) is not on a frame boundary at \(r)"
        case .notSampleAligned(let t, let sr): return "\(t) is not on a sample boundary at \(sr) Hz"
        case .belowConfidenceFloor(let b, let f): return "basis confidence \(b.confidence) is below the project floor \(f)"
        case .emptyRange: return "empty range"
        }
    }
}

/// What a command changed — enough for a UI or an agent to patch state without re-reading.
public struct Delta: Sendable, Equatable {
    public let before: NodeID
    public let after: NodeID
    public let decision: NodeID?
    public let shiftedTracks: [Int]
}

extension Document {
    /// Apply one command. Pure: returns the new document and a delta, or an error and no change.
    public func apply(_ command: Command) throws -> (Document, Delta) {
        let before = id
        switch command {
        case .addAsset(let asset):
            var a = assets; let key = Canonical.id(of: asset); a[key] = asset
            let d = with(assets: a)
            return (d, Delta(before: before, after: d.id, decision: nil, shiftedTracks: []))

        case .addTrack(let kind, let name):
            let t = Timeline(name: timeline.name, frameRate: timeline.frameRate, sampleRate: timeline.sampleRate,
                             tracks: timeline.tracks + [Track(kind: kind, name: name)])
            let d = with(timeline: t)
            return (d, Delta(before: before, after: d.id, decision: nil, shiftedTracks: []))

        case .placeClip(let trackIndex, let clip, let decision):
            try check(decision)
            guard timeline.tracks.indices.contains(trackIndex) else { throw ApplyError.noSuchTrack(trackIndex) }
            guard let asset = assets[clip.asset] else { throw ApplyError.noSuchAsset(clip.asset) }
            guard !(asset.duration < clip.source.end) else {
                throw ApplyError.sourceOutOfRange(asset: clip.asset, source: clip.source, duration: asset.duration)
            }
            let track = timeline.tracks[trackIndex]
            try requireAligned(clip.start, on: track.kind)
            try requireAligned(clip.end, on: track.kind)
            if let hit = track.clips.first(where: { $0.range.overlaps(clip.range) }) {
                throw ApplyError.overlap(existing: hit.range, new: clip.range)
            }
            let clips = (track.clips + [clip]).sorted { $0.start < $1.start }
            let d = replacing(track: trackIndex, with: Track(kind: track.kind, name: track.name, clips: clips))
                .recording(decision)
            return (d.0, Delta(before: before, after: d.0.id, decision: d.1, shiftedTracks: []))

        case .rippleDelete(let trackIndex, let range, let decision):
            try check(decision)
            guard timeline.tracks.indices.contains(trackIndex) else { throw ApplyError.noSuchTrack(trackIndex) }
            guard !range.isEmpty else { throw ApplyError.emptyRange }
            let track = timeline.tracks[trackIndex]
            try requireAligned(range.start, on: track.kind); try requireAligned(range.end, on: track.kind)
            var out: [Clip] = []
            for c in track.clips {
                guard let cut = c.range.intersection(range) else {
                    // untouched; shift left if it starts after the removed range
                    // `placement: c.placement` on every reconstruction below is load-bearing: a
                    // ripple delete must move a clip in TIME without silently resetting where it
                    // sits in the FRAME.
                    out.append(range.end < c.start || range.end == c.start ? Clip(asset: c.asset, source: c.source, start: c.start - range.duration, placement: c.placement) : c)
                    continue
                }
                // head piece before the cut
                if c.start < cut.start {
                    let headDur = cut.start - c.start
                    out.append(Clip(asset: c.asset, source: TimeRange(start: c.source.start, duration: headDur), start: c.start, placement: c.placement))
                }
                // tail piece after the cut, rippled left
                if cut.end < c.end {
                    let tailOffset = cut.end - c.start
                    let tailSourceStart = c.source.start + tailOffset
                    out.append(Clip(asset: c.asset, source: TimeRange(start: tailSourceStart, end: c.source.end), start: cut.end - range.duration, placement: c.placement))
                }
            }
            let d = replacing(track: trackIndex, with: Track(kind: track.kind, name: track.name, clips: out)).recording(decision)
            return (d.0, Delta(before: before, after: d.0.id, decision: d.1, shiftedTracks: [trackIndex]))

        case .placeInFrame(let trackIndex, let clipIndex, let placement, let decision):
            try check(decision)
            guard timeline.tracks.indices.contains(trackIndex) else { throw ApplyError.noSuchTrack(trackIndex) }
            let track = timeline.tracks[trackIndex]
            guard track.clips.indices.contains(clipIndex) else { throw ApplyError.noSuchClip(trackIndex, clipIndex) }
            guard track.kind == .video else { throw ApplyError.notAVideoTrack(trackIndex) }
            var clips = track.clips
            clips[clipIndex] = clips[clipIndex].placed(placement)
            let d = replacing(track: trackIndex, with: Track(kind: track.kind, name: track.name, clips: clips))
                .recording(decision)
            return (d.0, Delta(before: before, after: d.0.id, decision: d.1, shiftedTracks: []))

        case .recordDecision(let decision):
            try check(decision)
            let d = recording(decision)
            return (d.0, Delta(before: before, after: d.0.id, decision: d.1, shiftedTracks: []))
        }
    }

    /// The second anti-speculation gate (spec L2): a decision may not rest on a fact below the floor.
    private func check(_ decision: Decision) throws {
        if decision.basis.confidence < confidenceFloor {
            throw ApplyError.belowConfidenceFloor(basis: decision.basis, floor: confidenceFloor)
        }
    }

    /// Video edit points must sit on a frame boundary; audio edit points on a sample boundary.
    /// Enforcing the video grid on audio would quantise every cut to 1/30 s — audible, and wrong.
    private func requireAligned(_ t: TimeValue, on kind: TrackKind) throws {
        switch kind {
        case .video:
            if !t.isFrameAligned(at: timeline.frameRate) { throw ApplyError.notFrameAligned(t, timeline.frameRate) }
        case .audio:
            if (t.seconds * Rational(Int64(timeline.sampleRate))).den != 1 {
                throw ApplyError.notSampleAligned(t, timeline.sampleRate)
            }
        }
    }

    private func replacing(track index: Int, with track: Track) -> Document {
        var tracks = timeline.tracks; tracks[index] = track
        return with(timeline: Timeline(name: timeline.name, frameRate: timeline.frameRate, sampleRate: timeline.sampleRate, tracks: tracks))
    }

    private func recording(_ decision: Decision) -> (Document, NodeID) {
        var ds = decisions; let key = Canonical.id(of: decision); ds[key] = decision
        return (with(decisions: ds, decisionOrder: decisionOrder + [key]), key)
    }
}

// MARK: - Command log

extension Document {
    /// Every audio track's clip covering `t`, with the source instant it maps to.
    /// Unlike video these are summed, not stacked, so order carries no z-meaning.
    public func audioClips(at t: TimeValue) -> [(trackIndex: Int, clip: Clip, sourceTime: TimeValue)] {
        timeline.tracks.enumerated().compactMap { (i, track) in
            guard track.kind == .audio, let clip = track.clips.first(where: { $0.range.contains(t) }) else { return nil }
            return (i, clip, clip.source.start + (t - clip.start))
        }
    }

    /// Contiguous audio segments on one track, in timeline order: what to read from where.
    public func audioSegments(track index: Int) -> [(clip: Clip, timeline: TimeRange)] {
        guard timeline.tracks.indices.contains(index), timeline.tracks[index].kind == .audio else { return [] }
        return timeline.tracks[index].clips.map { ($0, $0.range) }
    }
}

/// Append-only history. Replaying it from the initial document must reproduce the current id —
/// that equality is the engine's integrity check and the basis of undo, branching and audit.
public struct CommandLog: Sendable, Codable, Equatable {
    public let initial: Document
    public private(set) var commands: [Command]
    public private(set) var head: Document

    public init(initial: Document) { self.initial = initial; self.commands = []; self.head = initial }

    @discardableResult
    public mutating func append(_ command: Command) throws -> Delta {
        let (next, delta) = try head.apply(command)
        commands.append(command); head = next
        return delta
    }

    /// Replay from the initial state. Equal to `head` by construction; tests assert it.
    public func replay() throws -> Document {
        try commands.reduce(initial) { try $0.apply($1).0 }
    }

    /// The document as it was after `count` commands — undo is a pointer, not an inverse.
    public func state(after count: Int) throws -> Document {
        try commands.prefix(count).reduce(initial) { try $0.apply($1).0 }
    }
}
