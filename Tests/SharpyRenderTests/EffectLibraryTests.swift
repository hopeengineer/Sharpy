// The self-evolving part. If this accepts a broken effect, the agent will believe an edit was
// applied that was not — so most of these are about what it must REFUSE.

import XCTest
import Metal
@testable import SharpyEngine
@testable import SharpyRender

final class EffectLibraryTests: XCTestCase {
    func library() throws -> EffectLibrary {
        try EffectLibrary(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("sharpy-effects-\(UUID().uuidString).json"))
    }

    /// The cinematic look the user described: warm highlights, cool shadows, lifted blacks.
    var teal: EffectSpec {
        EffectSpec(name: "warm-highlights", summary: "Warm the highlights, cool the shadows, lift the blacks — the film look.",
                   parameters: [
                       EffectParameter(name: "warmth", value: 0.08, minimum: 0, maximum: 0.4,
                                       meaning: "how much yellow goes into the bright end"),
                       EffectParameter(name: "lift", value: 0.02, minimum: 0, maximum: 0.15,
                                       meaning: "how far off pure black the shadows sit"),
                   ],
                   body: """
                   float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
                   float3 warm = float3(c.r + warmth * luma, c.g + warmth * luma * 0.6, c.b - warmth * luma * 0.5);
                   float3 cool = float3(warm.r, warm.g, warm.b + lift * (1.0 - luma));
                   return clamp(cool + lift * (1.0 - luma), 0.0, 1.0);
                   """)
    }

    func testAnAgentAuthoredLookCompilesAndIsMeasured() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let validation = try library().validate(teal)
        XCTAssertTrue(validation.compiles, validation.compileError ?? "")
        XCTAssertTrue(validation.usable, validation.summary)
        XCTAssertFalse(validation.samples.isEmpty)
    }

    /// Compiling is not the same as doing something. An effect that returns its input unchanged
    /// must be REFUSED — otherwise the agent applies it, sees no error, and reports the edit done.
    func testAnEffectThatDoesNothingIsRefused() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let inert = EffectSpec(name: "inert", summary: "does nothing", parameters: [],
                               body: "return c;")
        let validation = try library().validate(inert)
        XCTAssertTrue(validation.compiles, "it is perfectly valid Metal")
        XCTAssertTrue(validation.changedNothing)
        XCTAssertFalse(validation.usable, "…and it must still be refused")
        XCTAssertTrue(validation.summary.contains("silently does nothing"))
    }

    func testAnEffectThatCrushesToBlackIsRefused() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let dark = EffectSpec(name: "void", summary: "black", parameters: [],
                              body: "return float3(0.0);")
        let validation = try library().validate(dark)
        XCTAssertTrue(validation.crushedToBlack)
        XCTAssertFalse(validation.usable)
    }

    func testAnEffectProducingNaNIsRefused() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let broken = EffectSpec(name: "nan", summary: "divides by zero", parameters: [],
                                body: "return c / (c - c);")
        let validation = try library().validate(broken)
        XCTAssertTrue(validation.producedNaN, "\(validation.samples)")
        XCTAssertFalse(validation.usable)
    }

    func testAnEffectThatWillNotCompileIsRefusedWithItsError() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let nonsense = EffectSpec(name: "nonsense", summary: "not metal", parameters: [],
                                  body: "return purple;")
        let validation = try library().validate(nonsense)
        XCTAssertFalse(validation.compiles)
        XCTAssertNotNil(validation.compileError)
        XCTAssertTrue(validation.summary.contains("does not compile"))
    }

    /// A body that closes its own function could redefine what the compositor relies on. This is a
    /// structural check, which is the kind worth having — exact, not a guess about intent.
    func testABodyThatEscapesItsFunctionIsRefused() throws {
        let escaping = EffectSpec(name: "escape", summary: "escapes", parameters: [],
                                  body: "return c; } static inline float3 evil(float3 x) { return x;")
        XCTAssertThrowsError(try EffectLibrary.checkSafe(escaping.body)) { error in
            XCTAssertTrue("\(error)".contains("brace"), "\(error)")
        }
    }

    func testABodyDeclaringShaderStructureIsRefused() throws {
        for bad in ["#include <metal_stdlib>\nreturn c;",
                    "kernel void x() {}\nreturn c;",
                    "texture2d<float> t; return c;"] {
            XCTAssertThrowsError(try EffectLibrary.checkSafe(bad), bad)
        }
    }

    func testABodyThatNeverReturnsIsRefused() {
        XCTAssertThrowsError(try EffectLibrary.checkSafe("float x = c.r * 2.0;"))
    }

    /// Only effects that passed are written. A library holding a broken effect is a trap for the
    /// next session, which will find it there and assume it works.
    func testOnlyWorkingEffectsAreKept() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let lib = try library()
        XCTAssertThrowsError(try lib.register(EffectSpec(name: "inert", summary: "", parameters: [],
                                                         body: "return c;")))
        XCTAssertTrue(lib.all().isEmpty, "a refused effect must not be saved")
        try lib.register(teal)
        XCTAssertEqual(lib.all().count, 1)
        XCTAssertNotNil(lib.named("warm-highlights"))
    }

    /// The point of a library: the next video starts with what the last one taught it.
    func testAnEffectSurvivesTheProcess() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharpy-effects-\(UUID().uuidString).json")
        try EffectLibrary(url: url).register(teal)
        XCTAssertNotNil(try EffectLibrary(url: url).named("warm-highlights"),
                        "an effect written today must be there tomorrow, or nothing accumulates")
    }

    /// Parameters are clamped into the range the author declared, so a value nobody checked cannot
    /// turn a subtle grade into a broken one.
    func testParametersAreClampedToTheirDeclaredRange() {
        let p = EffectParameter(name: "warmth", value: 99, minimum: 0, maximum: 0.4)
        XCTAssertEqual(p.clamped, 0.4)
        XCTAssertTrue(EffectSpec(name: "x", summary: "", parameters: [p], body: "return c;")
            .msl.contains("const float warmth = 0.4;"))
    }
}

