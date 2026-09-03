// Walk a Document and write a file: resolve which clip each track shows at each instant, fetch
// that source frame or sample range, composite/sum, hand the result to the encoder.
// This is the M0 exit path — a complete edit rendered by a script, no UI process anywhere.
//
// Both writer inputs are driven with `requestMediaDataWhenReady`, the documented pattern for
// non-real-time writing. Polling `isReadyForMoreMediaData` from the calling thread deadlocks with
// two inputs: the writer advances them together and never signals readiness to a thread busy
// spinning on one of them. Measured: the polling version hung indefinitely on a 6 s fixture.

import AVFoundation
import Metal
import SharpyEngine

public struct ResolvedLayer: Sendable {
    public let trackIndex: Int
    public let clip: Clip
    public let sourceTime: TimeValue
}

extension Document {
    /// For each video track (bottom first), the clip covering `t` and the source instant it maps to.
    public func resolveVideo(at t: TimeValue) -> [ResolvedLayer] {
        timeline.tracks.enumerated().reversed().compactMap { (i, track) in
            guard track.kind == .video, let clip = track.clips.first(where: { $0.range.contains(t) }) else { return nil }
            return ResolvedLayer(trackIndex: i, clip: clip, sourceTime: clip.source.start + (t - clip.start))
        }
    }
}

public enum RenderCodec: Sendable { case proRes422HQ, h264(bitrate: Int), hevc(bitrate: Int) }

public struct RenderOptions: Sendable {
    public var width: Int
    public var height: Int
    public var codec: RenderCodec
    public var range: TimeRange?      // nil = whole timeline
    public var sampleRate: Int
    public var channels: Int
    /// Write an audio track when the document has one. Off only for picture-only deliverables.
    public var includeAudio: Bool
    /// Normalise the mix to a delivery target. Requires a measurement pass over the audio first.
    public var loudnessTarget: LoudnessTarget?
    public init(width: Int, height: Int, codec: RenderCodec = .proRes422HQ, range: TimeRange? = nil,
                sampleRate: Int = 48_000, channels: Int = 2, includeAudio: Bool = true,
                loudnessTarget: LoudnessTarget? = nil) {
        self.width = width; self.height = height; self.codec = codec; self.range = range
        self.sampleRate = sampleRate; self.channels = channels; self.includeAudio = includeAudio
        self.loudnessTarget = loudnessTarget
    }
}

public struct RenderReport: Sendable {
    public let framesRendered: Int
    public let audioSamplesWritten: Int
    public let duration: TimeValue
    public let wallSeconds: Double
    /// Loudness of the mix before normalisation, when a target was set.
    public let loudnessBefore: LoudnessReading?
    /// Gain applied, dB. Less than `target − measured` when the true-peak ceiling bound it.
    public let loudnessGainApplied: Double?
    /// Set when the ceiling prevented reaching the target — the deliverable is quieter on purpose.
    public let loudnessTargetMissedBy: Double?
    public var fps: Double { wallSeconds > 0 ? Double(framesRendered) / wallSeconds : 0 }
}

public enum RenderError: Error, CustomStringConvertible {
    case writerFailed(String), poolFailed, missingAsset(NodeID), noFrame(asset: String, at: TimeValue)
    public var description: String {
        switch self {
        case .writerFailed(let s): return "AVAssetWriter: \(s)"
        case .poolFailed: return "pixel buffer pool creation failed"
        case .missingAsset(let id): return "document references missing asset \(id)"
        case .noFrame(let a, let t): return "no frame in \(a) at \(t)"
        }
    }
}

public final class RenderSession {
    public let document: Document
    public let options: RenderOptions
    private let compositor: MetalCompositor
    private var sources: [NodeID: SequentialFrameSource] = [:]
    private var audioSources: [NodeID: AudioSource] = [:]

    public init(document: Document, options: RenderOptions, compositor: MetalCompositor? = nil) throws {
        self.document = document; self.options = options
        self.compositor = try compositor ?? MetalCompositor()
    }

    private func source(for id: NodeID) throws -> SequentialFrameSource {
        if let s = sources[id] { return s }
        guard let asset = document.assets[id] else { throw RenderError.missingAsset(id) }
        let s = try SequentialFrameSource(url: URL(fileURLWithPath: asset.path))
        sources[id] = s
        return s
    }

    private func audioSource(for id: NodeID) throws -> AudioSource {
        if let a = audioSources[id] { return a }
        guard let asset = document.assets[id] else { throw RenderError.missingAsset(id) }
        let a = try AudioSource(url: URL(fileURLWithPath: asset.path), sampleRate: options.sampleRate, channels: options.channels)
        audioSources[id] = a
        return a
    }

