// Who is speaking, and when.
//
// Diarization is what turns a transcript into something an agent can reason about
// conversationally: "cut the interviewer's question but keep the answer", "this is a two-hander,
// so a cut on a speaker change is free". Without it every word belongs to nobody and every
// multi-speaker edit is guesswork.
//
// SpeakerKit runs pyannote through CoreML, so this is on-device and needs no Python.
//
// MEASURED on 22.7 hours of real annotated audio — VoxConverse dev (216 recordings, 20.30 h,
// 1-20 speakers, YouTube/broadcast) and AMI dev (6 meetings, 2.37 h, 4 speakers, spontaneous
// overlapping conversation). Both CC BY 4.0 with reference RTTMs. Full numbers and the
// head-to-head against sherpa-onnx: bench/results/diarization_real_corpora.txt.
//
//                                DER(collar)   DER(full)   speaker count exact
//     VoxConverse dev, 216           3.67%        8.98%        127 / 216
//     AMI dev, 6 meetings            7.66%       20.17%          4 / 6
//
// Kept at DEFAULT settings deliberately. The threshold was swept on AMI — 0.50 -> 7.67 %,
// 0.60 -> 7.66 %, 0.70 -> 7.64 %, 0.80 -> 8.82 %, 0.90 -> 29.07 % — and the default already sits
// on the optimum, which is a plateau rather than a spike. There is nothing here to tune, and that
// is itself evidence: an engine whose best setting has to be searched for is an engine whose best
// setting will not transfer.
//
// THE WEAK AXIS IS COUNTING, NOT TIMING. On VoxConverse only 127 of 216 files get the number of
// speakers exactly right (58.8 %), skewed toward under-counting: -1 on 35 files, -2 on 13, +1 on
// 32. DER stays low because the dominant speakers are right and the missed ones are brief — but
// an editing instruction like "cut every question from the interviewer" is count-dependent in a
// way that DER does not capture. So: pass `numberOfSpeakers` whenever the count is known. It is
// honoured exactly.
//
// Earlier revisions of this file called automatic counting "not validated" on the strength of
// 200 s of `say` output spliced together, where it over-counted every multi-speaker case. That
// fixture was the problem, not the model: hard splices of separate takes produce boundary
// artefacts real conversation does not have. The same fixture had also certified this engine's
// predecessor, sherpa-onnx, as "2 of 2 speakers correct". On the AMI meetings that same
// configuration reports 64, 86, 104, 116, 159 and 180 speakers for four people.

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
    /// people into one. Left at SpeakerKit's default because the sweep found no better value:
    /// `bench/results/diarization_sweep.txt`.
    ///
    /// SpeakerKit also takes a `minClusterSize`, which is deliberately NOT exposed here. It
    /// measured completely inert — 0, 3, 6, 12, 25, 100 and 1000 all returned the identical
    /// "3 speakers, 31 turns" on the two-voice file. A public knob that provably does nothing
    /// invites an agent to fix over-counting with a lever that is not connected to anything.
    public let clusterDistanceThreshold: Float?
    /// When the count is known ahead of time, saying so beats any threshold. This is the only
    /// parameter measured to actually control the outcome, and it controls it exactly.
    public let numberOfSpeakers: Int?

    public init(minimumTurn: TimeValue = TimeValue(seconds: Rational(3, 10)),
                clusterDistanceThreshold: Float? = nil,
                numberOfSpeakers: Int? = nil) {
        self.minimumTurn = minimumTurn
        self.clusterDistanceThreshold = clusterDistanceThreshold
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
                                                 clusterDistanceThreshold: clusterDistanceThreshold)
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
