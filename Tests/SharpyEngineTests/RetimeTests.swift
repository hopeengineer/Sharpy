// Freeze, slow motion and speed-up are one operation. These check the arithmetic, and especially
// that a retimed clip occupies the right amount of TIMELINE — get that wrong and every overlap
// check and ripple delete is quietly incorrect.

import XCTest
@testable import SharpyEngine

final class RetimeTests: XCTestCase {
    let rate = FrameRate.r30
    func t(_ f: Int64) -> TimeValue { TimeValue(frames: f, at: .r30) }
    let asset = NodeID(contentOf: "a")

    func testANormalClipIsUnchanged() {
        let clip = Clip(asset: asset, source: TimeRange(start: t(0), end: t(30)), start: t(10))
        XCTAssertEqual(clip.end, t(40))
        XCTAssertEqual(clip.speed, .one)
        XCTAssertEqual(clip.sourceTime(at: t(25)), t(15), "15 frames in is 15 frames of source")
    }

    /// A frozen frame: one frame of source held for two seconds.
    func testAFreezeHoldsOneFrameAndOccupiesItsFullSpan() {
        let clip = Clip.freeze(asset: asset, at: t(90), frameDuration: t(1),
                               start: t(0), duration: t(60))
        XCTAssertEqual(clip.end, t(60), "it occupies two seconds of timeline")
        XCTAssertEqual(clip.timelineSpan, t(60))
        // Every instant inside it shows a time within that single source frame.
        for f in [Int64(0), 15, 30, 59] {
            let source = clip.sourceTime(at: t(f))
            XCTAssertGreaterThanOrEqual(source.seconds, t(90).seconds)
            XCTAssertLessThan(source.seconds, t(91).seconds, "still inside the held frame at \(f)")
        }
    }

    /// Slow motion: one second of source stretched over two.
    func testSlowMotionSamplesSourceAtHalfRate() {
        let clip = Clip(asset: asset, source: TimeRange(start: t(0), end: t(30)),
                        start: t(0), timelineDuration: t(60))
        XCTAssertEqual(clip.end, t(60))
        XCTAssertEqual(clip.speed, Rational(1, 2))
        XCTAssertEqual(clip.sourceTime(at: t(30)), t(15), "halfway through, half the source")
        XCTAssertEqual(clip.sourceTime(at: t(60)), t(30))
    }

    /// Speed up: two seconds of source in one.
    func testSpeedUpSamplesSourceAtDoubleRate() {
        let clip = Clip(asset: asset, source: TimeRange(start: t(0), end: t(60)),
                        start: t(0), timelineDuration: t(30))
        XCTAssertEqual(clip.end, t(30))
        XCTAssertEqual(clip.speed, Rational(2, 1))
        XCTAssertEqual(clip.sourceTime(at: t(15)), t(30))
    }

    /// Retiming must survive being placed and rippled, or a speed change silently reverts.
    func testRetimingSurvivesReplacement() {
        let clip = Clip(asset: asset, source: TimeRange(start: t(0), end: t(30)),
                        start: t(0), timelineDuration: t(90))
        let moved = clip.placed(ClipPlacement.full)
        XCTAssertEqual(moved.timelineDuration, t(90))
        XCTAssertEqual(moved.end, t(90))
    }

    /// Two retimed clips must not be judged for overlap by their SOURCE lengths.
    func testOverlapUsesTimelineSpanNotSourceLength() throws {
        var log = CommandLog(initial: Document(timeline: Timeline(name: "t", frameRate: rate)))
        try log.append(.addAsset(AssetRef(contentHash: "a", path: "/tmp/a.mov", duration: t(600),
                                          frameRate: rate, hasVideo: true, hasAudio: false)))
        try log.append(.addTrack(kind: .video, name: "V1"))
        let id = log.head.assets.keys.first!
        let basis = Basis.measuredMaterial(ref: "t", detail: "d", confidence: .one)
        // One frame of source, held for 60 frames.
        try log.append(.placeClip(track: 0,
            clip: Clip.freeze(asset: id, at: t(0), frameDuration: t(1), start: t(0), duration: t(60)),
            decision: Decision(kind: .speed, at: t(0), basis: basis)))
        XCTAssertEqual(log.head.timeline.duration, t(60),
                       "a freeze contributes its held length, not one frame")
        // Placing at frame 30 must be refused: the freeze runs to 60.
        XCTAssertThrowsError(try log.head.apply(.placeClip(track: 0,
            clip: Clip(asset: id, source: TimeRange(start: t(0), end: t(30)), start: t(30)),
            decision: Decision(kind: .cut, at: t(30), basis: basis))))
    }

    /// Old documents have no timelineDuration and must behave exactly as before.
    func testDocumentsWithoutRetimingDecodeUnchanged() throws {
        let clip = Clip(asset: asset, source: TimeRange(start: t(0), end: t(30)), start: t(0))
        var object = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(clip)) as! [String: Any]
        object.removeValue(forKey: "timelineDuration")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Clip.self, from: data)
        XCTAssertNil(decoded.timelineDuration)
        XCTAssertEqual(decoded.end, t(30))
        XCTAssertEqual(decoded.speed, .one)
    }
}
