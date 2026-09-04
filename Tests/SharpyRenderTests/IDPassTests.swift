// The ID pass is only worth having if it is EXACT. These render real layers through the real
// compositor and check the identity against geometry that is known by construction.

import XCTest
import Metal
import CoreVideo
@testable import SharpyRender

final class IDPassTests: XCTestCase {

    /// A solid BGRA buffer, so a layer's extent is known exactly and any disagreement is the
    /// compositor's, not the fixture's.
    func buffer(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * stride + x * 4
                p[0] = b; p[1] = g; p[2] = r; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    func render(_ layers: [CompositeLayer], width: Int, height: Int) throws -> IDPass {
        let compositor = try MetalCompositor()
        let out = compositor.makeOutputTexture(width: width, height: height)
        let ids = compositor.makeIDTexture(width: width, height: height)
        let cb = try compositor.encode(layers: layers, into: out, ids: ids)
        cb.commit()
        cb.waitUntilCompleted()
        return IDPass(texture: ids)
    }

    /// A half-width layer must own exactly the half it was placed on, to the pixel.
    func testOwnershipMatchesPlacementExactly() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let background = CompositeLayer(pixelBuffer: buffer(width: 200, height: 100, r: 0, g: 0, b: 0))
        let overlay = CompositeLayer(pixelBuffer: buffer(width: 100, height: 100, r: 255, g: 0, b: 0),
                                     placement: LayerPlacement(offset: SIMD2(100, 0), scale: 1, opacity: 1))
        let pass = try render([background, overlay], width: 200, height: 100)

        XCTAssertEqual(pass.owner(x: 50, y: 50), 0, "left half belongs to the background")
        XCTAssertEqual(pass.owner(x: 150, y: 50), 1, "right half belongs to the overlay")
        XCTAssertEqual(pass.boundingBox(of: 1), PixelRect(x: 100, y: 0, width: 100, height: 100))
        XCTAssertEqual(pass.uncoveredPixels, 0, "the background covers the frame")
    }

    /// The test the whole feature exists for: distinguishing "covering the subject" from
    /// "its edge is across the subject's face".
    func testEdgeCrossingIsDistinguishedFromFullCover() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let background = CompositeLayer(pixelBuffer: buffer(width: 200, height: 100, r: 0, g: 0, b: 0))
        let overlay = CompositeLayer(pixelBuffer: buffer(width: 100, height: 100, r: 255, g: 0, b: 0),
                                     placement: LayerPlacement(offset: SIMD2(100, 0), scale: 1, opacity: 1))
        let pass = try render([background, overlay], width: 200, height: 100)

        // A face straddling the wipe edge: half of it is under the overlay.
        let straddling = PixelRect(x: 60, y: 20, width: 80, height: 60)
        XCTAssertTrue(pass.edgeCrosses(layer: 1, region: straddling),
                      "an edge through the subject box must be caught")

        // A face entirely under the overlay is a deliberate cutaway, not a fault.
        let covered = PixelRect(x: 120, y: 20, width: 60, height: 60)
        XCTAssertFalse(pass.edgeCrosses(layer: 1, region: covered))
        XCTAssertEqual(pass.coverage(of: 1, in: covered), 1.0, accuracy: 0.001)

        // A face nowhere near it is untouched.
        let clear = PixelRect(x: 10, y: 20, width: 60, height: 60)
        XCTAssertFalse(pass.edgeCrosses(layer: 1, region: clear))
        XCTAssertEqual(pass.coverage(of: 1, in: clear), 0.0, accuracy: 0.001)
    }

    /// A transparent layer is PRESENT everywhere it is drawn but must not claim ownership of
    /// pixels a viewer would say belong to what is underneath.
    func testTransparentLayersArePresentWithoutOwning() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let background = CompositeLayer(pixelBuffer: buffer(width: 100, height: 100, r: 0, g: 0, b: 0))
        let ghost = CompositeLayer(pixelBuffer: buffer(width: 100, height: 100, r: 255, g: 255, b: 255),
                                   placement: LayerPlacement(offset: .zero, scale: 1, opacity: 0.2))
        let pass = try render([background, ghost], width: 100, height: 100)

        XCTAssertTrue(pass.contains(layer: 1, x: 50, y: 50), "a 20% layer is still present")
        XCTAssertEqual(pass.owner(x: 50, y: 50), 0,
                       "but at 20% the pixel still reads as the background's")
        XCTAssertEqual(pass.coverage(of: 1, in: PixelRect(x: 0, y: 0, width: 100, height: 100)), 1.0,
                       accuracy: 0.001)
    }

    /// A layer pushed partly off frame leaves the rest uncovered, and that must be visible rather
    /// than silently black.
    func testHolesAreCountedNotHidden() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let small = CompositeLayer(pixelBuffer: buffer(width: 50, height: 100, r: 9, g: 9, b: 9))
        let pass = try render([small], width: 100, height: 100)
        XCTAssertEqual(pass.uncoveredPixels, 50 * 100, "half the frame was never drawn")
        XCTAssertNil(pass.owner(x: 75, y: 50))
    }
}
