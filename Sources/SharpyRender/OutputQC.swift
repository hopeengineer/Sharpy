// Signal QC on the file that was actually written.
//
// The compositor's ID pass proves what the compositor did. It cannot prove what came out of the
// ENCODER — a wrong colour transform, an illegal level, a frame the encoder repeated, a black
// frame that should not be there. Those faults happen after every in-memory assertion has passed,
// which is exactly why the plan puts a measurement pass on the output (§6.2) and a
// predicted-versus-achieved comparison after it (§6.3).
//
// This is QCTools' tier, in Swift. The app links no ffmpeg, so the statistics are computed here
// over the decoded luma plane with Accelerate — which is also why they are exact rather than
// sampled: every frame is measured, not every eighth.
//
// One rule shapes the whole file: a check that could not run reports as a FAILURE, never as a
// quiet pass. "We measured and it was fine" and "we did not measure" are different claims, and
// conflating them is how QC becomes theatre.

import Foundation
import AVFoundation
import Accelerate
import SharpyEngine

public struct FrameStats: Sendable {
    public let index: Int64
    public let time: TimeValue
    /// Luma in code values as stored, 0…255 for 8-bit.
    public let lumaMin: Float, lumaMax: Float, lumaMean: Float
    /// Mean absolute luma difference from the previous frame, in code values. Zero means the
    /// encoder emitted the same picture twice.
    public let differenceFromPrevious: Float?
}

public struct OutputQCReport: Sendable {
    public let framesMeasured: Int
    public let duration: TimeValue
    /// Frames whose luma left the legal video range for their tag.
    ///
    /// EMPTY IS NOT AUTOMATICALLY A PASS: when the file carries no colour-range tag, legality is
    /// undefined and `couldNotRun` says so instead of a verdict being invented. Measured on the
    /// user's own untagged reel, an unconditional video-range assumption flagged 2088 of 2649
    /// frames — a check that fails on ordinary footage is a check that gets switched off.
    public let illegalLevelFrames: [Int64]
    /// Frames that are entirely (or almost entirely) black.
    public let blackFrames: [Int64]
    /// Frames effectively identical in luma to their predecessor.
    ///
    /// An OBSERVATION, not a fault. A static graphic card repeats frames because it is a static
    /// graphic card; the user's reel has 416 such frames and every one of them is correct. It
    /// becomes a fault only against a prediction that says the frames should differ, which is
    /// `RenderPrediction.expectsDistinctFrames` and is the caller's knowledge, not this tier's.
    public let repeatedFrames: [Int64]
    /// The colour range the levels check was decided against, or nil when the file was untagged.
    public let assessedRange: ClosedRange<Float>?
    /// Actual luma extremes across the whole file. Reported even when legality is undecidable,
    /// because the measurement is valid regardless of whether a verdict is.
    public let lumaExtremes: ClosedRange<Float>?
    public let loudness: LoudnessReading?
    /// Set when a check could not run. Non-empty means the report is incomplete and must not be
    /// read as a pass.
    public let couldNotRun: [String]

    /// Repeats are excluded on purpose — see `repeatedFrames`.
    public var isClean: Bool {
        illegalLevelFrames.isEmpty && blackFrames.isEmpty && couldNotRun.isEmpty
    }

    public var summary: String {
        guard framesMeasured > 0 else { return "output QC: did not run" }
        if !couldNotRun.isEmpty {
            return "output QC: INCOMPLETE — \(couldNotRun.joined(separator: "; "))"
        }
        let note = repeatedFrames.isEmpty ? ""
            : "  (\(repeatedFrames.count) repeated frame(s) — an observation, not a fault)"
        if isClean { return "output QC: clean across \(framesMeasured) frame(s)\(note)" }
        var parts: [String] = []
        if !illegalLevelFrames.isEmpty { parts.append("\(illegalLevelFrames.count) frame(s) outside legal range") }
        if !blackFrames.isEmpty { parts.append("\(blackFrames.count) black frame(s)") }
        return "output QC: " + parts.joined(separator: ", ") + note
    }
}

public enum OutputQCError: Error, CustomStringConvertible {
    case noVideoTrack(URL)
    case cannotRead(String)
    public var description: String {
        switch self {
        case .noVideoTrack(let u): return "no video track in \(u.lastPathComponent)"
        case .cannotRead(let s): return "cannot read output: \(s)"
        }
    }
}

public struct OutputQC: Sendable {
    /// EBU R103 tolerance bounds for 8-bit luma, NOT the preferred range.
    ///
    /// The preferred range is 16…235, but R103 tolerates excursions to 5…246 because rounding and
    /// chroma interpolation put a code value or two outside the nominal range in every correctly
    /// encoded file. Measured here: Sharpy's own render of a full-range (0…255) source lands at
    /// 15…237 — the conversion is right, and hard 16/235 limits called 1419 of 2479 frames illegal.
    /// A QC tier that fails correct output is a QC tier that gets switched off.
    public var legalLow: Float
    public var legalHigh: Float
    /// The nominal range, reported for context rather than asserted.
    public static let preferredRange: ClosedRange<Float> = 16...235
    /// A frame whose mean luma is under this reads as black.
    public var blackThreshold: Float
    /// Mean absolute difference under this counts as a repeat. Not zero: even a lossless-looking
    /// intra codec moves a code value or two, and demanding exact equality would find nothing.
    public var repeatThreshold: Float
    /// Sample every Nth frame. 1 = every frame, which is the point and the default.
    public var stride: Int64

    public init(legalLow: Float = 5, legalHigh: Float = 246,
                blackThreshold: Float = 17, repeatThreshold: Float = 0.05, stride: Int64 = 1) {
        self.legalLow = legalLow; self.legalHigh = legalHigh
        self.blackThreshold = blackThreshold; self.repeatThreshold = repeatThreshold
        self.stride = max(1, stride)
    }

