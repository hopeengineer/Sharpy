// Walk a Document frame by frame: resolve which clip each video track shows at the instant,
// fetch that source frame, composite the stack, and hand the result to an encoder — zero-copy,
// through an IOSurface-backed pixel-buffer pool whose buffers the compositor writes directly.
// This is the M0 exit path: a complete edit rendered by a script, no UI process anywhere.

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
    public init(width: Int, height: Int, codec: RenderCodec = .proRes422HQ, range: TimeRange? = nil) {
        self.width = width; self.height = height; self.codec = codec; self.range = range
    }
}

public struct RenderReport: Sendable {
    public let framesRendered: Int
    public let duration: TimeValue
    public let wallSeconds: Double
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

    /// Placement that fits a source frame into the output while preserving aspect (letterbox/pillarbox).
    private func fit(_ w: Int, _ h: Int) -> LayerPlacement {
        let sx = Float(options.width) / Float(w), sy = Float(options.height) / Float(h)
        let s = min(sx, sy)
        let ox = (Float(options.width) - Float(w) * s) / 2, oy = (Float(options.height) - Float(h) * s) / 2
        return LayerPlacement(offset: SIMD2(ox, oy), scale: s, opacity: 1)
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
        guard writer.startWriting() else { throw RenderError.writerFailed(writer.error?.localizedDescription ?? "startWriting") }
        writer.startSession(atSourceTime: .zero)

        let t0 = Date()
        var rendered = 0
        var pending: [MTLCommandBuffer] = []
        for f in firstFrame..<endFrame {
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
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
            let pts = try (t - range.start).cmTime()
            guard adaptor.append(out, withPresentationTime: pts) else { throw RenderError.writerFailed(writer.error?.localizedDescription ?? "append") }
            rendered += 1
            pending.removeAll()
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status == .failed { throw RenderError.writerFailed(writer.error?.localizedDescription ?? "finish") }
        return RenderReport(framesRendered: rendered, duration: TimeValue(frames: Int64(rendered), at: rate), wallSeconds: Date().timeIntervalSince(t0))
    }
}
