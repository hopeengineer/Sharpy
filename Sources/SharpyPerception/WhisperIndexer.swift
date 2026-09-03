// The verbatim engine, and the second vote.
//
// Apple's SpeechAnalyzer is fast and cheap but wrong for two jobs. It normalises fillers away
// entirely — measured on the user's reel it reported `fillers: 0` on narration that audibly
// contains them, which makes disfluency editing impossible — and it exposes no per-word
// confidence, so nothing downstream can tell a certain word from a guess.
//
// WhisperKit (MIT, CoreML, no Python) fixes both: it keeps what was said and it returns a
// `probability` per word. That per-word number plus agreement between two engines is what the
// confidence floor actually rests on, and it is why `remove_words` can refuse to cut beside a
// disputed word rather than shipping a meaning inversion.

import Foundation
import AVFoundation
import WhisperKit
import SharpyEngine

public enum WhisperIndexError: Error, CustomStringConvertible {
    case modelUnavailable(String)
    case noWordTimings
    public var description: String {
        switch self {
        case .modelUnavailable(let m): return "WhisperKit model unavailable: \(m)"
        case .noWordTimings: return "WhisperKit returned segments without word timings — wordTimestamps was not honoured"
        }
    }
}

public struct WhisperIndexer {
    /// Model name in WhisperKit's repo, which prefixes it with `openai_whisper-`. OpenAI's
    /// "large-v3-turbo" — the distilled-decoder release that measured best here, keeping every
    /// spoken filler with the fewest adjudicated errors — is `large-v3-v20240930` in this naming.
    /// WhisperKit's own `_turbo` suffix means something else entirely (its compute variant), which
    /// is exactly the kind of collision worth writing down.
    public let model: String
    public let language: String

    public init(model: String = "large-v3-v20240930", language: String = "en") {
        self.model = model
        self.language = language
    }

    public func transcribe(url: URL, asset: NodeID) async throws -> Transcript {
        let config = WhisperKitConfig(model: model)
        let whisper: WhisperKit
        do { whisper = try await WhisperKit(config) }
        catch {
            // Name what is actually there, so a wrong model string costs one turn rather than five.
            let available = (try? await WhisperKit.fetchAvailableModels()) ?? []
            let hint = available.isEmpty ? "" : "\n  available: \(available.prefix(12).joined(separator: ", "))"
            throw WhisperIndexError.modelUnavailable("\(model)\(hint)")
        }

        var options = DecodingOptions()
        options.wordTimestamps = true          // without this there is nothing to cut against
        options.language = language
        options.withoutTimestamps = false
        options.verbose = false

        let results = try await whisper.transcribe(audioPath: url.path, decodeOptions: options)

        var words: [Word] = []
        for result in results {
            for segment in result.segments {
                guard let timings = segment.words else { continue }
                for timing in timings {
                    let text = timing.word.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, timing.end > timing.start else { continue }
                    words.append(Word(index: words.count, text: text,
                                      range: TimeRange(start: TimeValue(seconds: Rational(Int64(timing.start * 1000), 1000)),
                                                       end: TimeValue(seconds: Rational(Int64(timing.end * 1000), 1000))),
                                      // The model's own probability, not a per-engine constant.
                                      confidence: Rational(Int64(max(0, min(1, timing.probability)) * 100), 100),
                                      sources: ["whisperkit-\(model)"]))
                }
            }
        }
        guard !words.isEmpty else { throw WhisperIndexError.noWordTimings }
        return Transcript(asset: asset, words: words, engines: ["whisperkit-\(model)"], language: language)
    }
}

extension IndexStore {
    /// The authoritative transcript: Apple's for speed, WhisperKit's for the words, and their
    /// agreement for the per-word confidence. Where the two disagree the confidence drops, which
    /// is what makes `CutsRestOnConfidentWords` able to hold a render.
    @available(macOS 26.0, *)
    public func votedTranscript(for url: URL,
                                apple: SpeechIndexer = SpeechIndexer(),
                                whisper: WhisperIndexer = WhisperIndexer()) async throws -> (Transcript, Bool) {
        let fingerprint = try MediaFingerprint(of: url)
        var record = load(fingerprint) ?? PerceptionRecord(fingerprint: fingerprint, path: url.path)
        let version = IndexStore.versions["votedTranscript"]
        if let existing = record.votedTranscript, record.producedBy["votedTranscript"] == version {
            return (existing, true)
        }
        let asset = NodeID(contentOf: url.path)
        // WhisperKit supplies the words — it is the verbatim engine, and Apple drops fillers.
        let primary = try await whisper.transcribe(url: url, asset: asset)
        let secondary = try await apple.transcribe(url: url, asset: asset)
        let voted = TranscriptMerge.agree(primary: primary, secondary: secondary)
        record.votedTranscript = voted
        record.producedBy["votedTranscript"] = version
        record.path = url.path
        try save(record)
        return (voted, false)
    }
}
