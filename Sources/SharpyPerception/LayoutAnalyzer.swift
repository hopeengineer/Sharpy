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
    /// Whether panels RESUME where they stopped, or cut to somewhere else.
    ///
    /// The distinction a viewer feels and cannot name, and it is measurable rather than something
    /// to be told: a panel that pauses and carries on shows almost the same picture either side of
    /// its freeze — a hand stops mid-gesture and completes it seconds later. A panel that cuts
    /// shows a different moment, and the picture jumps.
    ///
    /// It decides the whole construction: assembled as cuts, each return would restart the panel
    /// somewhere arbitrary and every gesture would break.
    public let resumesAfterFreeze: Bool?
    /// How alike the picture is either side of a freeze, averaged. 1 is a perfect resume.
    public let resumeSimilarity: Double?

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

    /// How far apart consecutive panels run during the opening, in seconds.
    ///
    /// `offsets` holds each panel's lag against the first; the step between them is what has to be
    /// applied when building the same opening from a single take. Averaged over the steps actually
    /// measured, so one panel the tracker could not lock onto does not lose the whole figure.
    ///
    /// Nil when nothing was measured, which stays distinct from a measured zero — panels opening in
    /// unison is a real answer, and guessing one would put an echo on an edit that has none.
    public var echoStepSeconds: Double? {
        let measured = offsets.compactMap { $0 }
        guard measured.count > 1 else { return nil }
        let steps = zip(measured.dropFirst(), measured).map { $0 - $1 }.filter { $0 > 0 }
        guard !steps.isEmpty else { return nil }
        return steps.reduce(0, +) / Double(steps.count)
    }

    /// One stretch where a single panel holds the floor.
    public struct Visit: Sendable {
        public let panel: Int
        public let start: Double, end: Double
        public var seconds: Double { end - start }
    }

    /// The order the edit visits its panels, and how long it stays each time.
    ///
    /// This is the mechanic that makes the format work, and it is invisible to any single frame: the
    /// reference does not present top, then middle, then bottom once. It RETURNS to each of them
    /// several times, and each return adds another piece — introduce, tease, explain, deepen, pay
    /// off. That rhythm is the reason it holds attention, and it is entirely a property of the
    /// sequence rather than of the layout.
    ///
    /// A panel holds the floor when it is the only one moving. Stretches where several move are the
    /// echo opening and belong to no single panel.
    public var visits: [Visit] {
        guard isSplitScreen, let n = activity.first?.motion.count, n > 0 else { return [] }
        var out: [Visit] = []
        var current: (panel: Int, start: Int)?
        func time(_ i: Int) -> Double { (sampledAt.first ?? 0) + Double(i) * secondsPerSample }

        for i in 0..<n {
            let moving = activity.filter { i < $0.motion.count && $0.motion[i] > $0.threshold }
            let holder = moving.count == 1 ? moving[0].index : nil
            if let holder, current?.panel == holder { continue }
            if let open = current {
                // Ignore flickers: a panel that "holds the floor" for a fifth of a second is a
                // measurement artefact, not an edit.
                if time(i) - time(open.start) >= 0.4 {
                    out.append(Visit(panel: open.panel, start: time(open.start), end: time(i)))
                }
                current = nil
            }
            if let holder { current = (holder, i) }
        }
        if let open = current, time(n) - time(open.start) >= 0.4 {
            out.append(Visit(panel: open.panel, start: time(open.start), end: time(n)))
        }
        // Merge consecutive turns by the same panel. A speaker pausing mid-sentence stops the
        // picture moving for a moment, and counting that as a new visit turned one turn into three
        // — which inflates the return count, the very number this is here to measure.
        var merged: [Visit] = []
        for visit in out {
            if let last = merged.last, last.panel == visit.panel, visit.start - last.end < 1.2 {
                merged[merged.count - 1] = Visit(panel: last.panel, start: last.start, end: visit.end)
            } else {
                merged.append(visit)
            }
        }
        return merged
    }

    /// How many separate times each panel takes the floor. More than one means the edit RETURNS.
    public var returnsPerPanel: [Int: Int] {
        var counts: [Int: Int] = [:]
        for visit in visits { counts[visit.panel, default: 0] += 1 }
        return counts
    }

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
        let sequence = visits
        if !sequence.isEmpty {
            let counts = returnsPerPanel
            let order = sequence.map { "\($0.panel + 1)" }.joined(separator: " → ")
            lines.append("  ORDER: \(order)")
            let returning = counts.filter { $0.value > 1 }
            if !returning.isEmpty {
                lines.append("  RETURNS: " + counts.sorted { $0.key < $1.key }
                    .map { "panel \($0.key + 1) takes the floor \($0.value)×" }.joined(separator: ", "))
                lines.append("  The edit does not present each panel once — it goes BACK to them, and each "
                             + "return adds another piece. That rhythm is the format, not the split.")
            }
            let average = sequence.reduce(0.0) { $0 + $1.seconds } / Double(sequence.count)
            lines.append(String(format: "  each turn lasts %.1f s on average", average))
        }
        if let resumes = resumesAfterFreeze, let score = resumeSimilarity {
            lines.append(resumes
                ? String(format: "  PAUSE, NOT CUT: a panel resumes where it stopped (%.1f%% identical across its freeze). "
                         + "Each panel is ONE continuous take being paused and unpaused, so a gesture stops mid-air and "
                         + "finishes seconds later. Assembling it as separate clips would break every gesture.", score * 100)
                : String(format: "  CUTS: panels jump to a different moment after a freeze (only %.1f%% identical), "
                         + "so each turn is its own clip rather than a paused take.", score * 100))
        }
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
                                  activity: [], offsets: [], sampledAt: times, secondsPerSample: interval,
                                  resumesAfterFreeze: nil, resumeSimilarity: nil)
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

        // Does a panel carry on from where it stopped, or jump somewhere else?
        //
        // Compare the picture just before a freeze with the picture just after it ends. Nearly the
        // same means it resumed; different means it cut. Averaged over every freeze in the piece,
        // because one comparison could be a coincidence.
        var resumeScores: [Double] = []
        for panel in 0..<best.panels {
            var frozenSince: Int?
            for i in 1..<best.sigs.count {
                let moved = distance(best.sigs[i][panel], best.sigs[i - 1][panel])
                let still = moved < 1e-4
                if still, frozenSince == nil { frozenSince = i - 1 }
                if !still, let since = frozenSince {
                    // Long enough to be a deliberate hold rather than a quiet moment.
                    if i - since >= 3 {
                        resumeScores.append(1 - distance(best.sigs[since][panel], best.sigs[i][panel]))
                    }
                    frozenSince = nil
                }
            }
        }
        let resumeSimilarity = resumeScores.isEmpty ? nil
            : resumeScores.reduce(0, +) / Double(resumeScores.count)

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

        // How far each panel lags the first — measured ONLY across the opening.
        //
        // Over the whole piece the panels take turns, so panel 2's motion has nothing to line up
        // against panel 1's and the correlation returns noise. During the opening they are all
        // delivering the same line a beat apart, which is the only stretch where a lag between them
        // is a real quantity. Correlating over everything returned nothing on a reel whose echo is
        // plainly audible.
        var offsets: [Double?] = []
        let maximumLag = Int((3.0 / interval).rounded())
        let together = activity.isEmpty ? nil : LayoutAnalysis(
            motionThreshold: threshold, panels: best.panels, stacked: best.stacked,
            panelSimilarity: best.similarity, activity: activity, offsets: [],
            sampledAt: times, secondsPerSample: interval,
            resumesAfterFreeze: nil, resumeSimilarity: nil).simultaneousOpening

        // The echo is read off the PICTURES, not off the motion.
        //
        // Correlating motion asked whether a shifted copy of panel 1's movement matched panel 2's,
        // and demanded it beat "no shift" by a fifth. During the opening the panels are 94% alike
        // already, so no shift can win by that much and a plainly audible echo measured as none.
        //
        // What is actually true of an echo is simpler and much stronger: panel 2 is SHOWING what
        // panel 1 showed a moment ago. So panel 0's frame at i is compared against panel k's frame
        // at i + shift, and the shift that matches best is the lag. Different crops of the frame
        // never match perfectly, which does not matter — the minimum is what carries the answer,
        // not its depth.
        func echoShift(_ panel: Int) -> Int? {
            guard let together else { return nil }
            let from = max(Int((together.lowerBound / interval).rounded()), 0)
            let to = min(Int((together.upperBound / interval).rounded()), best.sigs.count)
            guard to - from > 6 else { return nil }
            // An echo is a beat, not a scene: past a second it is two people talking, not one voice
            // arriving twice.
            let maximum = min(Int((1.0 / interval).rounded()), (to - from) / 2)
            guard maximum >= 1 else { return nil }
            func score(_ shift: Int) -> Double {
                var sum = 0.0, n = 0
                for i in from..<to where i + shift >= 0 && i + shift < best.sigs.count {
                    sum += distance(best.sigs[i][0], best.sigs[i + shift][panel]); n += 1
                }
                return n > 4 ? sum / Double(n) : .infinity
            }
            let atZero = score(0)
            var bestShift = 0, bestScore = atZero
            for shift in 1...maximum {
                let s = score(shift)
                if s < bestScore { bestScore = s; bestShift = shift }
            }
            // A real lag sits inside the search, not on its edge, and is a visible improvement on
            // no lag at all. 2% is small because the floor here is the difference between two crops
            // of the frame, which no shift can remove.
            guard bestShift > 0, bestShift < maximum, bestScore < atZero * 0.98 else { return nil }
            return bestShift
        }

        for panel in 0..<best.panels {
            if panel == 0 { offsets.append(0); continue }
            // The opening first, because that is where an echo lives. Failing that, the turn-taking
            // lag over the whole piece, which is a different quantity and a weaker one.
            if let shift = echoShift(panel) {
                offsets.append(Double(shift) * interval)
            } else {
                offsets.append(lag(activity[0].motion, activity[panel].motion, maximum: maximumLag)
                    .map { Double($0) * interval })
            }
        }

        return LayoutAnalysis(motionThreshold: threshold, panels: best.panels, stacked: best.stacked,
                              panelSimilarity: best.similarity, activity: activity,
                              offsets: offsets, sampledAt: times, secondsPerSample: interval,
                              resumesAfterFreeze: resumeSimilarity.map { $0 > 0.985 },
                              resumeSimilarity: resumeSimilarity)
    }
}
