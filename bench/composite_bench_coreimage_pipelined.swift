import Foundation
import AVFoundation
import CoreImage
import Metal

func peakRSSMB() -> Int { var ru = rusage(); getrusage(RUSAGE_SELF, &ru); return Int(ru.ru_maxrss / 1048576) }
let gInflight = DispatchSemaphore(value: 3)

final class FrameSource: @unchecked Sendable {
  private var buf: [CVPixelBuffer] = []; private let lock = NSLock()
  let space = DispatchSemaphore(value: 3), avail = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
  let reader: AVAssetReader
  init(_ url: URL, fmt: String) throws {
    let asset = AVURLAsset(url: url)
    let track = asset.tracks(withMediaType: .video).first!
    reader = try AVAssetReader(asset: asset)
    var settings: [String: Any]? = nil
    if fmt == "nv12" { settings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] }
    if fmt == "bgra" { settings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] }
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)   // nil = decoder-native, no conversion
    out.alwaysCopiesSampleData = false
    reader.add(out); reader.startReading()
    Thread.detachNewThread { [self] in
      while let sb = out.copyNextSampleBuffer() {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
        space.wait(); lock.lock(); buf.append(pb); lock.unlock(); avail.signal()
      }
      avail.signal(); done.signal()
    }
  }
  func next() -> CVPixelBuffer? {
    avail.wait(); lock.lock(); defer { lock.unlock() }
    if buf.isEmpty { return nil }
    let p = buf.removeFirst(); space.signal(); return p
  }
  func stop() { reader.cancelReading(); for _ in 0..<8 { space.signal() }; done.wait() }
}

@main struct CompositeBench6 {
  static func run(_ url: URL, layers: Int, label: String, fmt: String, cap: Double) throws {
    let device = MTLCreateSystemDefaultDevice()!
    let ctx = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    let sources = try (0..<layers).map { _ in try FrameSource(url, fmt: fmt) }
    let w = 3840, h = 2160
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    d.usage = [.shaderWrite, .shaderRead, .renderTarget]
    let texes = (0..<3).map { _ in device.makeTexture(descriptor: d)! }
    let queue = device.makeCommandQueue()!
    var n = 0; let t0 = Date(); var fmtSeen: String = "?"
    outer: while Date().timeIntervalSince(t0) < cap {
      var composed: CIImage? = nil
      for (i, s) in sources.enumerated() {
        guard let pb = s.next() else { break outer }
        if n == 0 && i == 0 { let f = CVPixelBufferGetPixelFormatType(pb); fmtSeen = String(format: "%c%c%c%c", (f>>24)&255, (f>>16)&255, (f>>8)&255, f&255) }
        var img = CIImage(cvPixelBuffer: pb)
        if i > 0 {
          img = img.transformed(by: CGAffineTransform(translationX: CGFloat(i) * 500, y: CGFloat(i) * 250).scaledBy(x: 0.5, y: 0.5))
          img = img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.8)])
        }
        composed = composed.map { img.composited(over: $0) } ?? img
      }
      gInflight.wait()
      let cb = queue.makeCommandBuffer()!
      cb.addCompletedHandler { _ in gInflight.signal() }
      ctx.render(composed!, to: texes[n % 3], commandBuffer: cb, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: CGColorSpaceCreateDeviceRGB())
      cb.commit()
      n += 1
    }
    for _ in 0..<3 { gInflight.wait() }; for _ in 0..<3 { gInflight.signal() }
    let dt = Date().timeIntervalSince(t0)
    print(String(format: "COMPOSITE-PIPELINED %-9@ fmt=%-6@ (%@) layers=%d frames=%d wall=%.1fs fps=%.1f peakRSS=%dMB", label as NSString, fmt as NSString, fmtSeen as NSString, layers, n, dt, Double(n)/dt, peakRSSMB()))
    fflush(stdout)
    for s in sources { s.stop() }
  }
  static func main() throws {
    let fmt = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "native"
    let h264 = URL(fileURLWithPath: "media/test4k_h264.mp4"), prores = URL(fileURLWithPath: "media/test4k_prores422hq.mov")
    for l in [1, 2, 4, 6] { try run(h264, layers: l, label: "4K H.264", fmt: fmt, cap: 40) }
    for l in [1, 2, 4, 6] { try run(prores, layers: l, label: "4K ProRes", fmt: fmt, cap: 40) }
  }
}
