// Vision's subject boxes, in the shape the render-time spatial guard wants.
//
// SharpyRender defines the protocol and cannot import this module — the dependency runs the other
// way — so this is the adapter that closes M3's gate: spatial assertions evaluated against REAL
// subject positions on every rendered frame, rather than against a fixture.
//
// Two things are protected, and they are protected for different reasons:
//   faces  a graphic edge across someone's face is the failure the user named — "misread the
//          intent, made a serious video funny" — and it is invisible until someone watches.
//   text   an edge through a caption does not look wrong, it makes the caption unreadable, which
//          is worse because the viewer cannot tell they missed something.
//
// The honest limit is unchanged and worth restating: the renderer's side of the test is exact, and
// this side is probabilistic. Vision measured 22/22 faces and 89/90 text lines on the labelled
// reel, so it is a good source — but a finding means "the edge crossed the box Vision gave us".

import Foundation
import SharpyEngine
import SharpyRender

public struct VisionSubjectSource: SpatialSubjectSource {
    public let index: VisionIndex
    /// Output size the regions are expressed in. Vision reports in the pixels of the frame it
    /// analysed, and the delivery resolution rarely matches — a 1080p analysis feeding a 4K master
    /// would otherwise protect a quarter of the right area.
    public let outputWidth: Int
    public let outputHeight: Int
    /// Boxes are grown by this fraction of their size before testing. A wipe that stops one pixel
    /// from an eyebrow is not a pass: the box is where the subject was measured, not where it is
    /// safe to cut.
    public let margin: Double
    public let protectsFaces: Bool
    public let protectsText: Bool
    /// Vision samples at its own rate, so a rendered frame between samples is tested against the
    /// nearest observation. Beyond this gap the observation is too old to stand for the frame, and
    /// the frame is left UNCHECKED rather than checked against a stale box — a subject that has
    /// moved would otherwise generate findings about where it used to be.
    public let maximumStaleness: TimeValue

    public init(index: VisionIndex, outputWidth: Int, outputHeight: Int, margin: Double = 0.05,
                protectsFaces: Bool = true, protectsText: Bool = true,
                maximumStaleness: TimeValue = TimeValue(seconds: Rational(1, 2))) {
        self.index = index
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.margin = margin
        self.protectsFaces = protectsFaces
        self.protectsText = protectsText
        self.maximumStaleness = maximumStaleness
    }

    private func rect(_ box: DetectedBox) -> PixelRect {
        let sx = Double(outputWidth) / Double(max(index.width, 1))
        let sy = Double(outputHeight) / Double(max(index.height, 1))
        let growX = box.width * margin, growY = box.height * margin
        return PixelRect(x: Int(((box.x - growX) * sx).rounded(.down)),
                         y: Int(((box.y - growY) * sy).rounded(.down)),
                         width: Int(((box.width + 2 * growX) * sx).rounded(.up)),
                         height: Int(((box.height + 2 * growY) * sy).rounded(.up)))
    }

    public func protectedRegions(at time: TimeValue) -> [ProtectedRegion] {
        guard let observation = index.observation(at: time) else { return [] }
        guard abs((observation.time - time).seconds.doubleValue) <= maximumStaleness.seconds.doubleValue else {
            return []
        }
        var regions: [ProtectedRegion] = []
        if protectsFaces {
            for (i, face) in observation.faces.enumerated() {
                regions.append(ProtectedRegion(name: "face \(i + 1)", rect: rect(face)))
            }
        }
        if protectsText {
            for line in observation.text {
                let label = line.text.isEmpty ? "on-screen text"
                    : "text \"\(line.text.prefix(24))\(line.text.count > 24 ? "…" : "")\""
                regions.append(ProtectedRegion(name: label, rect: rect(line.box)))
            }
        }
        return regions
    }
}
