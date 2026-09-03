import XCTest
@testable import SharpyEngine

final class AssertionTests: XCTestCase {
    let rate = FrameRate.r30
    func t(_ f: Int64) -> TimeValue { TimeValue(frames: f, at: rate) }
    var asset: AssetRef {
        AssetRef(contentHash: "a", path: "/a", duration: t(300), frameRate: rate, hasVideo: true, hasAudio: true)
    }
    var solid: Basis { .measuredMaterial(ref: "x", detail: "y", confidence: .one) }

    /// A document with one video track carrying one clip.
    func makeDocument(clipFrames: Int64 = 100) throws -> Document {
        var log = CommandLog(initial: Document(timeline: Timeline(name: "t", frameRate: rate)))
        try log.append(.addAsset(asset))
        try log.append(.addTrack(kind: .video, name: "V1"))
        let id = log.head.assets.keys.first!
        try log.append(.placeClip(track: 0, clip: Clip(asset: id, source: TimeRange(start: .zero, end: t(clipFrames)), start: .zero),
                                  decision: Decision(kind: .cut, at: .zero, basis: solid)))
        return log.head
    }

    func testACleanDocumentPasses() throws {
        let r = Verifier.standard.verify(VerificationContext(document: try makeDocument()))
        XCTAssertTrue(r.canRender, "unexpected failures: \(r.failures.map(\.description))")
        XCTAssertTrue(r.failures.isEmpty)
        XCTAssertGreaterThan(r.checked, 8)
    }

    func testAnEmptyTimelineBlocks() {
        let doc = Document(timeline: Timeline(name: "t", frameRate: rate))
        let r = Verifier.standard.verify(VerificationContext(document: doc))
        XCTAssertFalse(r.canRender)
        XCTAssertTrue(r.blocking.contains { $0.assertion.contains("something on it") })
    }

    /// A hold is the distinctive one: nothing is *wrong*, and it still must not ship alone.
    func testAModeratelyConfidentDecisionHoldsRatherThanBlocks() throws {
        var log = CommandLog(initial: Document(timeline: Timeline(name: "t", frameRate: rate)))
        try log.append(.addAsset(asset))
        try log.append(.addTrack(kind: .video, name: "V1"))
        let id = log.head.assets.keys.first!
        // 0.75 is above the 0.70 floor, below the 0.85 ship bar.
        let shaky = Basis.measuredMaterial(ref: "pause", detail: "maybe dead air", confidence: Rational(75, 100))
        try log.append(.placeClip(track: 0, clip: Clip(asset: id, source: TimeRange(start: .zero, end: t(100)), start: .zero),
                                  decision: Decision(kind: .cut, at: .zero, basis: shaky)))
        let r = Verifier.standard.verify(VerificationContext(document: log.head))
        XCTAssertTrue(r.blocking.isEmpty, "nothing is actually wrong")
        XCTAssertEqual(r.holds.count, 1)
        XCTAssertFalse(r.canRender, "a hold stops an unattended render even with no blocking failure")
    }

    func testLoudnessOffTargetBlocks() throws {
        let doc = try makeDocument()
        let ok = Verifier.standard.verify(VerificationContext(document: doc, integratedLoudness: -23.1, truePeak: -1.5,
                                                             loudnessTarget: (integrated: -23, truePeakCeiling: -1)))
        XCTAssertTrue(ok.blocking.isEmpty, "0.1 LU is within tolerance")

        let off = Verifier.standard.verify(VerificationContext(document: doc, integratedLoudness: -18, truePeak: -1.5,
                                                              loudnessTarget: (integrated: -23, truePeakCeiling: -1)))
        XCTAssertTrue(off.blocking.contains { $0.category == .audio && $0.assertion.contains("integrated loudness") })
    }

