// Vision indexing, against frames whose content is known by construction.
//
// The accuracy of the underlying detectors was established separately on 22 hand-labelled frames
// of the user's real reel: face count 22/22, hands 21/21, on-screen text 89/90 lines. These tests
// cover what that measurement could not — the parts that are *our* code rather than Apple's:
// the coordinate flip, the sampling rate, and the range coalescing.

import XCTest
import AVFoundation
import CoreImage
@testable import SharpyEngine
@testable import SharpyPerception

final class VisionIndexerTests: XCTestCase {
    static let w = 640, h = 480
    static let fps: Int64 = 30

    /// A movie where a black rectangle of known position carries known text in its upper-left
    /// quadrant, for `seconds`. Text is drawn large so OCR is not the thing under test.
    static func makeTextMovie(seconds: Double, text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sharpy-vis-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422HQ, AVVideoWidthKey: w, AVVideoHeightKey: h])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)

        // Render the text once with Core Graphics into a reusable buffer.
        let total = Int(seconds * Double(fps))
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        // CoreGraphics has a bottom-left origin, so "upper" here means a high y.
        ctx.textMatrix = .identity
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 56, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1)])
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = CGPoint(x: 40, y: Double(h) - 120)      // upper-left in image terms
        CTLineDraw(line, ctx)
        let image = ctx.makeImage()!

        let group = DispatchGroup(); group.enter()
        var next = 0
        input.requestMediaDataWhenReady(on: DispatchQueue(label: "vis.fixture")) {
            while input.isReadyForMoreMediaData {
                guard next < total else { input.markAsFinished(); group.leave(); return }
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
                let buf = pb!
                CVPixelBufferLockBaseAddress(buf, [])
                let dst = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: w, height: h,
                                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                dst.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                CVPixelBufferUnlockBaseAddress(buf, [])
                _ = adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(next), timescale: CMTimeScale(fps)))
                next += 1
            }
        }
        group.wait()
        let done = DispatchSemaphore(value: 0); writer.finishWriting { done.signal() }; done.wait()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }

    func testSamplingRateControlsHowManyFramesAreExamined() throws {
        let url = try Self.makeTextMovie(seconds: 4, text: "SHARPY")
        defer { try? FileManager.default.removeItem(at: url) }
        let one = try VisionIndexer(options: VisionIndexOptions(samplesPerSecond: 1, detectText: false, detectHands: false))
            .index(url: url, asset: NodeID(contentOf: "a"))
        let two = try VisionIndexer(options: VisionIndexOptions(samplesPerSecond: 2, detectText: false, detectHands: false))
            .index(url: url, asset: NodeID(contentOf: "a"))
        XCTAssertEqual(one.frames.count, 4, "4 s at 1 fps")
        XCTAssertEqual(two.frames.count, 8, "4 s at 2 fps")
        XCTAssertEqual(one.width, Self.w); XCTAssertEqual(one.height, Self.h)
        // Sample times are spaced by the requested interval.
        for (a, b) in zip(one.frames, one.frames.dropFirst()) {
            XCTAssertEqual((b.time - a.time).seconds.doubleValue, 1.0, accuracy: 0.05)
        }
    }

    /// The flip is our code, and getting it wrong puts every box in the wrong half of the frame —
    /// which would silently break every safe-area and subject-collision check downstream.
    func testTextBoxesUseTopLeftOriginPixels() throws {
        let url = try Self.makeTextMovie(seconds: 2, text: "SHARPY")
        defer { try? FileManager.default.removeItem(at: url) }
        let idx = try VisionIndexer(options: VisionIndexOptions(samplesPerSecond: 1, detectFaces: false, detectHands: false))
            .index(url: url, asset: NodeID(contentOf: "a"))
        let found = idx.frames.flatMap(\.text)
        XCTAssertFalse(found.isEmpty, "the fixture draws large text; Vision should read something")
        XCTAssertTrue(idx.allText.contains { $0.uppercased().contains("SHARPY") },
                      "expected to read SHARPY, got \(idx.allText)")
        let box = found.first { $0.text.uppercased().contains("SHARPY") }!.box
        // Drawn near the top-left: in top-left pixel coordinates that means small x and small y.
        XCTAssertLessThan(box.y, Double(Self.h) / 2, "text drawn in the upper half must have a small y")
        XCTAssertLessThan(box.x, Double(Self.w) / 2, "…and a small x")
        XCTAssertGreaterThan(box.width, 0); XCTAssertGreaterThan(box.height, 0)
        XCTAssertLessThanOrEqual(box.maxX, Double(Self.w) + 1)
        XCTAssertLessThanOrEqual(box.maxY, Double(Self.h) + 1)
    }

    func testBoxIntersectionIsTheGeometryDownstreamChecksNeed() {
        let a = DetectedBox(x: 10, y: 10, width: 100, height: 100, confidence: 1)
        let b = DetectedBox(x: 50, y: 50, width: 100, height: 100, confidence: 1)
        let c = DetectedBox(x: 200, y: 200, width: 10, height: 10, confidence: 1)
        XCTAssertTrue(a.intersects(b)); XCTAssertTrue(b.intersects(a))
        XCTAssertFalse(a.intersects(c))
        // Touching edges do not intersect — half-open, matching TimeRange.
        let touching = DetectedBox(x: 110, y: 10, width: 10, height: 10, confidence: 1)
        XCTAssertFalse(a.intersects(touching))
    }

    func testPersonVisibleRangesCoalesceAcrossTheSamplingInterval() {
        let f = { (t: Double, faces: Int) in
            FrameObservation(time: TimeValue(seconds: Rational(Int64(t * 100), 100)),
                             faces: (0..<faces).map { _ in DetectedBox(x: 0, y: 0, width: 10, height: 10, confidence: 1) },
                             hands: [], text: [])
        }
        let idx = VisionIndex(asset: NodeID(contentOf: "a"),
                              frames: [f(0, 1), f(1, 1), f(2, 0), f(3, 1), f(4, 1)],
                              width: 100, height: 100)
        let ranges = idx.personVisibleRanges(tolerance: TimeValue(seconds: Rational(1)))
        XCTAssertEqual(ranges.count, 2, "the gap at t=2 splits the run")
        XCTAssertEqual(ranges[0].start.seconds.doubleValue, 0); XCTAssertEqual(ranges[0].end.seconds.doubleValue, 2)
        XCTAssertEqual(ranges[1].start.seconds.doubleValue, 3); XCTAssertEqual(ranges[1].end.seconds.doubleValue, 5)
    }

    func testObservationLookupPicksTheNearestSample() {
        let f = { (t: Double) in FrameObservation(time: TimeValue(seconds: Rational(Int64(t * 100), 100)), faces: [], hands: [], text: []) }
        let idx = VisionIndex(asset: NodeID(contentOf: "a"), frames: [f(0), f(1), f(2)], width: 10, height: 10)
        XCTAssertEqual(idx.observation(at: TimeValue(seconds: Rational(140, 100)))?.time.seconds.doubleValue, 1)
        XCTAssertEqual(idx.observation(at: TimeValue(seconds: Rational(160, 100)))?.time.seconds.doubleValue, 2)
    }
}
