// Audio correctness. The test media encodes its own position: each second of audio is a pure
// sine at a distinct frequency, so a decoded or rendered stretch can be checked against the exact
// source second it must have come from — the audio analogue of the per-frame colour codes.

import XCTest
import AVFoundation
@testable import SharpyEngine
@testable import SharpyRender

final class AudioTests: XCTestCase {
    static let sampleRate = 48_000
    static let seconds = 6
    static let rate = FrameRate.r30
    static let w = 320, h = 180
    /// Second i is a sine at (i+1) × 200 Hz: 200, 400, 600, 800, 1000, 1200.
    static func frequency(ofSecond i: Int) -> Double { Double(i + 1) * 200 }
    static var avURL: URL!

    override class func setUp() {
        super.setUp()
        avURL = FileManager.default.temporaryDirectory.appendingPathComponent("sharpy-av-\(UUID().uuidString).mov")
        try! synthesise(to: avURL)
    }

    override class func tearDown() {
        if ProcessInfo.processInfo.environment["SHARPY_KEEP_TEST_MEDIA"] == nil { try? FileManager.default.removeItem(at: avURL) }
        super.tearDown()
    }

    /// A movie with ProRes video (grey) and 48 kHz stereo audio whose frequency steps every second.
    static func synthesise(to url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422HQ, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: ColorTag.writer709])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        // Linear PCM in the fixture: AAC would smear the band edges we assert on.
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        writer.add(video); writer.add(audio)
        writer.startWriting(); writer.startSession(atSourceTime: .zero)

        // Driven with requestMediaDataWhenReady, same as the render path: polling both inputs
        // from one thread deadlocks.
        let fmt = AudioFormatInfo(sampleRate: sampleRate, channels: 2)
        let group = DispatchGroup()
        var nextFrame = 0, nextSecond = 0

        group.enter()
        video.requestMediaDataWhenReady(on: DispatchQueue(label: "fixture.video")) {
            while video.isReadyForMoreMediaData {
                guard nextFrame < seconds * 30 else { video.markAsFinished(); group.leave(); return }
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
                ColorTag.tag709(pb!)
                CVPixelBufferLockBaseAddress(pb!, [])
                let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRow(pb!)
                let v = UInt8(40 + (nextFrame % 200))
                for y in 0..<h { for x in 0..<w { let p = base + y * stride + x * 4; p[0] = v; p[1] = v; p[2] = v; p[3] = 255 } }
                CVPixelBufferUnlockBaseAddress(pb!, [])
                _ = adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(nextFrame), timescale: 30))
                nextFrame += 1
            }
        }

        group.enter()
        audio.requestMediaDataWhenReady(on: DispatchQueue(label: "fixture.audio")) {
            while audio.isReadyForMoreMediaData {
                guard nextSecond < seconds else { audio.markAsFinished(); group.leave(); return }
                var block = [Float](repeating: 0, count: sampleRate * 2)
                let freq = frequency(ofSecond: nextSecond)
                for n in 0..<sampleRate {
                    // Phase restarts each second: the discontinuity sits on a boundary we never assert across.
                    let val = Float(sin(2 * Double.pi * freq * Double(n) / Double(sampleRate)) * 0.5)
                    block[n * 2] = val; block[n * 2 + 1] = val
                }
                guard let sb = try? AudioPacking.sampleBuffer(interleaved: block, format: fmt,
                                                              pts: TimeValue(seconds: Rational(Int64(nextSecond)))) else {
                    audio.markAsFinished(); group.leave(); return
                }
                _ = audio.append(sb)
                nextSecond += 1
            }
        }
        group.wait()

        let done = DispatchSemaphore(value: 0); writer.finishWriting { done.signal() }; done.wait()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    }

    /// Dominant frequency of an interleaved buffer, by counting zero crossings on the left channel.
    static func dominantFrequency(_ interleaved: [Float], channels: Int = 2, sampleRate: Int = sampleRate) -> Double {
        let frames = interleaved.count / channels
        guard frames > 1 else { return 0 }
        var crossings = 0
        var previous = interleaved[0]
        for n in 1..<frames {
            let v = interleaved[n * channels]
            if (previous < 0 && v >= 0) || (previous >= 0 && v < 0) { crossings += 1 }
            previous = v
        }
        return Double(crossings) / 2 / (Double(frames) / Double(sampleRate))
    }

    func assertFrequency(_ got: Double, _ want: Double, _ msg: String, tol: Double = 12, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(abs(got - want), tol, "\(msg): got \(Int(got)) Hz, want \(Int(want)) Hz", file: file, line: line)
    }

    // MARK: tests

    func testSampleAlignmentRuleDependsOnTrackKind() throws {
        // 29.97: one frame = 48000 × 1001/30000 = 1601.6 samples, so a frame boundary is NOT a
        // sample boundary. Video must take the frame; audio must take a sample.
        let doc = Document(timeline: Timeline(name: "t", frameRate: .ntsc30, sampleRate: 48_000))
        let oneFrame = TimeValue(frames: 1, at: .ntsc30)
        XCTAssertTrue(oneFrame.isFrameAligned(at: .ntsc30))
        XCTAssertNotEqual((oneFrame.seconds * Rational(48_000)).den, 1, "1 frame at 29.97 is 1601.6 samples — not a whole sample")
        let snapped = oneFrame.alignedToSample(at: 48_000)
        XCTAssertEqual((snapped.seconds * Rational(48_000)).den, 1)
        XCTAssertLessThan(abs((snapped.seconds - oneFrame.seconds).doubleValue), 1.0 / 48_000, "snap moves less than one sample")

        var log = CommandLog(initial: doc)
        let asset = AssetRef(contentHash: "x", path: "/x", duration: TimeValue(seconds: Rational(10)), frameRate: .ntsc30, hasVideo: true, hasAudio: true)
        try log.append(.addAsset(asset))
        try log.append(.addTrack(kind: .video, name: "V1"))
        try log.append(.addTrack(kind: .audio, name: "A1"))
        let id = log.head.assets.keys.first!
        let basis = Basis.clientRule(rule: "test")

        // A sample-aligned-but-not-frame-aligned start is legal on audio, refused on video.
        let odd = TimeValue(seconds: Rational(7, 48_000))
        try log.append(.placeClip(track: 1, clip: Clip(asset: id, source: TimeRange(start: .zero, duration: TimeValue(seconds: Rational(1))), start: odd),
                                  decision: Decision(kind: .cut, at: odd, basis: basis)))
        XCTAssertThrowsError(try log.append(.placeClip(track: 0, clip: Clip(asset: id, source: TimeRange(start: .zero, duration: TimeValue(seconds: Rational(1))), start: odd),
                                                       decision: Decision(kind: .cut, at: odd, basis: basis)))) { e in
            guard case ApplyError.notFrameAligned = e as! ApplyError else { return XCTFail("\(e)") }
        }
        // And a mid-sample position is refused on audio too.
        let subSample = TimeValue(seconds: Rational(1, 96_000))
        XCTAssertThrowsError(try log.append(.placeClip(track: 1, clip: Clip(asset: id, source: TimeRange(start: .zero, duration: TimeValue(seconds: Rational(1))), start: subSample),
                                                       decision: Decision(kind: .cut, at: subSample, basis: basis)))) { e in
            guard case ApplyError.notSampleAligned = e as! ApplyError else { return XCTFail("\(e)") }
        }
    }

    func testAudioSourceReadsExactSampleRanges() throws {
        let src = try AudioSource(url: Self.avURL, sampleRate: Self.sampleRate, channels: 2)
        XCTAssertEqual(src.duration.seconds, Rational(Int64(Self.seconds)))

        for s in 0..<Self.seconds {
            // Read the middle 0.5 s of each second, away from the phase discontinuity at the edge.
            let start = TimeValue(seconds: Rational(Int64(s)) + Rational(1, 4))
            let samples = try src.read(TimeRange(start: start, duration: TimeValue(seconds: Rational(1, 2))))
            XCTAssertEqual(samples.count, Self.sampleRate / 2 * 2, "second \(s) sample count")
            assertFrequency(Self.dominantFrequency(samples), Self.frequency(ofSecond: s), "second \(s)")
        }

        // A range that straddles a boundary contains both frequencies: the second half must match
        // the later second, proving the read is positioned, not merely the right length.
        let straddle = try src.read(TimeRange(start: TimeValue(seconds: Rational(7, 4)), duration: TimeValue(seconds: Rational(1, 2))))
        let secondHalf = Array(straddle[(straddle.count / 2)...])
        assertFrequency(Self.dominantFrequency(secondHalf), Self.frequency(ofSecond: 2), "second half of a straddling read")
    }

    func testRenderedAudioFollowsTheRippleCut() throws {
        // Cut out source second 1 (frames 30..60) on both tracks; the output must run
        // 200, 600, 800, 1000, 1200 Hz — second 1's 400 Hz gone, everything after moved up.
        var log = CommandLog(initial: Document(timeline: Timeline(name: "t", frameRate: Self.rate, sampleRate: Self.sampleRate)))
        let vsrc = try SequentialFrameSource(url: Self.avURL)
        let asrc = try AudioSource(url: Self.avURL, sampleRate: Self.sampleRate, channels: 2)
        let asset = AssetRef(contentHash: "av", path: Self.avURL.path, duration: vsrc.duration, frameRate: Self.rate, hasVideo: true, hasAudio: true)
        try log.append(.addAsset(asset))
        try log.append(.addTrack(kind: .video, name: "V1"))
        try log.append(.addTrack(kind: .audio, name: "A1"))
        let id = log.head.assets.keys.first!
        let basis = Basis.measuredMaterial(ref: "test", detail: "synthetic", confidence: .one)
        func t(_ f: Int64) -> TimeValue { TimeValue(frames: f, at: Self.rate) }

        try log.append(.placeClip(track: 0, clip: Clip(asset: id, source: TimeRange(start: .zero, end: t(180)), start: .zero),
                                  decision: Decision(kind: .cut, at: .zero, basis: basis)))
        try log.append(.placeClip(track: 1, clip: Clip(asset: id, source: TimeRange(start: .zero, end: asrc.duration), start: .zero),
                                  decision: Decision(kind: .cut, at: .zero, basis: basis)))
        try log.append(.rippleDelete(track: 0, range: TimeRange(start: t(30), end: t(60)), decision: Decision(kind: .cut, at: t(30), basis: basis)))
        try log.append(.rippleDelete(track: 1, range: TimeRange(start: TimeValue(seconds: Rational(1)), end: TimeValue(seconds: Rational(2))),
                                     decision: Decision(kind: .cut, at: TimeValue(seconds: Rational(1)), basis: basis)))
        XCTAssertEqual(log.head.timeline.duration, TimeValue(seconds: Rational(5)))

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("sharpy-audio-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: out) }
        let session = try RenderSession(document: log.head, options: RenderOptions(width: Self.w, height: Self.h, codec: .proRes422HQ, sampleRate: Self.sampleRate))
        let report = try session.render(to: out)
        XCTAssertEqual(report.framesRendered, 150)
        XCTAssertEqual(report.audioSamplesWritten, Self.sampleRate * 5, "5 s of audio")

        // The rendered file has an audio track at all — the bug this whole pass exists to fix.
        let rendered = AVURLAsset(url: out)
        XCTAssertEqual(rendered.tracks(withMediaType: .audio).count, 1, "output must carry audio")
        XCTAssertEqual(rendered.tracks(withMediaType: .video).count, 1)

        let check = try AudioSource(url: out, sampleRate: Self.sampleRate, channels: 2)
        let expected = [0, 2, 3, 4, 5].map { Self.frequency(ofSecond: $0) }   // second 1 removed
        for (i, want) in expected.enumerated() {
            let start = TimeValue(seconds: Rational(Int64(i)) + Rational(1, 4))
            let samples = try check.read(TimeRange(start: start, duration: TimeValue(seconds: Rational(1, 2))))
            assertFrequency(Self.dominantFrequency(samples), want, "output second \(i)")
        }
    }
}