    /// Placement that fits a source frame into the output while preserving aspect (letterbox/pillarbox).
    private func fit(_ w: Int, _ h: Int) -> LayerPlacement {
        let sx = Float(options.width) / Float(w), sy = Float(options.height) / Float(h)
        let s = min(sx, sy)
        let ox = (Float(options.width) - Float(w) * s) / 2, oy = (Float(options.height) - Float(h) * s) / 2
        return LayerPlacement(offset: SIMD2(ox, oy), scale: s, opacity: 1)
    }

    /// Sum every audio track over one chunk of the output timeline. A ripple-deleted gap simply
    /// has no contributor, so the following audio moves up with the picture.
    private func audioChunk(_ chunkRange: TimeRange) throws -> [Float] {
        let sr = options.sampleRate, ch = options.channels
        let frames = Int((chunkRange.duration.seconds * Rational(Int64(sr))).rounded)
        var mix = [Float](repeating: 0, count: frames * ch)
        for track in document.timeline.tracks where track.kind == .audio {
            for clip in track.clips where clip.range.overlaps(chunkRange) {
                guard let hit = clip.range.intersection(chunkRange) else { continue }
                let src = try audioSource(for: clip.asset)
                let sourceStart = clip.source.start + (hit.start - clip.start)
                let samples = try src.read(TimeRange(start: sourceStart, duration: hit.duration))
                let offset = Int(((hit.start - chunkRange.start).seconds * Rational(Int64(sr))).rounded) * ch
                guard offset >= 0, offset < mix.count else { continue }
                let n = min(samples.count, mix.count - offset)
                for k in 0..<n { mix[offset + k] += samples[k] }
            }
        }
        return mix
    }

