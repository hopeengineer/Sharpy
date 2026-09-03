// Subject, on-screen text and hands, from Apple Vision.
//
// Measured on the user's real reel against 22 hand-labelled frames: face count exact 22/22, hands
// 21/21, on-screen text recall 89/90 lines, at 0.63 s per frame with OCR and hand pose enabled —
// beating every local VLM tested on speed at equal or better accuracy, with no model files and
// ~80 MB of process memory. So these facts come from Vision, and the VLM is reserved for the
// questions Vision cannot answer (what is happening, what kind of shot this is).
//
// Vision returns normalised, bottom-left-origin coordinates. Everything here converts once, to
// top-left-origin pixels, because every downstream consumer — safe-area checks, the compositor's
// ID pass, an agent reading a box — thinks in top-left pixels.

import Foundation
import AVFoundation
import Vision
import SharpyEngine

public struct DetectedBox: Sendable, Equatable, Codable {
    /// Top-left origin, in pixels of the frame it was found in.
    public let x: Double, y: Double, width: Double, height: Double
    public let confidence: Double
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var area: Double { width * height }

    public func intersects(_ o: DetectedBox) -> Bool {
        x < o.maxX && o.x < maxX && y < o.maxY && o.y < maxY
    }
}

public struct TextLine: Sendable, Equatable, Codable {
    public let text: String
    public let box: DetectedBox
}

/// Everything Vision saw in one frame.
public struct FrameObservation: Sendable, Codable {
    public let time: TimeValue
    public let faces: [DetectedBox]
    public let hands: [DetectedBox]
    public let text: [TextLine]
    public var personVisible: Bool { !faces.isEmpty }
    public var faceCount: Int { faces.count }
}

public struct VisionIndexOptions: Sendable {
    /// Frames per second to sample. 1 is plenty for subject tracking on talking-head material.
    public var samplesPerSecond: Double
    public var detectFaces: Bool
    public var detectText: Bool
    public var detectHands: Bool
    /// OCR accuracy. `.accurate` roughly halves throughput; on the reel it read 89/90 lines.
    public var accurateText: Bool
    public init(samplesPerSecond: Double = 1, detectFaces: Bool = true, detectText: Bool = true,
                detectHands: Bool = true, accurateText: Bool = true) {
        self.samplesPerSecond = samplesPerSecond; self.detectFaces = detectFaces
        self.detectText = detectText; self.detectHands = detectHands; self.accurateText = accurateText
    }
}

public struct VisionIndex: Sendable, Codable {
    public let asset: NodeID
    public let frames: [FrameObservation]
    public let width: Int
    public let height: Int

    /// The observation nearest an instant.
    public func observation(at t: TimeValue) -> FrameObservation? {
        frames.min { abs(($0.time - t).seconds.doubleValue) < abs(($1.time - t).seconds.doubleValue) }
    }

    /// Ranges where a face was visible, coalescing across the sampling interval.
    public func personVisibleRanges(tolerance: TimeValue) -> [TimeRange] {
        var out: [TimeRange] = []
        for f in frames where f.personVisible {
            let r = TimeRange(start: f.time, end: f.time + tolerance)
            if let last = out.last, !(last.end < r.start) {
                out[out.count - 1] = TimeRange(start: last.start, end: max(last.end, r.end))
            } else { out.append(r) }
        }
        return out
    }

    /// Every distinct line of on-screen text, in first-appearance order.
    public var allText: [String] {
        var seen = Set<String>(); var out: [String] = []
        for f in frames { for l in f.text where !seen.contains(l.text) { seen.insert(l.text); out.append(l.text) } }
        return out
    }
}

public enum VisionIndexError: Error, CustomStringConvertible {
    case noVideoTrack(URL)
    public var description: String {
        switch self { case .noVideoTrack(let u): return "no video track in \(u.lastPathComponent)" }
    }
}

public struct VisionIndexer {
    public let options: VisionIndexOptions
    public init(options: VisionIndexOptions = VisionIndexOptions()) { self.options = options }

    public func index(url: URL, asset: NodeID) throws -> VisionIndex {
        let avAsset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = avAsset.tracks(withMediaType: .video).first else { throw VisionIndexError.noVideoTrack(url) }

        let reader = try AVAssetReader(asset: avAsset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw VisionIndexError.noVideoTrack(url) }

        let size = track.naturalSize.applying(track.preferredTransform)
        let w = Int(abs(size.width).rounded()), h = Int(abs(size.height).rounded())
        let interval = 1.0 / max(options.samplesPerSecond, 0.0001)

        var frames: [FrameObservation] = []
        var nextSampleAt = 0.0

        while let sb = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            let seconds = Double(pts.value) / Double(pts.timescale)
            guard seconds + 1e-9 >= nextSampleAt, let pixels = CMSampleBufferGetImageBuffer(sb) else { continue }
            nextSampleAt = seconds + interval

            let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up)
            var requests: [VNRequest] = []
            let faceRequest = VNDetectFaceRectanglesRequest()
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = options.accurateText ? .accurate : .fast
            let handRequest = VNDetectHumanHandPoseRequest()
            if options.detectFaces { requests.append(faceRequest) }
            if options.detectText { requests.append(textRequest) }
            if options.detectHands { requests.append(handRequest) }
            guard !requests.isEmpty else { continue }
            try handler.perform(requests)

            // Vision's normalised rect has a bottom-left origin; flip once, here.
            func box(_ r: CGRect, _ confidence: Float) -> DetectedBox {
                DetectedBox(x: Double(r.minX) * Double(w),
                            y: (1.0 - Double(r.maxY)) * Double(h),
                            width: Double(r.width) * Double(w),
                            height: Double(r.height) * Double(h),
                            confidence: Double(confidence))
            }

            let faces = (faceRequest.results ?? []).map { box($0.boundingBox, $0.confidence) }
            let text = (textRequest.results ?? []).compactMap { obs -> TextLine? in
                guard let top = obs.topCandidates(1).first else { return nil }
                return TextLine(text: top.string, box: box(obs.boundingBox, obs.confidence))
            }
            // A hand pose has no rect, so derive one from the joints that were actually found.
            let hands: [DetectedBox] = (handRequest.results ?? []).compactMap { obs in
                guard let points = try? obs.recognizedPoints(.all) else { return nil }
                let valid = points.values.filter { $0.confidence > 0.3 }
                guard !valid.isEmpty else { return nil }
                let xs = valid.map { Double($0.location.x) }, ys = valid.map { Double($0.location.y) }
                let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
                return DetectedBox(x: minX * Double(w), y: (1.0 - maxY) * Double(h),
                                   width: (maxX - minX) * Double(w), height: (maxY - minY) * Double(h),
                                   confidence: Double(obs.confidence))
            }

            frames.append(FrameObservation(time: TimeValue(seconds: Rational(Int64(pts.value), Int64(pts.timescale))),
                                           faces: faces, hands: hands, text: text))
        }
        reader.cancelReading()
        return VisionIndex(asset: asset, frames: frames, width: w, height: h)
    }
}
