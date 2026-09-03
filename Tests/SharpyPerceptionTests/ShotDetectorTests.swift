// Shot detection, against footage whose cuts are known by construction.
//
// The thing worth testing is not "does it find edges" but the two decisions that make it usable:
// the threshold adapts to the material rather than being a constant, and sub-minimum "shots" are
// folded away so a flash or a compression artefact never becomes an edit point.

import XCTest
import AVFoundation
@testable import SharpyEngine
@testable import SharpyPerception

final class ShotDetectorTests: XCTestCase {
    static let w = 320, h = 180
    static let fps: Int64 = 30

    /// A movie of solid colours: one per entry in `sections`, each lasting its given seconds.
    /// Cuts fall exactly on the section boundaries.
    static func makeCutMovie(_ sections: [(r: UInt8, g: UInt8, b: UInt8, seconds: Double)]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sharpy-shots-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422HQ, AVVideoWidthKey: w, AVVideoHeightKey: h])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)

        var plan: [(UInt8, UInt8, UInt8)] = []
        for s in sections {
            for _ in 0..<Int(s.seconds * Double(fps)) { plan.append((s.r, s.g, s.b)) }
        }
        let group = DispatchGroup(); group.enter()
        var next = 0
        input.requestMediaDataWhenReady(on: DispatchQueue(label: "shots.fixture")) {
            while input.isReadyForMoreMediaData {
                guard next < plan.count else { input.markAsFinished(); group.leave(); return }
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
                let buf = pb!
                CVPixelBufferLockBaseAddress(buf, [])
                let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRow(buf)
                let c = plan[next]
                // A little per-frame noise so a static shot is not perfectly identical — real
                // footage never is, and a detector that only works on identical frames is a toy.
                for y in 0..<h { for x in 0..<w {
                    let p = base + y * stride + x * 4
                    let jitter = Int8(truncatingIfNeeded: (x &+ y &+ next) % 3)
                    p[0] = UInt8(clamping: Int(c.2) + Int(jitter))
                    p[1] = UInt8(clamping: Int(c.1) + Int(jitter))
                    p[2] = UInt8(clamping: Int(c.0) + Int(jitter))
                    p[3] = 255
                } }
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

    func testFindsCutsWhereTheyWereMade() throws {
        let url = try Self.makeCutMovie([
            (220, 40, 40, 2.0),      // red   0–2
            (40, 200, 60, 1.5),      // green 2–3.5
            (50, 60, 220, 2.0),      // blue  3.5–5.5
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let idx = try ShotDetector().detect(url: url, asset: NodeID(contentOf: "a"))
        XCTAssertEqual(idx.shots.count, 3, "three colours, two cuts")
        XCTAssertEqual(idx.shots[0].range.start.seconds.doubleValue, 0, accuracy: 0.05)
        XCTAssertEqual(idx.shots[1].range.start.seconds.doubleValue, 2.0, accuracy: 0.1)
        XCTAssertEqual(idx.shots[2].range.start.seconds.doubleValue, 3.5, accuracy: 0.1)
        XCTAssertEqual(idx.medianDuration.seconds.doubleValue, 2.0, accuracy: 0.15)
        // Shot indices are consecutive and cover the piece without gaps.
        for (i, s) in idx.shots.enumerated() { XCTAssertEqual(s.index, i) }
        for (a, b) in zip(idx.shots, idx.shots.dropFirst()) { XCTAssertEqual(a.range.end, b.range.start) }
    }

    func testStaticFootageIsOneShot() throws {
        let url = try Self.makeCutMovie([(120, 120, 120, 4.0)])
        defer { try? FileManager.default.removeItem(at: url) }
        let idx = try ShotDetector().detect(url: url, asset: NodeID(contentOf: "a"))
        XCTAssertEqual(idx.shots.count, 1, "no cuts means one shot, not noise-driven fragments")
        XCTAssertEqual(idx.shots[0].duration.seconds.doubleValue, 4.0, accuracy: 0.15)
    }

    /// The fold-away rule: a one-frame flash is not an edit.
    func testShotsBelowTheMinimumAreFoldedAway() throws {
        let url = try Self.makeCutMovie([
            (200, 30, 30, 2.0),
            (255, 255, 255, 0.066),   // two-frame flash
            (200, 30, 30, 2.0),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let idx = try ShotDetector(options: ShotDetectorOptions(minimumShotDuration: TimeValue(seconds: Rational(5, 10))))
            .detect(url: url, asset: NodeID(contentOf: "a"))
        XCTAssertLessThanOrEqual(idx.shots.count, 2, "a 2-frame flash must not create its own shot; got \(idx.shots.count)")
        for s in idx.shots {
            XCTAssertGreaterThan(s.duration.seconds.doubleValue, 0.4, "no shot should survive below the minimum")
        }
    }

    func testThresholdIsDerivedFromTheMaterial() throws {
        let url = try Self.makeCutMovie([(200, 30, 30, 1.5), (30, 30, 200, 1.5)])
        defer { try? FileManager.default.removeItem(at: url) }
        let idx = try ShotDetector().detect(url: url, asset: NodeID(contentOf: "a"))
        XCTAssertGreaterThan(idx.threshold, 0, "a threshold must have been computed")
        XCTAssertGreaterThanOrEqual(idx.threshold, idx.medianScore, "it sits above the material's own median")
    }

    func testShotLookupByTime() throws {
        let url = try Self.makeCutMovie([(200, 30, 30, 1.5), (30, 200, 30, 1.5)])
        defer { try? FileManager.default.removeItem(at: url) }
        let idx = try ShotDetector().detect(url: url, asset: NodeID(contentOf: "a"))
        XCTAssertEqual(idx.shot(at: TimeValue(seconds: Rational(5, 10)))?.index, 0)
        XCTAssertEqual(idx.shot(at: TimeValue(seconds: Rational(20, 10)))?.index, idx.shots.count - 1)
    }
}