    /// Render one output frame and hand it to the writer.
    private func renderFrame(_ f: Int64, rate: FrameRate, rangeStart: TimeValue,
                             input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor,
                             writer: AVAssetWriter) throws {
        let t = TimeValue(frames: f, at: rate)
        let layers = try document.resolveVideo(at: t).map { rl -> CompositeLayer in
            let src = try source(for: rl.clip.asset)
            guard let frame = try src.frame(at: rl.sourceTime) else {
                throw RenderError.noFrame(asset: src.url.lastPathComponent, at: rl.sourceTime)
            }
            return CompositeLayer(pixelBuffer: frame.pixelBuffer, placement: fit(src.width, src.height))
        }
        guard let pool = adaptor.pixelBufferPool else { throw RenderError.poolFailed }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out)
        guard let out else { throw RenderError.poolFailed }
        ColorTag.tag709(out)
        let (tex, keepAlive) = try compositor.outputTexture(for: out)
        let cb = try compositor.encode(layers: layers, into: tex)
        cb.addCompletedHandler { _ in _ = keepAlive }
        cb.commit()
        cb.waitUntilCompleted()   // the encoder must see finished pixels; overlap comes with the playback engine
        let pts = try (t - rangeStart).cmTime()
        guard adaptor.append(out, withPresentationTime: pts) else {
            throw RenderError.writerFailed(writer.error?.localizedDescription ?? "video append at frame \(f)")
        }
    }

    /// Mutable progress shared with the writer callbacks. Each field is touched by exactly one
    /// serial queue, so this is a box, not a lock.
    private final class Progress: @unchecked Sendable {
        var frame: Int64 = 0
        var framesWritten = 0
        var samplesWritten = 0
        var videoError: Error?
        var audioError: Error?
    }

    /// Render to `url`. Existing file is replaced.
    public func render(to url: URL) throws -> RenderReport {
        let rate = document.timeline.frameRate
        let full = TimeRange(start: .zero, end: document.timeline.duration)
        let range = options.range ?? full
        let firstFrame = range.start.frame(at: rate)
        let endFrame = range.end.frame(at: rate) + (range.end.isFrameAligned(at: rate) ? 0 : 1)

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings: [String: Any] = [AVVideoWidthKey: options.width, AVVideoHeightKey: options.height,
                                       AVVideoColorPropertiesKey: ColorTag.writer709]
        switch options.codec {
        case .proRes422HQ: settings[AVVideoCodecKey] = AVVideoCodecType.proRes422HQ
        case .h264(let br): settings[AVVideoCodecKey] = AVVideoCodecType.h264; settings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: br]
        case .hevc(let br): settings[AVVideoCodecKey] = AVVideoCodecType.hevc; settings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: br]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: options.width, kCVPixelBufferHeightKey as String: options.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: poolAttrs)
        writer.add(input)

        // Audio: one mixed track summed from every audio track in the document.
        let sr = options.sampleRate, ch = options.channels
        let format = AudioFormatInfo(sampleRate: sr, channels: ch)
        let hasAudio = options.includeAudio && document.timeline.tracks.contains { $0.kind == .audio && !$0.clips.isEmpty }
        let totalAudio = hasAudio ? Int((range.duration.seconds * Rational(Int64(sr))).rounded) : 0
        var audioInput: AVAssetWriterInput?
        if hasAudio {
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: options.sampleRate,
                AVNumberOfChannelsKey: options.channels,
                AVEncoderBitRateKey: 192_000,
            ])
            ai.expectsMediaDataInRealTime = false
            writer.add(ai)
            audioInput = ai
        }

        // Loudness normalisation needs the whole mix measured before a sample is written.
        // A limiter would let us hit any target, but it changes the sound; that is an explicit
        // creative decision, not something a delivery step should do silently. So the gain is
        // capped by the true-peak ceiling and the shortfall is reported.
        var loudnessBefore: LoudnessReading?
        var appliedGain: Double?
        var missedBy: Double?
        var audioScale: Float = 1
        if hasAudio, let target = options.loudnessTarget {
            let meter = LoudnessMeter(sampleRate: sr, channels: ch)
            var at = range.start
            let step = TimeValue(seconds: Rational(1))
            while at < range.end {
                let end = min(at + step, range.end)
                meter.add(try audioChunk(TimeRange(start: at, end: end)))
                at = end
            }
            let reading = meter.result()
            loudnessBefore = reading
            if let wanted = reading.gain(toReach: target.integrated) {
                let headroom = target.truePeakCeiling - reading.truePeak
                let gain = min(wanted, headroom)
                appliedGain = gain
                if gain < wanted - 0.01 { missedBy = wanted - gain }
                audioScale = Float(pow(10.0, gain / 20.0))
            }
        }

        guard writer.startWriting() else { throw RenderError.writerFailed(writer.error?.localizedDescription ?? "startWriting") }
        writer.startSession(atSourceTime: .zero)

        let t0 = Date()
        let progress = Progress()
        progress.frame = firstFrame
        let group = DispatchGroup()

        group.enter()
        input.requestMediaDataWhenReady(on: DispatchQueue(label: "sharpy.render.video")) { [self] in
            while input.isReadyForMoreMediaData {
                guard progress.frame < endFrame else { input.markAsFinished(); group.leave(); return }
                do {
                    try renderFrame(progress.frame, rate: rate, rangeStart: range.start, input: input, adaptor: adaptor, writer: writer)
                    progress.frame += 1
                    progress.framesWritten += 1
                } catch {
                    progress.videoError = error
                    input.markAsFinished(); group.leave(); return
                }
            }
        }

        if let audioInput {
            group.enter()
            audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "sharpy.render.audio")) { [self] in
                while audioInput.isReadyForMoreMediaData {
                    guard progress.samplesWritten < totalAudio else { audioInput.markAsFinished(); group.leave(); return }
                    do {
                        let n = min(sr, totalAudio - progress.samplesWritten)
                        let at = TimeValue(seconds: Rational(Int64(progress.samplesWritten), Int64(sr)))
                        var chunk = try audioChunk(TimeRange(start: range.start + at, duration: TimeValue(seconds: Rational(Int64(n), Int64(sr)))))
                        if audioScale != 1 { for i in chunk.indices { chunk[i] *= audioScale } }
                        let sb = try AudioPacking.sampleBuffer(interleaved: chunk, format: format, pts: at)
                        guard audioInput.append(sb) else {
                            throw RenderError.writerFailed(writer.error?.localizedDescription ?? "audio append at sample \(progress.samplesWritten)")
                        }
                        progress.samplesWritten += n
                    } catch {
                        progress.audioError = error
                        audioInput.markAsFinished(); group.leave(); return
                    }
                }
            }
        }

        group.wait()
        if let e = progress.videoError { writer.cancelWriting(); throw e }
        if let e = progress.audioError { writer.cancelWriting(); throw e }

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status == .failed { throw RenderError.writerFailed(writer.error?.localizedDescription ?? "finish") }
        return RenderReport(framesRendered: progress.framesWritten, audioSamplesWritten: progress.samplesWritten,
                            duration: TimeValue(frames: Int64(progress.framesWritten), at: rate),
                            wallSeconds: Date().timeIntervalSince(t0),
                            loudnessBefore: loudnessBefore, loudnessGainApplied: appliedGain,
                            loudnessTargetMissedBy: missedBy)
    }
}
