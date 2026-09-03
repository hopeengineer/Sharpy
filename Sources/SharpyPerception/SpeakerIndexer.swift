// Who is speaking, and when.
//
// Diarization is what turns a transcript into something an agent can reason about
// conversationally: "cut the interviewer's question but keep the answer", "this is a two-hander,
// so a cut on a speaker change is free". Without it every word belongs to nobody and every
// multi-speaker edit is guesswork.
//
// SpeakerKit runs pyannote through CoreML, so this is on-device and needs no Python.
//
// MEASURED LIMITATION — automatic speaker counting is not validated. Against known truth:
//
//     one voice     -> 1  correct        the user's real reel -> 1  correct
//     two voices    -> 3  WRONG (+1)     three voices        -> 4  WRONG (+1)
//
// It over-counts by exactly one whenever more than one person speaks, and the spurious cluster is
// consistently tiny — 4 % / 7.0 s and 3 % / 6.8 s. That size and consistency point at windows
// straddling the boundaries of the test files, which are hard concatenations of separate
// recordings; real conversational audio may not behave the same way. So no "drop small clusters"
// correction is applied here: with two synthetic multi-speaker files it would be fitting a rule to
// the fixture rather than to diarization. Settling it needs a real multi-speaker recording.
//
// `numberOfSpeakers` is honoured exactly when supplied — forcing 2 on the two-voice file gives 2
// with a 66/34 split against an expected 62/38 — so pass it when the count is known.
//
// For reference, the measured alternative: sherpa-onnx pyannote-3.0 + eres2net found 2 of 2 on the
// same audio at 13.8x realtime. SpeakerKit runs at ~280x. Speed is not the deciding axis here.
//
// Speaker labels are per-recording: "speaker 0" in one file has nothing to do with "speaker 0" in
// another. SpeakerKit exposes per-speaker centroid embeddings for linking identities across
// files, which is what an enrolment registry would eventually use; that is deliberately not done
// here, because "the same voice" across recordings needs a calibrated threshold and guessing one
// would put a name on the wrong person.

import Foundation
import AVFoundation
import SpeakerKit
import SharpyEngine
import SharpyRender

public struct SpeakerTurn: Sendable, Codable, Equatable {
    /// Per-recording label, not a person's identity.
    public let speaker: Int
    public let range: TimeRange
    public var duration: TimeValue { range.duration }
}

public struct SpeakerIndex: Sendable, Codable {
    public let asset: NodeID
    public let turns: [SpeakerTurn]
    public let speakerCount: Int

    public func speaker(at t: TimeValue) -> Int? { turns.first { $0.range.contains(t) }?.speaker }

    /// Total speaking time per label — who actually holds the floor.
    public var shareOfVoice: [Int: TimeValue] {
        var out: [Int: TimeValue] = [:]
        for turn in turns { out[turn.speaker] = (out[turn.speaker] ?? .zero) + turn.duration }
        return out
    }

    /// Instants where the speaker changes: the cheapest legitimate cut points in a conversation.
    public var speakerChanges: [TimeValue] {
        zip(turns, turns.dropFirst()).compactMap { $0.speaker != $1.speaker ? $1.range.start : nil }
    }
}

public enum SpeakerIndexError: Error, CustomStringConvertible {
    case noAudioTrack(URL)
    case modelUnavailable(String)
    public var description: String {
        switch self {
        case .noAudioTrack(let u): return "no audio track in \(u.lastPathComponent)"
        case .modelUnavailable(let m): return "SpeakerKit models unavailable: \(m)"
        }
    }
}

public struct SpeakerIndexer {
    /// Turns shorter than this are dropped: pyannote emits slivers around overlaps, and a 100 ms
    /// "turn" is a crossfade artefact rather than somebody speaking.
    public let minimumTurn: TimeValue
    /// Agglomerative clustering cut-off. Lower splits one voice into several; higher merges two
    /// people into one. Calibrated against known truth rather than taken from the default — see
    /// `bench/results/diarization_sweep.txt`.
    public let clusterDistanceThreshold: Float?
    /// Smallest number of embedding windows that may form a speaker. This is the parameter that
    /// suppresses a spurious extra voice assembled from a handful of scattered windows.
    public let minClusterSize: Int?
    /// When the count is known ahead of time, saying so beats any threshold.
    public let numberOfSpeakers: Int?

