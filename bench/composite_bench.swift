import Foundation
import AVFoundation
import CoreImage
import Metal

func peakRSSMB() -> Int { var ru = rusage(); getrusage(RUSAGE_SELF, &ru); return Int(ru.ru_maxrss / 1048576) }

@main struct CompositeBench {
  static func makeReader(_ url: URL) async throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
    let asset = AVURLAsset(url: url)
    let track = try await asset.loadTracks(withMediaType: .video).first!
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    out.alwaysCopiesSampleData = false
    reader.add(out); reader.startReading()
    return (reader, out)
  }
  static func run(_ url: URL, layers: Int, maxFrames: Int, label: String) async throws {
    let device = MTLCreateSystemDefaultDevice()!
    let ctx = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    var readers: [(AVAssetReader, AVAssetReaderTrackOutput)] = []
    for _ in 0..<layers { readers.append(try await makeReader(url)) }
    let w = 3840, h = 2160
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    d.usage = [.shaderWrite, .shaderRead, .renderTarget]
    let outTex = device.makeTexture(descriptor: d)!
    let queue = device.makeCommandQueue()!
    var n = 0; let t0 = Date()
    outer: while n < maxFrames {
      var composed: CIImage? = nil
      for (i, (_, out)) in readers.enumerated() {
        guard let sb = out.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else { break outer }
        var img = CIImage(cvPixelBuffer: pb)
        if i > 0 { // real PIP composite: scale, offset, 80% opacity
          img = img.transformed(by: CGAffineTransform(translationX: CGFloat(i) * 600, y: CGFloat(i) * 300).scaledBy(x: 0.5, y: 0.5))
          img = img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.8)])
        }
        composed = composed.map { img.composited(over: $0) } ?? img
      }
      let cb = queue.makeCommandBuffer()!
      ctx.render(composed!, to: outTex, commandBuffer: cb, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: CGColorSpaceCreateDeviceRGB())
      cb.commit(); cb.waitUntilCompleted()
      n += 1
    }
    let dt = Date().timeIntervalSince(t0)
    print(String(format: "COMPOSITE %-10@ layers=%d frames=%d wall=%.1fs fps=%.1f peakRSS=%dMB  (HW decode -> CoreImage/Metal composite -> 4K texture, sync per frame)", label as NSString, layers, n, dt, Double(n)/dt, peakRSSMB()))
  }
  static func main() async throws {
    let h264 = URL(fileURLWithPath: "media/test4k_h264.mp4")
    let prores = URL(fileURLWithPath: "media/test4k_prores422hq.mov")
    for l in [1, 2, 4] { try await run(h264, layers: l, maxFrames: 300, label: "4K H.264") }
    for l in [1, 2, 4] { try await run(prores, layers: l, maxFrames: 300, label: "4K ProRes") }
  }
}
