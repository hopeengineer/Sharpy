// A guard against the seek-thrash bug, which cost 24x and was invisible on synthetic media.
//
// The synthetic test patterns this project was built against carry valid sample durations. Real
// phone footage does not: the user's 4K HEVC recording reports duration `value 0, timescale 0` on
// every sample, and AVFoundation reports its nominalFrameRate as 109.356 for a file that is exactly
// 30 fps. Together those made `frame(at:)` decide it could not step forward and rebuild an entire
// AVAssetReader per frame — 43 fps where raw decode measures 696.
//
// So this is a floor, not a benchmark. It fails only if sequential reading has fallen off the
// stepping path again, which is the one regression that matters here.

import XCTest
import Metal
import CoreVideo
@testable import SharpyEngine
@testable import SharpyRender

final class FrameSourceThroughputTests: XCTestCase {

    /// Well under what the machine does (600+ fps at 4K) and far above what seek-thrash produces
    /// (43 fps), so it separates the two without being a timing test in disguise.
    static let floor = 200.0

    func testSequentialReadingDoesNotFallBackToSeeking() throws {
        let candidates = ["/Desktop/20260904_014657.mp4", "/Desktop/reel-12-NOSFX.mp4"]
            .map { URL(fileURLWithPath: NSHomeDirectory() + $0) }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("no local footage to read")
        }
        let source = try SequentialFrameSource(url: url)
        let rate = source.nominalFrameRate
        // Warm: the first frame opens the reader, which is legitimately slow and not what is tested.
        _ = try source.frame(at: .zero)

        let frames = 200
        let started = Date()
        var got = 0
        for i in 0..<frames where try source.frame(at: TimeValue(frames: Int64(i), at: rate)) != nil {
            got += 1
        }
        let fps = Double(got) / Date().timeIntervalSince(started)
        XCTAssertGreaterThan(got, 0)
        XCTAssertGreaterThan(fps, Self.floor,
                             "\(Int(fps)) fps — sequential reads are seeking again, which rebuilds an AVAssetReader per frame")
    }

    /// The root cause, checked directly: a file whose samples carry no duration must still report
    /// its real cadence, taken from the gap between presentation times.
    func testFrameDurationComesFromObservedCadenceNotTheHeader() throws {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/20260904_014657.mp4")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("no 4K asset") }
        let source = try SequentialFrameSource(url: url)
        _ = try source.frame(at: .zero)
        guard let second = try source.frame(at: TimeValue(seconds: Rational(1, 10))) else {
            return XCTFail("could not read a second frame")
        }
        let seconds = second.duration.seconds.doubleValue
        // The file is 30 fps; nominalFrameRate claims 109.356. Anything near 1/109 means the
        // header was believed over the material.
        XCTAssertGreaterThan(seconds, 1.0 / 40, "duration \(seconds) looks like the bogus 109 fps header")
        XCTAssertLessThan(seconds, 1.0 / 20)
    }
}
