// Spatial assertions evaluated on EVERY rendered frame, against what the compositor actually did.
//
// The plan's gate for M3: "every spatial assertion evaluated on rendered frames, every frame."
// Sampling at 6-8 fps cannot see a wipe edge that crosses a face for four frames, and a viewer
// can. The ID pass makes the renderer's side exact, and this is what reads it.
//
// The regions arrive through a protocol rather than a concrete Vision type on purpose:
// SharpyPerception already depends on SharpyRender, so the dependency cannot run the other way.
// The caller — which has the Vision index — supplies them.
//
// WHY THESE ARE HOLDS AND NOT BLOCKS. The renderer's side of the test is exact; the subject box is
// Vision's and is probabilistic. A finding therefore means "the edge crossed the box we were
// given", not "the edge crossed a face". Aborting a finished render on a probabilistic box would
// destroy good output over a bad box. `hold` is exactly the outcome the vocabulary already has for
// this: nothing is provably wrong, and confidence is too low to ship unattended.

import Foundation
import SharpyEngine

/// A region of the frame something must not be cut through, in output pixels, top-left origin.
public struct ProtectedRegion: Sendable, Equatable {
    /// What it is, in words, so a finding reads as a sentence rather than a rectangle.
    public let name: String
    public let rect: PixelRect
    public init(name: String, rect: PixelRect) { self.name = name; self.rect = rect }
}

/// Supplies the regions to protect at a given instant. Implemented by the caller from whatever
/// subject track it has.
public protocol SpatialSubjectSource: Sendable {
    func protectedRegions(at time: TimeValue) -> [ProtectedRegion]
}

public struct SpatialFinding: Sendable, Equatable, CustomStringConvertible {
    public let frame: Int64
    public let time: TimeValue
    public let layer: Int
    public let region: String
    /// Fraction of the region the layer touched. Between the tolerances = an edge through it.
    public let coverage: Double

    public var description: String {
        String(format: "frame %d (%.3f s): layer %d covers %.0f%% of %@ — its edge runs through it",
               frame, time.seconds.doubleValue, layer, coverage * 100, region)
    }
}

/// Evaluates the spatial checks for one frame.
public struct SpatialGuard: Sendable {
    public let source: any SpatialSubjectSource
    /// A layer touching between these fractions of a region has its EDGE through it. Fully
    /// covering is a deliberate cutaway; not touching is fine. Only the middle is a fault.
    public let tolerance: Double
    /// Layer 0 is the base picture and is *supposed* to sit under the subject; only layers
    /// composited above it can cut through one.
    public let ignoresBaseLayer: Bool

    public init(source: any SpatialSubjectSource, tolerance: Double = 0.02,
                ignoresBaseLayer: Bool = true) {
        self.source = source
        self.tolerance = tolerance
        self.ignoresBaseLayer = ignoresBaseLayer
    }

    /// Returns whether the frame was actually CHECKABLE as well as what was found.
    ///
    /// A frame with one layer, or with no subject boxes, cannot produce a finding — nothing can cut
    /// through anything. Counting it as "checked and clean" is how a tier reports "clean across
    /// 2649 frames" having examined none of them, which is the exact failure this file was written
    /// to prevent. Measured on the user's reel: a single-layer render is 2649 uncheckable frames,
    /// and it must say so.
    public func check(_ pass: IDPass, frame: Int64, time: TimeValue,
                      layerCount: Int) -> (checkable: Bool, findings: [SpatialFinding]) {
        let regions = source.protectedRegions(at: time)
        guard !regions.isEmpty, layerCount > 1 else { return (false, []) }
        var findings: [SpatialFinding] = []
        for layer in (ignoresBaseLayer ? 1 : 0)..<layerCount {
            for region in regions {
                let coverage = pass.coverage(of: layer, in: region.rect)
                if coverage > tolerance && coverage < 1 - tolerance {
                    findings.append(SpatialFinding(frame: frame, time: time, layer: layer,
                                                   region: region.name, coverage: coverage))
                }
            }
        }
        return (true, findings)
    }
}

/// What the spatial tier found across a whole render.
public struct SpatialReport: Sendable {
    /// Frames that could actually produce a finding — more than one layer, and at least one
    /// subject box. NOT the number of frames rendered.
    public let framesChecked: Int
    /// Frames where there was nothing to check. Reported so "clean" cannot quietly mean "empty".
    public let framesNotCheckable: Int
    public let findings: [SpatialFinding]

    public init(framesChecked: Int, framesNotCheckable: Int = 0, findings: [SpatialFinding]) {
        self.framesChecked = framesChecked
        self.framesNotCheckable = framesNotCheckable
        self.findings = findings
    }

    public var isClean: Bool { findings.isEmpty }
    /// Distinct frames with at least one finding — the number that matters, since one edge across
    /// a face produces a finding per region per layer.
    public var affectedFrames: Int { Set(findings.map(\.frame)).count }

    public var summary: String {
        let skipped = framesNotCheckable > 0
            ? " (\(framesNotCheckable) frame(s) had nothing to check — single layer or no subject)" : ""
        guard !findings.isEmpty else {
            if framesChecked == 0 {
                return framesNotCheckable > 0
                    ? "spatial: nothing to check\(skipped)"
                    : "spatial: not run"
            }
            return "spatial: clean across \(framesChecked) checkable frame(s)\(skipped)"
        }
        return "spatial: \(findings.count) finding(s) on \(affectedFrames) of \(framesChecked) checkable frame(s)\(skipped) — HOLD"
    }
}
