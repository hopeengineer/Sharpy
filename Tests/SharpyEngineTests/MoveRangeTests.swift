// Without this the agent can only subtract. "Move the payoff earlier" is the edit the whole
// project exists for, and these check it does the thing a person means by it.

import XCTest
@testable import SharpyEngine

final class MoveRangeTests: XCTestCase {
    let rate = FrameRate.r30
    func t(_ f: Int64) -> TimeValue { TimeValue(frames: f, at: .r30) }
    var basis: Basis { .measuredMaterial(ref: "t", detail: "d", confidence: .one) }

    /// One 300-frame clip, source 0–300 on the timeline at 0.
    func log(assetDuration: Int64 = 600) throws -> (CommandLog, NodeID) {
        var log = CommandLog(initial: Document(timeline: Timeline(name: "t", frameRate: rate)))
        try log.append(.addAsset(AssetRef(contentHash: "a", path: "/tmp/a.mov",
                                          duration: t(assetDuration), frameRate: rate,
                                          hasVideo: true, hasAudio: false)))
        try log.append(.addTrack(kind: .video, name: "V1"))
        let id = log.head.assets.keys.first!
        try log.append(.placeClip(track: 0,
                                  clip: Clip(asset: id, source: TimeRange(start: t(0), end: t(300)), start: t(0)),
                                  decision: Decision(kind: .cut, at: t(0), basis: basis)))
        return (log, id)
    }

    /// The shape of the result: source order 0–100, 200–260, 100–200, 260–300 on the timeline,
    /// with total duration unchanged. Nothing is lost by moving.
    func testMovingASegmentEarlierReordersTheMaterialAndKeepsItAll() throws {
        var (log, _) = try log()
        try log.append(.moveRange(track: 0, range: TimeRange(start: t(200), end: t(260)),
                                  to: t(100), decision: Decision(kind: .structure, at: t(100), basis: basis)))
        let clips = log.head.timeline.tracks[0].clips
        XCTAssertEqual(log.head.timeline.duration, t(300), "moving loses nothing")
        let sourceOrder = clips.map { ($0.source.start.frame(at: rate), $0.source.end.frame(at: rate)) }
        XCTAssertEqual(sourceOrder.map(\.0), [0, 200, 100, 260])
        XCTAssertEqual(sourceOrder.map(\.1), [100, 260, 200, 300])
        // The timeline stays gapless and in order.
        var expected: Int64 = 0
        for clip in clips {
            XCTAssertEqual(clip.start.frame(at: rate), expected, "gap or overlap at \(clip.start)")
            expected += clip.range.duration.frame(at: rate)
        }
    }

    func testMovingASegmentLaterAlsoKeepsEverything() throws {
        var (log, _) = try log()
        try log.append(.moveRange(track: 0, range: TimeRange(start: t(0), end: t(60)),
                                  to: t(300), decision: Decision(kind: .cut, at: t(300), basis: basis)))
        let clips = log.head.timeline.tracks[0].clips
        XCTAssertEqual(log.head.timeline.duration, t(300))
        XCTAssertEqual(clips.map { $0.source.start.frame(at: rate) }, [60, 0],
                       "the opening 2 s now plays last")
    }

    /// The destination is named in the timeline the caller can SEE. If the engine interpreted it
    /// post-lift, every move to a later point would land in the wrong place — and the caller would
    /// be doing frame arithmetic, which is what they are meant to be freed from.
    func testTheDestinationIsInTheTimelineTheCallerCanSee() throws {
        var (log, _) = try log()
        // Move 0–60 so it begins where frame 150 currently is.
        try log.append(.moveRange(track: 0, range: TimeRange(start: t(0), end: t(60)),
                                  to: t(150), decision: Decision(kind: .cut, at: t(150), basis: basis)))
        let clips = log.head.timeline.tracks[0].clips
        // After the lift, old frame 150 is at 90; the moved block must start there.
        let moved = clips.first { $0.source.start == t(0) }
        XCTAssertEqual(moved?.start.frame(at: rate), 90,
                       "old 150 minus the 60 lifted from before it")
    }

    /// A move that lands mid-clip must split it. Silently snapping to the nearest boundary would
    /// be a different edit from the one asked for.
    func testALandingPointInsideAClipSplitsIt() throws {
        var (log, _) = try log()
        try log.append(.moveRange(track: 0, range: TimeRange(start: t(240), end: t(300)),
                                  to: t(90), decision: Decision(kind: .cut, at: t(90), basis: basis)))
        let clips = log.head.timeline.tracks[0].clips
        XCTAssertEqual(clips.count, 3, "head, the moved block, tail")
        XCTAssertEqual(clips.map { $0.source.start.frame(at: rate) }, [0, 240, 90])
    }

    /// Landing inside the material being moved has no meaning — it would have to be both lifted
    /// and still there.
    func testLandingInsideTheMovedRangeIsRefused() throws {
        var (log, _) = try log()
        XCTAssertThrowsError(try log.append(.moveRange(
            track: 0, range: TimeRange(start: t(100), end: t(200)), to: t(150),
            decision: Decision(kind: .cut, at: t(150), basis: basis)))) { error in
            guard case ApplyError.destinationInsideMovedRange = error else {
                return XCTFail("expected a refusal, got \(error)")
            }
        }
    }

