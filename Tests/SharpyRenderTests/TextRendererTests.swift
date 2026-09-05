// Drawing text onto video. If the alpha is wrong every caption is a solid rectangle; if the
// measurement is wrong every caption is clipped. Both look like the renderer is broken.

import XCTest
import Metal
import CoreVideo
@testable import SharpyEngine
@testable import SharpyRender

final class TextRendererTests: XCTestCase {

    func pixel(_ b: CVPixelBuffer, _ x: Int, _ y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
        let p = base + y * CVPixelBufferGetBytesPerRow(b) + x * 4
        return (p[0], p[1], p[2], p[3])
    }

    func testTextIsDrawnAndTheBufferFitsIt() throws {
        let rendered = try TextRenderer.render("HELLO", style: TextStyle(pointSize: 80))
        XCTAssertGreaterThan(rendered.width, 100, "five capitals at 80pt are wider than 100px")
        XCTAssertGreaterThan(rendered.height, 40)
        XCTAssertLessThan(rendered.width, 2000, "it is sized to the text, not to a frame")

        // Something opaque was actually drawn.
        var opaque = 0
        for y in stride(from: 0, to: rendered.height, by: 3) {
            for x in stride(from: 0, to: rendered.width, by: 3) where pixel(rendered.pixelBuffer, x, y).a > 200 {
                opaque += 1
            }
        }
        XCTAssertGreaterThan(opaque, 20, "no glyphs were drawn")
    }

    /// Without a backing, everything that is not a glyph must be TRANSPARENT — otherwise a caption
    /// composites as a black box over the picture.
    func testPlainTextIsTransparentAwayFromTheGlyphs() throws {
        let rendered = try TextRenderer.render("I", style: TextStyle(pointSize: 60))
        // The very corner cannot be part of a single narrow letter.
        XCTAssertEqual(pixel(rendered.pixelBuffer, 1, 1).a, 0, "the corner must be fully transparent")
    }

    /// A pill has to be opaque behind the words, because that is the whole reason it is there.
    func testAPillFillsItsBackground() throws {
        let rendered = try TextRenderer.render("READ ME", style: .caption(pointSize: 60))
        let middle = pixel(rendered.pixelBuffer, rendered.width / 2, rendered.height / 2)
        XCTAssertGreaterThan(middle.a, 100, "the pill must be visible behind the text")
    }

    /// A stroke spills OUTSIDE the glyphs, so the buffer has to allow for it or the outline is
    /// clipped on the outermost letters — which reads as a rendering fault.
    func testAStrokeIsNotClipped() throws {
        // The SAME style either way, so only the stroke differs. Comparing `.label` against the
        // default compared their padding as well, which is not what this is about.
        var style = TextStyle(pointSize: 60, padding: 10)
        let plain = try TextRenderer.render("W", style: style)
        style.backing = .stroke(red: 0, green: 0, blue: 0, width: 6)
        let outlined = try TextRenderer.render("W", style: style)
        XCTAssertGreaterThan(outlined.width, plain.width, "a stroke needs room beyond the glyph")
        XCTAssertEqual(outlined.width - plain.width, 12, accuracy: 2, "6px of stroke on each side")
    }

    func testWrappingRespectsAMaximumWidth() throws {
        let narrow = try TextRenderer.render(
            "the quick brown fox jumps over the lazy dog",
            style: TextStyle(pointSize: 40, maximumWidth: 400))
        XCTAssertLessThanOrEqual(narrow.width, 500, "it wrapped rather than running on")
        XCTAssertGreaterThan(narrow.height, 60, "wrapping means more than one line")
    }

    func testEmptyTextIsRefusedRatherThanDrawnAsNothing() {
        XCTAssertThrowsError(try TextRenderer.render("   ", style: TextStyle()))
    }

    /// THE ONE THAT MATTERS FOR COMPOSITING. A transparent overlay must let the picture through.
    /// The shader ignored texture alpha entirely, so every caption would have been a solid block.
    func testATransparentOverlayCompositesOverThePicture() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let w = 400, h = 200
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        let background = pb!
        CVPixelBufferLockBaseAddress(background, [])
        let base = CVPixelBufferGetBaseAddress(background)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(background)
        for y in 0..<h { for x in 0..<w {
            let p = base + y * stride + x * 4
            p[0] = 0; p[1] = 200; p[2] = 0; p[3] = 255          // solid green
        } }
        CVPixelBufferUnlockBaseAddress(background, [])

        let text = try TextRenderer.render("HI", style: TextStyle(pointSize: 40))
        let compositor = try MetalCompositor()
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderWrite, .shaderRead]; d.storageMode = .shared
        let out = compositor.device.makeTexture(descriptor: d)!
        let overlay = TextRenderer.placement(for: text, in: w, outputHeight: h, anchor: (x: 0.5, y: 0.5))
        let cb = try compositor.encode(layers: [
            CompositeLayer(pixelBuffer: background),
            CompositeLayer(pixelBuffer: text.pixelBuffer, placement: overlay),
        ], into: out, ids: nil)
        cb.commit(); cb.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        out.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        // A corner far from the text must still be the green background, not a black box.
        let corner = (y: 5, x: 5)
        let i = (corner.y * w + corner.x) * 4
        XCTAssertGreaterThan(bytes[i + 1], 150,
                             "the background shows through where there is no text — otherwise the overlay is an opaque rectangle")
    }
}
