import XCTest
@testable import SharpyEngine

final class RationalTests: XCTestCase {
    func testReduction() {
        XCTAssertEqual(Rational(30000, 1001), Rational(60000, 2002))
        XCTAssertEqual(Rational(-2, -4), Rational(1, 2))
        XCTAssertEqual(Rational(2, -4), Rational(-1, 2))
        XCTAssertEqual(Rational(0, 5), .zero)
    }

    func testArithmeticIsExact() {
        let frame = FrameRate.ntsc30.frameDuration          // 1001/30000
        var t = Rational.zero
        for _ in 0..<30000 { t = t + frame }               // 30000 frames
        XCTAssertEqual(t, Rational(1001))                   // exactly 1001 s, no drift
        XCTAssertEqual(Rational(1, 3) + Rational(1, 6), Rational(1, 2))
        XCTAssertEqual(Rational(3, 4) * Rational(4, 3), .one)
        XCTAssertEqual(Rational(1, 2) / Rational(1, 4), Rational(2))
    }

    func testOrderingAndRounding() {
        XCTAssertTrue(Rational(1, 3) < Rational(1, 2))
        XCTAssertTrue(Rational(-1, 2) < Rational(0))
        XCTAssertEqual(Rational(7, 2).floor, 3)
        XCTAssertEqual(Rational(-7, 2).floor, -4)
        XCTAssertEqual(Rational(7, 2).ceil, 4)
        XCTAssertEqual(Rational(7, 2).rounded, 4)
        XCTAssertEqual(Rational(-7, 2).rounded, -4)
        XCTAssertEqual(Rational(5, 4).rounded, 1)
    }

    func testTwentyFourHoursAtNTSCDoesNotOverflow() {
        let frames: Int64 = 24 * 60 * 60 * 30       // nominal 24 h of 30 fps frame indices
        let t = TimeValue(frames: frames, at: .ntsc30)
        XCTAssertEqual(t.seconds, Rational(frames) * Rational(1001, 30000))
        XCTAssertEqual(t.frame(at: .ntsc30), frames)
    }

    func testCanonicalEncodingHasNoFloats() throws {
        let data = try Canonical.encoder.encode(TimeValue(frames: 7, at: .ntsc24))
        let s = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(s, #"{"seconds":{"den":24000,"num":7007}}"#)
    }
}

final class TimeValueTests: XCTestCase {
    func testFrameConversionRoundTrips() {
        for rate in [FrameRate.ntsc24, .film24, .pal25, .ntsc30, .r30, .ntsc60, .r60] {
            for f: Int64 in [0, 1, 2, 29, 30, 1799, 1800, 17981, 17982, 107892, 2_000_000] {
                let t = TimeValue(frames: f, at: rate)
                XCTAssertEqual(t.frame(at: rate), f, "\(rate) frame \(f)")
                XCTAssertTrue(t.isFrameAligned(at: rate))
            }
        }
    }

    func testMidFrameInstantsFloorToContainingFrame() {
        let half = TimeValue(seconds: FrameRate.r30.frameDuration * Rational(1, 2))  // 1/60 s
        XCTAssertEqual(half.frame(at: .r30), 0)
        XCTAssertEqual((half + TimeValue(frames: 1, at: .r30)).frame(at: .r30), 1)
        XCTAssertFalse(half.isFrameAligned(at: .r30))
        XCTAssertTrue(half.isFrameAligned(at: .r60))
    }

    func testRangeSemanticsAreHalfOpen() {
        let r = TimeRange(start: TimeValue(frames: 10, at: .r30), end: TimeValue(frames: 20, at: .r30))
        XCTAssertTrue(r.contains(TimeValue(frames: 10, at: .r30)))
        XCTAssertFalse(r.contains(TimeValue(frames: 20, at: .r30)))
        let adjacent = TimeRange(start: TimeValue(frames: 20, at: .r30), end: TimeValue(frames: 30, at: .r30))
        XCTAssertFalse(r.overlaps(adjacent))
        XCTAssertNil(r.intersection(adjacent))
        XCTAssertEqual(r.duration, TimeValue(frames: 10, at: .r30))
    }
}

final class TimecodeTests: XCTestCase {
    func testNonDropFrame() {
        XCTAssertEqual(Timecode(frameIndex: 0, rate: .r30).description, "00:00:00:00")
        XCTAssertEqual(Timecode(frameIndex: 29, rate: .r30).description, "00:00:00:29")
        XCTAssertEqual(Timecode(frameIndex: 30, rate: .r30).description, "00:00:01:00")
        XCTAssertEqual(Timecode(frameIndex: 24 * 3600 - 1, rate: .film24).description, "00:59:59:23")
        XCTAssertEqual(Timecode(frameIndex: 1800, rate: .ntsc30).description, "00:01:00:00")  // NDF does not skip
    }

    func testDropFrameSMPTEReferencePoints() {
        // SMPTE ST 12-1 invariants at 29.97 DF
        XCTAssertEqual(Timecode(frameIndex: 0, rate: .ntsc30DF).description, "00:00:00;00")
        XCTAssertEqual(Timecode(frameIndex: 1799, rate: .ntsc30DF).description, "00:00:59;29")
        XCTAssertEqual(Timecode(frameIndex: 1800, rate: .ntsc30DF).description, "00:01:00;02")
        XCTAssertEqual(Timecode(frameIndex: 17982, rate: .ntsc30DF).description, "00:10:00;00")
        XCTAssertEqual(Timecode(frameIndex: 107892, rate: .ntsc30DF).description, "01:00:00;00")
        // 59.94 DF drops 4 per minute
        XCTAssertEqual(Timecode(frameIndex: 3600, rate: .ntsc60DF).description, "00:01:00;04")
        XCTAssertEqual(Timecode(frameIndex: 35964, rate: .ntsc60DF).description, "00:10:00;00")
    }

    func testDropFrameRoundTripsEveryFrameOfAnHour() {
        for f: Int64 in stride(from: 0, through: 107892, by: 1) {
            let tc = Timecode(frameIndex: f, rate: .ntsc30DF)
            XCTAssertEqual(tc.frameIndex, f, "round trip failed at frame \(f) → \(tc)")
        }
    }

    func testDropFrameWallClockTracksRealTime() {
        // After exactly one hour of 29.97 frames (107892 frames), real elapsed time is
        // 107892 * 1001/30000 s = 3599.9964 s — within one frame of 3600 s. NDF would read 00:59:56:12.
        let t = TimeValue(frames: 107892, at: .ntsc30)
        XCTAssertTrue(t.seconds < Rational(3600))
        XCTAssertTrue(Rational(3600) - t.seconds < FrameRate.ntsc30.frameDuration)
    }

    func testParsingRejectsDroppedFrameNumbers() {
        XCTAssertNotNil(Timecode(string: "00:01:00;02", rate: .ntsc30DF))
        XCTAssertNil(Timecode(string: "00:01:00;00", rate: .ntsc30DF))      // frame 0 at 00:01:00 does not exist in DF
        XCTAssertNil(Timecode(string: "00:01:00;01", rate: .ntsc30DF))
        XCTAssertNotNil(Timecode(string: "00:10:00;00", rate: .ntsc30DF))   // 10th minute keeps 0 and 1
        XCTAssertNil(Timecode(string: "00:00:00:30", rate: .r30))
        XCTAssertEqual(Timecode(string: "01:02:03:04", rate: .pal25)?.frameIndex, ((3600 + 120 + 3) * 25) + 4)
    }
}
