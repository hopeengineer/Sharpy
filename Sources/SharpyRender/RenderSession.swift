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
    /// Video layers at an instant, BOTTOM FIRST — the order the compositor blends them.
    ///
    /// A higher track index renders ON TOP, which is the convention in Premiere, Resolve and Final
    /// Cut, and this project's stated bar is those tools' output. It previously reversed the
    /// tracks, putting V1 above V2; nothing documented that and no test pinned it, so an editor
    /// stacking a lower third on V2 would have watched it disappear behind the picture. Pinned now
    /// by `testHigherTracksRenderOnTop`.
    public func resolveVideo(at t: TimeValue) -> [ResolvedLayer] {
        timeline.tracks.enumerated().compactMap { (i, track) in
            guard track.kind == .video, let clip = track.clips.first(where: { $0.range.contains(t) }) else { return nil }
            return ResolvedLayer(trackIndex: i, clip: clip, sourceTime: clip.sourceTime(at: t))
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
    /// Assertions gate the render. `nil` means the standard set; pass an empty Verifier to skip,
    /// which exists for tests and for deliberately rendering something known to be broken.
    public var verifier: Verifier?
    public var skipVerification: Bool
    /// Spatial checks against the compositor's own ID pass, evaluated on EVERY rendered frame.
    /// `nil` renders without emitting identity, which is the cheaper path but also the blind one.
    public var spatialGuard: SpatialGuard?
    public init(width: Int, height: Int, codec: RenderCodec = .proRes422HQ, range: TimeRange? = nil,
                sampleRate: Int = 48_000, channels: Int = 2, includeAudio: Bool = true,
                loudnessTarget: LoudnessTarget? = nil, verifier: Verifier? = nil,
                skipVerification: Bool = false, spatialGuard: SpatialGuard? = nil) {
        self.width = width; self.height = height; self.codec = codec; self.range = range
        self.sampleRate = sampleRate; self.channels = channels; self.includeAudio = includeAudio
        self.loudnessTarget = loudnessTarget; self.verifier = verifier
        self.skipVerification = skipVerification; self.spatialGuard = spatialGuard
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
    /// What the per-frame spatial tier found. Empty `findings` with a non-zero `framesChecked`
    /// means it ran and was clean; `framesChecked == 0` means it did not run at all, and those are
    /// different claims.
    public let spatial: SpatialReport
    public var fps: Double { wallSeconds > 0 ? Double(framesRendered) / wallSeconds : 0 }
}

public enum RenderError: Error, CustomStringConvertible {
    case writerFailed(String), poolFailed, missingAsset(NodeID), noFrame(asset: String, at: TimeValue)
    case wouldNotFit(estimateBytes: Int64, availableBytes: Int64)
    case refusedByAssertions(VerificationResult)
    public var description: String {
        switch self {
        case .writerFailed(let s): return "AVAssetWriter: \(s)"
        case .poolFailed: return "pixel buffer pool creation failed"
        case .missingAsset(let id): return "document references missing asset \(id)"
        case .noFrame(let a, let t): return "no frame in \(a) at \(t)"
        case .wouldNotFit(let estimate, let available):
            let gb = { (b: Int64) in String(format: "%.1f GB", Double(b) / 1_073_741_824) }
            return "this render is estimated at \(gb(estimate)) and only \(gb(available)) is free. "
                 + "Render a shorter range, choose h264/hevc instead of ProRes, or free some space. "
                 + "Refusing rather than filling the disk."
        case .refusedByAssertions(let r):
            let lines = (r.blocking + r.holds).map { "  " + $0.description }.joined(separator: "\n")
            return "render refused — \(r.summary)\n\(lines)"
        }
    }
}

public final class RenderSession {
    public let document: Document
    public let options: RenderOptions
    private let compositor: MetalCompositor
    /// Reused across frames: allocating a 4K identity texture per frame would cost more than the
    /// pass itself.
    private var idTexture: MTLTexture?
    private var spatialFindings: [SpatialFinding] = []
    private var spatialFramesChecked = 0
    private var spatialFramesNotCheckable = 0
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

    /// Resolve a document placement against this render's output size. Aspect is preserved: the
    /// placement states a width, and height follows from the source, because a placement that
    /// stretched faces would be a silent quality fault.
    private func place(_ p: ClipPlacement, srcWidth: Int, srcHeight: Int,
                       rotation: Double = 0) -> LayerPlacement {
        let outW = Float(options.width), outH = Float(options.height)
        let quarterTurn = rotation == 90 || rotation == 270

        // A document's crop is stated in DISPLAY space — what the person sees — while the shader
        // crops the source pixels before rotating them. For a quarter turn those axes are not the
        // same, so the crop is transformed here rather than making every caller think about it.
        //
        // For 90° clockwise a point at source (x, y) lands at display (H − y, x), so:
        //   display left   trims large source y  -> source bottom
        //   display right  trims small source y  -> source top
        //   display top    trims small source x  -> source left
        //   display bottom trims large source x  -> source right
        let dl = Float(p.cropLeft.doubleValue), dr = Float(p.cropRight.doubleValue)
        let dt = Float(p.cropTop.doubleValue), db = Float(p.cropBottom.doubleValue)
        let crop: SIMD4<Float>          // left, right, top, bottom in SOURCE axes
        switch rotation {
        case 90:  crop = SIMD4(dt, db, dr, dl)
        case 270: crop = SIMD4(db, dt, dl, dr)
        case 180: crop = SIMD4(dr, dl, db, dt)
        default:  crop = SIMD4(dl, dr, dt, db)
        }

        // The visible size after cropping, in display axes.
        let croppedSrcW = Float(srcWidth) * (1 - crop.x - crop.y)
        let croppedSrcH = Float(srcHeight) * (1 - crop.z - crop.w)
        let shownW = quarterTurn ? croppedSrcH : croppedSrcW
        let shownH = quarterTurn ? croppedSrcW : croppedSrcH

        // A placement states a width in output fractions; height follows, so nothing is stretched.
        let targetW = Float(p.width.doubleValue) * outW
        let scale = targetW / max(shownW, 1)
        // The shader pivots on `offset + drawn * 0.5` using the UNROTATED drawn size, so the offset
        // is chosen to put that pivot where the rotated picture should be centred.
        let drawn = SIMD2(croppedSrcW * scale, croppedSrcH * scale)
        let wantedCentre = SIMD2(Float(p.x.doubleValue) * outW + shownW * scale / 2,
                                 Float(p.y.doubleValue) * outH + shownH * scale / 2)
        return LayerPlacement(offset: wantedCentre - drawn / 2,
                              scale: scale,
                              opacity: Float(p.opacity.doubleValue),
                              rotation: Float(rotation),
                              crop: crop)
    }

    /// Placement that fits a source frame into the output while preserving aspect, applying the
    /// container's rotation.
    ///
    /// The rotation is not decoration. A phone records landscape pixels and tags the file "rotate
    /// 90"; ignoring that draws a sideways frame into a portrait canvas and shows a cropped sliver.
    /// The shader already rotates — nothing was telling it to.
    private func fit(_ w: Int, _ h: Int, rotation: Double = 0) -> LayerPlacement {
        let quarterTurn = rotation == 90 || rotation == 270
        // Fit the frame as it will LOOK, so a quarter turn compares against swapped dimensions.
        let shownW = quarterTurn ? Float(h) : Float(w)
        let shownH = quarterTurn ? Float(w) : Float(h)
        let s = min(Float(options.width) / shownW, Float(options.height) / shownH)
        // The shader rotates about `offset + drawn * 0.5`, where `drawn` is the UNROTATED size — so
        // the offset is chosen to put that pivot at the centre of the output. Centring the
        // unrotated box instead would spin the picture about the wrong point.
        let drawn = SIMD2(Float(w) * s, Float(h) * s)
        let centre = SIMD2(Float(options.width) / 2, Float(options.height) / 2)
        return LayerPlacement(offset: centre - drawn / 2, scale: s,
                              opacity: 1, rotation: Float(rotation))
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
                let sourceStart = clip.sourceTime(at: hit.start)
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
            // A clip with no placement fits the frame, as it always has. One with a placement is
            // positioned in output fractions, so the same document delivers correctly at 1080p and
            // 4K without re-authoring.
            // The DECODED dimensions, not the source's reported ones. `SequentialFrameSource.width`
            // is `naturalSize` with the rotation applied — 2160x3840 for a phone recording whose
            // pixels are actually 3840x2160 — and the shader samples the real texture. Fitting
            // against the reported size scaled the picture by the wrong factor on top of not
            // rotating it.
            let decodedW = CVPixelBufferGetWidth(frame.pixelBuffer)
            let decodedH = CVPixelBufferGetHeight(frame.pixelBuffer)
            let placement = rl.clip.placement.map {
                place($0, srcWidth: decodedW, srcHeight: decodedH, rotation: src.rotationDegrees)
            } ?? fit(decodedW, decodedH, rotation: src.rotationDegrees)
            return CompositeLayer(pixelBuffer: frame.pixelBuffer, placement: placement)
        }
        guard let pool = adaptor.pixelBufferPool else { throw RenderError.poolFailed }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out)
        guard let out else { throw RenderError.poolFailed }
        ColorTag.tag709(out)
        let (tex, keepAlive) = try compositor.outputTexture(for: out)
        if options.spatialGuard != nil, idTexture == nil {
            idTexture = compositor.makeIDTexture(width: tex.width, height: tex.height)
        }
        let cb = try compositor.encode(layers: layers, into: tex, ids: idTexture)
        cb.addCompletedHandler { _ in _ = keepAlive }
        cb.commit()
        cb.waitUntilCompleted()   // the encoder must see finished pixels; overlap comes with the playback engine
        // Read identity only after the buffer completes: reading in flight would assert against
        // whatever the texture held last, which is a check that passes for the wrong reason.
        if let guardian = options.spatialGuard, let idTexture {
            let outcome = guardian.check(IDPass(texture: idTexture), frame: f, time: t,
                                         layerCount: layers.count)
            if outcome.checkable { spatialFramesChecked += 1 } else { spatialFramesNotCheckable += 1 }
            spatialFindings += outcome.findings
        }
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

    /// Check the document against its assertions without rendering anything.
    /// Loudness assertions need the mix measured, which costs a pass over the audio, so they only
    /// run when a target is set — asserting against a number nobody asked for would be theatre.
    public func verify(using verifier: Verifier? = nil) throws -> VerificationResult {
        var measured: Double?
        var peak: Double?
        var target: (integrated: Double, truePeakCeiling: Double)?
        if let t = options.loudnessTarget {
            target = (t.integrated, t.truePeakCeiling)
            let hasAudio = document.timeline.tracks.contains { $0.kind == .audio && !$0.clips.isEmpty }
            if hasAudio {
                let range = options.range ?? TimeRange(start: .zero, end: document.timeline.duration)
                let meter = LoudnessMeter(sampleRate: options.sampleRate, channels: options.channels)
                var at = range.start
                let step = TimeValue(seconds: Rational(1))
                while at < range.end {
                    let end = min(at + step, range.end)
                    meter.add(try audioChunk(TimeRange(start: at, end: end)))
                    at = end
                }
                let reading = meter.result()
                measured = reading.integrated
                peak = reading.truePeak
            }
        }
        let context = VerificationContext(document: document, integratedLoudness: measured,
                                          truePeak: peak, loudnessTarget: target)
        return (verifier ?? options.verifier ?? .standard).verify(context)
    }

    /// Render to `url`. Existing file is replaced.
    ///
    /// Assertions run first and can refuse. Note the ordering with loudness normalisation: the
    /// mix is normalised *during* the write, so a loudness assertion evaluated here judges the
    /// mix as it stands. When a target is set, normalisation will meet it — so the check is run
    /// against the post-normalisation intent rather than blocking a render that would have fixed
    /// itself. Anything else would make `--loudness` and verification mutually exclusive.
    /// Refuse a render that cannot fit.
    ///
    /// This exists because it happened. A frame-rate bug made a 10-minute source look like 71,475
    /// frames instead of 19,608, and the resulting 4K ProRes render reached 42 GB and took the
    /// machine down to 2.3 GB free before anybody noticed. The frame-rate bug is fixed; the reason
    /// to keep this is that an agent editing unattended is exactly who will not notice.
    ///
    /// The estimate is deliberately crude — bytes per frame times frames — because the point is to
    /// catch the case that is wrong by an order of magnitude, not to predict a file size.
    public func checkOutputFits(frames: Int64, at url: URL) throws {
        guard frames > 0 else { return }
        let bytesPerFrame: Double = {
            let pixels = Double(options.width * options.height)
            switch options.codec {
            case .proRes422HQ: return pixels * 1.1        // ~0.55 bytes/pixel at 4:2:2 10-bit
            case .h264(let bitrate), .hevc(let bitrate): return Double(bitrate) / 8 / 30
            }
        }()
        let estimate = bytesPerFrame * Double(frames)
        let directory = url.deletingLastPathComponent()
        guard let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else { return }
        // Four fifths, so a render that just fits still leaves the machine usable.
        let budget = Double(available) * 0.8
        if estimate > budget {
            throw RenderError.wouldNotFit(estimateBytes: Int64(estimate), availableBytes: available)
        }
    }

    public func render(to url: URL) throws -> RenderReport {
        if !options.skipVerification {
            let context = VerificationContext(document: document, integratedLoudness: nil, truePeak: nil,
                                              loudnessTarget: nil)
            let result = (options.verifier ?? .standard).verify(context)
            if !result.canRender { throw RenderError.refusedByAssertions(result) }
        }
        let rate = document.timeline.frameRate
        let full = TimeRange(start: .zero, end: document.timeline.duration)
        let range = options.range ?? full
        let firstFrame = range.start.frame(at: rate)
        let endFrame = range.end.frame(at: rate) + (range.end.isFrameAligned(at: rate) ? 0 : 1)
        try checkOutputFits(frames: endFrame - firstFrame, at: url)

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
                            loudnessTargetMissedBy: missedBy,
                            spatial: SpatialReport(framesChecked: spatialFramesChecked,
                                                   framesNotCheckable: spatialFramesNotCheckable,
                                                   findings: spatialFindings))
    }
}
