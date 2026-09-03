import Foundation
import AVFoundation
import Vision

func peakRSSMB() -> Int { var ru = rusage(); getrusage(RUSAGE_SELF, &ru); return Int(ru.ru_maxrss / 1048576) }

@main struct VisionBench {
  static func pass(_ url: URL, maxFrames: Int, mode: String) async throws {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    out.alwaysCopiesSampleData = false
    reader.add(out); reader.startReading()
    let face = VNDetectFaceRectanglesRequest()
    let text = VNRecognizeTextRequest(); text.recognitionLevel = .fast
    let pose = VNDetectHumanBodyPoseRequest()
    var n = 0, faces = 0, texts = 0
    let t0 = Date()
    while n < maxFrames, let sb = out.copyNextSampleBuffer() {
      guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
      if mode != "decode" {
        let h = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up)
        var reqs: [VNRequest] = []
        if mode.contains("face") { reqs.append(face) }
        if mode.contains("text") { reqs.append(text) }
        if mode.contains("pose") { reqs.append(pose) }
        try h.perform(reqs)
        faces += face.results?.count ?? 0
        texts += text.results?.count ?? 0
      }
      n += 1
    }
    let dt = Date().timeIntervalSince(t0)
    print(String(format: "VISION %-18@ %@  frames=%d wall=%.1fs fps=%.1f faces=%d textRegions=%d peakRSS=%dMB", mode as NSString, url.lastPathComponent as NSString, n, dt, Double(n)/dt, faces, texts, peakRSSMB()))
  }
  static func main() async throws {
    let f1080 = URL(fileURLWithPath: "media/talkinghead1080.mp4")
    let f4k = URL(fileURLWithPath: "media/test4k_h264.mp4")
    for m in ["decode", "face", "face+text", "face+text+pose"] { try await pass(f1080, maxFrames: 300, mode: m) }
    for m in ["decode", "face", "face+text"] { try await pass(f4k, maxFrames: 300, mode: m) }
  }
}
