// End-to-end correctness of the M0 render path, with media the tests synthesise themselves.
// Each synthetic frame is a solid colour that encodes its own index, so a decoded or rendered
// frame can be checked against the exact source frame it must have come from.

import XCTest
import AVFoundation
import Metal
@testable import SharpyEngine
@testable import SharpyRender

final class RenderTests: XCTestCase {
    static let rate = FrameRate.r30
    static let frames: Int64 = 60
    static let w = 640, h = 360
    static var clipURL: URL!

    /// Colour for frame i: red ramps with the index, green fixed, blue identifies the clip.
    static func colour(_ i: Int64, clip: UInt8 = 200) -> (r: UInt8, g: UInt8, b: UInt8) { (UInt8(min(255, 20 + i * 3)), 128, clip) }

    override class func setUp() {
        super.setUp()
        clipURL = FileManager.default.temporaryDirectory.appendingPathComponent("sharpy-synth-\(UUID().uuidString).mov")
        try! synthesise(to: clipURL, frames: frames, clip: 200)
    }

    override class func tearDown() {
        if ProcessInfo.processInfo.environment["SHARPY_KEEP_TEST_MEDIA"] == nil { try? FileManager.default.removeItem(at: clipURL) } else { print("kept \(clipURL.path)") }
        super.tearDown()
    }

