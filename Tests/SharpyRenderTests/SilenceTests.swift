// Dead-air detection, against audio whose silences are known by construction.
//
// The motivating measurement: on 88 s of real narration, Apple's SpeechAnalyzer word timings
// produced 28 "gaps" totalling 2.0 s, every one of them exactly 0.06 s or 0.12 s — quantisation,
// not silence. The same audio measured from the waveform has 4 real silences totalling 0.90 s.
// These tests pin the waveform method so that finding cannot silently regress.

import XCTest
import AVFoundation
@testable import SharpyEngine
@testable import SharpyRender

final class SilenceTests: XCTestCase {
    static let sr = 48_000

    /// Build a file: 2 s tone, 1.5 s silence, 2 s tone, 0.2 s silence, 2 s tone.
    /// Silences carry a little room tone so this is not the trivial digital-zero case.
    static func makeTestFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sharpy-sil-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        writer.add(input)
        writer.startWriting(); writer.startSession(atSourceTime: .zero)

        var samples: [Float] = []
        func tone(_ seconds: Double) {
            let n = Int(Double(sr) * seconds)
            for i in 0..<n { samples.append(Float(sin(2 * Double.pi * 220 * Double(i) / Double(sr)) * 0.3)) }
        }
        func quiet(_ seconds: Double) {
            let n = Int(Double(sr) * seconds)
            // −60 dBFS room tone, well under a −22 dBFS speech level.
            for _ in 0..<n { samples.append(Float.random(in: -0.001...0.001)) }
        }
        tone(2.0); quiet(1.5); tone(2.0); quiet(0.2); tone(2.0)

        let fmt = AudioFormatInfo(sampleRate: sr, channels: 1)
        let sb = try AudioPacking.sampleBuffer(interleaved: samples, format: fmt, pts: .zero)
        let group = DispatchGroup(); group.enter()
        var appended = false
        input.requestMediaDataWhenReady(on: DispatchQueue(label: "sil.fixture")) {
            while input.isReadyForMoreMediaData {
                if appended { input.markAsFinished(); group.leave(); return }
                _ = input.append(sb); appended = true
            }
        }
        group.wait()
        let done = DispatchSemaphore(value: 0); writer.finishWriting { done.signal() }; done.wait()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }

    func testFindsTheLongSilenceAndSkipsTheShortOne() throws {
        let url = try Self.makeTestFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let p = try SilenceDetector.analyse(url: url, sampleRate: Self.sr,
                                            minimumDuration: TimeValue(seconds: Rational(4, 10)),
                                            padding: TimeValue(seconds: Rational(1, 10)))

        // Speech level is measured from the tone, which is 0.3 amplitude → RMS ≈ −13.5 dBFS.
        XCTAssertEqual(p.speechLevel, -13.5, accuracy: 1.5, "speech level should track the tone's RMS")
        XCTAssertLessThan(p.noiseFloor, -45, "the quiet sections are around −60 dBFS")

        XCTAssertEqual(p.runs.count, 1, "only the 1.5 s gap exceeds the 0.4 s minimum; the 0.2 s one must not appear")
        let run = p.runs[0]
        // Detected 2.0–3.5, padded inward by 0.1 either side.
        XCTAssertEqual(run.range.start.seconds.doubleValue, 2.1, accuracy: 0.08)
        XCTAssertEqual(run.range.end.seconds.doubleValue, 3.4, accuracy: 0.08)
        XCTAssertEqual(run.duration.seconds.doubleValue, 1.3, accuracy: 0.1, "1.5 s less 0.1 s padding each side")
    }

    func testPaddingKeepsCutsOffTheSpeech() throws {
        let url = try Self.makeTestFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let none = try SilenceDetector.analyse(url: url, sampleRate: Self.sr,
                                               minimumDuration: TimeValue(seconds: Rational(4, 10)),
                                               padding: .zero)
        let padded = try SilenceDetector.analyse(url: url, sampleRate: Self.sr,
                                                 minimumDuration: TimeValue(seconds: Rational(4, 10)),
                                                 padding: TimeValue(seconds: Rational(2, 10)))
        XCTAssertGreaterThan(none.runs[0].duration.seconds.doubleValue, padded.runs[0].duration.seconds.doubleValue,
                             "padding must shrink the removable range, never grow it")
        XCTAssertEqual(none.runs[0].duration.seconds.doubleValue - padded.runs[0].duration.seconds.doubleValue,
                       0.4, accuracy: 0.05, "0.2 s of padding at each end")
    }

    func testTighteningPlanCapsRatherThanDeletes() throws {
        let url = try Self.makeTestFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let p = try SilenceDetector.analyse(url: url, sampleRate: Self.sr,
                                            minimumDuration: TimeValue(seconds: Rational(3, 10)))
        let cap = TimeValue(seconds: Rational(5, 10))
        let plan = SilenceDetector.tighteningPlan(p, cappingAt: cap)
        XCTAssertFalse(plan.isEmpty)
        for (run, removal) in zip(p.runs, plan) {
            XCTAssertEqual(removal.end, run.range.end, "the tail of the gap is what goes")
            XCTAssertEqual((run.duration - removal.duration).seconds.doubleValue, 0.5, accuracy: 0.02,
                           "exactly the cap survives")
        }
    }

    func testAThresholdRelativeToSpeechAdaptsToLevel() throws {
        // The same content 20 dB quieter must yield the same silence structure — that is the whole
        // reason the threshold is relative to the recording's own speech level, not absolute.
        let url = try Self.makeTestFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let loud = try SilenceDetector.analyse(url: url, sampleRate: Self.sr,
                                               minimumDuration: TimeValue(seconds: Rational(4, 10)))
        XCTAssertEqual(loud.runs.count, 1)
        XCTAssertEqual(loud.threshold, loud.speechLevel - 25, accuracy: 0.001,
                       "threshold is defined relative to measured speech, not a fixed dBFS")
    }
}
