// Watching the edit, in a form an agent can reason about.
//
// One screenshot cannot show that a cut works. An edit succeeds or fails AT ITS BOUNDARIES, and a
// frame from the middle of a shot proves nothing about them. What an editor actually does is scrub
// across the cut — last frame out, first frame in — and judge the join.
//
// So this gives both halves of that:
//
//   MEASUREMENTS at every cut, which an agent can act on without seeing anything: how far the
//   picture jumped, whether the audio steps discontinuously (a click), whether a shot is too short
//   to register, whether on-screen text is cut mid-line.
//
//   A CONTACT SHEET, several frames either side of each cut in one image, because the numbers
//   cannot settle every question and "look at it" is a legitimate final step. Several frames, not
//   one — a single frame is exactly what fails to show a seam.
//
// The measurements come first on purpose. An agent that only looks is guessing from pixels; an
// agent with numbers can say WHY it thinks a cut is wrong, and that reason is auditable.

import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Accelerate
import SharpyEngine

public struct CutObservation: Sendable {
    public let atFrame: Int64
    public let time: TimeValue
    /// Mean absolute luma difference across the join, 0…255. Near zero on a continuous shot; large
    /// at a genuine shot change.
    public let lumaJump: Float
    /// Peak absolute sample step across the audio join, 0…2. A click is a large step; a clean cut
    /// on a zero crossing is near zero.
    public let audioStep: Float?
    /// Duration of the shot that ENDS here.
    public let outgoingDuration: TimeValue
    /// Duration of the shot that STARTS here.
    public let incomingDuration: TimeValue
    /// On-screen text immediately before and after the join, when a text source was supplied.
    ///
    /// This exists because the luma check misses the failure that matters most on talking-head
    /// material. Moving a segment of the author's reel produced a cut the numbers called clean —
    /// same person, same room, luma jump tiny — while the BURNED-IN GRAPHICS changed completely
    /// across the join, putting a "-46.0 dB" meter on screen before the line that explains it. It
    /// was invisible to every measurement and obvious in one glance at the contact sheet.
    public let textBefore: Set<String>?
    public let textAfter: Set<String>?

    /// A cut on continuous material — same framing, same subject — reads as a jump cut rather than
    /// a shot change. It is not automatically wrong (it is the dominant style of short-form) but it
    /// is the thing a person means by "does that cut work".
    public var looksLikeAJumpCut: Bool { lumaJump < 12 }
    /// Short enough that a viewer registers a flicker rather than a shot.
    public var isFlashFrame: Bool { incomingDuration.seconds.doubleValue < 0.2 }
    /// A step this large in one sample is audible as a click.
    public var hasAudibleClick: Bool { (audioStep ?? 0) > 0.15 }
    /// Burned-in text that was on screen is gone across the join, or arrives from nothing.
    ///
    /// NOT gated on the picture holding still, which was the first version of this check and was
    /// wrong: on the author's reel a moved segment produced a caption going 4 lines → 0 at a join
    /// whose luma jump was 21.6, so a "picture barely moved" condition never fired and the tool
    /// reported the cut clean. A caption interrupted mid-display is a fault whether or not the
    /// framing changed with it.
    public var textInterrupted: Bool {
        guard let textBefore, let textAfter else { return false }
        return (!textBefore.isEmpty && textAfter.isEmpty) || (textBefore.isEmpty && !textAfter.isEmpty)
    }
    /// Burned-in text replaced wholesale — one graphic gives way to a different one at the join.
    public var textReplacedWholesale: Bool {
        guard let textBefore, let textAfter, !textBefore.isEmpty, !textAfter.isEmpty else { return false }
        return textBefore.intersection(textAfter).isEmpty
    }

    public var notes: [String] {
        var out: [String] = []
        if isFlashFrame {
            out.append(String(format: "the shot after this lasts %.2f s — a viewer sees a flicker, not a shot",
                              incomingDuration.seconds.doubleValue))
        }
        if hasAudibleClick {
            out.append(String(format: "audio steps by %.2f across the join — audible as a click; cut on a zero crossing",
                              audioStep ?? 0))
        }
        if textInterrupted {
            let vanished = !(textBefore ?? []).isEmpty
            let lines = (vanished ? textBefore : textAfter) ?? []
            let sample = lines.sorted().prefix(2).joined(separator: ", ")
            out.append(vanished
                ? "on-screen text disappears at this cut — \"\(sample)\" was up and is gone. A caption cut mid-display reads as a mistake even when the picture is fine."
                : "on-screen text appears from nothing at this cut — \"\(sample)\". Check the line that sets it up is still before it.")
        }
        if textReplacedWholesale {
            let gone = (textBefore ?? []).subtracting(textAfter ?? []).sorted().prefix(2).joined(separator: ", ")
            let arrived = (textAfter ?? []).subtracting(textBefore ?? []).sorted().prefix(2).joined(separator: ", ")
            out.append("on-screen text is wholly replaced — \"\(gone)\" gives way to \"\(arrived)\". Check the new graphic is not arriving before the line that explains it.")
        }
        if looksLikeAJumpCut {
            out.append(String(format: "picture barely changes (luma jump %.1f) — this reads as a jump cut, not a shot change",
                              lumaJump))
        }
        return out
    }
}

