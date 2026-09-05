// If this cannot tell a real cut from no cut at all, it measures nothing and every candidate
// assembly it ranks is noise.

import XCTest
import Accelerate
@testable import SharpyEngine
@testable import SharpyRender

final class JoinQualityTests: XCTestCase {

    /// A steady tone at `hz`, at a given amplitude.
    func tone(_ hz: Double, seconds: Double, amplitude: Float = 0.3, sampleRate: Int = 48_000) -> [Float] {
        let n = Int(Double(sampleRate) * seconds)
        return (0..<n).map { amplitude * sinf(Float(2 * Double.pi * hz * Double($0) / Double(sampleRate))) }
    }

    func testPitchIsMeasuredAccurately() {
        for hz in [90.0, 140.0, 220.0] {
            let measured = JoinQuality.pitch(tone(hz, seconds: 0.12), sampleRate: 48_000)
            XCTAssertNotNil(measured, "\(hz) Hz should read as voiced")
            XCTAssertEqual(measured!, hz, accuracy: hz * 0.05, "within 5% at \(hz) Hz")
        }
    }

    /// Noise and silence have no pitch, and saying so is right: a join on a consonant or a breath
    /// has nothing to mismatch, which makes it a GOOD place to cut.
    func testUnvoicedAudioReportsNoPitch() {
        let noise = (0..<6000).map { _ in Float.random(in: -0.2...0.2) }
        XCTAssertNil(JoinQuality.pitch(noise, sampleRate: 48_000))
        XCTAssertNil(JoinQuality.pitch([Float](repeating: 0, count: 6000), sampleRate: 48_000))
    }

    func testLevelIsMeasuredInDecibels() {
        let loud = tone(120, seconds: 0.1, amplitude: 0.5)
        let quiet = tone(120, seconds: 0.1, amplitude: 0.25)
        // Half the amplitude is 6 dB down.
        XCTAssertEqual(JoinQuality.rmsDb(loud) - JoinQuality.rmsDb(quiet), 6.02, accuracy: 0.2)
    }

    /// A pitch jump is the most audible tell, so it must dominate the cost.
    func testAPitchJumpCostsMoreThanASmallLevelStep() {
        let matched = JoinMeasurement(levelStepDb: 1.5, pitchBefore: 120, pitchAfter: 121,
                                      roomStepDb: 0.2, outgoingSettles: true)
        let jumped = JoinMeasurement(levelStepDb: 0, pitchBefore: 120, pitchAfter: 160,
                                     roomStepDb: 0.2, outgoingSettles: true)
        XCTAssertLessThan(matched.cost, jumped.cost)
        XCTAssertGreaterThan(jumped.pitchStepSemitones!, 4)
    }

    /// Cutting mid-phrase is penalised even when everything else matches, because the listener is
    /// left waiting for a word that never comes.
    func testCuttingMidPhraseIsPenalised() {
        let finished = JoinMeasurement(levelStepDb: 0, pitchBefore: nil, pitchAfter: nil,
                                       roomStepDb: 0, outgoingSettles: true)
        let interrupted = JoinMeasurement(levelStepDb: 0, pitchBefore: nil, pitchAfter: nil,
                                          roomStepDb: 0, outgoingSettles: false)
        XCTAssertEqual(finished.cost, 0, accuracy: 0.001, "nothing wrong is cost zero")
        XCTAssertGreaterThan(interrupted.cost, finished.cost)
    }

    /// A room-tone change is what makes two takes sound like two takes.
    func testARoomChangeCosts() {
        let same = JoinMeasurement(levelStepDb: 0, pitchBefore: nil, pitchAfter: nil,
                                   roomStepDb: 0, outgoingSettles: true)
        let different = JoinMeasurement(levelStepDb: 0, pitchBefore: nil, pitchAfter: nil,
                                        roomStepDb: 8, outgoingSettles: true)
        XCTAssertGreaterThan(different.cost, same.cost + 1)
    }

    /// THE ONE THAT MATTERS. On real speech, a join inside one continuous take is not a cut at all
    /// and must measure near-seamless; a join stitched from two different moments must measure
    /// worse. If these come out the same, the whole ranking is meaningless.
    func testOnRealSpeechAContinuousJoinBeatsAStitchedOne() throws {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/20260904_014657.mp4")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("no recording") }
        let source = try AudioSource(url: url, sampleRate: 48_000, channels: 1)
        func t(_ s: Double) -> TimeValue { TimeValue(seconds: Rational(Int64(s * 1000), 1000)) }

        // Continuous: the join is where the audio already runs on.
        var continuous: [Double] = []
        var stitched: [Double] = []
        for base in stride(from: 30.0, to: 90.0, by: 10.0) {
            continuous.append(try JoinQuality.measure(source: source,
                                                      outgoingEndsAt: t(base),
                                                      incomingStartsAt: t(base)).cost)
            // Stitched: the same outgoing side, but the incoming side comes from two minutes later.
            stitched.append(try JoinQuality.measure(source: source,
                                                    outgoingEndsAt: t(base),
                                                    incomingStartsAt: t(base + 120)).cost)
        }
        let meanContinuous = continuous.reduce(0, +) / Double(continuous.count)
        let meanStitched = stitched.reduce(0, +) / Double(stitched.count)
        XCTAssertLessThan(meanContinuous, meanStitched,
                          "continuous \(meanContinuous) vs stitched \(meanStitched) — the measure cannot tell a cut from no cut")
    }
}
