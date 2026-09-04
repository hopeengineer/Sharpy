// The VLM pass: shot size, activity, setting — and nothing Apple Vision already does better.
//
// This target is separate from SharpyPerception because linking MLX makes a product that plain
// `swift build` cannot produce a working binary for. That is verified, not assumed: a
// `swift build` binary dies at runtime with "MLX error: Failed to load the default metallib",
// while the same source built by `xcodebuild -scheme sharpy-probe` loads Gemma 4 E2B and answers
// in 5.1 s/frame at 4.05 GB. Keeping MLX out of SharpyPerception is what lets the perception
// tests run under `swift test`; it is a response to a measured constraint, not a preference about
// build tooling.
//
// The prompt asks for THREE things and forbids the rest. Earlier versions of this prompt (see
// bench/bench_vlm_quality.py) also asked for faces, hands and on-screen text, which is how the
// models were measured — but Vision beat every one of them on those fields while being ~8x
// faster, so asking again here would spend 5 s a frame to get a worse answer. Every field the
// model is asked for is one it is the best available source of.

import Foundation
import AVFoundation
import CoreImage
import MLX
import MLXVLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers
import SharpyEngine
import SharpyPerception

public enum SceneIndexError: Error, CustomStringConvertible {
    case modelUnavailable(String)
    case noVideoTrack(URL)
    case unparseable(count: Int, of: Int, sample: String)
    case tooManyAbstentions(rate: Double)
    public var description: String {
        switch self {
        case .modelUnavailable(let m): return "VLM unavailable: \(m)"
        case .noVideoTrack(let u): return "no video track in \(u.lastPathComponent)"
        case .unparseable(let c, let n, let s):
            return "VLM returned unparseable JSON on \(c) of \(n) frames; sample: \(s.prefix(160))"
        case .tooManyAbstentions(let rate):
            return String(format: "VLM answered \"other\" on %.0f%% of frames — it is abstaining, "
                          + "not perceiving, and `other` is the one answer Vision cannot refute", rate * 100)
        }
    }
}

public struct SceneIndexOptions: Sendable {
    /// One frame every N seconds. 5 s is the ingest default: a shot shorter than that is caught by
    /// the shot detector, which is 300x cheaper, and the VLM is here for what a shot *is*.
    public var secondsPerSample: Double
    /// Long side in pixels handed to the model. 1024 is what every published number here was
    /// measured at; changing it invalidates the comparison.
    public var resize: Int
    /// Fraction of frames allowed to return unparseable JSON before the whole index is refused.
    /// Qwen3-VL-2B failed 5 of 22 in measurement — a format fault, not a perception one, but an
    /// index built from a model that cannot hold its format is not worth caching.
    public var maxUnparseableFraction: Double
    /// Fraction of frames the model may answer `other` on before the index is refused.
    ///
    /// Abstention is correct on an ambiguous frame, and the prompt explicitly asks for it rather
    /// than a guess. But `other` is also the one answer Vision can never refute, so a model that
    /// abstains everywhere scores a perfect zero contradictions. Without this ceiling the
    /// cross-check rewards exactly the failure it exists to catch.
    public var maxAbstentionFraction: Double

    public init(secondsPerSample: Double = 5, resize: Int = 1024,
                maxUnparseableFraction: Double = 0.25,
                maxAbstentionFraction: Double = 0.5) {
        self.secondsPerSample = secondsPerSample
        self.resize = resize
        self.maxUnparseableFraction = maxUnparseableFraction
        self.maxAbstentionFraction = maxAbstentionFraction
    }
}

public struct SceneIndexer {
    /// A local snapshot directory, e.g. the Gemma 4 E2B 4-bit one measured at 22/22 person and
    /// face on the labelled reel.
    public let modelDirectory: URL
    public let options: SceneIndexOptions

    public init(modelDirectory: URL, options: SceneIndexOptions = SceneIndexOptions()) {
        self.modelDirectory = modelDirectory
        self.options = options
    }

    static let prompt = """
    You are the perception module of a video editor. Another system has already measured the faces, \
    hands and on-screen text in this frame, so do not report those. Answer ONLY with a JSON object, \
    no prose, no markdown:
    {"shot": "closeUp"|"medium"|"wide"|"card"|"split"|"other", "activity": "<one short phrase for what \
    is happening>", "setting": "<one short phrase for where this is>"}
    Rules: card means a graphic or title fills the frame with no person. split means a graphic and a \
    person share the frame. closeUp means a head and shoulders fill the frame; medium is head to \
    waist; wide means the subject is small in the frame or absent. If you are unsure of the shot, \
    answer "other" rather than guessing — a wrong answer is worse than no answer here.
    """

