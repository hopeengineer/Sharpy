// The spatial tier, end to end: a real render, real placement, real identity readback.
//
// The unit-level proof is in IDPassTests. This is the one that matters, because it exercises the
// path a delivery actually takes — document -> placement -> compositor -> ID pass -> finding.

import XCTest
import AVFoundation
@testable import SharpyEngine
@testable import SharpyRender

final class SpatialGuardTests: XCTestCase {
    static let rate = FrameRate.r30
    static let w = 640, h = 360
    static let frames: Int64 = 12
    nonisolated(unsafe) static var clipURL: URL!

    override class func setUp() {
        super.setUp()
        clipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharpy-spatial-\(UUID().uuidString).mov")
        try! RenderTests.synthesise(to: clipURL, frames: frames, clip: 200)
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: clipURL)
        super.tearDown()
    }

    /// A fixed region, standing in for a subject track. Fixed on purpose: the point of this test is
    /// the render path, and a moving box would make a failure ambiguous between the two.
    struct FixedRegions: SpatialSubjectSource {
        let regions: [ProtectedRegion]
        func protectedRegions(at time: TimeValue) -> [ProtectedRegion] { regions }
    }

    func document(placement: ClipPlacement?) throws -> Document {
        var log = CommandLog(initial: Document(timeline: Timeline(name: "t", frameRate: Self.rate)))
        let asset = AssetRef(contentHash: "synth", path: Self.clipURL.path,
                             duration: TimeValue(frames: Self.frames, at: Self.rate),
                             frameRate: Self.rate, hasVideo: true, hasAudio: false)
        try log.append(.addAsset(asset))
        try log.append(.addTrack(kind: .video, name: "V1"))
        try log.append(.addTrack(kind: .video, name: "V2"))
        let id = log.head.assets.keys.first!
        func t(_ f: Int64) -> TimeValue { TimeValue(frames: f, at: Self.rate) }
        let basis = Basis.measuredMaterial(ref: "test", detail: "synthetic", confidence: .one)
        let decision = Decision(kind: .cut, at: t(0), basis: basis)
        let range = TimeRange(start: t(0), end: t(Self.frames))
        try log.append(.placeClip(track: 0, clip: Clip(asset: id, source: range, start: t(0)),
                                  decision: decision))
        try log.append(.placeClip(track: 1,
                                  clip: Clip(asset: id, source: range, start: t(0), placement: placement),
                                  decision: decision))
        return log.head
    }

    func render(_ doc: Document, guardian: SpatialGuard?) throws -> RenderReport {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharpy-spatial-out-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: out) }
        let session = try RenderSession(document: doc, options: RenderOptions(
            width: Self.w, height: Self.h, codec: .proRes422HQ, includeAudio: false,
            skipVerification: true, spatialGuard: guardian))
        return try session.render(to: out)
    }

    /// The whole point: an overlay whose edge runs through a face is caught on every frame.
    func testAnOverlayEdgeThroughTheSubjectIsCaughtEveryFrame() throws {
        // Right-hand half of the frame, full height.
        let doc = try document(placement: ClipPlacement(x: Rational(1, 2), y: .zero, width: Rational(1, 2)))
        // A "face" straddling x=320, so the overlay's left edge runs through it.
        let face = ProtectedRegion(name: "face", rect: PixelRect(x: 260, y: 100, width: 120, height: 120))
        let report = try render(doc, guardian: SpatialGuard(source: FixedRegions(regions: [face])))

        XCTAssertEqual(report.spatial.framesChecked, Int(Self.frames))
        XCTAssertFalse(report.spatial.isClean, "an edge through the subject must be reported")
        XCTAssertEqual(report.spatial.affectedFrames, Int(Self.frames),
                       "the overlay is static, so every frame is affected — sampling could have missed none of them, and that is the claim")
        XCTAssertTrue(report.spatial.summary.contains("HOLD"))
        let first = try XCTUnwrap(report.spatial.findings.first)
        XCTAssertEqual(first.layer, 1, "layer 0 is the base picture and cannot cut through a subject")
        XCTAssertGreaterThan(first.coverage, 0.2)
        XCTAssertLessThan(first.coverage, 0.8)
    }

    /// An overlay nowhere near the subject is not a fault, and must not be reported as one.
    func testAnOverlayClearOfTheSubjectIsClean() throws {
        let doc = try document(placement: ClipPlacement(x: Rational(1, 2), y: .zero, width: Rational(1, 2)))
        let face = ProtectedRegion(name: "face", rect: PixelRect(x: 40, y: 100, width: 120, height: 120))
        let report = try render(doc, guardian: SpatialGuard(source: FixedRegions(regions: [face])))
        XCTAssertTrue(report.spatial.isClean)
        XCTAssertEqual(report.spatial.framesChecked, Int(Self.frames))
        XCTAssertTrue(report.spatial.summary.contains("clean"))
    }

    /// "Did not run" and "ran and found nothing" are different claims and must read differently.
    func testNotRunningIsDistinguishedFromRunningClean() throws {
        let doc = try document(placement: nil)
        let report = try render(doc, guardian: nil)
        XCTAssertEqual(report.spatial.framesChecked, 0)
        XCTAssertTrue(report.spatial.isClean, "no findings…")
        XCTAssertTrue(report.spatial.summary.contains("not run"), "…but it must not read as a pass")
    }

    /// Placement is stated in fractions of the output, so the same document delivers correctly at
    /// another resolution. If this drifts, a picture-in-picture authored at 1080p lands wrong on a
    /// 4K master — the kind of fault nobody sees until delivery.
    func testPlacementIsResolutionIndependent() throws {
        let doc = try document(placement: ClipPlacement(x: Rational(1, 2), y: .zero, width: Rational(1, 2)))
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharpy-spatial-4x-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: out) }
        // Same document, double the output size; the face doubles with it.
        let face = ProtectedRegion(name: "face", rect: PixelRect(x: 520, y: 200, width: 240, height: 240))
        let session = try RenderSession(document: doc, options: RenderOptions(
            width: Self.w * 2, height: Self.h * 2, codec: .proRes422HQ, includeAudio: false,
            skipVerification: true,
            spatialGuard: SpatialGuard(source: FixedRegions(regions: [face]))))
        let report = try session.render(to: out)
        XCTAssertFalse(report.spatial.isClean,
                       "the same placement must still cross the same relative region at 2x")
    }

    /// A ripple delete moves a clip in time. It must not silently move it in space.
    func testRippleDeletePreservesPlacement() throws {
        let placement = ClipPlacement(x: Rational(1, 2), y: .zero, width: Rational(1, 2))
        var log = CommandLog(initial: try document(placement: placement))
        func t(_ f: Int64) -> TimeValue { TimeValue(frames: f, at: Self.rate) }
        let basis = Basis.measuredMaterial(ref: "test", detail: "synthetic", confidence: .one)
        try log.append(.rippleDelete(track: 1, range: TimeRange(start: t(2), end: t(4)),
                                     decision: Decision(kind: .cut, at: t(2), basis: basis)))
        for clip in log.head.timeline.tracks[1].clips {
            XCTAssertEqual(clip.placement, placement,
                           "a cut in time reset where the clip sits in the frame")
        }
    }

    /// Track order is a correctness question, not a detail: an editor stacking a lower third on V2
    /// expects to see it. Before this was pinned, resolveVideo reversed the tracks and V1 rendered
    /// on top, so the lower third would have vanished behind the picture with nothing to explain it.
    func testHigherTracksRenderOnTop() throws {
        let doc = try document(placement: ClipPlacement(x: Rational(1, 2), y: .zero, width: Rational(1, 2)))
        let layers = doc.resolveVideo(at: TimeValue(frames: 0, at: Self.rate))
        XCTAssertEqual(layers.map(\.trackIndex), [0, 1],
                       "bottom first: V1 then V2, so V2 composites over V1")
        XCTAssertNil(layers.first?.clip.placement, "V1 is the full-frame base")
        XCTAssertNotNil(layers.last?.clip.placement, "V2 is the placed overlay, and it is on top")
    }
}
