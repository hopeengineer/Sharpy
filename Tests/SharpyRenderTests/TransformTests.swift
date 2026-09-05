// Mirror, crop, mask, rotate and blend, checked against geometry known by construction.
//
// These are the primitives a "proper edit" is made of, and each of them is a place where an
// off-by-one or an inverted sign produces something that looks nearly right. Nearly right is the
// worst outcome: it ships.

import XCTest
import Metal
import CoreVideo
@testable import SharpyEngine
@testable import SharpyRender

final class TransformTests: XCTestCase {

    /// A buffer whose LEFT half is red and right half is blue, so a horizontal mirror is visible
    /// as an exact swap rather than as "it looks flipped".
    func halves(width: Int, height: Int) -> CVPixelBuffer {
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
                let left = x < width / 2
                p[0] = left ? 0 : 255; p[1] = 0; p[2] = left ? 255 : 0; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    func solid(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> CVPixelBuffer {
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

    /// Reads back the composited RGBA8 output.
    /// A SHARED output texture, made here rather than with `makeOutputTexture`, which returns a
    /// `.private` texture on purpose — right for rendering, and unreadable from the CPU. The first
    /// version of this helper used it and every test read back zeros, which looks exactly like a
    /// broken shader and is not.
    func sharedOutput(_ device: MTLDevice, width: Int, height: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                         width: width, height: height, mipmapped: false)
        d.usage = [.shaderWrite, .shaderRead]; d.storageMode = .shared
        return device.makeTexture(descriptor: d)!
    }

    func render(_ layers: [CompositeLayer], width: Int, height: Int) throws -> [UInt8] {
        let compositor = try MetalCompositor()
        let out = sharedOutput(compositor.device, width: width, height: height)
        let cb = try compositor.encode(layers: layers, into: out, ids: nil)
        cb.commit(); cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        out.getBytes(&bytes, bytesPerRow: width * 4,
                     from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return bytes
    }

    /// Returned as (r, g, b, a). The texture is BGRA, so byte 0 is blue and byte 2 is red —
    /// getting this backwards makes a correct mirror look broken and a broken one look correct.
    func pixel(_ bytes: [UInt8], _ x: Int, _ y: Int, width: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let i = (y * width + x) * 4
        return (bytes[i + 2], bytes[i + 1], bytes[i], bytes[i + 3])
    }

    /// THE FRONT-CAMERA FIX. A selfie recording is stored as the shooter saw themselves, so any
    /// text in shot reads backwards. Mirroring must swap the halves exactly.
    func testHorizontalMirrorSwapsLeftAndRight() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let w = 64, h = 32
        let plain = try render([CompositeLayer(pixelBuffer: halves(width: w, height: h))], width: w, height: h)
        XCTAssertGreaterThan(pixel(plain, 8, 16, width: w).0, 200, "left is red unmirrored")
        XCTAssertGreaterThan(pixel(plain, 56, 16, width: w).2, 200, "right is blue unmirrored")

        let mirrored = try render([CompositeLayer(pixelBuffer: halves(width: w, height: h),
                                                  placement: LayerPlacement(mirrorX: true))],
                                  width: w, height: h)
        XCTAssertGreaterThan(pixel(mirrored, 8, 16, width: w).2, 200, "left is now blue")
        XCTAssertGreaterThan(pixel(mirrored, 56, 16, width: w).0, 200, "right is now red")
    }

    func testVerticalMirrorSwapsTopAndBottom() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let w = 32, h = 64
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<h {
            for x in 0..<w {
                let p = base + y * stride + x * 4
                let top = y < h / 2
                p[0] = top ? 0 : 255; p[1] = 0; p[2] = top ? 255 : 0; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let flipped = try render([CompositeLayer(pixelBuffer: buffer,
                                                 placement: LayerPlacement(mirrorY: true))],
                                 width: w, height: h)
        XCTAssertGreaterThan(pixel(flipped, 16, 8, width: w).2, 200, "top is now blue")
        XCTAssertGreaterThan(pixel(flipped, 16, 56, width: w).0, 200, "bottom is now red")
    }

    /// Cropping the left half away must leave only the blue side, filling the frame.
    func testCropRemovesSourceBeforeScaling() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let w = 64, h = 32
        let cropped = try render([CompositeLayer(
            pixelBuffer: halves(width: w, height: h),
            placement: LayerPlacement(scale: 2, crop: SIMD4(0.5, 0, 0, 0)))],
                                 width: w, height: h)
        XCTAssertGreaterThan(pixel(cropped, 8, 16, width: w).2, 200, "the red half was cropped away")
        XCTAssertGreaterThan(pixel(cropped, 56, 16, width: w).2, 200)
    }

    /// A mask must hide what is outside it and keep what is inside.
    func testARectangleMaskHidesOutsideItself() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let w = 64, h = 64
        let layers = [
            CompositeLayer(pixelBuffer: solid(width: w, height: h, r: 0, g: 0, b: 0)),
            CompositeLayer(pixelBuffer: solid(width: w, height: h, r: 255, g: 0, b: 0),
                           placement: LayerPlacement(maskRect: SIMD4(0.25, 0.25, 0.5, 0.5),
                                                     maskFeather: 0.001)),
        ]
        let out = try render(layers, width: w, height: h)
        XCTAssertGreaterThan(pixel(out, 32, 32, width: w).0, 200, "inside the mask the red shows")
        XCTAssertLessThan(pixel(out, 4, 4, width: w).0, 40, "outside it the background shows")
    }

    /// Inverted, it covers — the "hide a logo or a face" case.
    func testAnInvertedMaskCoversInsteadOfReveals() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let w = 64, h = 64
        let layers = [
            CompositeLayer(pixelBuffer: solid(width: w, height: h, r: 0, g: 0, b: 0)),
            CompositeLayer(pixelBuffer: solid(width: w, height: h, r: 255, g: 0, b: 0),
                           placement: LayerPlacement(maskRect: SIMD4(0.25, 0.25, 0.5, 0.5),
                                                     maskFeather: 0.001, maskInverted: true)),
        ]
        let out = try render(layers, width: w, height: h)
        XCTAssertLessThan(pixel(out, 32, 32, width: w).0, 40, "the middle is covered")
        XCTAssertGreaterThan(pixel(out, 4, 4, width: w).0, 200, "the outside shows")
    }

