// A reviewer who cannot see what changed cannot approve it. These check that the diff says the
// thing that happened, not the thing the data structure did.

import XCTest
@testable import SharpyEngine

final class CutDiffTests: XCTestCase {
    let rate = FrameRate.r30
    func t(_ f: Int64) -> TimeValue { TimeValue(frames: f, at: .r30) }

    func document(clips: [Clip], assetDuration: Int64 = 600) throws -> (Document, NodeID) {
        var log = CommandLog(initial: Document(timeline: Timeline(name: "t", frameRate: rate)))
        let asset = AssetRef(contentHash: "a", path: "/tmp/a.mov",
                             duration: t(assetDuration), frameRate: rate, hasVideo: true, hasAudio: false)
        try log.append(.addAsset(asset))
        try log.append(.addTrack(kind: .video, name: "V1"))
        let id = log.head.assets.keys.first!
        let basis = Basis.measuredMaterial(ref: "t", detail: "d", confidence: .one)
        for clip in clips {
            try log.append(.placeClip(track: 0,
                                      clip: Clip(asset: id, source: clip.source, start: clip.start,
                                                 placement: clip.placement),
                                      decision: Decision(kind: .cut, at: clip.start, basis: basis)))
        }
        return (log.head, id)
    }

    func clip(_ sourceStart: Int64, _ sourceEnd: Int64, at: Int64, placement: ClipPlacement? = nil) -> Clip {
        Clip(asset: NodeID(contentOf: "placeholder"),
             source: TimeRange(start: t(sourceStart), end: t(sourceEnd)),
             start: t(at), placement: placement)
    }

    /// The headline case: a ripple delete splits one clip into two without changing a frame of
    /// what survives. A clip-by-clip diff would call that "one removed, two added" and bury the
    /// two seconds that actually went.
    func testARippleDeleteReportsTheSecondsThatWentNotTheClipsThatSplit() throws {
        let (before, _) = try document(clips: [clip(0, 300, at: 0)])
        let (after, _) = try document(clips: [clip(0, 100, at: 0), clip(160, 300, at: 100)])
        let diff = before.diff(to: after)

        XCTAssertEqual(diff.changes.count, 1, "one thing happened, however many clips exist now")
        XCTAssertEqual(diff.changes[0].kind, .removed)
        XCTAssertEqual(diff.changes[0].sourceRange.start.seconds.doubleValue, 100.0 / 30, accuracy: 0.001)
        XCTAssertEqual(diff.changes[0].sourceRange.end.seconds.doubleValue, 160.0 / 30, accuracy: 0.001)
        XCTAssertEqual(diff.removedSeconds, 2.0, accuracy: 0.001)
    }

    /// Source time, not timeline time. Cutting at the top shifts every later timecode; a
    /// timeline-based diff would report the whole piece as changed when one cut moved.
    func testAnEarlyCutDoesNotReportEverythingAfterItAsChanged() throws {
        let (before, _) = try document(clips: [clip(0, 300, at: 0)])
        let (after, _) = try document(clips: [clip(30, 300, at: 0)])
        let diff = before.diff(to: after)
        XCTAssertEqual(diff.changes.count, 1)
        XCTAssertEqual(diff.changes[0].kind, .removed)
        XCTAssertEqual(diff.removedSeconds, 1.0, accuracy: 0.001)
    }

    func testAddedMaterialIsReported() throws {
        let (before, _) = try document(clips: [clip(0, 100, at: 0)])
        let (after, _) = try document(clips: [clip(0, 100, at: 0), clip(200, 260, at: 100)])
        let diff = before.diff(to: after)
        XCTAssertEqual(diff.changes.count, 1)
        XCTAssertEqual(diff.changes[0].kind, .added)
        XCTAssertEqual(diff.addedSeconds, 2.0, accuracy: 0.001)
    }

    /// "Still there, moved" is a different question for a reviewer than "gone".
    func testReframingIsReportedSeparatelyFromCutting() throws {
        let (before, _) = try document(clips: [clip(0, 300, at: 0)])
        let (after, _) = try document(clips: [clip(0, 300, at: 0,
                                                   placement: ClipPlacement(x: Rational(1, 2), y: .zero, width: Rational(1, 2)))])
        let diff = before.diff(to: after)
        XCTAssertEqual(diff.changes.count, 1)
        XCTAssertEqual(diff.changes[0].kind, .reframed)
        XCTAssertEqual(diff.removedSeconds, 0, "nothing was cut")
    }

    func testAnUnchangedDocumentDiffsToNothing() throws {
        let (before, _) = try document(clips: [clip(0, 300, at: 0)])
        let (after, _) = try document(clips: [clip(0, 300, at: 0)])
        let diff = before.diff(to: after)
        XCTAssertTrue(diff.isEmpty)
        XCTAssertTrue(diff.summary.contains("no change"))
    }

    /// A reviewer's attention should meet the two seconds that went before the forty milliseconds
    /// that did.
    func testChangesAreOrderedBySizeSoTheBiggestIsMetFirst() throws {
        let (before, _) = try document(clips: [clip(0, 600, at: 0)])
        let (after, _) = try document(clips: [
            clip(0, 100, at: 0),      // removes 100–101 (small)
            clip(101, 200, at: 100),  // removes 200–260 (large)
            clip(260, 600, at: 199),
        ])
        let diff = before.diff(to: after)
        XCTAssertEqual(diff.changes.count, 2)
        XCTAssertGreaterThan(diff.changes[0].seconds, diff.changes[1].seconds)
    }

    /// Several separate cuts must each be reported, not summed into one span.
    func testSeparateCutsAreSeparateChanges() throws {
        let (before, _) = try document(clips: [clip(0, 600, at: 0)])
        let (after, _) = try document(clips: [
            clip(0, 100, at: 0), clip(130, 300, at: 100), clip(400, 600, at: 270),
        ])
        let diff = before.diff(to: after)
        XCTAssertEqual(diff.changes.count, 2, "two holes, two changes")
        XCTAssertEqual(diff.removedSeconds, 1.0 + (100.0 / 30), accuracy: 0.001)
    }

    func testTheSummaryStatesTheDurationChange() throws {
        let (before, _) = try document(clips: [clip(0, 300, at: 0)])
        let (after, _) = try document(clips: [clip(0, 100, at: 0), clip(160, 300, at: 100)])
        let summary = before.diff(to: after).summary
        XCTAssertTrue(summary.contains("10.00 s → 8.00 s"), summary)
        XCTAssertTrue(summary.contains("-2.00 s"), summary)
    }
}
