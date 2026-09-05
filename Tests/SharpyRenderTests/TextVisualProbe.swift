import XCTest
import Metal
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
@testable import SharpyEngine
@testable import SharpyRender

/// Not an assertion — a look. Numbers said the compositing was right; this is the picture.
final class TextVisualProbe: XCTestCase {
    func testWriteACaptionedFrame() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let source = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/20260904_014657.mp4")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("no footage") }

        let frames = try SequentialFrameSource(url: source)
        guard let frame = try frames.frame(at: TimeValue(seconds: Rational(12, 1))) else {
            throw XCTSkip("no frame")
        }
        let w = frames.width, h = frames.height
        let compositor = try MetalCompositor()
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderWrite, .shaderRead]; d.storageMode = .shared
        let out = compositor.device.makeTexture(descriptor: d)!

        let caption = try TextRenderer.render("this is what a burned-in caption looks like",
                                              style: .caption(pointSize: Double(w) * 0.055,
                                                              maximumWidth: Double(w) * 0.82))
        let label = try TextRenderer.render("SECTION ONE", style: .label(pointSize: Double(w) * 0.06))
        let badge = try TextRenderer.render("16.8M",
                                            style: TextStyle(pointSize: Double(w) * 0.035,
                                                             backing: .pill(red: 0.9, green: 0.25, blue: 0.15,
                                                                            alpha: 0.95, cornerRadius: Double(w) * 0.012),
                                                             padding: Double(w) * 0.014))

        let layers = [
            CompositeLayer(pixelBuffer: frame.pixelBuffer,
                           placement: LayerPlacement(offset: SIMD2(Float(w - 3840) / 2, Float(h - 2160) / 2),
                                                     scale: 1, rotation: Float(frames.rotationDegrees))),
            CompositeLayer(pixelBuffer: label.pixelBuffer,
                           placement: TextRenderer.placement(for: label, in: w, outputHeight: h,
                                                             anchor: (x: 0.28, y: 0.10))),
            CompositeLayer(pixelBuffer: badge.pixelBuffer,
                           placement: TextRenderer.placement(for: badge, in: w, outputHeight: h,
                                                             anchor: (x: 0.22, y: 0.17))),
            CompositeLayer(pixelBuffer: caption.pixelBuffer,
                           placement: TextRenderer.placement(for: caption, in: w, outputHeight: h,
                                                             anchor: (x: 0.5, y: 0.80))),
        ]
        let cb = try compositor.encode(layers: layers, into: out, ids: nil)
        cb.commit(); cb.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        out.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                     | CGBitmapInfo.byteOrder32Little.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)!
        let url = URL(fileURLWithPath: "/private/tmp/claude-501/-Applications-Sharpy/48399543-83e4-45e2-9363-638d25e2c50a/scratchpad/captioned.png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        print("PROBE wrote \(url.path)")
    }
}
