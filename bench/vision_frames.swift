import Foundation
import Vision
import AppKit

@main struct VisionFrames {
  static func main() throws {
    let dir = CommandLine.arguments[1]
    let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".jpg") }.sorted()
    let face = VNDetectFaceRectanglesRequest()
    let text = VNRecognizeTextRequest(); text.recognitionLevel = .accurate; text.usesLanguageCorrection = false
    let hands = VNDetectHumanHandPoseRequest(); hands.maximumHandCount = 4
    var results: [String: Any] = [:]
    let t0 = Date()
    for f in files {
      guard let img = NSImage(contentsOfFile: dir + "/" + f), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
      let h = VNImageRequestHandler(cgImage: cg, orientation: .up)
      try h.perform([face, text, hands])
      let faces = face.results?.count ?? 0
      let handCount = hands.results?.filter { $0.confidence > 0.5 }.count ?? 0
      let lines: [String] = (text.results ?? []).compactMap { $0.topCandidates(1).first }.filter { $0.confidence > 0.3 }.map { $0.string }
      results[f] = ["faces": faces, "hands": handCount, "text": lines]
      print("\(f) faces=\(faces) hands=\(handCount) text=\(lines)")
    }
    let dt = Date().timeIntervalSince(t0)
    print(String(format: "VISION-FRAMES %d frames in %.1fs (%.2fs/frame, face+accurateOCR+handpose)", files.count, dt, dt / Double(max(files.count,1))))
    let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: "results/vision_frames_nosfx.json"))
  }
}