    /// A feathered edge must actually be soft — a hard mask on moving footage crawls.
    func testFeatherProducesASoftEdge() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let w = 64, h = 64
        let out = try render([
            CompositeLayer(pixelBuffer: solid(width: w, height: h, r: 0, g: 0, b: 0)),
            CompositeLayer(pixelBuffer: solid(width: w, height: h, r: 255, g: 0, b: 0),
                           placement: LayerPlacement(maskRect: SIMD4(0.25, 0.25, 0.5, 0.5),
                                                     maskFeather: 0.15)),
        ], width: w, height: h)
        // Somewhere across the boundary there must be a partial value — neither 0 nor 255.
        var sawPartial = false
        for x in 8..<24 where (40...215).contains(Int(pixel(out, x, 32, width: w).0)) { sawPartial = true }
        XCTAssertTrue(sawPartial, "a feathered edge must have intermediate values")
    }

    /// Screen blend must lighten. Checked as a direction rather than an exact value, because the
    /// value depends on the colour pipeline in force.
    func testScreenBlendLightens() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let w = 32, h = 32
        let base = CompositeLayer(pixelBuffer: solid(width: w, height: h, r: 90, g: 90, b: 90))
        let overNormal = try render([base,
            CompositeLayer(pixelBuffer: solid(width: w, height: h, r: 90, g: 90, b: 90),
                           placement: LayerPlacement(blend: 0))], width: w, height: h)
        let overScreen = try render([base,
            CompositeLayer(pixelBuffer: solid(width: w, height: h, r: 90, g: 90, b: 90),
                           placement: LayerPlacement(blend: 3))], width: w, height: h)
        XCTAssertGreaterThan(pixel(overScreen, 16, 16, width: w).0, pixel(overNormal, 16, 16, width: w).0,
                             "screen must be lighter than plain over")
    }

    /// Rotation by 180° is its own check: the halves swap, exactly as a horizontal+vertical flip.
    func testRotationByOneEightyIsEquivalentToBothFlips() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let w = 64, h = 32
        let rotated = try render([CompositeLayer(pixelBuffer: halves(width: w, height: h),
                                                 placement: LayerPlacement(rotation: 180))],
                                 width: w, height: h)
        XCTAssertGreaterThan(pixel(rotated, 8, 16, width: w).2, 200, "left is blue after 180°")
        XCTAssertGreaterThan(pixel(rotated, 56, 16, width: w).0, 200, "right is red after 180°")
    }

    /// The document type must round-trip, and old documents that predate transforms must still
    /// decode — a content-addressed history whose old revisions stop loading is a liability.
    func testOldPlacementsStillDecode() throws {
        let encoded = try JSONEncoder().encode(ClipPlacement(x: .zero, y: .zero, width: .one))
        // Strip every field that did not exist before transforms, to stand for an old document.
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        for key in ["height", "rotation", "mirrorHorizontal", "mirrorVertical",
                    "cropLeft", "cropRight", "cropTop", "cropBottom", "blend", "mask"] {
            object.removeValue(forKey: key)
        }
        let legacy = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        let decoded = try JSONDecoder().decode(ClipPlacement.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.width, .one)
        XCTAssertFalse(decoded.mirrorHorizontal)
        XCTAssertEqual(decoded.blend, .over)
        XCTAssertNil(decoded.mask)
        XCTAssertNil(decoded.height, "no vertical scale means keep the source aspect")
    }

    func testMirroringIsItsOwnInverse() {
        let p = ClipPlacement(x: .zero, y: .zero, width: .one)
        XCTAssertTrue(p.mirrored.mirrorHorizontal)
        XCTAssertFalse(p.mirrored.mirrored.mirrorHorizontal)
    }
}