public struct CutInspection: Sendable {
    public let observations: [CutObservation]
    /// Where the contact sheet was written, when one was asked for.
    public let contactSheet: URL?

    public var worthALook: [CutObservation] { observations.filter { !$0.notes.isEmpty } }

    public var summary: String {
        guard !observations.isEmpty else { return "cuts: none in this timeline" }
        var lines = ["cuts: \(observations.count) inspected, \(worthALook.count) worth a look"]
        // Every cut's NUMBERS, not only the flagged ones. A threshold is a judgement and this
        // tool's job is to let the agent make its own — showing only what tripped a rule hides
        // the cut that sits just under it, which is exactly the one worth arguing about.
        for o in observations.prefix(24) {
            var row = String(format: "  %7.2f s (frame %d)  luma jump %5.1f", o.time.seconds.doubleValue,
                             o.atFrame, o.lumaJump)
            if let step = o.audioStep { row += String(format: "  audio step %.3f", step) }
            row += String(format: "  shot %.2f s", o.incomingDuration.seconds.doubleValue)
            if let before = o.textBefore, let after = o.textAfter, !(before.isEmpty && after.isEmpty) {
                row += "  text \(before.count)→\(after.count)"
                if before.intersection(after).isEmpty { row += " (nothing in common)" }
            }
            lines.append(row)
            for note in o.notes { lines.append("     · " + note) }
        }
        if observations.count > 24 { lines.append("  … \(observations.count - 24) more") }
        if let contactSheet { lines.append("  contact sheet: \(contactSheet.path)") }
        return lines.joined(separator: "\n")
    }
}

public enum CutInspectorError: Error, CustomStringConvertible {
    case noVideoTrack(URL)
    case cannotWriteSheet(String)
    public var description: String {
        switch self {
        case .noVideoTrack(let u): return "no video track in \(u.lastPathComponent)"
        case .cannotWriteSheet(let s): return "contact sheet: \(s)"
        }
    }
}

public struct CutInspector: Sendable {
    /// Frames shown either side of each cut in the contact sheet. Three and three, because two
    /// frames show a join and six show whether it *settles* — which is what "seamless" means.
    public let framesEitherSide: Int
    /// Width of each thumbnail in the sheet.
    public let thumbnailWidth: Int

    public init(framesEitherSide: Int = 3, thumbnailWidth: Int = 240) {
        self.framesEitherSide = framesEitherSide
        self.thumbnailWidth = thumbnailWidth
    }

    /// Cut boundaries from the document: every clip start after zero, on video tracks.
    public static func cutFrames(in document: Document, rate: FrameRate) -> [Int64] {
        var frames: Set<Int64> = []
        for track in document.timeline.tracks where track.kind == .video {
            for clip in track.clips where clip.start > .zero {
                frames.insert(clip.start.nearestFrame(at: rate))
            }
        }
        return frames.sorted()
    }

    /// Supplies the on-screen text at an instant. The renderer cannot read text itself, and the
    /// module that can (Vision) depends on this one, so the caller closes the loop.
    public typealias TextAt = @Sendable (TimeValue) -> Set<String>

    public func inspect(rendered url: URL, document: Document, rate: FrameRate,
                        contactSheetTo sheetURL: URL? = nil,
                        textAt: TextAt? = nil) throws -> CutInspection {
        let cuts = CutInspector.cutFrames(in: document, rate: rate)
        guard !cuts.isEmpty else { return CutInspection(observations: [], contactSheet: nil) }

        // Frames wanted: the cut frame, the one before, and the sheet's neighbours.
        var wanted: Set<Int64> = []
        for cut in cuts {
            for offset in -(Int64(framesEitherSide))...(Int64(framesEitherSide) - 1) {
                let f = cut + offset
                if f >= 0 { wanted.insert(f) }
            }
        }
        let images = try decode(url: url, frames: wanted)

        let audio = try? AudioSource(url: url, sampleRate: 48_000, channels: 1)
        var observations: [CutObservation] = []
        for (i, cut) in cuts.enumerated() {
            let before = images[cut - 1]?.luma
            let after = images[cut]?.luma
            var jump: Float = 0
            if let before, let after, before.count == after.count, !before.isEmpty {
                var delta = [Float](repeating: 0, count: before.count)
                vDSP_vsub(before, 1, after, 1, &delta, 1, vDSP_Length(before.count))
                vDSP_meamgv(delta, 1, &jump, vDSP_Length(delta.count))
            }
            let time = TimeValue(frames: cut, at: rate)
            let previousCut = i == 0 ? Int64(0) : cuts[i - 1]
            // The last cut runs to the END OF THE PIECE, not to an arbitrary hour — reporting a
            // 3600 s shot makes the flash-frame check meaningless in the other direction and looks
            // like a bug to anyone reading the numbers, because it is one.
            let timelineEnd = document.timeline.duration.nearestFrame(at: rate)
            let nextCut = i + 1 < cuts.count ? cuts[i + 1] : max(timelineEnd, cut)
            observations.append(CutObservation(
                atFrame: cut, time: time,
                lumaJump: jump,
                audioStep: audio.flatMap { step(in: $0, at: time) },
                outgoingDuration: TimeValue(frames: cut - previousCut, at: rate),
                incomingDuration: TimeValue(frames: nextCut - cut, at: rate),
                textBefore: textAt.map { $0(TimeValue(frames: max(cut - 1, 0), at: rate)) },
                textAfter: textAt.map { $0(time) }))
        }

        var sheet: URL?
        if let sheetURL {
            sheet = try writeContactSheet(cuts: cuts, images: images, rate: rate, to: sheetURL)
        }
        return CutInspection(observations: observations, contactSheet: sheet)
    }

