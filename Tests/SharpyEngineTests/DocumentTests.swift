import XCTest
@testable import SharpyEngine

final class DocumentTests: XCTestCase {
    let rate = FrameRate.r30
    func t(_ frames: Int64) -> TimeValue { TimeValue(frames: frames, at: rate) }
    func r(_ a: Int64, _ b: Int64) -> TimeRange { TimeRange(start: t(a), end: t(b)) }

    var asset: AssetRef {
        AssetRef(contentHash: "sha256:abc", path: "/media/take1.mov", duration: t(3000), frameRate: rate, hasVideo: true, hasAudio: true)
    }
    var assetID: NodeID { Canonical.id(of: asset) }
    var measured: Basis { .measuredMaterial(ref: "pause@41.20", detail: "420 ms gap", confidence: Rational(9, 10)) }

    func fresh() throws -> CommandLog {
        var log = CommandLog(initial: Document(timeline: Timeline(name: "main", frameRate: rate)))
        try log.append(.addAsset(asset))
        try log.append(.addTrack(kind: .video, name: "V1"))
        return log
    }

    func testContentAddressing() throws {
        let a = Document(timeline: Timeline(name: "main", frameRate: rate))
        let b = Document(timeline: Timeline(name: "main", frameRate: rate))
        XCTAssertEqual(a.id, b.id, "equal content, equal id")
        let c = Document(timeline: Timeline(name: "other", frameRate: rate))
        XCTAssertNotEqual(a.id, c.id)
    }

    func testDecisionCannotExistWithoutBasis() {
        // Compile-time guarantee: Decision.init requires `basis:`. This test documents it.
        let d = Decision(kind: .cut, at: t(0), basis: measured)
        XCTAssertEqual(d.basis.rank, 3)
    }

    func testConfidenceFloorBlocksLowConfidenceFacts() throws {
        var log = try fresh()
        let weak = Basis.structuralInference(evidence: ["topic shift?"], confidence: Rational(1, 2))
        XCTAssertThrowsError(try log.append(.recordDecision(Decision(kind: .structure, at: t(0), basis: weak)))) { e in
            guard case ApplyError.belowConfidenceFloor = e as! ApplyError else { return XCTFail("\(e)") }
        }
        // rules carry confidence 1 and always pass the floor
        try log.append(.recordDecision(Decision(kind: .graphic, at: t(0), basis: .clientRule(rule: "face in lower half on any split"))))
        XCTAssertEqual(log.head.decisionOrder.count, 1)
    }

    func testPlaceRefusesOverlapAndOffFrameStarts() throws {
        var log = try fresh()
        let clip = Clip(asset: assetID, source: r(0, 100), start: t(0))
        try log.append(.placeClip(track: 0, clip: clip, decision: Decision(kind: .cut, at: t(0), basis: measured)))
        let overlapping = Clip(asset: assetID, source: r(500, 600), start: t(50))
        XCTAssertThrowsError(try log.append(.placeClip(track: 0, clip: overlapping, decision: Decision(kind: .cut, at: t(50), basis: measured)))) { e in
            guard case ApplyError.overlap = e as! ApplyError else { return XCTFail("\(e)") }
        }
        let offFrame = Clip(asset: assetID, source: r(500, 600), start: TimeValue(seconds: Rational(1, 7)))
        XCTAssertThrowsError(try log.append(.placeClip(track: 0, clip: offFrame, decision: Decision(kind: .cut, at: t(0), basis: measured)))) { e in
            guard case ApplyError.notFrameAligned = e as! ApplyError else { return XCTFail("\(e)") }
        }
        let beyondSource = Clip(asset: assetID, source: r(2950, 3050), start: t(1000))
        XCTAssertThrowsError(try log.append(.placeClip(track: 0, clip: beyondSource, decision: Decision(kind: .cut, at: t(0), basis: measured))))
        XCTAssertEqual(log.head.timeline.tracks[0].clips.count, 1, "refused commands change nothing")
    }