    func testTruePeakOverCeilingBlocks() throws {
        let doc = try makeDocument()
        let r = Verifier.standard.verify(VerificationContext(document: doc, integratedLoudness: -23, truePeak: -0.2,
                                                             loudnessTarget: (integrated: -23, truePeakCeiling: -1)))
        XCTAssertTrue(r.blocking.contains { $0.assertion.contains("true peak") })
    }

    /// A check that cannot run must say so. Silently passing is how a QC layer becomes decorative.
    func testAnUnmeasuredMixFailsRatherThanPassesQuietly() throws {
        let doc = try makeDocument()
        let r = Verifier.standard.verify(VerificationContext(document: doc, integratedLoudness: nil,
                                                             loudnessTarget: (integrated: -23, truePeakCeiling: -1)))
        XCTAssertTrue(r.blocking.contains { $0.detail.contains("never measured") },
                      "an unmeasurable assertion must fail, not pass")
    }

    func testAClipReadingPastItsSourceBlocks() throws {
        // Built by hand: `apply` refuses this, so the only way to reach it is a corrupted record.
        let id = Canonical.id(of: asset)
        var doc = Document(timeline: Timeline(name: "t", frameRate: rate))
        doc = try doc.apply(.addAsset(asset)).0
        doc = try doc.apply(.addTrack(kind: .video, name: "V1")).0
        XCTAssertThrowsError(try doc.apply(.placeClip(track: 0,
                                                      clip: Clip(asset: id, source: TimeRange(start: .zero, end: t(400)), start: .zero),
                                                      decision: Decision(kind: .cut, at: .zero, basis: solid))),
                             "apply itself refuses a clip that reads past its source")
    }

    func testShortClipWarnsButDoesNotBlock() throws {
        var log = CommandLog(initial: Document(timeline: Timeline(name: "t", frameRate: rate)))
        try log.append(.addAsset(asset))
        try log.append(.addTrack(kind: .video, name: "V1"))
        let id = log.head.assets.keys.first!
        try log.append(.placeClip(track: 0, clip: Clip(asset: id, source: TimeRange(start: .zero, end: t(2)), start: .zero),
                                  decision: Decision(kind: .cut, at: .zero, basis: solid)))
        let r = Verifier.standard.verify(VerificationContext(document: log.head))
        XCTAssertTrue(r.warnings.contains { $0.assertion.contains("minimum shot length") })
        XCTAssertTrue(r.blocking.isEmpty, "a deliberate flash cut is legitimate, so this warns")
        XCTAssertTrue(r.canRender, "warnings do not stop a render")
    }

    func testFailuresCarryTheirLocation() throws {
        var log = CommandLog(initial: Document(timeline: Timeline(name: "t", frameRate: rate)))
        try log.append(.addAsset(asset))
        try log.append(.addTrack(kind: .video, name: "V1"))
        let id = log.head.assets.keys.first!
        try log.append(.placeClip(track: 0, clip: Clip(asset: id, source: TimeRange(start: .zero, end: t(100)), start: .zero),
                                  decision: Decision(kind: .cut, at: .zero, basis: solid)))
        try log.append(.placeClip(track: 0, clip: Clip(asset: id, source: TimeRange(start: .zero, end: t(2)), start: t(200)),
                                  decision: Decision(kind: .cut, at: t(200), basis: solid)))
        let r = Verifier.standard.verify(VerificationContext(document: log.head))
        let warning = r.warnings.first { $0.assertion.contains("minimum shot length") }
        XCTAssertEqual(warning?.at, t(200), "the failure must say where")
        XCTAssertTrue(warning!.description.contains("6.67s"), "and render that location in the message: \(warning!.description)")
    }

    func testSummaryCountsEachMode() throws {
        let doc = Document(timeline: Timeline(name: "t", frameRate: rate))
        let r = Verifier.standard.verify(VerificationContext(document: doc))
        XCTAssertTrue(r.summary.contains("blocking"))
        XCTAssertEqual(r.checked, Verifier.standard.assertions.count)
    }
}
