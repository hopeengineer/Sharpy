// Reframing must not cut off the head. Most of these are about the ways a crop goes wrong.

import XCTest
@testable import SharpyEngine
@testable import SharpyPerception

final class ReframeTests: XCTestCase {

    func testKeepingTheSameShapeCropsNothing() {
        let r = Reframer.plan(sourceWidth: 1080, sourceHeight: 1920,
                              targetAspect: 1080.0 / 1920.0, subject: nil)
        XCTAssertEqual(r.cropLeft + r.cropRight + r.cropTop + r.cropBottom, 0, accuracy: 0.001)
    }

    /// Vertical to square trims height, and the trim follows the face.
    func testASquareCropFollowsTheSubjectVertically() {
        let high = Reframer.plan(sourceWidth: 1080, sourceHeight: 1920, targetAspect: 1,
                                 subject: (x: 0.5, y: 0.25))
        let low = Reframer.plan(sourceWidth: 1080, sourceHeight: 1920, targetAspect: 1,
                                subject: (x: 0.5, y: 0.75))
        XCTAssertLessThan(high.cropTop, low.cropTop, "a subject high in frame keeps more of the top")
        XCTAssertEqual(high.width, high.height, "square")
    }

    /// Landscape to vertical trims width around the speaker — the interview-to-reel case.
    func testAVerticalCropFollowsTheSubjectHorizontally() {
        let left = Reframer.plan(sourceWidth: 3840, sourceHeight: 2160,
                                 targetAspect: 9.0 / 16.0, subject: (x: 0.2, y: 0.5))
        // The window is centred ON the subject, so a face at 20% starts the crop at 4.2%, not 0.
        // Nearly all of the trimming comes off the far side.
        XCTAssertLessThan(left.cropLeft, 0.1, "very little comes off the side the subject is on")
        XCTAssertGreaterThan(left.cropRight, 0.5)
        let right = Reframer.plan(sourceWidth: 3840, sourceHeight: 2160,
                                  targetAspect: 9.0 / 16.0, subject: (x: 0.8, y: 0.5))
        XCTAssertGreaterThan(right.cropLeft, left.cropLeft,
                             "a subject on the right keeps the right, not the left")
    }

    /// A crop centred on a subject at the very edge would run off the frame and show black. It has
    /// to slide back inside, even though that leaves the subject off-centre.
    func testACropNeverRunsOffTheEdge() {
        for x in [0.0, 0.02, 0.98, 1.0] {
            let r = Reframer.plan(sourceWidth: 3840, sourceHeight: 2160,
                                  targetAspect: 9.0 / 16.0, subject: (x: x, y: 0.5))
            XCTAssertGreaterThanOrEqual(r.cropLeft, 0, "x=\(x)")
            XCTAssertGreaterThanOrEqual(r.cropRight, 0, "x=\(x)")
            XCTAssertLessThanOrEqual(r.cropLeft + r.cropRight, 1.0001, "x=\(x)")
        }
    }

    /// Without a subject the crop centres — the only honest fallback.
    func testNoSubjectCentresTheCrop() {
        let r = Reframer.plan(sourceWidth: 3840, sourceHeight: 2160,
                              targetAspect: 1, subject: nil)
        XCTAssertEqual(r.cropLeft, r.cropRight, accuracy: 0.001)
    }

    /// h264 and hevc both refuse odd dimensions, with an error that says nothing about aspect.
    func testDimensionsAreAlwaysEven() {
        for aspect in [9.0/16.0, 1.0, 16.0/9.0, 4.0/5.0] {
            let r = Reframer.plan(sourceWidth: 1081, sourceHeight: 1921, targetAspect: aspect, subject: nil)
            XCTAssertEqual(r.width % 2, 0, "\(aspect)")
            XCTAssertEqual(r.height % 2, 0, "\(aspect)")
        }
    }

    func testAspectParsing() {
        XCTAssertEqual(Reframer.parse("9:16")!, 0.5625, accuracy: 0.0001)
        XCTAssertEqual(Reframer.parse("16:9")!, 1.7778, accuracy: 0.0001)
        XCTAssertEqual(Reframer.parse("1:1")!, 1.0, accuracy: 0.0001)
        XCTAssertNil(Reframer.parse("original"))
        XCTAssertNil(Reframer.parse("nonsense"))
    }

    /// The median, not the mean: one frame with a face in the background would drag a mean off the
    /// speaker and leave the crop slightly wrong for the whole video.
    func testSubjectPositionUsesTheMedianAndTheLargestFace() {
        func frame(_ t: Double, faces: [DetectedBox]) -> FrameObservation {
            FrameObservation(time: TimeValue(seconds: Rational(Int64(t * 100), 100)),
                             faces: faces, hands: [], text: [])
        }
        let speaker = DetectedBox(x: 400, y: 400, width: 200, height: 200, confidence: 0.9)
        let bystander = DetectedBox(x: 900, y: 100, width: 40, height: 40, confidence: 0.9)
        let index = VisionIndex(asset: NodeID(contentOf: "a"),
                                frames: [frame(0, faces: [speaker, bystander]),
                                         frame(1, faces: [speaker]),
                                         frame(2, faces: [speaker, bystander])],
                                width: 1000, height: 1000)
        let subject = Reframer.subject(in: index)
        XCTAssertNotNil(subject)
        XCTAssertEqual(subject!.x, 0.5, accuracy: 0.01, "the speaker, not the bystander")
    }
}
