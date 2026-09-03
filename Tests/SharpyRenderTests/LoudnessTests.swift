// R128 loudness. Absolute correctness was established by cross-checking the user's real reel
// against ffmpeg's ebur128 (an independent implementation): Sharpy read −20.84 LUFS / 5.36 LU /
// −1.50 dBTP where ffmpeg read −20.9 / 5.4 / −1.5. These tests lock in the invariants that would
// break if the filter, the gating, or the peak detector regressed.

import XCTest
@testable import SharpyEngine
@testable import SharpyRender

final class LoudnessTests: XCTestCase {
    static let sr = 48_000

    /// `seconds` of a stereo sine at `amplitude`, interleaved.
    static func sine(_ hz: Double, amplitude: Double, seconds: Double, sampleRate: Int = sr) -> [Float] {
        let n = Int(Double(sampleRate) * seconds)
        var out = [Float](repeating: 0, count: n * 2)
        for i in 0..<n {
            let v = Float(sin(2 * Double.pi * hz * Double(i) / Double(sampleRate)) * amplitude)
            out[i * 2] = v; out[i * 2 + 1] = v
        }
        return out
    }

    static func measure(_ samples: [Float]) -> LoudnessReading {
        let m = LoudnessMeter(sampleRate: sr, channels: 2)
        m.add(samples)
        return m.result()
    }

    func testSilenceHasNoIntegratedLoudness() {
        let r = Self.measure([Float](repeating: 0, count: Self.sr * 2 * 5))
        XCTAssertNil(r.integrated, "silence fails the −70 LUFS absolute gate, so integrated is undefined")
        XCTAssertEqual(r.truePeak, -.infinity)
    }

    func testDoublingAmplitudeAddsSixLU() {
        let quiet = Self.measure(Self.sine(1000, amplitude: 0.1, seconds: 5))
        let loud = Self.measure(Self.sine(1000, amplitude: 0.2, seconds: 5))
        let q = try! XCTUnwrap(quiet.integrated), l = try! XCTUnwrap(loud.integrated)
        XCTAssertEqual(l - q, 20 * log10(2.0), accuracy: 0.05, "a 2× amplitude change is exactly +6.02 LU")
    }

    func testTruePeakTracksAmplitude() {
        for amp in [0.5, 0.25, 1.0] {
            let r = Self.measure(Self.sine(997, amplitude: amp, seconds: 2))
            XCTAssertEqual(r.truePeak, 20 * log10(amp), accuracy: 0.15, "true peak of a \(amp) sine")
        }
    }

    /// K-weighting is a filter, so loudness must depend on frequency in a specific way — a flat
    /// meter would read all three the same. The absolute values below were cross-checked against
    /// ffmpeg's ebur128 on identical amplitude-0.2 tones: it read −17.6 / −14.0 / −10.6 LUFS where
    /// this meter reads −17.57 / −13.97 / −10.64, agreeing within 0.04 LU.
    func testKWeightingMatchesTheStandardCurve() {
        let low = try! XCTUnwrap(Self.measure(Self.sine(60, amplitude: 0.2, seconds: 5)).integrated)
        let mid = try! XCTUnwrap(Self.measure(Self.sine(1000, amplitude: 0.2, seconds: 5)).integrated)
        let high = try! XCTUnwrap(Self.measure(Self.sine(6000, amplitude: 0.2, seconds: 5)).integrated)
        XCTAssertEqual(low, -17.57, accuracy: 0.15, "60 Hz through the RLB high-pass")
        XCTAssertEqual(mid, -13.97, accuracy: 0.15, "1 kHz sits near the reference point")
        XCTAssertEqual(high, -10.64, accuracy: 0.15, "6 kHz through the +4 dB shelf")
        // The shape, stated as relationships so the intent survives a re-derivation.
        XCTAssertEqual(mid - low, 3.6, accuracy: 0.2, "60 Hz reads 3.6 LU below 1 kHz")
        XCTAssertEqual(high - mid, 3.3, accuracy: 0.2, "6 kHz reads 3.3 LU above 1 kHz")
    }

    /// The relative gate is what stops a long quiet passage dragging the integrated value down.
    func testRelativeGateIgnoresQuietPassages() {
        var loudThenQuiet = Self.sine(1000, amplitude: 0.3, seconds: 5)
        loudThenQuiet += Self.sine(1000, amplitude: 0.003, seconds: 15)   // 40 dB down, four times as long
        let gated = try! XCTUnwrap(Self.measure(loudThenQuiet).integrated)
        let loudOnly = try! XCTUnwrap(Self.measure(Self.sine(1000, amplitude: 0.3, seconds: 5)).integrated)
        XCTAssertEqual(gated, loudOnly, accuracy: 0.5,
                       "the −10 LU relative gate should discard the quiet tail, leaving the loud section's value")
    }

    func testGainToTargetIsTheDifference() {
        let r = Self.measure(Self.sine(1000, amplitude: 0.2, seconds: 5))
        let i = try! XCTUnwrap(r.integrated)
        XCTAssertEqual(try XCTUnwrap(r.gain(toReach: -23)), -23 - i, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(r.gain(toReach: -14)), -14 - i, accuracy: 1e-9)
    }

    /// Applying the meter's own recommended gain must land on the target.
    func testNormalisingHitsTheTarget() {
        let original = Self.sine(1000, amplitude: 0.2, seconds: 6)
        let before = try! XCTUnwrap(Self.measure(original).integrated)
        let gainDB = -23.0 - before
        let scale = Float(pow(10.0, gainDB / 20.0))
        let after = try! XCTUnwrap(Self.measure(original.map { $0 * scale }).integrated)
        XCTAssertEqual(after, -23.0, accuracy: 0.1, "after applying the recommended gain the signal should read −23 LUFS")
    }

    func testCoefficientsAreDerivedForTheActualSampleRate() {
        // The same signal at two rates must read the same loudness. It only does if the
        // K-weighting coefficients are re-derived rather than hardcoded at 48 kHz.
        let at48 = LoudnessMeter(sampleRate: 48_000, channels: 2)
        at48.add(Self.sine(1000, amplitude: 0.2, seconds: 5, sampleRate: 48_000))
        let at44 = LoudnessMeter(sampleRate: 44_100, channels: 2)
        at44.add(Self.sine(1000, amplitude: 0.2, seconds: 5, sampleRate: 44_100))
        let a = try! XCTUnwrap(at48.result().integrated), b = try! XCTUnwrap(at44.result().integrated)
        XCTAssertEqual(a, b, accuracy: 0.1, "48 kHz and 44.1 kHz must agree on the same tone")
    }
}
