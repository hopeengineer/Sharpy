// The second vote.
//
// The plan locks two independent engines producing the transcript, their agreement standing as
// the per-word confidence, and Apple's SpeechAnalyzer excluded from that pair: on real narration
// Apple produced ~9 adjudicated errors including one that inverts meaning ("did" for "didn't").
// An engine that wrong cannot be half of a confidence signal. Where it agrees with the primary it
// certifies nothing; where both fail the same way it stamps the error high-confidence and lets it
// render, which is the exact failure this tool exists to prevent.
//
// That pairing was nevertheless what shipped for a while, because parakeet had been measured only
// through Python MLX and `mlx-swift-lm` contains no ASR at all — its libraries are LLM, VLM,
// embedders and rerankers. The decided design was unreachable through the pinned runtime, and
// rather than say so I substituted the disqualified engine and moved on.
//
// Parakeet TDT v3 through FluidAudio (Apache-2.0, CoreML) restores it. Parakeet is the right
// second engine for a specific reason rather than a general one: it is a different architecture
// (RNN-T token-and-duration transducer, not an autoregressive attention decoder), trained on
// different data, so its errors are uncorrelated with Whisper's. Two engines that fail the same
// way agree on the failure, and agreement between them would mean nothing.
//
// It emits sub-word SentencePiece tokens, so words come from `buildWordTimings`, which groups on
// the `▁` boundary marker. Token times are emission times, not forced-alignment boundaries — the
// decoder emits once it has heard enough context, so a word's start can sit slightly late. That
// is why `TranscriptMerge` aligns by SEQUENCE and never by time overlap.

import Foundation
import AVFoundation
import FluidAudio
import SharpyEngine

public enum ParakeetIndexError: Error, CustomStringConvertible {
    case modelUnavailable(String)
    case noWordTimings
    public var description: String {
        switch self {
        case .modelUnavailable(let m): return "Parakeet models unavailable: \(m)"
        case .noWordTimings: return "Parakeet returned a transcript with no token timings"
        }
    }
}

public struct ParakeetIndexer {
    /// Parakeet TDT v3 — 25 European languages, the version measured at 0.57 % WER through MLX.
    public let version: AsrModelVersion
    /// The encoder runs int8 on the Neural Engine by default. Held here rather than hardcoded so a
    /// precision change is a measurable variable and not an invisible one.
    public let encoderPrecision: ParakeetEncoderPrecision

    public init(version: AsrModelVersion = .v3, encoderPrecision: ParakeetEncoderPrecision = .int8) {
        self.version = version
        self.encoderPrecision = encoderPrecision
    }

    public func transcribe(url: URL, asset: NodeID) async throws -> Transcript {
        let models: AsrModels
        do {
            models = try await AsrModels.downloadAndLoad(version: version, encoderPrecision: encoderPrecision)
        } catch {
            throw ParakeetIndexError.modelUnavailable(String(describing: error))
        }
        let manager = AsrManager()
        try await manager.loadModels(models)

        var state = try TdtDecoderState()
        let result = try await manager.transcribe(url, decoderState: &state)
        guard let tokens = result.tokenTimings, !tokens.isEmpty else {
            throw ParakeetIndexError.noWordTimings
        }

        // Sub-word tokens -> words. Doing this here rather than downstream keeps every engine's
        // output in the same shape, which is what lets the merge compare them at all.
        let timings = buildWordTimings(from: tokens)

        // A word's confidence is the mean of the confidences of the tokens that built it. Taking
        // the first token's would call a word certain on the strength of its first syllable.
        var tokenCursor = 0
        var words: [Word] = []
        for timing in timings {
            let text = timing.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, timing.endTime > timing.startTime else { continue }
            var confidences: [Float] = []
            while tokenCursor < tokens.count, tokens[tokenCursor].startTime < timing.endTime {
                if tokens[tokenCursor].endTime > timing.startTime {
                    confidences.append(tokens[tokenCursor].confidence)
                }
                tokenCursor += 1
            }
            let mean = confidences.isEmpty ? result.confidence
                                           : confidences.reduce(0, +) / Float(confidences.count)
            words.append(Word(index: words.count, text: text,
                              range: TimeRange(start: TimeValue(seconds: Rational(Int64(timing.startTime * 1000), 1000)),
                                               end: TimeValue(seconds: Rational(Int64(timing.endTime * 1000), 1000))),
                              confidence: Rational(Int64(max(0, min(1, mean)) * 100), 100),
                              sources: ["parakeet-tdt-\(version)"]))
        }
        guard !words.isEmpty else { throw ParakeetIndexError.noWordTimings }
        return Transcript(asset: asset, words: words, engines: ["parakeet-tdt-\(version)"], language: "en")
    }
}
