// Reading an edit's STRUCTURE off the reference, not its still frames.
//
// A screenshot cannot show what matters about the split-screen format. The first seconds of the
// reference run all three panels saying the SAME thing a beat apart, which reads as an echo — and
// every frame of it looks like "three panels with a person in them". The structure is entirely in
// time: which panel is moving, which is held, and how far apart the same content appears in each.
//
// All three are measurable:
//
//   PANELS      candidate splits are tested and scored. Bands showing the same person at the same
//               moment are far more similar to each other than bands of an ordinary frame are, and
//               the split that maximises that similarity is the one the editor used.
//   ACTIVITY    frame-to-frame difference PER BAND. A held panel is flat; a playing one is not.
//               This is what says "two are frozen while the third talks", which no still shows.
//   OFFSET      cross-correlation between two bands' activity over time. If the middle band is
//               doing what the top band did a second ago, that lag IS the echo.
//
// The point is recognition rather than description: given a reference, say what the format IS, so
// the same format can be applied to somebody else's footage.

import Foundation
import AVFoundation
import Accelerate
import SharpyEngine

public struct PanelActivity: Sendable {
    public let index: Int
    /// Motion per sampled instant, 0…1. Near zero means held on a frame.
    public let motion: [Double]
    /// Threshold separating held from playing, chosen from the material.
    public let threshold: Double
    /// Fraction of the piece this panel is moving.
    public var activeFraction: Double {
        guard !motion.isEmpty else { return 0 }
        return Double(motion.filter { $0 > threshold }.count) / Double(motion.count)
    }
}

public struct LayoutAnalysis: Sendable {
    /// Threshold separating held panels from playing ones, found in the material by Otsu's method.
    ///
    /// Not a constant. A fixed 0.012 sat at the 90th percentile of this reference's motion and
    /// classified almost everything as frozen — the numbers looked plausible and were wrong. The
    /// distribution is genuinely two clusters (a held panel is near zero, a playing one is not), so
    /// the threshold that best separates them is a property of the footage, not of my guess.
    public let motionThreshold: Double

    public let panels: Int
    /// Horizontal bands (stacked) or vertical ones (side by side).
    public let stacked: Bool
    /// How alike the panels are at the same instant, 0…1. High means they carry the same content.
    public let panelSimilarity: Double
    public let activity: [PanelActivity]
    /// Seconds by which panel *i* lags panel 0, when a lag was found.
    public let offsets: [Double?]
    public let sampledAt: [Double]
    public let secondsPerSample: Double

    /// All panels moving at once, which is the echo opening rather than the sequential body.
    public var simultaneousFraction: Double {
        guard !activity.isEmpty, let n = activity.first?.motion.count, n > 0 else { return 0 }
        var together = 0
        for i in 0..<n where activity.allSatisfy({ i < $0.motion.count && $0.motion[i] > $0.threshold }) {
            together += 1
        }
        return Double(together) / Double(n)
    }

    public var isSplitScreen: Bool { panels > 1 && panelSimilarity > 0.55 }

    /// The stretch at the start where every panel runs at once, in seconds.
    ///
    /// Reported as a RANGE rather than a percentage because "16% of the piece" is true of an
    /// opening hook and of five scattered moments, and those are different formats. The claim
    /// "they run together, then take turns" is only worth making if the together part is at the
    /// beginning.
    public var simultaneousOpening: ClosedRange<Double>? {
        guard !activity.isEmpty, let n = activity.first?.motion.count, n > 0 else { return nil }
        func allMoving(_ i: Int) -> Bool {
            activity.allSatisfy { i < $0.motion.count && $0.motion[i] > $0.threshold }
        }
        // Walk forward from the start, allowing a couple of quiet samples so a breath does not end
        // the run.
        var last = -1, gap = 0
        for i in 0..<n {
            if allMoving(i) { last = i; gap = 0 }
            else { gap += 1; if gap > 3 && last >= 0 { break } }
        }
        guard last >= 2 else { return nil }
        let start = sampledAt.first ?? 0
        return start...(start + Double(last) * secondsPerSample)
    }

    /// Motion values sorted, for choosing a threshold from the material rather than by guess.
    public var motionQuantiles: [Double] {
        let all = activity.flatMap(\.motion).sorted()
        guard !all.isEmpty else { return [] }
        return [0.1, 0.25, 0.5, 0.75, 0.9].map { all[min(Int(Double(all.count - 1) * $0), all.count - 1)] }
    }

