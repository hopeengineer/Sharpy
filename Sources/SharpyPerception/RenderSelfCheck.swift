// Look at what came out, and compare it to what went in.
//
// This exists because of a specific failure. A phone records landscape pixels and tags the file
// "rotate 90"; the renderer reported the rotated SIZE but drew the unrotated pixels, and every
// frame it wrote was a sideways, cropped sliver. Every other check passed — the levels were legal,
// the loudness was fine, the frame count matched, the cuts measured clean — because none of them
// looked at whether the picture still showed the thing it was a picture of.
//
// The user spotted it in one glance. That is the gap: a tool that verifies everything except
// whether the output resembles the input is not context-aware, it is thorough about the wrong
// things.
//
// The check is a comparison, not a threshold. Absolute numbers cannot say much — some footage
// legitimately has no face in it — but a source where somebody is on screen for most of the piece
// and an output where they are not is wrong no matter what the footage is.

import Foundation
import AVFoundation
import CoreGraphics
import SharpyEngine
import SharpyRender

public struct RenderSelfCheck: Sendable {
    public struct Finding: Sendable, CustomStringConvertible {
        public let what: String
        public let detail: String
        public var description: String { "\(what): \(detail)" }
    }

    public let sourceFaceFraction: Double
    public let outputFaceFraction: Double
    public let sourceAspect: Double
    public let outputAspect: Double
    public let framesChecked: Int
    public let findings: [Finding]

    public var looksRight: Bool { findings.isEmpty }

    public var summary: String {
        guard framesChecked > 0 else { return "self-check: did not run" }
        var lines = [String(format: "self-check: %d frame(s) — subject on screen %.0f%% in source, %.0f%% in output; aspect %.2f → %.2f",
                            framesChecked, sourceFaceFraction * 100, outputFaceFraction * 100,
                            sourceAspect, outputAspect)]
        for finding in findings { lines.append("  ✗ " + finding.description) }
        if findings.isEmpty { lines.append("  the output resembles the source") }
        return lines.joined(separator: "\n")
    }
}

public enum RenderVerifier {
    /// A drop this large in how often the subject is on screen is not framing, it is a fault.
    public static let subjectDropTolerance = 0.35
    /// Aspect ratios closer than this are the same shape; anything further is a different frame.
    public static let aspectTolerance = 0.02

