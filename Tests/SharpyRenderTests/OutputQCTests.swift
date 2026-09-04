// The M3 gate: "zero regressions on a fixture set of deliberately broken renders."
//
// Every test here BREAKS something on purpose and requires the QC tier to notice. A QC pass that
// has only ever seen good files is not evidence of anything — it is a check that has never been
// asked a hard question.

import XCTest
import AVFoundation
@testable import SharpyEngine
@testable import SharpyRender

final class OutputQCTests: XCTestCase {
    static let w = 320, h = 180
    static let rate = FrameRate.r30

    /// Writes a ProRes file whose luma is dictated per frame, so the fault is known exactly.
    /// ProRes because an inter-frame codec would invent its own repeats and blur the thing under
    /// test.
    @discardableResult
    static func write(to url: URL, frames: Int, luma: (Int) -> UInt8) throws -> URL {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422HQ,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: ColorTag.writer709])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
            let buffer = pb!
            CVPixelBufferLockBaseAddress(buffer, [])
            let value = luma(i)
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<h {
                for x in 0..<w {
                    let p = base + y * stride + x * 4
                    // Neutral grey: R=G=B makes the luma equal the code value, so a threshold on
                    // luma means exactly what it says.
                    p[0] = value; p[1] = value; p[2] = value; p[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { usleep(200) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status == .failed { throw writer.error! }
        return url
    }

    func temporary() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sharpy-qc-\(UUID().uuidString).mov")
    }

    /// Writes luma DIRECTLY into a full-range NV12 buffer, so the code value survives to the file
    /// instead of being range-converted on the way in. This is the actual fault being tested: a
    /// full-range picture carried in a file whose tags say video range.
    ///
    /// The earlier version of this fixture wrote BGRA 255 and expected superwhite. It did not get
    /// it — AVFoundation correctly converted 255 to ~235, so the fixture tested nothing and would
    /// have passed forever once the tolerance was set correctly.
    @discardableResult
    static func writeFullRange(to url: URL, frames: Int, luma: (Int) -> UInt8) throws -> URL {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422HQ,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: ColorTag.writer709])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
            let buffer = pb!
            CVPixelBufferLockBaseAddress(buffer, [])
            let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let value = luma(i)
            for row in 0..<h { memset(y + row * yStride, Int32(value), w) }
            let c = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
            let cStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            for row in 0..<(h / 2) { memset(c + row * cStride, 128, w) }   // neutral chroma
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { usleep(200) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status == .failed { throw writer.error! }
        return url
    }

    /// Levels outside tolerance must be caught, exercised through the real decode path.
    ///
    /// A note worth recording, because it took a wrong fixture to learn: AVAssetWriter ALWAYS
    /// range-converts. Writing 255 into a full-range NV12 buffer produces 236 in the file, and 200
    /// produces 188. So a superwhite deliverable cannot originate from Sharpy's own writer path at
    /// all — this fault can only arrive in a file produced elsewhere. The threshold is therefore
    /// tightened here to stand in for that content, which tests the same decode-and-decide path
    /// with a real file rather than a hand-built report.
    func testLevelsOutsideToleranceAreCaught() throws {
        let url = temporary(); defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeFullRange(to: url, frames: 6) { $0 % 2 == 0 ? 255 : 200 }
        let strict = OutputQC(legalLow: 5, legalHigh: 200)   // the file lands at 188…236
        let report = try strict.analyse(url: url, measureAudio: false)
        XCTAssertNotNil(report.assessedRange, "the fixture is tagged, so legality is decidable")
        XCTAssertFalse(report.illegalLevelFrames.isEmpty, "236 exceeds the ceiling under test")
        XCTAssertFalse(report.isClean)
        XCTAssertTrue(report.summary.contains("legal range"), report.summary)
    }

    /// The counterpart that makes the test above mean something: a correctly converted file sits a
    /// code value or two outside the NOMINAL range and must still pass. Measured on Sharpy's own
    /// render of a full-range source: luma 15…237, which hard 16/235 limits called 1419 illegal
    /// frames and R103's tolerance correctly calls clean.
    func testNormalRoundingOvershootIsNotAFault() throws {
        let url = temporary(); defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeFullRange(to: url, frames: 4) { _ in 237 }
        let report = try OutputQC().analyse(url: url, measureAudio: false)
        XCTAssertTrue(report.illegalLevelFrames.isEmpty,
                      "237 is inside R103 tolerance; flagging it would fail correct renders")
    }

    /// A legal picture must NOT be reported. A QC tier that flags good files is one people switch
    /// off, and a switched-off gate protects nothing.
    func testALegalPictureIsClean() throws {
        let url = temporary(); defer { try? FileManager.default.removeItem(at: url) }
        // Distinct mid-grey values, comfortably inside 16…235 and different every frame.
        try Self.write(to: url, frames: 6) { UInt8(80 + $0 * 12) }
        let report = try OutputQC().analyse(url: url, measureAudio: false)
        XCTAssertTrue(report.illegalLevelFrames.isEmpty, "levels 80…140 are well inside tolerance")
        XCTAssertTrue(report.blackFrames.isEmpty)
        XCTAssertTrue(report.repeatedFrames.isEmpty, "every frame differs from the last")
        if report.assessedRange != nil { XCTAssertTrue(report.isClean, report.summary) }
    }

    /// A repeated frame in a rendered deliverable means a dropped frame upstream.
    func testRepeatedFramesAreCaught() throws {
        let url = temporary(); defer { try? FileManager.default.removeItem(at: url) }
        // Frames 2 and 3 identical.
        let values: [UInt8] = [80, 100, 120, 120, 160, 180]
        try Self.write(to: url, frames: values.count) { values[$0] }
        let report = try OutputQC().analyse(url: url, measureAudio: false)
        XCTAssertEqual(report.repeatedFrames, [3], "only the duplicate, not its original")
    }

    func testBlackFramesAreCaught() throws {
        let url = temporary(); defer { try? FileManager.default.removeItem(at: url) }
        try Self.write(to: url, frames: 4) { $0 == 2 ? 0 : UInt8(100 + $0 * 10) }
        let report = try OutputQC().analyse(url: url, measureAudio: false)
        XCTAssertEqual(report.blackFrames, [2])
    }

    // MARK: predicted vs achieved

    func testAMissingFrameIsCaughtAsADelta() throws {
        let url = temporary(); defer { try? FileManager.default.removeItem(at: url) }
        try Self.write(to: url, frames: 5) { UInt8(80 + $0 * 12) }
        let achieved = try OutputQC().analyse(url: url, measureAudio: false)
        let predicted = RenderPrediction(frames: 6, duration: TimeValue(frames: 6, at: Self.rate),
                                         expectsDistinctFrames: true)
        let comparison = PredictedVsAchieved.compare(predicted: predicted, achieved: achieved)
        XCTAssertFalse(comparison.isClean)
        XCTAssertTrue(comparison.findings.contains { $0.check == "frame count" })
    }

    func testMatchingDeliveryIsClean() throws {
        let url = temporary(); defer { try? FileManager.default.removeItem(at: url) }
        try Self.write(to: url, frames: 5) { UInt8(80 + $0 * 12) }
        let achieved = try OutputQC().analyse(url: url, measureAudio: false)
        let predicted = RenderPrediction(frames: 5, duration: TimeValue(frames: 5, at: Self.rate))
        let findings = PredictedVsAchieved.compare(predicted: predicted, achieved: achieved).findings
        // An untagged fixture legitimately reports "levels undecidable"; nothing else may appear.
        XCTAssertTrue(findings.allSatisfy { $0.check == "incomplete" }, "\(findings)")
    }

    /// Off-target loudness is a delivery fault even though the file is perfectly legal.
    func testOffTargetLoudnessIsCaught() {
        let achieved = OutputQCReport(
            framesMeasured: 10, duration: TimeValue(frames: 10, at: Self.rate),
            illegalLevelFrames: [], blackFrames: [], repeatedFrames: [], assessedRange: 16...235, lumaExtremes: 20...200,
            loudness: LoudnessReading(integrated: -20.0, range: 3, truePeak: -3,
                                      maxMomentary: -18, maxShortTerm: -19),
            couldNotRun: [])
        let predicted = RenderPrediction(frames: 10, duration: TimeValue(frames: 10, at: Self.rate),
                                         loudnessTarget: -14)
        let comparison = PredictedVsAchieved.compare(predicted: predicted, achieved: achieved)
        XCTAssertTrue(comparison.findings.contains { $0.check == "loudness" },
                      "6 LU quiet is legal and completely wrong")
    }

    /// …but a shortfall the render already declared — the true-peak ceiling bound the gain — is
    /// NOT a fault. False alarms are how a gate gets switched off.
    func testADeclaredLoudnessShortfallIsNotAFault() {
        let achieved = OutputQCReport(
            framesMeasured: 10, duration: TimeValue(frames: 10, at: Self.rate),
            illegalLevelFrames: [], blackFrames: [], repeatedFrames: [], assessedRange: 16...235, lumaExtremes: 20...200,
            loudness: LoudnessReading(integrated: -16.0, range: 3, truePeak: -1,
                                      maxMomentary: -14, maxShortTerm: -15),
            couldNotRun: [])
        let predicted = RenderPrediction(frames: 10, duration: TimeValue(frames: 10, at: Self.rate),
                                         loudnessTarget: -14, loudnessKnownShortfall: 2.0)
        XCTAssertTrue(PredictedVsAchieved.compare(predicted: predicted, achieved: achieved).isClean,
                      "the render said it would be 2 LU quiet, and it is exactly 2 LU quiet")
    }

    /// "Could not measure" must never read as "measured and fine".
    func testAnIncompleteCheckIsAFailureNotAPass() {
        let achieved = OutputQCReport(
            framesMeasured: 0, duration: .zero, illegalLevelFrames: [], blackFrames: [],
            repeatedFrames: [], assessedRange: nil, lumaExtremes: nil, loudness: nil,
            couldNotRun: ["no frames decoded"])
        XCTAssertFalse(achieved.isClean)
        XCTAssertTrue(achieved.summary.contains("did not run"))
        let comparison = PredictedVsAchieved.compare(
            predicted: RenderPrediction(frames: 10, duration: .zero), achieved: achieved)
        XCTAssertTrue(comparison.findings.contains { $0.check == "incomplete" })
    }
}