    public var summary: String {
        guard isSplitScreen else {
            return String(format: "layout: single frame (best split scored %.2f similarity — not a split screen)",
                          panelSimilarity)
        }
        var lines = [String(format: "layout: %d %@ panels carrying the same content (similarity %.2f)",
                            panels, stacked ? "stacked" : "side-by-side", panelSimilarity)]
        for panel in activity {
            lines.append(String(format: "  panel %d: moving %.0f%% of the time", panel.index + 1,
                                panel.activeFraction * 100))
        }
        let echoes = offsets.enumerated().compactMap { (i, o) -> String? in
            guard let o, i > 0 else { return nil }
            return String(format: "panel %d lags panel 1 by %.2f s", i + 1, o)
        }
        if !echoes.isEmpty {
            lines.append("  echo: " + echoes.joined(separator: ", ")
                         + " — the same delivery offset between panels, which is what reads as several voices")
        }
        lines.append(String(format: "  all panels move together %.0f%% of the time", simultaneousFraction * 100))
        if let opening = simultaneousOpening {
            lines.append(String(format: "  OPENING: all %d panels run together for the first %.1f s, then they take turns — "
                                + "that is the hook, and it is why the audio reads as several voices",
                                panels, opening.upperBound - opening.lowerBound))
        }
        return lines.joined(separator: "\n")
    }
}

public enum LayoutAnalyzer {
    /// Downsampled luma signature of a rectangle: coarse enough that compression noise does not
    /// register, fine enough that a moving face does.
    static func signature(_ luma: [Float], width: Int, height: Int,
                          y0: Int, y1: Int, x0: Int, x1: Int, cells: Int = 24) -> [Float] {
        var out = [Float](repeating: 0, count: cells * cells)
        let h = max(y1 - y0, 1), w = max(x1 - x0, 1)
        for cy in 0..<cells {
            for cx in 0..<cells {
                var sum: Float = 0, count: Float = 0
                let ys = y0 + cy * h / cells, ye = y0 + (cy + 1) * h / cells
                let xs = x0 + cx * w / cells, xe = x0 + (cx + 1) * w / cells
                var y = ys
                while y < min(ye, height) {
                    var x = xs
                    while x < min(xe, width) { sum += luma[y * width + x]; count += 1; x += 1 }
                    y += 1
                }
                out[cy * cells + cx] = count > 0 ? sum / count : 0
            }
        }
        return out
    }

    /// Otsu's method: the threshold that minimises the variance WITHIN the two groups it makes.
    /// The standard way to split a bimodal distribution, and the distribution here genuinely is
    /// bimodal — a held panel and a playing one are different things, not two ends of a scale.
    static func otsu(_ values: [Double], bins: Int = 128) -> Double {
        guard values.count > 8, let high = values.max(), high > 0 else { return 0.005 }
        // In the LOG domain. Motion here spans four orders of magnitude — a held panel is 1e-6 and
        // a talking one 1e-2 — so a linear histogram drops almost every sample into the first bin
        // and Otsu picks a threshold up in the tail. Measured on the reference: it chose 0.0123
        // when 48% of samples sat below 1e-4, and called three panels frozen that were talking.
        let floor = 1e-6
        let logs = values.map { log10(max($0, floor)) }
        let low = logs.min()!, top = logs.max()!
        guard top > low else { return high / 2 }
        var histogram = [Int](repeating: 0, count: bins)
        for v in logs {
            histogram[min(Int((v - low) / (top - low) * Double(bins - 1)), bins - 1)] += 1
        }
        let total = Double(values.count)
        var sumAll = 0.0
        for (i, count) in histogram.enumerated() { sumAll += Double(i) * Double(count) }
        var sumBelow = 0.0, weightBelow = 0.0, bestVariance = -1.0, bestBin = 0
        for (i, count) in histogram.enumerated() {
            weightBelow += Double(count)
            if weightBelow == 0 { continue }
            let weightAbove = total - weightBelow
            if weightAbove == 0 { break }
            sumBelow += Double(i) * Double(count)
            let meanBelow = sumBelow / weightBelow
            let meanAbove = (sumAll - sumBelow) / weightAbove
            let variance = weightBelow * weightAbove * (meanBelow - meanAbove) * (meanBelow - meanAbove)
            if variance > bestVariance { bestVariance = variance; bestBin = i }
        }
        return pow(10, low + Double(bestBin) / Double(bins - 1) * (top - low))
    }

    static func distance(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var total: Double = 0
        for (x, y) in zip(a, b) { total += Double(abs(x - y)) }
        return total / Double(a.count) / 255.0
    }

    /// Cross-correlation lag, in samples, that best aligns `b` onto `a`.
    ///
    /// Reported only when the best alignment is clearly better than no alignment — otherwise two
    /// unrelated panels would always produce some lag, and a confident wrong number is worse than
    /// saying nothing.
    static func lag(_ a: [Double], _ b: [Double], maximum: Int) -> Int? {
        guard a.count > 4, b.count == a.count else { return nil }
        func score(_ shift: Int) -> Double {
            var sum = 0.0, n = 0
            for i in 0..<a.count where i + shift >= 0 && i + shift < b.count {
                sum += abs(a[i] - b[i + shift]); n += 1
            }
            return n > 0 ? sum / Double(n) : .infinity
        }
        let baseline = score(0)
        var bestShift = 0, bestScore = baseline
        for shift in -maximum...maximum where shift != 0 {
            let s = score(shift)
            if s < bestScore { bestScore = s; bestShift = shift }
        }
        // Needs to beat "no offset" by a clear margin to be worth reporting.
        // A best lag sitting ON the search boundary means the true alignment is outside the window,
        // or there is none — either way the number would be an artefact of where I stopped looking.
        guard bestShift != 0, abs(bestShift) < maximum,
              bestScore < baseline * 0.8 else { return nil }
        return bestShift
    }

