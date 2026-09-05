// Changing the shape of the frame without losing the person in it.
//
// Repurposing is mostly reframing: a 9:16 recording wanted as 1:1 for a feed, or a 16:9 interview
// wanted vertical. A centre crop is the obvious way and it is wrong often enough to matter —
// people do not stand in the middle of the frame, and the one thing a talking-head crop must not
// do is cut off the head.
//
// So the crop follows the SUBJECT: where Vision actually found the face, across the whole piece
// rather than at one instant. Using the median position rather than tracking per-frame is
// deliberate — a crop that chases the subject frame by frame is a camera move nobody asked for,
// and on handheld footage it looks like the frame is breathing.

import Foundation
import SharpyEngine
import SharpyRender

public struct Reframing: Sendable {
    /// Output pixel size.
    public let width: Int, height: Int
    /// Fractions of the SOURCE trimmed from each side to reach that shape.
    public let cropLeft: Double, cropRight: Double, cropTop: Double, cropBottom: Double
    /// Where the subject sat, 0…1 across the source, when one was found.
    public let subjectAt: (x: Double, y: Double)?

    public var placement: ClipPlacement {
        ClipPlacement(x: .zero, y: .zero, width: .one, opacity: .one, height: .one,
                      cropLeft: Rational(Int64(cropLeft * 10_000), 10_000),
                      cropRight: Rational(Int64(cropRight * 10_000), 10_000),
                      cropTop: Rational(Int64(cropTop * 10_000), 10_000),
                      cropBottom: Rational(Int64(cropBottom * 10_000), 10_000))
    }

    public var summary: String {
        let where_ = subjectAt.map { String(format: "subject at %.0f%%,%.0f%%", $0.x * 100, $0.y * 100) }
            ?? "no subject found — centred"
        return String(format: "reframe: %d×%d, trimming L%.0f%% R%.0f%% T%.0f%% B%.0f%% (%@)",
                      width, height, cropLeft * 100, cropRight * 100, cropTop * 100, cropBottom * 100, where_)
    }
}

public enum Reframer {
    /// Parse "9:16", "1:1", "16:9" — or nil for "keep the source's shape".
    public static func parse(_ text: String) -> Double? {
        if text == "original" || text == "source" { return nil }
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > 0 else { return nil }
        return parts[0] / parts[1]
    }

    /// Fit `sourceWidth × sourceHeight` into `targetAspect`, cropping around the subject.
    ///
    /// - Parameter subject: where the face sits in the source, 0…1. Nil centres the crop, which is
    ///   the only honest fallback when nobody was found.
    public static func plan(sourceWidth: Int, sourceHeight: Int, targetAspect: Double,
                            subject: (x: Double, y: Double)?,
                            longEdge: Int? = nil) -> Reframing {
        let sourceAspect = Double(sourceWidth) / Double(max(sourceHeight, 1))
        var cropL = 0.0, cropR = 0.0, cropT = 0.0, cropB = 0.0

        if targetAspect > sourceAspect {
            // Wanted wider: keep the full width, trim height.
            let keep = sourceAspect / targetAspect                 // fraction of height retained
            let trim = 1 - keep
            // Centre the retained band on the subject, then slide it back inside the frame — a
            // crop that runs off the edge would show black, which is worse than being off-centre.
            let centre = subject.map { $0.y } ?? 0.5
            var top = centre - keep / 2
            top = min(max(top, 0), trim)
            cropT = top; cropB = trim - top
        } else if targetAspect < sourceAspect {
            let keep = targetAspect / sourceAspect                 // fraction of width retained
            let trim = 1 - keep
            let centre = subject.map { $0.x } ?? 0.5
            var left = centre - keep / 2
            left = min(max(left, 0), trim)
            cropL = left; cropR = trim - left
        }

        // Output size: preserve the source's detail on the long edge unless told otherwise.
        let croppedW = Double(sourceWidth) * (1 - cropL - cropR)
        let croppedH = Double(sourceHeight) * (1 - cropT - cropB)
        let edge = Double(longEdge ?? Int(max(croppedW, croppedH).rounded()))
        let outW: Int, outH: Int
        if croppedW >= croppedH {
            outW = Int(edge.rounded()); outH = Int((edge / targetAspect).rounded())
        } else {
            outH = Int(edge.rounded()); outW = Int((edge * targetAspect).rounded())
        }
        // Even dimensions: h264 and hevc both require them, and an odd one fails at the encoder
        // with a message that says nothing about aspect ratios.
        return Reframing(width: outW - (outW % 2), height: outH - (outH % 2),
                         cropLeft: cropL, cropRight: cropR, cropTop: cropT, cropBottom: cropB,
                         subjectAt: subject)
    }

    /// Where the subject sits across a whole piece, as fractions of the frame.
    ///
    /// The MEDIAN, not the mean: one frame where Vision found a face in the background would drag a
    /// mean off the speaker, and the crop would sit slightly wrong for the entire video.
    public static func subject(in vision: VisionIndex) -> (x: Double, y: Double)? {
        let centres = vision.frames.compactMap { frame -> (Double, Double)? in
            // The largest face is the speaker; anything smaller is someone in the background.
            guard let face = frame.faces.max(by: { $0.width * $0.height < $1.width * $1.height })
            else { return nil }
            return ((face.x + face.width / 2) / Double(max(vision.width, 1)),
                    (face.y + face.height / 2) / Double(max(vision.height, 1)))
        }
        guard !centres.isEmpty else { return nil }
        let xs = centres.map(\.0).sorted(), ys = centres.map(\.1).sorted()
        return (xs[xs.count / 2], ys[ys.count / 2])
    }
}
