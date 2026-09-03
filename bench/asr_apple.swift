import Foundation
import Speech
import AVFoundation

func peakRSSMB() -> Int { var ru = rusage(); getrusage(RUSAGE_SELF, &ru); return Int(ru.ru_maxrss / 1048576) }

@main struct ASRBench {
  static func main() async throws {
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    let locale = Locale(identifier: "en-US")
    let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      print("installing speech assets..."); let t = Date(); try await req.downloadAndInstall(); print("installed in \(Date().timeIntervalSince(t))s")
    }
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let file = try AVAudioFile(forReading: url)
    let dur = Double(file.length) / file.processingFormat.sampleRate
    let t0 = Date()
    let collector = Task { () -> (Int, Int, String, [(String, Double, Double)]) in
      var words = 0, timed = 0, text = ""; var first: [(String, Double, Double)] = []
      for try await r in transcriber.results where r.isFinal {
        let s = String(r.text.characters); text += s
        for run in r.text.runs {
          let w = String(r.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
          if w.isEmpty { continue }
          words += 1
          if let tr = run.audioTimeRange { timed += 1; if first.count < 8 { first.append((w, tr.start.seconds, tr.end.seconds)) } }
        }
      }
      return (words, timed, text, first)
    }
    try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
    let (words, timed, text, first) = try await collector.value
    let dt = Date().timeIntervalSince(t0)
    let lower = text.lowercased()
    let fillers = lower.components(separatedBy: .whitespacesAndNewlines).filter { ["um","uh","um,","uh,","um.","uh."].contains($0) }.count
    print(String(format: "APPLE SpeechAnalyzer: wall=%.1fs audio=%.0fs RTFx=%.1f words=%d timed_runs=%d fillers(um/uh)=%d peakRSS=%dMB", dt, dur, dur/dt, words, timed, fillers, peakRSSMB()))
    print("   sample: " + String(text.prefix(160)))
    print("   words: " + first.map { "(\($0.0), \(String(format: "%.2f", $0.1))-\(String(format: "%.2f", $0.2)))" }.joined(separator: " "))
  }
}