    public init(minimumTurn: TimeValue = TimeValue(seconds: Rational(3, 10)),
                clusterDistanceThreshold: Float? = nil,
                minClusterSize: Int? = nil,
                numberOfSpeakers: Int? = nil) {
        self.minimumTurn = minimumTurn
        self.clusterDistanceThreshold = clusterDistanceThreshold
        self.minClusterSize = minClusterSize
        self.numberOfSpeakers = numberOfSpeakers
    }

    public func index(url: URL, asset: NodeID) async throws -> SpeakerIndex {
        // Pyannote wants 16 kHz mono, which is also the cheapest thing to decode.
        let source = try AudioSource(url: url, sampleRate: 16_000, channels: 1)
        let samples = try source.read(TimeRange(start: .zero, end: source.duration))
        guard !samples.isEmpty else { throw SpeakerIndexError.noAudioTrack(url) }

        let kit: SpeakerKit
        do { kit = try await SpeakerKit() }
        catch { throw SpeakerIndexError.modelUnavailable(String(describing: error)) }

        let options = PyannoteDiarizationOptions(numberOfSpeakers: numberOfSpeakers,
                                                 clusterDistanceThreshold: clusterDistanceThreshold,
                                                 minClusterSize: minClusterSize)
        let result = try await kit.diarize(audioArray: samples, options: options, progressCallback: nil)

        let turns = result.segments.compactMap { segment -> SpeakerTurn? in
            let start = TimeValue(seconds: Rational(Int64(segment.startTime * 1000), 1000))
            let end = TimeValue(seconds: Rational(Int64(segment.endTime * 1000), 1000))
            guard start < end else { return nil }
            let range = TimeRange(start: start, end: end)
            guard !(range.duration.seconds < minimumTurn.seconds) else { return nil }
            return SpeakerTurn(speaker: segment.speaker.id, range: range)
        }.sorted { $0.range.start < $1.range.start }

        return SpeakerIndex(asset: asset, turns: turns,
                            speakerCount: Set(turns.map { $0.speaker }).count)
    }
}

extension SpeakerInfo {
    /// The numeric label, whatever shape the enum takes.
    var id: Int {
        switch self {
        case .speakerId(let n): return n
        default: return String(describing: self).compactMap(\.wholeNumberValue).reduce(0) { $0 * 10 + $1 }
        }
    }
}

extension Transcript {
    /// Attach speaker labels to words by turn overlap. A word belongs to whoever was speaking
    /// when it started — the only rule that stays stable across a word that straddles a turn.
    public func labelled(with speakers: SpeakerIndex) -> Transcript {
        Transcript(asset: asset,
                   words: words.map { w in
                       Word(index: w.index, text: w.text, range: w.range, confidence: w.confidence,
                            speaker: speakers.speaker(at: w.range.start).map { "speaker \($0)" },
                            sources: w.sources)
                   },
                   engines: engines + ["speakerkit"], language: language)
    }
}

extension IndexStore {
    public func speakers(for url: URL, indexer: SpeakerIndexer = SpeakerIndexer()) async throws -> (SpeakerIndex, Bool) {
        let fingerprint = try MediaFingerprint(of: url)
        var record = load(fingerprint) ?? PerceptionRecord(fingerprint: fingerprint, path: url.path)
        let version = IndexStore.versions["speakers"]
        if let existing = record.speakers, record.producedBy["speakers"] == version {
            return (existing, true)
        }
        let produced = try await indexer.index(url: url, asset: NodeID(contentOf: url.path))
        record.speakers = produced
        record.producedBy["speakers"] = version
        record.path = url.path
        try save(record)
        return (produced, false)
    }
}