    /// A move is an edit, so it needs a basis like every other edit.
    func testAMoveWithoutAnAdequateBasisIsRefused() throws {
        var log = CommandLog(initial: Document(timeline: Timeline(name: "t", frameRate: rate),
                                               confidenceFloor: Rational(9, 10)))
        try log.append(.addAsset(AssetRef(contentHash: "a", path: "/tmp/a.mov", duration: t(600),
                                          frameRate: rate, hasVideo: true, hasAudio: false)))
        try log.append(.addTrack(kind: .video, name: "V1"))
        let id = log.head.assets.keys.first!
        let strong = Basis.safetyConstraint(standard: "fixture", detail: "setup")
        try log.append(.placeClip(track: 0,
                                  clip: Clip(asset: id, source: TimeRange(start: t(0), end: t(300)), start: t(0)),
                                  decision: Decision(kind: .cut, at: t(0), basis: strong)))
        let weak = Basis.structuralInference(evidence: ["guess"], confidence: Rational(1, 10))
        XCTAssertThrowsError(try log.head.apply(.moveRange(
            track: 0, range: TimeRange(start: t(0), end: t(60)), to: t(200),
            decision: Decision(kind: .structure, at: t(200), basis: weak))),
            "a move is an edit and needs a basis like every other edit")
    }

    /// Moving in TIME must not move a clip in the FRAME. The same bug was found in rippleDelete.
    func testAMovePreservesFraming() throws {
        var (log, id) = try log()
        try log.append(.placeInFrame(track: 0, clipIndex: 0,
                                     placement: ClipPlacement(x: Rational(1, 4), y: .zero, width: Rational(1, 2)),
                                     decision: Decision(kind: .camera, at: t(0), basis: basis)))
        try log.append(.moveRange(track: 0, range: TimeRange(start: t(200), end: t(260)),
                                  to: t(0), decision: Decision(kind: .cut, at: t(0), basis: basis)))
        _ = id
        for clip in log.head.timeline.tracks[0].clips {
            XCTAssertEqual(clip.placement?.x, Rational(1, 4), "a move in time is not a move in space")
        }
    }

    /// Audio must stay sample-aligned, not snap to the video grid.
    func testAudioTracksKeepTheirOwnGrid() throws {
        var log = CommandLog(initial: Document(timeline: Timeline(name: "t", frameRate: rate)))
        try log.append(.addAsset(AssetRef(contentHash: "a", path: "/tmp/a.mov", duration: t(600),
                                          frameRate: rate, hasVideo: false, hasAudio: true)))
        try log.append(.addTrack(kind: .audio, name: "A1"))
        let id = log.head.assets.keys.first!
        let end = TimeValue(seconds: Rational(480_000, 48_000))
        try log.append(.placeClip(track: 0,
                                  clip: Clip(asset: id, source: TimeRange(start: .zero, end: end), start: .zero),
                                  decision: Decision(kind: .cut, at: .zero, basis: basis)))
        // A boundary that is a whole number of samples but NOT a frame boundary.
        let odd = TimeValue(seconds: Rational(1601, 48_000))
        let oddEnd = TimeValue(seconds: Rational(3202, 48_000))
        XCTAssertNoThrow(try log.append(.moveRange(
            track: 0, range: TimeRange(start: odd, end: oddEnd), to: .zero,
            decision: Decision(kind: .cut, at: .zero, basis: basis))))
    }

    func testTheLogReplaysToTheSameDocument() throws {
        var (log, _) = try log()
        try log.append(.moveRange(track: 0, range: TimeRange(start: t(200), end: t(260)),
                                  to: t(100), decision: Decision(kind: .structure, at: t(100), basis: basis)))
        XCTAssertEqual(try log.replay().id, log.head.id, "a move must be replayable like any command")
    }
}

/// One editorial act is one finding, however many tracks it touched.
extension MoveRangeTests {
    func testOneEditorialActProducesOneFindingNotOnePerTrack() throws {
        var log = CommandLog(initial: Document(timeline: Timeline(name: "t", frameRate: rate)))
        try log.append(.addAsset(AssetRef(contentHash: "a", path: "/tmp/a.mov", duration: t(600),
                                          frameRate: rate, hasVideo: true, hasAudio: true)))
        // Four tracks, so a per-application bug would show up as 4x rather than 2x.
        for i in 0..<4 { try log.append(.addTrack(kind: i < 2 ? .video : .audio, name: "T\(i)")) }
        let id = log.head.assets.keys.first!
        // A basis above the floor but below the ship bar: passes, holds.
        let shaky = Basis.structuralInference(evidence: ["the agent's own reading"], confidence: Rational(3, 4))
        let decision = Decision(kind: .structure, at: t(0), basis: shaky)
        for track in 0..<4 {
            try log.append(.placeClip(track: track,
                                      clip: Clip(asset: id, source: TimeRange(start: t(0), end: t(300)), start: t(0)),
                                      decision: decision))
        }
        let unique = log.head.uniqueDecisions
        XCTAssertEqual(unique.count, 1, "one act")
        XCTAssertEqual(unique[0].applications, 4, "…applied to four tracks")

        let holds = LowConfidenceDecisionsHoldTheRender()
            .evaluate(VerificationContext(document: log.head))
        XCTAssertEqual(holds.count, 1,
                       "a reviewer must see the questionable edit once, not once per track")
    }
}
