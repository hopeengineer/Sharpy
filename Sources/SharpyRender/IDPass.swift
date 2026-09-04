// The renderer's own account of which layer owns which pixel.
//
// Spatial assertions used to sample: check a few frames per second, hope nothing happened in
// between. A wipe edge crossing a face for four frames is invisible to a 6 fps sampler and
// obvious to a viewer. This is the fix — the compositor reports, per pixel, exactly what it did,
// so "the edge must never cross the subject" becomes an intersection test at every frame rather
// than an inference from samples.
//
// The design is Cryptomatte's idea (an ID + coverage channel emitted by the renderer, an open
// standard read by Nuke, Fusion and After Effects) adapted to a bounded layer count: with at most
// 8 layers, presence fits in a bitmask and no hashing or ranked-pair storage is needed.
//
// The honest limit, restated from the plan: this side of the test is EXACT. The other side — the
// subject box — comes from Vision and is probabilistic. So a failure means "the edge crossed the
// box", and whether the box was right is a separate, measured question. That is still a large
// improvement on "we never looked".

import Metal
import Foundation

/// A rectangle in output pixels, top-left origin — the same convention as `DetectedBox`, so a
/// Vision result can be handed straight to these queries without a flip.
public struct PixelRect: Sendable, Equatable {
    public let x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
}

/// One frame of the compositor's identity output, read back for assertion.
public struct IDPass: Sendable {
    public let width: Int, height: Int
    /// Bit i set = layer i contributed to this pixel with non-zero opacity.
    public let present: [UInt32]
    /// Topmost still-visible layer, or nil where nothing was drawn.
    public let owner: [UInt32]
    /// Sentinel written by the kernel where no layer covered the pixel.
    public static let noOwner: UInt32 = 0xFFFF_FFFF

    public init(width: Int, height: Int, present: [UInt32], owner: [UInt32]) {
        self.width = width; self.height = height; self.present = present; self.owner = owner
    }

    /// Read back an ID texture written by `MetalCompositor.encode(layers:into:ids:)`.
    ///
    /// The command buffer must have completed. Passing a texture whose work is still in flight
    /// would read whatever was there before, which is the kind of bug that makes an assertion pass
    /// for the wrong reason.
    public init(texture: MTLTexture) {
        let w = texture.width, h = texture.height
        var raw = [UInt32](repeating: 0, count: w * h * 2)
        raw.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: w * 2 * MemoryLayout<UInt32>.size,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        var present = [UInt32](repeating: 0, count: w * h)
        var owner = [UInt32](repeating: IDPass.noOwner, count: w * h)
        for i in 0..<(w * h) {
            present[i] = raw[i * 2]
            owner[i] = raw[i * 2 + 1]
        }
        self.init(width: w, height: h, present: present, owner: owner)
    }

    private func index(_ x: Int, _ y: Int) -> Int? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        return y * width + x
    }

    public func owner(x: Int, y: Int) -> Int? {
        guard let i = index(x, y), owner[i] != IDPass.noOwner else { return nil }
        return Int(owner[i])
    }

    public func contains(layer: Int, x: Int, y: Int) -> Bool {
        guard layer >= 0, layer < 32, let i = index(x, y) else { return false }
        return present[i] & (1 << UInt32(layer)) != 0
    }

    private func clamped(_ r: PixelRect) -> PixelRect {
        let x0 = max(0, r.x), y0 = max(0, r.y)
        let x1 = min(width, r.maxX), y1 = min(height, r.maxY)
        return PixelRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    /// Fraction of a region that a layer touches at all, 0…1.
    public func coverage(of layer: Int, in region: PixelRect) -> Double {
        let r = clamped(region)
        guard !r.isEmpty, layer >= 0, layer < 32 else { return 0 }
        let bit = UInt32(1) << UInt32(layer)
        var hits = 0
        for y in r.y..<r.maxY {
            let row = y * width
            for x in r.x..<r.maxX where present[row + x] & bit != 0 { hits += 1 }
        }
        return Double(hits) / Double(r.width * r.height)
    }

    /// Fraction of a region a layer is the visible owner of.
    public func ownership(of layer: Int, in region: PixelRect) -> Double {
        let r = clamped(region)
        guard !r.isEmpty else { return 0 }
        var hits = 0
        for y in r.y..<r.maxY {
            let row = y * width
            for x in r.x..<r.maxX where owner[row + x] == UInt32(layer) { hits += 1 }
        }
        return Double(hits) / Double(r.width * r.height)
    }

    /// True when a layer covers part of a region but not all of it — i.e. its EDGE passes through.
    ///
    /// This is the test a wipe or a lower-third needs. A layer fully covering a face is a
    /// deliberate cutaway; a layer covering 40% of it is an edge across someone's mouth. The
    /// distinction is the entire point, and coverage alone cannot make it.
    public func edgeCrosses(layer: Int, region: PixelRect, tolerance: Double = 0.02) -> Bool {
        let c = coverage(of: layer, in: region)
        return c > tolerance && c < 1 - tolerance
    }

    /// Tight bounding box of everywhere a layer appears, or nil if it appears nowhere.
    public func boundingBox(of layer: Int) -> PixelRect? {
        guard layer >= 0, layer < 32 else { return nil }
        let bit = UInt32(1) << UInt32(layer)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where present[row + x] & bit != 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return nil }
        return PixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Pixels no layer reached. A non-zero count on a full-frame composite means holes — a clip
    /// that did not cover the frame, or a placement that pushed it off the edge.
    public var uncoveredPixels: Int {
        owner.reduce(0) { $0 + ($1 == IDPass.noOwner ? 1 : 0) }
    }
}