    /// Largest single-sample step in a short window across the join. A click is a discontinuity, so
    /// the measure is the step between neighbouring samples rather than a level.
    private func step(in source: AudioSource, at time: TimeValue) -> Float? {
        let window = TimeValue(seconds: Rational(5, 1000))     // 5 ms either side
        let start = time.seconds < window.seconds ? TimeValue.zero : time - window
        let range = TimeRange(start: start, end: time + window)
        guard let samples = try? source.read(range), samples.count > 1 else { return nil }
        var maximum: Float = 0
        for i in 1..<samples.count {
            maximum = max(maximum, abs(samples[i] - samples[i - 1]))
        }
        return maximum
    }

    private struct DecodedLuma {
        let luma: [Float]
        let image: CGImage?
        let width: Int
        let height: Int
    }

    /// One sequential pass, keeping only the frames asked for — seeking per frame on a long master
    /// is far slower than reading through once.
    private func decode(url: URL, frames wanted: Set<Int64>) throws -> [Int64: DecodedLuma] {
        let asset = AVURLAsset(url: url)
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var track: AVAssetTrack?
        Task { track = try? await asset.loadTracks(withMediaType: .video).first; semaphore.signal() }
        semaphore.wait()
        guard let track else { throw CutInspectorError.noVideoTrack(url) }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()

        var out: [Int64: DecodedLuma] = [:]
        var index: Int64 = 0
        let context = CIContext(options: [.useSoftwareRenderer: false])
        while let sample = output.copyNextSampleBuffer() {
            defer { index += 1 }
            guard wanted.contains(index), let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            var luma = [Float](repeating: 0, count: width * height)
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<height {
                    for x in 0..<width {
                        let p = bytes + y * stride + x * 4
                        // Rec.709 weights; a channel average would call a colour change a
                        // brightness change and mis-measure the join.
                        luma[y * width + x] = 0.2126 * Float(p[2]) + 0.7152 * Float(p[1]) + 0.0722 * Float(p[0])
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            let cg = context.createCGImage(CIImage(cvPixelBuffer: buffer),
                                           from: CGRect(x: 0, y: 0, width: width, height: height))
            out[index] = DecodedLuma(luma: luma, image: cg, width: width, height: height)
            if out.count == wanted.count { break }
        }
        return out
    }

    /// One row per cut, frames in order, with the join marked. The agent looks at this when the
    /// numbers do not settle it.
    private func writeContactSheet(cuts: [Int64], images: [Int64: DecodedLuma],
                                   rate: FrameRate, to url: URL) throws -> URL {
        guard let sample = images.values.first(where: { $0.image != nil }),
              let first = sample.image else {
            throw CutInspectorError.cannotWriteSheet("no frames decoded")
        }
        let aspect = Double(first.height) / Double(max(first.width, 1))
        let cellW = thumbnailWidth, cellH = Int(Double(thumbnailWidth) * aspect)
        let columns = framesEitherSide * 2
        let labelHeight = 22
        let sheetW = cellW * columns
        let sheetH = (cellH + labelHeight) * cuts.count

        guard let context = CGContext(data: nil, width: sheetW, height: sheetH, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CutInspectorError.cannotWriteSheet("could not allocate \(sheetW)×\(sheetH)")
        }
        context.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))

        for (row, cut) in cuts.enumerated() {
            let y = sheetH - (row + 1) * (cellH + labelHeight)
            for column in 0..<columns {
                let frame = cut - Int64(framesEitherSide) + Int64(column)
                guard let image = images[frame]?.image else { continue }
                let rect = CGRect(x: column * cellW, y: y + labelHeight, width: cellW, height: cellH)
                context.draw(image, in: rect)
                // The join itself: a bright rule between the last outgoing and first incoming
                // frame, so the eye goes to the boundary rather than hunting for it.
                if column == framesEitherSide {
                    context.setFillColor(CGColor(red: 1, green: 0.35, blue: 0.2, alpha: 1))
                    context.fill(CGRect(x: column * cellW - 1, y: y + labelHeight, width: 3, height: cellH))
                }
            }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
            context.fill(CGRect(x: 0, y: y, width: 4, height: labelHeight))
        }

        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CutInspectorError.cannotWriteSheet("could not encode")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CutInspectorError.cannotWriteSheet("could not write \(url.path)")
        }
        return url
    }
}