    public func index(url: URL, asset: NodeID, vision: VisionIndex?) async throws -> SceneIndex {
        let avAsset = AVURLAsset(url: url)
        guard try await !avAsset.loadTracks(withMediaType: .video).isEmpty else {
            throw SceneIndexError.noVideoTrack(url)
        }
        let duration = try await avAsset.load(.duration).seconds
        guard duration > 0 else { throw SceneIndexError.noVideoTrack(url) }

        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        // Exact frames: a tolerance would let the model describe a frame other than the one whose
        // Vision observation it is being checked against, which would manufacture contradictions.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: options.resize, height: options.resize)

        MLX.GPU.set(cacheLimit: 512 * 1024 * 1024)
        let container: ModelContainer
        do {
            container = try await VLMModelFactory.shared.loadContainer(
                from: modelDirectory, using: #huggingFaceTokenizerLoader())
        } catch {
            throw SceneIndexError.modelUnavailable(String(describing: error))
        }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharpy-scene-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        var observations: [SceneObservation] = []
        var unparseable = 0
        var firstFailure = ""
        var sampleTimes: [Double] = []
        var t = 0.0
        while t < duration { sampleTimes.append(t); t += options.secondsPerSample }

        for (i, seconds) in sampleTimes.enumerated() {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { continue }
            let frameURL = temporary.appendingPathComponent("f\(i).jpg")
            guard writeJPEG(cgImage, to: frameURL) else { continue }

            var input = UserInput(prompt: Self.prompt, images: [.url(frameURL)])
            input.processing.resize = CGSize(width: options.resize, height: options.resize)
            let prepared = try await container.prepare(input: input)
            var parameters = GenerateParameters()
            parameters.maxTokens = 120
            parameters.temperature = 0        // an index must be reproducible from the same frames
            var text = ""
            for await generated in try await container.generate(input: prepared, parameters: parameters) {
                if case .chunk(let chunk) = generated { text += chunk }
            }

            guard let json = Self.parseJSON(text) else {
                unparseable += 1
                if firstFailure.isEmpty { firstFailure = text }
                continue
            }
            let shot = ShotSize(rawValue: (json["shot"] as? String) ?? "") ?? .other
            let sharpyTime = TimeValue(seconds: Rational(Int64(seconds * 1000), 1000))
            let (standing, reason) = SceneCrossCheck.standing(
                shot: shot, vision: vision?.observation(at: sharpyTime))
            observations.append(SceneObservation(
                time: sharpyTime, shot: shot,
                activity: Self.phrase(json["activity"]),
                setting: Self.phrase(json["setting"]),
                standing: standing, reason: reason))
        }

        let attempted = observations.count + unparseable
        if attempted > 0, Double(unparseable) / Double(attempted) > options.maxUnparseableFraction {
            throw SceneIndexError.unparseable(count: unparseable, of: attempted, sample: firstFailure)
        }
        let index = SceneIndex(asset: asset, observations: observations,
                               model: modelDirectory.lastPathComponent)
        if !observations.isEmpty, index.abstentionRate > options.maxAbstentionFraction {
            throw SceneIndexError.tooManyAbstentions(rate: index.abstentionRate)
        }
        return index
    }

    private func writeJPEG(_ image: CGImage, to url: URL) -> Bool {
        let context = CIContext()
        let ciImage = CIImage(cgImage: image)
        guard let colorSpace = ciImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else { return false }
        return (try? context.writeJPEGRepresentation(of: ciImage, to: url, colorSpace: colorSpace)) != nil
    }

    /// One short phrase. A model asked for a phrase will sometimes write a sentence; truncating
    /// here keeps the index scannable and stops a narration from being cached as an observation.
    static func phrase(_ value: Any?) -> String {
        let raw = (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let firstClause = raw.split(separator: ".", maxSplits: 1).first.map(String.init) ?? raw
        return String(firstClause.prefix(80))
    }

    static func parseJSON(_ text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return nil
        }
        var candidate = String(text[start...end])
        if let data = candidate.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        // A trailing comma before a closer is the one malformation worth repairing: it is a
        // formatting slip, not a perception failure, and refusing it would discard a good answer.
        candidate = candidate.replacingOccurrences(of: ",\\s*([}\\]])", with: "$1",
                                                   options: .regularExpression)
        guard let data = candidate.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
