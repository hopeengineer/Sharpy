// Diarization candidates measured against SpeakerKit.
//
// SpeakerKit's measured weakness is COUNTING, not timing: on VoxConverse dev it scores 3.67 % DER
// but gets the number of speakers exactly right on only 127 of 216 files, skewed toward
// under-counting. DER stays low because the dominant speakers are right and the missed ones are
// brief — but "cut every question from the interviewer" is a count-dependent instruction, so the
// axis it is weakest on is the one an editing agent leans on hardest.
//
// Two candidates from FluidAudio (Apache-2.0, CoreML) are therefore measured against it rather
// than assumed to be worse:
//
//   .clustering  pyannote segmentation + embedding clustering. Same family as SpeakerKit, so a
//                difference here is implementation, not architecture.
//   .sortformer  NVIDIA Sortformer, end-to-end. A different architecture that models speakers
//                jointly instead of clustering embeddings after the fact, and predicts
//                OVERLAPPING speech directly — which is where the no-collar DER is lost.
//
// Nothing here is adopted on being newer or on being available. See
// bench/results/diarization_real_corpora.txt for what actually won and on what evidence.

import Foundation
import AVFoundation
import FluidAudio
import SharpyEngine
import SharpyRender

public struct FluidSpeakerIndexer {
    public enum Backend: String, Sendable, CaseIterable {
        case clustering
        case sortformer
    }

    public let backend: Backend
    /// Turns shorter than this are dropped, matching `SpeakerIndexer` exactly. Comparing two
    /// diarizers under different post-filters would measure the filters.
    public let minimumTurn: TimeValue

    public init(backend: Backend = .sortformer,
                minimumTurn: TimeValue = TimeValue(seconds: Rational(3, 10))) {
        self.backend = backend
        self.minimumTurn = minimumTurn
    }

    public func index(url: URL, asset: NodeID) async throws -> SpeakerIndex {
        let source = try AudioSource(url: url, sampleRate: 16_000, channels: 1)
        let samples = try source.read(TimeRange(start: .zero, end: source.duration))
        guard !samples.isEmpty else { throw SpeakerIndexError.noAudioTrack(url) }

        let raw: [(speaker: Int, start: Double, end: Double)]
        switch backend {
        case .clustering:
            let models: DiarizerModels
            do { models = try await DiarizerModels.downloadIfNeeded() }
            catch { throw SpeakerIndexError.modelUnavailable(String(describing: error)) }
            let manager = DiarizerManager()
            manager.initialize(models: consume models)
            let result = try manager.performCompleteDiarization(samples, sampleRate: 16_000)
            raw = result.segments.map {
                // Labels arrive as strings here and as ints everywhere else; keep the digits so
                // "speaker 2" means the same thing across backends.
                (Int($0.speakerId.filter(\.isNumber)) ?? 0,
                 Double($0.startTimeSeconds), Double($0.endTimeSeconds))
            }

        case .sortformer:
            let diarizer = OfflineSortformerDiarizer(config: .offlineV2_1)
            do { try await diarizer.initializeFromHuggingFace() }
            catch { throw SpeakerIndexError.modelUnavailable(String(describing: error)) }
            let timeline = try diarizer.processComplete(samples, sourceSampleRate: 16_000)
            let seconds = Double(timeline.config.frameDurationSeconds)
            var collected: [(speaker: Int, start: Double, end: Double)] = []
            for speaker in timeline.speakers.values {
                for segment in speaker.finalizedSegments {
                    let start = Double(segment.startFrame) * seconds
                    let end = Double(segment.endFrame) * seconds
                    collected.append((speaker: segment.speakerIndex, start: start, end: end))
                }
            }
            raw = collected
        }

        let turns = raw.compactMap { seg -> SpeakerTurn? in
            let start = TimeValue(seconds: Rational(Int64(seg.start * 1000), 1000))
            let end = TimeValue(seconds: Rational(Int64(seg.end * 1000), 1000))
            guard start < end else { return nil }
            let range = TimeRange(start: start, end: end)
            guard !(range.duration.seconds < minimumTurn.seconds) else { return nil }
            return SpeakerTurn(speaker: seg.speaker, range: range)
        }.sorted { $0.range.start < $1.range.start }

        return SpeakerIndex(asset: asset, turns: turns,
                            speakerCount: Set(turns.map { $0.speaker }).count)
    }
}
