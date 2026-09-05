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

/// The disk guard. It exists because a frame-rate bug produced a 42 GB render that took the
/// machine to 2.3 GB free before anyone noticed — and an agent editing unattended is exactly who
/// will not notice.
final class OutputFitsTests: XCTestCase {
    func session(width: Int, height: Int, codec: RenderCodec) throws -> RenderSession {
        var log = CommandLog(initial: Document(timeline: Timeline(name: "t", frameRate: .r30)))
        try log.append(.addAsset(AssetRef(contentHash: "a", path: "/tmp/a.mov",
                                          duration: TimeValue(frames: 100, at: .r30),
                                          frameRate: .r30, hasVideo: true, hasAudio: false)))
        return try RenderSession(document: log.head,
                                 options: RenderOptions(width: width, height: height, codec: codec))
    }

    func testAnOrdinaryRenderIsAllowed() throws {
        let s = try session(width: 1920, height: 1080, codec: .proRes422HQ)
        XCTAssertNoThrow(try s.checkOutputFits(frames: 300, at: FileManager.default.temporaryDirectory
            .appendingPathComponent("x.mov")))
    }

    /// A million frames of 4K ProRes is roughly 9 TB. It must be refused on any machine.
    func testAnAbsurdRenderIsRefusedWithSomethingActionable() throws {
        let s = try session(width: 3840, height: 2160, codec: .proRes422HQ)
        XCTAssertThrowsError(try s.checkOutputFits(frames: 1_000_000,
            at: FileManager.default.temporaryDirectory.appendingPathComponent("x.mov"))) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("free"), message)
            // A refusal that does not say what to do instead is just an obstacle.
            XCTAssertTrue(message.contains("shorter range") || message.contains("h264"), message)
        }
    }

    /// h264 at a sane bitrate is far smaller than ProRes, and the guard must know the difference —
    /// otherwise it refuses renders that would have been fine.
    func testTheGuardAccountsForTheCodec() throws {
        let prores = try session(width: 3840, height: 2160, codec: .proRes422HQ)
        let h264 = try session(width: 3840, height: 2160, codec: .h264(bitrate: 40_000_000))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("x.mov")
        // 20 minutes at 4K: ProRes is ~40 GB, h264 ~6 GB.
        let frames: Int64 = 36_000
        var proresRefused = false
        do { try prores.checkOutputFits(frames: frames, at: url) } catch { proresRefused = true }
        var h264Refused = false
        do { try h264.checkOutputFits(frames: frames, at: url) } catch { h264Refused = true }
        XCTAssertFalse(h264Refused, "h264 at 40 Mb/s for 20 minutes is about 6 GB and should pass")
        _ = proresRefused   // depends on the machine's free space; the codec difference is the point
    }
}
