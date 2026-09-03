// Speech → words with timings, using Apple's on-device SpeechAnalyzer.
//
// Measured on this machine: 94× realtime, 20 MB of process RSS, because the model lives in the OS
// rather than in our memory budget. That makes it the right engine for the live pass — but not
// for the authoritative transcript: on real speech it produced ~9 adjudicated errors against
// whisper-turbo's ~3, including one that inverted meaning ("did" for "didn't"). So this is the
// preview engine, and the verbatim engine votes on top of it.

import Foundation
import AVFoundation
import Speech
import SharpyEngine

public enum SpeechIndexError: Error, CustomStringConvertible {
    case unsupportedLocale(String)
    case assetInstallFailed(String)
    case noAudio(URL)
    public var description: String {
        switch self {
        case .unsupportedLocale(let l): return "no on-device speech model for \(l)"
        case .assetInstallFailed(let m): return "speech asset install failed: \(m)"
        case .noAudio(let u): return "no audio track in \(u.lastPathComponent)"
        }
    }
}

public struct SpeechIndexer {
    public let locale: Locale
    public init(locale: Locale = Locale(identifier: "en-US")) { self.locale = locale }

    /// Transcribe a file to word-level timings. `asset` is the document's id for the media, so the
    /// transcript can be attached to it in the index.
    @available(macOS 26.0, *)
    public func transcribe(url: URL, asset: NodeID) async throws -> Transcript {
        let file = try AVAudioFile(forReading: url)

        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            do { try await request.downloadAndInstall() }
            catch { throw SpeechIndexError.assetInstallFailed(String(describing: error)) }
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Collect concurrently with analysis: results stream as the file is consumed.
        let collector = Task { () -> [Word] in
            var words: [Word] = []
            for try await result in transcriber.results where result.isFinal {
                let attributed = result.text
                for run in attributed.runs {
                    let piece = String(attributed[run.range].characters)
                    let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    guard let span = run.audioTimeRange else { continue }
                    let start = TimeValue(seconds: Rational(Int64(span.start.value), Int64(span.start.timescale)))
                    let end = TimeValue(seconds: Rational(Int64(span.end.value), Int64(span.end.timescale)))
                    guard start < end else { continue }
                    words.append(Word(index: words.count, text: trimmed,
                                      range: TimeRange(start: start, end: end),
                                      // Apple exposes no per-word confidence; this is the engine's
                                      // measured standing, not a claim about this particular word.
                                      confidence: Rational(75, 100),
                                      sources: ["apple-speechanalyzer"]))
                }
            }
            return words
        }

        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        let words = try await collector.value
        return Transcript(asset: asset, words: words, engines: ["apple-speechanalyzer"],
                          language: locale.identifier)
    }
}
