// The adapter that closes M3's gate. If it is wrong, every spatial assertion is checked against
// the wrong rectangle and reports "clean" for the wrong reason.

import XCTest
@testable import SharpyEngine
@testable import SharpyPerception
@testable import SharpyRender

final class VisionSubjectSourceTests: XCTestCase {
    func s(_ x: Double) -> TimeValue { TimeValue(seconds: Rational(Int64(x * 100), 100)) }

    func index(_ observations: [(Double, [DetectedBox])], w: Int = 100, h: Int = 100) -> VisionIndex {
        VisionIndex(asset: NodeID(contentOf: "a"),
                    frames: observations.map { FrameObservation(time: s($0.0), faces: $0.1, hands: [], text: []) },
                    width: w, height: h)
    }

    let face = DetectedBox(x: 40, y: 40, width: 20, height: 20, confidence: 0.9)

    /// Vision analysed at one resolution and the master is delivered at another. Getting this
    /// wrong protects the wrong quarter of the frame and reports clean.
    func testBoxesScaleToTheDeliveryResolution() {
        let source = VisionSubjectSource(index: index([(0, [face])]),
                                         outputWidth: 400, outputHeight: 400, margin: 0)
        let region = source.protectedRegions(at: s(0)).first
        XCTAssertEqual(region?.rect, PixelRect(x: 160, y: 160, width: 80, height: 80),
                       "a 100px analysis onto a 400px master is 4x in both axes")
    }

    /// The margin exists because stopping one pixel from an eyebrow is not a pass.
    func testTheMarginGrowsTheBox() {
        let source = VisionSubjectSource(index: index([(0, [face])]),
                                         outputWidth: 100, outputHeight: 100, margin: 0.5)
        let region = source.protectedRegions(at: s(0)).first
        XCTAssertEqual(region?.rect, PixelRect(x: 30, y: 30, width: 40, height: 40))
    }

    /// A stale observation must produce NO region rather than a wrong one. A subject that has moved
    /// would otherwise generate findings about where it used to be — and, worse, miss where it is.
    func testAStaleObservationIsNotUsed() {
        let source = VisionSubjectSource(index: index([(0, [face])]),
                                         outputWidth: 100, outputHeight: 100,
                                         maximumStaleness: s(0.5))
        XCTAssertEqual(source.protectedRegions(at: s(0.4)).count, 1, "within tolerance")
        XCTAssertTrue(source.protectedRegions(at: s(5)).isEmpty,
                      "five seconds later that box says nothing about this frame")
    }

    func testTextRegionsAreNamedByWhatTheySay() {
        let line = TextLine(text: "Subscribe for more", box: DetectedBox(x: 0, y: 80, width: 100, height: 15, confidence: 0.9))
        let vision = VisionIndex(asset: NodeID(contentOf: "a"),
                                 frames: [FrameObservation(time: s(0), faces: [], hands: [], text: [line])],
                                 width: 100, height: 100)
        let source = VisionSubjectSource(index: vision, outputWidth: 100, outputHeight: 100, margin: 0)
        let region = source.protectedRegions(at: s(0)).first
        XCTAssertEqual(region?.name, "text \"Subscribe for more\"",
                       "a finding must read as a sentence, not a rectangle")
    }

    func testFacesAndTextCanBeProtectedSeparately() {
        let line = TextLine(text: "caption", box: DetectedBox(x: 0, y: 80, width: 100, height: 15, confidence: 0.9))
        let vision = VisionIndex(asset: NodeID(contentOf: "a"),
                                 frames: [FrameObservation(time: s(0), faces: [face], hands: [], text: [line])],
                                 width: 100, height: 100)
        let facesOnly = VisionSubjectSource(index: vision, outputWidth: 100, outputHeight: 100,
                                           protectsText: false)
        XCTAssertEqual(facesOnly.protectedRegions(at: s(0)).count, 1)
        let both = VisionSubjectSource(index: vision, outputWidth: 100, outputHeight: 100)
        XCTAssertEqual(both.protectedRegions(at: s(0)).count, 2)
    }
}