/// The loop closed: an effect the agent wrote actually changes rendered pixels.
extension EffectLibraryTests {
    func solid(_ w: Int, _ h: Int, r: UInt8, g: UInt8, b: UInt8) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<h { for x in 0..<w {
            let p = base + y * stride + x * 4
            p[0] = b; p[1] = g; p[2] = r; p[3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    func render(_ layer: CVPixelBuffer, look: EffectSpec?, w: Int, h: Int) throws -> (UInt8, UInt8, UInt8) {
        let compositor = try MetalCompositor(colorPipeline: .passthrough, look: look)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderWrite, .shaderRead]; d.storageMode = .shared
        let out = compositor.device.makeTexture(descriptor: d)!
        let cb = try compositor.encode(layers: [CompositeLayer(pixelBuffer: layer)], into: out, ids: nil)
        cb.commit(); cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        out.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return (bytes[2], bytes[1], bytes[0])      // BGRA in memory, returned as RGB
    }

    /// An agent writes a warm grade; the rendered frame is warmer. This is the whole claim of
    /// self-evolution reduced to something falsifiable.
    func testAnAuthoredLookChangesTheRenderedPicture() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let grey = solid(16, 16, r: 128, g: 128, b: 128)
        let plain = try render(grey, look: nil, w: 16, h: 16)
        let graded = try render(grey, look: teal, w: 16, h: 16)
        XCTAssertGreaterThan(graded.0, plain.0, "red is lifted by the warm grade")
        XCTAssertLessThanOrEqual(graded.2, plain.2 + 6, "blue is not lifted more than red")
        XCTAssertTrue(graded != plain, "the look must actually reach the pixels")
    }

    /// No look must render exactly as before — self-evolution cannot cost anything when unused.
    func testNoLookLeavesTheRenderUnchanged() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let grey = solid(16, 16, r: 100, g: 140, b: 200)
        XCTAssertEqual(try render(grey, look: nil, w: 16, h: 16).0, 100, accuracy: 2)
        XCTAssertEqual(try render(grey, look: nil, w: 16, h: 16).1, 140, accuracy: 2)
    }
}
