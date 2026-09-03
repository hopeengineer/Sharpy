import Foundation
import AVFoundation
import Metal
import CoreVideo

func peakRSSMB() -> Int { var ru = rusage(); getrusage(RUSAGE_SELF, &ru); return Int(ru.ru_maxrss / 1048576) }
let gInflight = DispatchSemaphore(value: 3)

let shaderSrc = """
#include <metal_stdlib>
using namespace metal;
struct Layer { float2 offset; float scale; float alpha; };
kernel void composite(texture2d<float, access::write> out [[texture(0)]],
                      array<texture2d<float, access::sample>, 6> ys [[texture(1)]],
                      array<texture2d<float, access::sample>, 6> cs [[texture(7)]],
                      constant Layer* layers [[buffer(0)]],
                      constant uint& n [[buffer(1)]],
                      constant uint& isBGRA [[buffer(2)]],
                      uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
  constexpr sampler s(filter::linear, address::clamp_to_edge);
  float2 outSize = float2(out.get_width(), out.get_height());
  float3 rgb = float3(0.0);
  for (uint i = 0; i < n; i++) {
    float2 p = (float2(gid) - layers[i].offset) / layers[i].scale;
    float2 uv = p / outSize;
    if (uv.x < 0.0 || uv.y < 0.0 || uv.x >= 1.0 || uv.y >= 1.0) continue;
    float3 c;
    if (isBGRA) { c = ys[i].sample(s, uv).rgb; }
    else {
      float y = ys[i].sample(s, uv).r; float2 cbcr = cs[i].sample(s, uv).rg - 0.5;
      y = (y - 16.0/255.0) * (255.0/219.0);
      c = float3(y + 1.5748*cbcr.y, y - 0.1873*cbcr.x - 0.4681*cbcr.y, y + 1.8556*cbcr.x);
    }
    rgb = mix(rgb, c, layers[i].alpha);
  }
  out.write(float4(rgb, 1.0), gid);
}
"""

final class FrameSource: @unchecked Sendable {
  private var buf: [CVPixelBuffer] = []; private let lock = NSLock()
  let space = DispatchSemaphore(value: 3), avail = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
  let reader: AVAssetReader
  init(_ url: URL, bgra: Bool) throws {
    let asset = AVURLAsset(url: url)
    let track = asset.tracks(withMediaType: .video).first!
    reader = try AVAssetReader(asset: asset)
    let settings: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: bgra ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
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

struct LayerU { var offset: SIMD2<Float>; var scale: Float; var alpha: Float }

@main struct MetalCompositeBench {
  static func run(_ url: URL, layers: Int, label: String, bgra: Bool, cap: Double, device: MTLDevice, pso: MTLComputePipelineState, cache: CVMetalTextureCache) throws {
    let sources = try (0..<layers).map { _ in try FrameSource(url, bgra: bgra) }
    let w = 3840, h = 2160
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    d.usage = [.shaderWrite, .shaderRead]; d.storageMode = .private
    let texes = (0..<3).map { _ in device.makeTexture(descriptor: d)! }
    let queue = device.makeCommandQueue()!
    var lus: [LayerU] = []
    for i in 0..<6 {
      let fi = Float(i)
      let off = SIMD2<Float>(fi * 500.0, fi * 250.0)
      let sc: Float = (i == 0) ? 1.0 : 0.5
      let al: Float = (i == 0) ? 1.0 : 0.8
      lus.append(LayerU(offset: off, scale: sc, alpha: al))
    }
    var n = 0; let t0 = Date(); var nn = UInt32(layers); var isB = UInt32(bgra ? 1 : 0)
    outer: while Date().timeIntervalSince(t0) < cap {
      var keep: [CVMetalTexture] = []; var yT: [MTLTexture?] = Array(repeating: nil, count: 6); var cT: [MTLTexture?] = Array(repeating: nil, count: 6)
      for (i, s) in sources.enumerated() {
        guard let pb = s.next() else { break outer }
        var t0m: CVMetalTexture?
        if bgra {
          CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, .bgra8Unorm, w, h, 0, &t0m)
          keep.append(t0m!); yT[i] = CVMetalTextureGetTexture(t0m!); cT[i] = yT[i]
        } else {
          var t1m: CVMetalTexture?
          CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, .r8Unorm, w, h, 0, &t0m)
          CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, .rg8Unorm, w/2, h/2, 1, &t1m)
          keep.append(t0m!); keep.append(t1m!); yT[i] = CVMetalTextureGetTexture(t0m!); cT[i] = CVMetalTextureGetTexture(t1m!)
        }
      }
      for i in layers..<6 { yT[i] = yT[0]; cT[i] = cT[0] }   // fill unused slots
      gInflight.wait()
      let cb = queue.makeCommandBuffer()!
      let held = keep
      cb.addCompletedHandler { _ in _ = held.count; gInflight.signal() }
      let enc = cb.makeComputeCommandEncoder()!
      enc.setComputePipelineState(pso)
      enc.setTexture(texes[n % 3], index: 0)
      enc.setTextures(yT, range: 1..<7); enc.setTextures(cT, range: 7..<13)
      enc.setBytes(&lus, length: MemoryLayout<LayerU>.stride * 6, index: 0)
      enc.setBytes(&nn, length: 4, index: 1); enc.setBytes(&isB, length: 4, index: 2)
      let tg = MTLSize(width: 16, height: 16, depth: 1)
      enc.dispatchThreadgroups(MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1), threadsPerThreadgroup: tg)
      enc.endEncoding(); cb.commit()
      n += 1
    }
    for _ in 0..<3 { gInflight.wait() }; for _ in 0..<3 { gInflight.signal() }
    let dt = Date().timeIntervalSince(t0)
    print(String(format: "METAL-COMPOSITE %-9@ fmt=%-4@ layers=%d frames=%d wall=%.1fs fps=%.1f peakRSS=%dMB", label as NSString, (bgra ? "bgra" : "nv12") as NSString, layers, n, dt, Double(n)/dt, peakRSSMB()))
    fflush(stdout)
    for s in sources { s.stop() }
    CVMetalTextureCacheFlush(cache, 0)
  }
  static func main() throws {
    let device = MTLCreateSystemDefaultDevice()!
    let lib = try device.makeLibrary(source: shaderSrc, options: nil)
    let pso = try device.makeComputePipelineState(function: lib.makeFunction(name: "composite")!)
    var cache: CVMetalTextureCache?; CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
    let h264 = URL(fileURLWithPath: "media/test4k_h264.mp4"), prores = URL(fileURLWithPath: "media/test4k_prores422hq.mov")
    let bgra = CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "bgra"
    for l in [1, 2, 4, 6] { try run(h264, layers: l, label: "4K H.264", bgra: bgra, cap: 40, device: device, pso: pso, cache: cache!) }
    for l in [1, 2, 4, 6] { try run(prores, layers: l, label: "4K ProRes", bgra: bgra, cap: 40, device: device, pso: pso, cache: cache!) }
  }
}
