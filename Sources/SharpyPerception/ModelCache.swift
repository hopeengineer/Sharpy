// Loaded models are held once per process, not once per file.
//
// Both ASR indexers originally constructed their engine inside `transcribe`, so a batch of N
// files paid N model loads. That is invisible on a single reel and ruinous at ingest: measured on
// LibriSpeech test-clean, Parakeet ran at 43x realtime reloading per file against 171x on a
// single file, and WhisperKit — whose model is far larger — did not finish 25 files in the time
// Parakeet finished 2620.
//
// It is also a correctness trap in the making. An engine rebuilt per call cannot hold warm state,
// so any future caching inside the engine silently does nothing, and the cost shows up as "the
// machine is slow" rather than as a bug.
//
// Held by an actor because the underlying engines are reference types loaded from disk and must
// not be built twice concurrently: two ingests starting together would otherwise each pay a load
// and each hold a copy, which on a 16 GB machine is the difference between fitting and not.

import Foundation
import WhisperKit
import FluidAudio

/// A non-Sendable engine carried across an isolation boundary.
///
/// `WhisperKit` is an `open class` with no Sendable conformance, so a `Task<WhisperKit, Error>`
/// used to dedupe concurrent loads cannot type-check without this. The unchecked conformance is
/// sound because the box is only ever opened inside `ModelCache`'s actor — the instance is never
/// handed to a caller and never touched from two tasks at once. WhisperKit's own test suite uses
/// the same wrapper for the same reason.
private struct Unsafely<Wrapped>: @unchecked Sendable {
    let value: Wrapped
}

actor ModelCache {
    static let shared = ModelCache()

    private var whisper: [String: WhisperKit] = [:]
    private var parakeet: [String: AsrManager] = [:]
    /// In-flight loads, so N concurrent callers wait on one load rather than starting N.
    private var whisperLoading: [String: Task<Unsafely<WhisperKit>, Error>] = [:]
    private var parakeetLoading: [String: Task<AsrManager, Error>] = [:]

    /// Transcribes INSIDE the actor rather than handing the model out.
    ///
    /// `WhisperKit` is an `open class`, not an actor, and it is not Sendable — WhisperKit's own
    /// tests wrap it in `@unchecked Sendable` to use it across tasks. Nothing documents it as safe
    /// for concurrent calls, so two ingests sharing one cached instance would be a data race that
    /// shows up as a corrupted transcript rather than a crash. Keeping every access on the actor
    /// serialises calls, which costs nothing here (ingest is sequential) and removes the question.
    func transcribe(model: String, path: String,
                    options: DecodingOptions) async throws -> [TranscriptionResult] {
        let kit: WhisperKit
        if let existing = whisper[model] {
            kit = existing
        } else if let inFlight = whisperLoading[model] {
            kit = try await inFlight.value.value
        } else {
            let task = Task<Unsafely<WhisperKit>, Error> {
                Unsafely(value: try await WhisperKit(WhisperKitConfig(model: model)))
            }
            whisperLoading[model] = task
            defer { whisperLoading[model] = nil }
            kit = try await task.value.value
            whisper[model] = kit
        }
        return try await kit.transcribe(audioPath: path, decodeOptions: options)
    }

    func parakeetManager(version: AsrModelVersion,
                         encoderPrecision: ParakeetEncoderPrecision) async throws -> AsrManager {
        let key = "\(version)-\(encoderPrecision)"
        if let existing = parakeet[key] { return existing }
        if let inFlight = parakeetLoading[key] { return try await inFlight.value }
        let task = Task<AsrManager, Error> {
            let models = try await AsrModels.downloadAndLoad(version: version,
                                                            encoderPrecision: encoderPrecision)
            let manager = AsrManager()
            try await manager.loadModels(models)
            return manager
        }
        parakeetLoading[key] = task
        defer { parakeetLoading[key] = nil }
        let loaded = try await task.value
        parakeet[key] = loaded
        return loaded
    }

    /// Drop everything. The render path needs the memory back before a 4K composite, and an
    /// ingest that has finished should not hold 1.6 GB of Whisper for the rest of the session.
    func evict() {
        whisper.removeAll()
        parakeet.removeAll()
    }
}