    public func analyse(url: URL, measureAudio: Bool = true) throws -> OutputQCReport {
        let asset = AVURLAsset(url: url)
        var couldNotRun: [String] = []

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var track: AVAssetTrack?
        nonisolated(unsafe) var loadError: Error?
        Task {
            do { track = try await asset.loadTracks(withMediaType: .video).first }
            catch { loadError = error }
            semaphore.signal()
        }
        semaphore.wait()
        if let loadError { throw OutputQCError.cannotRead(String(describing: loadError)) }
        guard let track else { throw OutputQCError.noVideoTrack(url) }

        // Which range the levels are legal against is a property of the FILE, not an assumption.
        // Untagged material is the common case (the user's own reel is untagged, and so is the 4K
        // test pattern), and for untagged material legality is undefined: video-range limits
        // flagged 2088 of 2649 frames of perfectly ordinary footage. So an untagged file gets its
        // levels MEASURED and no verdict, which is the honest answer.
        var range: ClosedRange<Float>?
        if let description = track.formatDescriptions.first {
            let cmDescription = description as! CMFormatDescription
            // The MATRIX tag is what proves the file was deliberately tagged. AVFoundation
            // synthesises a video-range default for untagged media, so the range extension alone
            // is not evidence: on the user's untagged reel that default produced a confident
            // "2088 of 2649 frames illegal" for footage that is very probably full range.
            //
            // With a matrix tag present the file has been through a colour-aware pipeline, and
            // video range is the documented default there — an explicit full-range tag overrides
            // it. With no matrix tag, nothing is decidable and none is invented.
            let matrix = CMFormatDescriptionGetExtension(
                cmDescription, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix)
            let full = CMFormatDescriptionGetExtension(
                cmDescription, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool
            if matrix != nil { range = (full ?? false) ? 0...255 : legalLow...legalHigh }
        }
        if range == nil {
            couldNotRun.append("untagged colour: levels measured, legality undecidable")
        }

        let reader = try AVAssetReader(asset: asset)
        // Force 8-bit 4:2:0 so the luma plane is plane 0 and the thresholds mean one thing.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw OutputQCError.cannotRead("reader rejected the output") }
        reader.add(output)
        guard reader.startReading() else {
            throw OutputQCError.cannotRead(reader.error?.localizedDescription ?? "startReading")
        }

        var stats: [FrameStats] = []
        var previous: [Float]?
        var index: Int64 = 0
        var lastTime = TimeValue.zero

        while let sample = output.copyNextSampleBuffer() {
            defer { index += 1 }
            guard index % stride == 0, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let time = TimeValue(seconds: Rational(Int64(pts.value), Int64(max(pts.timescale, 1))))
            lastTime = time

            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
                couldNotRun.append("frame \(index): luma plane unavailable")
                continue
            }
            let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
            let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)

            // Rows are copied out because the plane is padded to the stride; measuring the padding
            // would report levels that are not in the picture.
            var luma = [Float](repeating: 0, count: width * height)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            luma.withUnsafeMutableBufferPointer { out in
                for y in 0..<height {
                    vDSP_vfltu8(bytes + y * rowBytes, 1, out.baseAddress! + y * width, 1, vDSP_Length(width))
                }
            }

            var minimum: Float = 0, maximum: Float = 0, mean: Float = 0
            vDSP_minv(luma, 1, &minimum, vDSP_Length(luma.count))
            vDSP_maxv(luma, 1, &maximum, vDSP_Length(luma.count))
            vDSP_meanv(luma, 1, &mean, vDSP_Length(luma.count))

            var difference: Float?
            if let previous, previous.count == luma.count {
                var delta = [Float](repeating: 0, count: luma.count)
                vDSP_vsub(previous, 1, luma, 1, &delta, 1, vDSP_Length(luma.count))
                var meanAbsolute: Float = 0
                vDSP_meamgv(delta, 1, &meanAbsolute, vDSP_Length(delta.count))
                difference = meanAbsolute
            }
            previous = luma
            stats.append(FrameStats(index: index, time: time, lumaMin: minimum, lumaMax: maximum,
                                    lumaMean: mean, differenceFromPrevious: difference))
        }

        if reader.status == .failed {
            throw OutputQCError.cannotRead(reader.error?.localizedDescription ?? "read failed")
        }
        if stats.isEmpty { couldNotRun.append("no frames decoded") }

        var loudness: LoudnessReading?
        if measureAudio {
            do { loudness = try LoudnessMeter.measure(url: url) }
            catch {
                // Only a fault if the file claims to have audio. A picture-only deliverable has
                // nothing to measure and that is not a failure.
                let hasAudio = (try? AudioSource(url: url)) != nil
                if hasAudio { couldNotRun.append("loudness: \(error)") }
            }
        }

        return OutputQCReport(
            framesMeasured: stats.count,
            duration: lastTime,
            illegalLevelFrames: range.map { limits in
                stats.filter { $0.lumaMin < limits.lowerBound || $0.lumaMax > limits.upperBound }.map(\.index)
            } ?? [],
            blackFrames: stats.filter { $0.lumaMean < blackThreshold }.map(\.index),
            repeatedFrames: stats.compactMap { s in
                guard let d = s.differenceFromPrevious, d < repeatThreshold else { return nil }
                return s.index
            },
            assessedRange: range,
            lumaExtremes: stats.isEmpty ? nil
                : (stats.map(\.lumaMin).min()!)...(stats.map(\.lumaMax).max()!),
            loudness: loudness,
            couldNotRun: couldNotRun)
    }
}