    /// ProRes keeps the solid colours within a couple of code values; H.264 would need a wider tolerance.
    static func synthesise(to url: URL, frames: Int64, clip: UInt8) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.proRes422HQ, AVVideoWidthKey: w, AVVideoHeightKey: h,
                                                                             AVVideoColorPropertiesKey: ColorTag.writer709])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            let c = colour(i, clip: clip)
            ColorTag.tag709(pb!)
            CVPixelBufferLockBaseAddress(pb!, [])
            let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pb!)
            for y in 0..<h { for x in 0..<w { let p = base + y * stride + x * 4; p[0] = c.b; p[1] = c.g; p[2] = c.r; p[3] = 255 } }
            CVPixelBufferUnlockBaseAddress(pb!, [])
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
            XCTAssertTrue(adaptor.append(pb!, withPresentationTime: CMTime(value: i, timescale: 30)))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0); writer.finishWriting { done.signal() }; done.wait()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    }

    static func bgra(of pb: CVPixelBuffer, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let p = base + y * CVPixelBufferGetBytesPerRow(pb) + x * 4
        return (p[2], p[1], p[0])
    }

    static func bgra(of tex: MTLTexture, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        var px = [UInt8](repeating: 0, count: 4)
        tex.getBytes(&px, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return (px[2], px[1], px[0])
    }

    func assertColour(_ got: (r: UInt8, g: UInt8, b: UInt8), _ want: (r: UInt8, g: UInt8, b: UInt8), tol: Int = 6, _ msg: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(abs(Int(got.r) - Int(want.r)), tol, "\(msg): red got \(got.r) want \(want.r)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(Int(got.g) - Int(want.g)), tol, "\(msg): green got \(got.g) want \(want.g)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(Int(got.b) - Int(want.b)), tol, "\(msg): blue got \(got.b) want \(want.b)", file: file, line: line)
    }

    // MARK: tests

    func testFrameSourceIsFrameAccurateSequentiallyAndOnSeek() throws {
        let src = try SequentialFrameSource(url: Self.clipURL, pixelFormat: kCVPixelFormatType_32BGRA)
        XCTAssertEqual(src.nominalFrameRate.fps, Rational(30))
        XCTAssertEqual(src.duration, TimeValue(frames: Self.frames, at: Self.rate))
        for i: Int64 in [0, 1, 2, 3, 17, 18, 19] {                       // sequential
            let f = try XCTUnwrap(try src.frame(at: TimeValue(frames: i, at: Self.rate)))
            XCTAssertEqual(f.presentation, TimeValue(frames: i, at: Self.rate))
            assertColour(Self.bgra(of: f.pixelBuffer, x: 320, y: 180), Self.colour(i), "frame \(i)")
        }
        for i: Int64 in [45, 7, 59, 30, 0] {                              // seeks, forward and back
            let f = try XCTUnwrap(try src.frame(at: TimeValue(frames: i, at: Self.rate)))
            XCTAssertEqual(f.presentation, TimeValue(frames: i, at: Self.rate), "seek to \(i)")
            assertColour(Self.bgra(of: f.pixelBuffer, x: 10, y: 10), Self.colour(i), "seek \(i)")
        }
        // mid-frame instant resolves to the containing frame
        let mid = TimeValue(frames: 12, at: Self.rate) + TimeValue(seconds: Rational(1, 90))
        XCTAssertEqual(try XCTUnwrap(try src.frame(at: mid)).presentation, TimeValue(frames: 12, at: Self.rate))
        XCTAssertNil(try src.frame(at: TimeValue(frames: Self.frames + 5, at: Self.rate)), "past the end")
    }

    func testCompositorPlacesLayersExactly() throws {
        let comp = try MetalCompositor()
        let src = try SequentialFrameSource(url: Self.clipURL)                 // NV12 path through the kernel
        let base = try XCTUnwrap(try src.frame(at: TimeValue(frames: 5, at: Self.rate)))
        let over = try XCTUnwrap(try src.frame(at: TimeValue(frames: 40, at: Self.rate)))
        let out = comp.makeOutputTexture(width: Self.w, height: Self.h)
        // read back needs a shared texture; blit private -> shared
        let shared = comp.device.makeTexture(descriptor: {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Self.w, height: Self.h, mipmapped: false)
            d.storageMode = .shared; d.usage = [.shaderWrite, .shaderRead]; return d }())!
        let cb = try comp.encode(layers: [
            CompositeLayer(pixelBuffer: base.pixelBuffer, placement: .full),
            CompositeLayer(pixelBuffer: over.pixelBuffer, placement: LayerPlacement(offset: SIMD2(320, 180), scale: 0.5, opacity: 1)),
        ], into: shared)
        cb.commit(); cb.waitUntilCompleted()
        _ = out
        assertColour(Self.bgra(of: shared, x: 100, y: 100), Self.colour(5), "base layer region")
        assertColour(Self.bgra(of: shared, x: 480, y: 270), Self.colour(40), "overlay region (scaled 0.5 at 320,180)")
        assertColour(Self.bgra(of: shared, x: 319, y: 179), Self.colour(5), "one pixel outside the overlay")
        assertColour(Self.bgra(of: shared, x: 320, y: 180), Self.colour(40), "overlay top-left corner is inside")
    }

    func testRenderedTimelineReflectsRippleDelete() throws {
        // timeline: whole clip [0,60), then ripple-delete frames [10,20) → 50 frames; output frame 10 must be source frame 20.
        var log = CommandLog(initial: Document(timeline: Timeline(name: "t", frameRate: Self.rate)))
        let asset = AssetRef(contentHash: "synth", path: Self.clipURL.path, duration: TimeValue(frames: Self.frames, at: Self.rate), frameRate: Self.rate, hasVideo: true, hasAudio: false)
        try log.append(.addAsset(asset)); try log.append(.addTrack(kind: .video, name: "V1"))
        let id = log.head.assets.keys.first!
        func t(_ f: Int64) -> TimeValue { TimeValue(frames: f, at: Self.rate) }
        let basis = Basis.measuredMaterial(ref: "test", detail: "synthetic", confidence: .one)
        try log.append(.placeClip(track: 0, clip: Clip(asset: id, source: TimeRange(start: t(0), end: t(60)), start: t(0)), decision: Decision(kind: .cut, at: t(0), basis: basis)))
        try log.append(.rippleDelete(track: 0, range: TimeRange(start: t(10), end: t(20)), decision: Decision(kind: .cut, at: t(10), basis: basis)))
        XCTAssertEqual(log.head.timeline.duration, t(50))

        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("sharpy-render-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: outURL) }
        let session = try RenderSession(document: log.head, options: RenderOptions(width: Self.w, height: Self.h, codec: .proRes422HQ))
        let report = try session.render(to: outURL)
        XCTAssertEqual(report.framesRendered, 50)
        XCTAssertEqual(report.duration, t(50))

        let check = try SequentialFrameSource(url: outURL, pixelFormat: kCVPixelFormatType_32BGRA)
        XCTAssertEqual(check.duration, t(50))
        for (outFrame, srcFrame): (Int64, Int64) in [(0, 0), (9, 9), (10, 20), (11, 21), (49, 59)] {
            let f = try XCTUnwrap(try check.frame(at: t(outFrame)))
            assertColour(Self.bgra(of: f.pixelBuffer, x: 300, y: 200), Self.colour(srcFrame), "output frame \(outFrame) should be source frame \(srcFrame)")
        }
        print("render: \(report.framesRendered) frames in \(String(format: "%.2f", report.wallSeconds)) s = \(String(format: "%.1f", report.fps)) fps (640x360 ProRes, synchronous per frame)")
    }
}
