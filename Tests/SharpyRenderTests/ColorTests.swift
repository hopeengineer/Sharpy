// Colour management correctness. These assert against values computed from the published
// transfer functions, not against "whatever the code produced" — a colour test that only checks
// self-consistency would pass just as happily with the transform switched off.

import XCTest
import Metal
import CoreVideo
@testable import SharpyEngine
@testable import SharpyRender

final class ColorTests: XCTestCase {

    /// The sRGB opto-electronic transfer function (IEC 61966-2-1): linear → display code value.
    static func srgbEncode(_ linear: Double) -> Double {
        linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1.0 / 2.4) - 0.055
    }

    static func makeBGRA(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferMetalCompatibilityKey as String: true,
                             kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary, &pb)
        let buf = pb!
        ColorTag.tag709(buf)
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<height { for x in 0..<width {
            let p = base + y * stride + x * 4
            p[0] = b; p[1] = g; p[2] = r; p[3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    static func composite(_ pipeline: ColorPipeline, input: CVPixelBuffer, width: Int, height: Int) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        let comp = try MetalCompositor(colorPipeline: pipeline)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.storageMode = .shared; d.usage = [.shaderWrite, .shaderRead]
        let tex = comp.device.makeTexture(descriptor: d)!
        let cb = try comp.encode(layers: [CompositeLayer(pixelBuffer: input, placement: .full)], into: tex)
        cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: 4)
        tex.getBytes(&px, bytesPerRow: 4, from: MTLRegionMake2D(width / 2, height / 2, 1, 1), mipmapLevel: 0)
        return (px[2], px[1], px[0])
    }

    // MARK: tests

    func testOCIOIsLinkedAndShipsTheACESConfig() throws {
        XCTAssertFalse(ColorTransform.ocioVersion.isEmpty)
        let spaces = try ColorTransform.colorSpaces()
        XCTAssertGreaterThan(spaces.count, 10, "built-in config should carry the ACES spaces")
        for required in ["ACEScg", "ACES2065-1", "sRGB - Display", "Linear Rec.709 (sRGB)"] {
            XCTAssertTrue(spaces.contains(required), "config is missing \(required); available: \(spaces.prefix(30))")
        }
    }

    func testTransformGeneratesCallableMetal() throws {
        let t = try ColorTransform(from: "Linear Rec.709 (sRGB)", to: "sRGB - Display", functionName: "SharpyOutputTransform")
        XCTAssertTrue(t.msl.contains("float4 SharpyOutputTransform("), "must expose the free function the kernel calls")
        XCTAssertTrue(t.luts.isEmpty, "this transform is analytic")
        XCTAssertGreaterThan(t.msl.count, 200)
    }

    /// The load-bearing test: mid grey through the display transform must land where the sRGB
    /// standard says, not merely somewhere repeatable.
    func testLinearToDisplayMatchesTheSRGBStandard() throws {
        let w = 16, h = 16
        for code in [UInt8(46), UInt8(128), UInt8(220)] {                // linear inputs to try
            let linear = Double(code) / 255.0
            let expected = Self.srgbEncode(linear) * 255.0
            let input = Self.makeBGRA(width: w, height: h, r: code, g: code, b: code)
            let pipeline = ColorPipeline(input: nil, output: try ColorTransform(from: "Linear Rec.709 (sRGB)", to: "sRGB - Display", functionName: "SharpyOutputTransform"))
            let got = try Self.composite(pipeline, input: input, width: w, height: h)
            XCTAssertLessThanOrEqual(abs(Double(got.r) - expected), 2.0,
                                     "linear \(code)/255 should encode to \(Int(expected.rounded())), got \(got.r)")
            XCTAssertEqual(got.r, got.g); XCTAssertEqual(got.g, got.b)
        }
        // 0.18 mid grey specifically — the number a colourist would check first.
        let mid = Self.srgbEncode(0.18) * 255
        XCTAssertEqual(Int(mid.rounded()), 118, "sanity: sRGB encoding of linear 0.18 is 118/255")
    }

    func testPassthroughLeavesValuesAlone() throws {
        let w = 16, h = 16
        let input = Self.makeBGRA(width: w, height: h, r: 46, g: 128, b: 220)
        let got = try Self.composite(.passthrough, input: input, width: w, height: h)
        XCTAssertEqual(got.r, 46); XCTAssertEqual(got.g, 128); XCTAssertEqual(got.b, 220)
    }

    /// A full round trip should return what it started with: any drift is the pipeline lying.
    func testRoundTripThroughACEScgIsIdentity() throws {
        let w = 16, h = 16
        let pipeline = ColorPipeline(
            input: try ColorTransform(from: "sRGB - Display", to: "ACEScg", functionName: "SharpyInputTransform"),
            output: try ColorTransform(from: "ACEScg", to: "sRGB - Display", functionName: "SharpyOutputTransform"))
        for code in [UInt8(20), UInt8(90), UInt8(200)] {
            let input = Self.makeBGRA(width: w, height: h, r: code, g: code, b: code)
            let got = try Self.composite(pipeline, input: input, width: w, height: h)
            XCTAssertLessThanOrEqual(abs(Int(got.r) - Int(code)), 2, "sRGB → ACEScg → sRGB should return \(code), got \(got.r)")
        }
    }

    /// Blending happens in the working space, so a 50 % mix of black and white is *linear* 0.5,
    /// which displays as sRGB 188 — not 128. Getting this wrong is the classic compositing bug.
    func testBlendingHappensInLinearLight() throws {
        let w = 16, h = 16
        let black = Self.makeBGRA(width: w, height: h, r: 0, g: 0, b: 0)
        let white = Self.makeBGRA(width: w, height: h, r: 255, g: 255, b: 255)
        let pipeline = ColorPipeline(input: nil, output: try ColorTransform(from: "Linear Rec.709 (sRGB)", to: "sRGB - Display", functionName: "SharpyOutputTransform"))
        let comp = try MetalCompositor(colorPipeline: pipeline)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.storageMode = .shared; d.usage = [.shaderWrite, .shaderRead]
        let tex = comp.device.makeTexture(descriptor: d)!
        let cb = try comp.encode(layers: [
            CompositeLayer(pixelBuffer: black, placement: .full),
            CompositeLayer(pixelBuffer: white, placement: LayerPlacement(offset: .zero, scale: 1, opacity: 0.5)),
        ], into: tex)
        cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: 4)
        tex.getBytes(&px, bytesPerRow: 4, from: MTLRegionMake2D(w / 2, h / 2, 1, 1), mipmapLevel: 0)
        let expected = Self.srgbEncode(0.5) * 255      // ≈ 188
        XCTAssertLessThanOrEqual(abs(Double(px[2]) - expected), 2.0,
                                 "a 50% linear mix must display as \(Int(expected.rounded())), got \(px[2]) — 128 would mean blending in display space")
    }

    func testLUTRequiringTransformIsRefusedNotSilentlyWrong() throws {
        // No path in the built-in config currently needs LUTs, so this documents the contract:
        // if one ever does, the error names it rather than rendering wrong colour.
        let e = ColorTransformError.needsLUTs(source: "A", destination: "B", count: 2)
        XCTAssertTrue(e.description.contains("Refusing"))
    }
}