    func testRippleDeleteInsideOneClip() throws {
        var log = try fresh()
        try log.append(.placeClip(track: 0, clip: Clip(asset: assetID, source: r(0, 300), start: t(0)),
                                  decision: Decision(kind: .cut, at: t(0), basis: measured)))
        // remove frames [100, 130) — a 30-frame dead-air gap
        try log.append(.rippleDelete(track: 0, range: r(100, 130), decision: Decision(kind: .cut, at: t(100), basis: measured)))
        let clips = log.head.timeline.tracks[0].clips
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].range, r(0, 100));   XCTAssertEqual(clips[0].source, r(0, 100))
        XCTAssertEqual(clips[1].range, r(100, 270)); XCTAssertEqual(clips[1].source, r(130, 300))
        XCTAssertEqual(log.head.timeline.duration, t(270))
    }

    func testRippleDeleteAcrossClipsShiftsFollowers() throws {
        var log = try fresh()
        try log.append(.placeClip(track: 0, clip: Clip(asset: assetID, source: r(0, 100), start: t(0)), decision: Decision(kind: .cut, at: t(0), basis: measured)))
        try log.append(.placeClip(track: 0, clip: Clip(asset: assetID, source: r(200, 300), start: t(100)), decision: Decision(kind: .cut, at: t(100), basis: measured)))
        try log.append(.placeClip(track: 0, clip: Clip(asset: assetID, source: r(400, 500), start: t(200)), decision: Decision(kind: .cut, at: t(200), basis: measured)))
        // cut from the tail of clip 1 through the head of clip 2: [80, 120)
        try log.append(.rippleDelete(track: 0, range: r(80, 120), decision: Decision(kind: .cut, at: t(80), basis: measured)))
        let clips = log.head.timeline.tracks[0].clips
        XCTAssertEqual(clips.map(\.range), [r(0, 80), r(80, 160), r(160, 260)])
        XCTAssertEqual(clips.map(\.source), [r(0, 80), r(220, 300), r(400, 500)])
        XCTAssertEqual(log.head.timeline.duration, t(260))
    }

    func testReplayReproducesHeadAndUndoIsAPointer() throws {
        var log = try fresh()
        try log.append(.placeClip(track: 0, clip: Clip(asset: assetID, source: r(0, 300), start: t(0)), decision: Decision(kind: .cut, at: t(0), basis: measured)))
        let afterPlace = log.head.id
        try log.append(.rippleDelete(track: 0, range: r(10, 20), decision: Decision(kind: .cut, at: t(10), basis: measured)))
        try log.append(.recordDecision(Decision(kind: .sound, at: t(50), params: ["cue": "whoosh_03", "rel_db": "-6"], basis: .craftRule(rule: "movement and arrival take separate cues", why: "a sound belongs to a component arriving"))))
        XCTAssertEqual(try log.replay().id, log.head.id, "replaying the log reproduces the head state exactly")
        XCTAssertEqual(try log.state(after: 3).id, afterPlace, "undo is a pointer into the log")
        XCTAssertEqual(log.head.decisionOrder.count, 3)
        // every decision in the record has a basis and none is below the floor
        for id in log.head.decisionOrder {
            let d = log.head.decisions[id]!
            XCTAssertFalse(d.basis.confidence < log.head.confidenceFloor)
        }
    }

    func testLogSerialisesAndDeserialisesToTheSameHead() throws {
        var log = try fresh()
        try log.append(.placeClip(track: 0, clip: Clip(asset: assetID, source: r(0, 300), start: t(0)), decision: Decision(kind: .cut, at: t(0), basis: measured)))
        let data = try Canonical.encoder.encode(log)
        let back = try Canonical.decoder.decode(CommandLog.self, from: data)
        XCTAssertEqual(back.head.id, log.head.id)
        XCTAssertEqual(try back.replay().id, log.head.id)
    }
}