    public static func analyse(url: URL, samplesPerSecond: Double = 6,
                               maximumSeconds: Double = 30) throws -> LayoutAnalysis {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw VisionIndexError.noVideoTrack(url)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw VisionIndexError.noVideoTrack(url) }

        let interval = 1.0 / max(samplesPerSecond, 0.1)
        var times: [Double] = []
        // Signatures for each candidate split, per sampled frame.
        let candidates = [2, 3, 4]
        var stackedSigs: [Int: [[[Float]]]] = [:]     // panels -> frame -> band -> signature
        var sideSigs: [Int: [[[Float]]]] = [:]
        for n in candidates { stackedSigs[n] = []; sideSigs[n] = [] }
        var nextAt = 0.0

        while let sb = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            let seconds = Double(pts.value) / Double(max(pts.timescale, 1))
            guard seconds >= nextAt, seconds <= maximumSeconds,
                  let pixels = CMSampleBufferGetImageBuffer(sb) else {
                if seconds > maximumSeconds { break }
                continue
            }
            nextAt = seconds + interval
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            let w = CVPixelBufferGetWidthOfPlane(pixels, 0)
            let h = CVPixelBufferGetHeightOfPlane(pixels, 0)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
            var luma = [Float](repeating: 0, count: w * h)
            if let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) {
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                luma.withUnsafeMutableBufferPointer { out in
                    for y in 0..<h {
                        vDSP_vfltu8(bytes + y * stride, 1, out.baseAddress! + y * w, 1, vDSP_Length(w))
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)

            for n in candidates {
                var bands: [[Float]] = []
                for i in 0..<n {
                    bands.append(signature(luma, width: w, height: h,
                                           y0: i * h / n, y1: (i + 1) * h / n, x0: 0, x1: w))
                }
                stackedSigs[n]!.append(bands)
                var columns: [[Float]] = []
                for i in 0..<n {
                    columns.append(signature(luma, width: w, height: h,
                                             y0: 0, y1: h, x0: i * w / n, x1: (i + 1) * w / n))
                }
                sideSigs[n]!.append(columns)
            }
            times.append(seconds)
        }
        guard times.count > 4 else {
            return LayoutAnalysis(motionThreshold: 0, panels: 1, stacked: true, panelSimilarity: 0,
                                  activity: [], offsets: [], sampledAt: times, secondsPerSample: interval)
        }

        // The split whose bands are most alike is the one the editor used.
        var best: (panels: Int, stacked: Bool, similarity: Double, sigs: [[[Float]]]) = (1, true, 0, [])
        for (isStacked, table) in [(true, stackedSigs), (false, sideSigs)] {
            for n in candidates {
                guard let frames = table[n], !frames.isEmpty else { continue }
                var total = 0.0, count = 0.0
                for bands in frames {
                    for i in 0..<bands.count {
                        for j in (i + 1)..<bands.count {
                            total += 1 - distance(bands[i], bands[j]); count += 1
                        }
                    }
                }
                let similarity = count > 0 ? total / count : 0
                if similarity > best.similarity { best = (n, isStacked, similarity, frames) }
            }
        }

        // Motion per panel over time.
        var rawMotion: [[Double]] = []
        for panel in 0..<best.panels {
            var motion: [Double] = []
            for i in 1..<best.sigs.count {
                motion.append(distance(best.sigs[i][panel], best.sigs[i - 1][panel]))
            }
            rawMotion.append(motion)
        }
        // One threshold across all panels: they are the same footage in the same room, so a
        // per-panel threshold would let a quiet panel set a low bar and count its own stillness as
        // movement.
        let threshold = otsu(rawMotion.flatMap { $0 })
        let activity = rawMotion.enumerated().map {
            PanelActivity(index: $0.offset, motion: $0.element, threshold: threshold)
        }

        // How far each panel lags the first.
        var offsets: [Double?] = []
        let maximumLag = Int((3.0 / interval).rounded())
        for panel in 0..<best.panels {
            if panel == 0 { offsets.append(0); continue }
            let shift = lag(activity[0].motion, activity[panel].motion, maximum: maximumLag)
            offsets.append(shift.map { Double($0) * interval })
        }

        return LayoutAnalysis(motionThreshold: threshold, panels: best.panels, stacked: best.stacked,
                              panelSimilarity: best.similarity, activity: activity,
                              offsets: offsets, sampledAt: times, secondsPerSample: interval)
    }
}
