// Shot boundaries, from the pixels.
//
// Method: decode to a small proxy (the decoder scales for free, so this costs almost nothing),
// build a per-frame HSV-ish histogram, and score consecutive frames by histogram distance. This is
// the classic content detector, measured elsewhere at F1 0.75–0.82 against neural methods — good
// enough for a *shot inventory*, which is what L2 needs. Cut-frame precision never comes from here;
// it comes from the decision record, where a cut is a decision with a basis, not a guess.
//
// The threshold adapts to the material. A fixed one is wrong twice over: a locked-off interview
// has almost no frame-to-frame change, so a fixed threshold finds nothing, while handheld footage
// exceeds it constantly. So the score distribution is measured first and the threshold set from
// its own spread — the same principle as judging silence against the recording's own speech level.

import Foundation
import AVFoundation
import CoreVideo
import SharpyEngine

public struct Shot: Sendable, Equatable, Codable {
    public let index: Int
    public let range: TimeRange
    /// Histogram distance at the cut into this shot; 0 for the first.
    public let boundaryScore: Double
    public var duration: TimeValue { range.duration }
}

public struct ShotIndex: Sendable, Codable {
    public let asset: NodeID
    public let shots: [Shot]
    /// Threshold the detector settled on, and the distribution it came from.
    public let threshold: Double
    public let medianScore: Double

    public func shot(at t: TimeValue) -> Shot? { shots.first { $0.range.contains(t) } }

    /// Median shot length — the single most descriptive pacing number for a cut piece.
    public var medianDuration: TimeValue {
        guard !shots.isEmpty else { return .zero }
        let sorted = shots.map(\.duration.seconds).sorted { $0 < $1 }
        return TimeValue(seconds: sorted[sorted.count / 2])
    }
}

public struct ShotDetectorOptions: Sendable {
    /// Proxy width the decoder scales to. 64 is enough for histogram comparison and keeps this
    /// bound by decode rather than by arithmetic.
    public var proxyWidth: Int
    /// How many multiples above the median score a frame must jump to count as a cut.
    public var sensitivity: Double
    /// Shots shorter than this are folded into the previous one — below about 6 frames a "shot"
    /// is a flash, a strobe, or a compression artefact, not an edit.
    public var minimumShotDuration: TimeValue
    public init(proxyWidth: Int = 64, sensitivity: Double = 6, minimumShotDuration: TimeValue = TimeValue(seconds: Rational(2, 10))) {
        self.proxyWidth = proxyWidth; self.sensitivity = sensitivity; self.minimumShotDuration = minimumShotDuration
    }
}

public enum ShotDetectorError: Error, CustomStringConvertible {
    case noVideoTrack(URL)
    public var description: String {
        switch self { case .noVideoTrack(let u): return "no video track in \(u.lastPathComponent)" }
    }
}

public struct ShotDetector {
    public let options: ShotDetectorOptions
    public init(options: ShotDetectorOptions = ShotDetectorOptions()) { self.options = options }

    /// 16 bins per channel over BGRA, normalised — cheap, and insensitive to small motion while
    /// still reacting strongly to a change of scene.
    private static func histogram(_ pb: CVPixelBuffer) -> [Double] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return [] }
        let p = base.assumingMemoryBound(to: UInt8.self)
        var bins = [Double](repeating: 0, count: 48)          // 16 per channel × 3
        for y in 0..<h {
            let row = p + y * stride
            for x in 0..<w {
                let px = row + x * 4
                bins[Int(px[2]) >> 4] += 1                     // R
                bins[16 + (Int(px[1]) >> 4)] += 1              // G
                bins[32 + (Int(px[0]) >> 4)] += 1              // B
            }
        }
        let total = Double(w * h)
        for i in bins.indices { bins[i] /= total }
        return bins
    }

    private static func distance(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var sum = 0.0
        for i in a.indices { sum += abs(a[i] - b[i]) }
        return sum / 3.0                                       // three channels each sum to 1
    }

    public func detect(url: URL, asset: NodeID) throws -> ShotIndex {
        let avAsset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = avAsset.tracks(withMediaType: .video).first else { throw ShotDetectorError.noVideoTrack(url) }

        let size = track.naturalSize.applying(track.preferredTransform)
        let aspect = abs(size.height) / max(abs(size.width), 1)
        let pw = options.proxyWidth, ph = max(Int(Double(pw) * aspect), 1)

        let reader = try AVAssetReader(asset: avAsset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: pw,
            kCVPixelBufferHeightKey as String: ph,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw ShotDetectorError.noVideoTrack(url) }

        // Pass one: score every frame transition.
        var times: [TimeValue] = []
        var scores: [Double] = []
        var previous: [Double]? = nil
        var lastTime = TimeValue.zero
        while let sb = output.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            let t = TimeValue(seconds: Rational(Int64(pts.value), Int64(pts.timescale)))
            let h = Self.histogram(pb)
            if let prev = previous { times.append(t); scores.append(Self.distance(prev, h)) }
            previous = h
            lastTime = t
        }
        reader.cancelReading()
        let duration = TimeValue(track.timeRange.duration)
        let end = duration.seconds > lastTime.seconds ? duration : lastTime

        guard !scores.isEmpty else {
            return ShotIndex(asset: asset, shots: [Shot(index: 0, range: TimeRange(start: .zero, end: end), boundaryScore: 0)],
                             threshold: 0, medianScore: 0)
        }

        // Pass two: a threshold from the material's own distribution, not a constant.
        let sorted = scores.sorted()
        let median = sorted[sorted.count / 2]
        // A floor keeps perfectly static footage (median ≈ 0) from turning noise into cuts.
        let threshold = max(median * options.sensitivity, 0.08)

        var boundaries: [(TimeValue, Double)] = []
        for (i, s) in scores.enumerated() where s > threshold { boundaries.append((times[i], s)) }

        // Build shots, folding away anything below the minimum length.
        var shots: [Shot] = []
        var start = TimeValue.zero
        var pendingScore = 0.0
        for (t, s) in boundaries {
            let candidate = TimeRange(start: start, end: t)
            if options.minimumShotDuration < candidate.duration {
                shots.append(Shot(index: shots.count, range: candidate, boundaryScore: pendingScore))
                start = t
                pendingScore = s
            }
        }
        if start < end { shots.append(Shot(index: shots.count, range: TimeRange(start: start, end: end), boundaryScore: pendingScore)) }
        if shots.isEmpty { shots = [Shot(index: 0, range: TimeRange(start: .zero, end: end), boundaryScore: 0)] }

        return ShotIndex(asset: asset, shots: shots, threshold: threshold, medianScore: median)
    }
}
