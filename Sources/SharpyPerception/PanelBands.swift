// Where each panel sits in the frame, and what of the source it shows.
//
// A band is short and wide; the recording is tall and narrow. Fitting one into the other means
// throwing away most of the source height, and WHICH two thirds you throw away is the whole
// question — centre the band on the frame and you get a chest and a chin.
//
// So the band is centred on the face, and then pushed back inside the picture if that would run it
// off the top or bottom. The face is measured (Vision), not assumed; with no measurement the band
// sits slightly above centre, where heads are, rather than dead centre, where they are not.

import Foundation
import SharpyEngine

public enum PanelBands {

    /// Vertical middle of the band as a fraction of source height, when nothing was measured.
    /// People frame themselves in the upper half of a vertical shot — a third of the way down is
    /// closer to a face than half way is.
    public static let assumedFaceHeight = 0.36

    /// The placement for one panel of a stack.
    ///
    /// - Parameter panel: 0 at the top.
    /// - Parameter subjectY: face centre as a fraction of source height, if it was measured.
    public static func placement(panel: Int, of panels: Int,
                                 sourceWidth: Int, sourceHeight: Int,
                                 outputWidth: Int, outputHeight: Int,
                                 subjectY: Double?) -> ClipPlacement {
        precondition(panels > 0 && panel >= 0 && panel < panels)
        let bandHeight = Double(outputHeight) / Double(panels)
        let bandAspect = Double(outputWidth) / bandHeight

        // Keep the full width and as much height as the band's shape allows. If the band is
        // narrower than the source instead, the width is what gives.
        let sourceAspect = Double(sourceWidth) / Double(sourceHeight)
        var keepHeight = 1.0, keepWidth = 1.0
        if sourceAspect < bandAspect {
            keepHeight = sourceAspect / bandAspect          // tall source, wide band — usual case
        } else {
            keepWidth = bandAspect / sourceAspect
        }

        let centre = subjectY ?? assumedFaceHeight
        // Centre on the face, then slide back inside the picture rather than letting the crop run
        // off the edge — a band hanging past the top of the source would show black, and black in
        // one of three panels reads as a broken render, not a style.
        let top = min(max(centre - keepHeight / 2, 0), 1 - keepHeight)
        let left = (1 - keepWidth) / 2

        // A fraction on a fixed denominator, so the same source and output always give the same
        // crop and a re-render is bit-identical rather than merely similar.
        func exact(_ value: Double) -> Rational {
            Rational(Int64((min(max(value, 0), 1) * 100_000).rounded()), 100_000)
        }
        return ClipPlacement(
            x: .zero,
            y: Rational(Int64(panel), Int64(panels)),
            width: .one,
            height: Rational(1, Int64(panels)),
            cropLeft: exact(left),
            cropRight: exact(left),
            cropTop: exact(top),
            cropBottom: exact(1 - keepHeight - top))
    }

    /// What the placement does, in words, so a plan can be read before it is rendered.
    public static func describe(panel: Int, of panels: Int, placement: ClipPlacement) -> String {
        let keptHeight = 1 - placement.cropTop.doubleValue - placement.cropBottom.doubleValue
        return String(format: "  panel %d of %d: band y %.0f%%–%.0f%%, showing %.0f%% of the source height from %.0f%% down",
                      panel + 1, panels,
                      placement.y.doubleValue * 100,
                      (placement.y.doubleValue + (placement.height?.doubleValue ?? 0)) * 100,
                      keptHeight * 100, placement.cropTop.doubleValue * 100)
    }
}