    /// Compare a rendered file against the material it came from.
    ///
    /// Deliberately cheap — a handful of frames from each, because the faults worth catching here
    /// are gross ones. A check that doubled render time is a check people switch off.
    /// - Parameter intendedAspect: the shape the caller ASKED for. A reframe that was requested is
    ///   not a fault; only an unexplained change of shape is. Without this the check cries wolf on
    ///   every deliberate 1:1 or 16:9 export, and a check that cries wolf gets switched off.
    /// Does every band of a stacked layout actually contain a picture?
    ///
    /// The failure this edit has is not a wrong colour or a wrong crop, it is a band that never got
    /// a clip and renders black — and black in one of three panels looks deliberate enough that a
    /// glance will not catch it. Every other check compares the output against the source as a
    /// whole and would call a stack "reframed" and pass it.
    ///
    /// A band is judged by its variation, not its brightness: a dark room is dim everywhere but
    /// still varies, while an unwritten band is flat to the bit.
    public static func bandsCarryPicture(output: URL, bands: Int, samples: Int = 6) throws -> String {
        let asset = AVURLAsset(url: output)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration > 0, bands > 0 else { return "bands: nothing to check" }

        var spreadPerBand = [Double](repeating: 0, count: bands)
        var counted = 0
        for i in 0..<samples {
            // Skipping the first and last instant: a fade or a black tail there is legitimate and
            // would be reported as an empty band.
            let at = duration * (Double(i) + 1) / Double(samples + 1)
            guard let image = try? generator.copyCGImage(at: CMTime(seconds: at, preferredTimescale: 600),
                                                         actualTime: nil) else { continue }
            let width = image.width, height = image.height
            var grey = [UInt8](repeating: 0, count: width * height)
            guard let context = CGContext(data: &grey, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { continue }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            counted += 1
            for band in 0..<bands {
                let from = height * band / bands, to = height * (band + 1) / bands
                var sum = 0.0, sumSquares = 0.0, n = 0.0
                for y in stride(from: from, to: to, by: 3) {
                    for x in stride(from: 0, to: width, by: 3) {
                        let value = Double(grey[y * width + x])
                        sum += value; sumSquares += value * value; n += 1
                    }
                }
                guard n > 0 else { continue }
                let mean = sum / n
                spreadPerBand[band] += (sumSquares / n - mean * mean).squareRoot()
            }
        }
        guard counted > 0 else { return "bands: could not read the output" }

        // A single code value everywhere gives a spread of 0. Camera noise alone clears 1; anything
        // with a person in it is far above. 2 is well clear of noise and well below content.
        let empty = (0..<bands).filter { spreadPerBand[$0] / Double(counted) < 2 }
        let detail = (0..<bands).map { String(format: "%d:%.0f", $0 + 1, spreadPerBand[$0] / Double(counted)) }
            .joined(separator: "  ")
        if empty.isEmpty {
            return "bands:     all \(bands) carry picture across \(counted) sampled frame(s)  (spread \(detail))"
        }
        return "bands:     BAND \(empty.map { String($0 + 1) }.joined(separator: ", ")) IS BLANK across "
            + "\(counted) sampled frame(s) — that panel got no clip  (spread \(detail))"
    }

    public static func check(source: URL, output: URL, samples: Int = 8,
                             intendedAspect: Double? = nil) throws -> RenderSelfCheck {
        // One frame every few seconds is plenty: the faults this catches are gross ones.
        let options = VisionIndexOptions(samplesPerSecond: 0.4, detectFaces: true,
                                          detectText: false, detectHands: false, accurateText: false)
        let indexer = VisionIndexer(options: options)
        let sourceVision = try indexer.index(url: source, asset: NodeID(contentOf: source.path),
                                             maximumFrames: samples)
        let outputVision = try indexer.index(url: output, asset: NodeID(contentOf: output.path),
                                             maximumFrames: samples)

        func faceFraction(_ index: VisionIndex) -> Double {
            guard !index.frames.isEmpty else { return 0 }
            return Double(index.frames.filter { !$0.faces.isEmpty }.count) / Double(index.frames.count)
        }
        let sourceFaces = faceFraction(sourceVision)
        let outputFaces = faceFraction(outputVision)
        let sourceAspect = Double(sourceVision.width) / Double(max(sourceVision.height, 1))
        let outputAspect = Double(outputVision.width) / Double(max(outputVision.height, 1))

        var findings: [RenderSelfCheck.Finding] = []
        // The check that would have caught the rotation bug in one pass.
        if sourceFaces > 0.5, sourceFaces - outputFaces > RenderVerifier.subjectDropTolerance {
            findings.append(.init(
                what: "the subject has gone missing",
                detail: String(format: "on screen in %.0f%% of the source and only %.0f%% of the output — "
                               + "the picture is being cropped, rotated or framed wrongly",
                               sourceFaces * 100, outputFaces * 100)))
        }
        let expected = intendedAspect ?? sourceAspect
        if abs(expected - outputAspect) > RenderVerifier.aspectTolerance {
            findings.append(.init(
                what: "the shape of the frame changed",
                detail: String(format: "expected %.2f and the output is %d×%d (%.2f)%@",
                               expected, outputVision.width, outputVision.height, outputAspect,
                               intendedAspect == nil
                                 ? " — the source is \(sourceVision.width)×\(sourceVision.height), so it is being reframed by accident"
                                 : " — the requested reframe did not come out at the shape asked for")))
        }
        if outputVision.frames.isEmpty {
            findings.append(.init(what: "nothing decoded", detail: "the output could not be read back at all"))
        }
        return RenderSelfCheck(sourceFaceFraction: sourceFaces, outputFaceFraction: outputFaces,
                               sourceAspect: sourceAspect, outputAspect: outputAspect,
                               framesChecked: outputVision.frames.count, findings: findings)
    }
}
