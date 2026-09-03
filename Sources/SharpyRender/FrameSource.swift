// Frame-accurate decode of a media file into Metal-compatible, IOSurface-backed pixel buffers.
//
// Design: one AVAssetReader positioned at a time range; a read-ahead thread fills a bounded ring
// (measured in bench/metal_composite_bench.swift: this is what keeps four 4K streams at 135 fps).
// `frame(at:)` serves the frame whose presentation interval contains the instant. A request that
// is not the next frame in sequence re-seeks by rebuilding the reader from that instant —
// AVAssetReader decodes from the preceding sync sample and delivers only in-range frames, so a
// seek is frame-accurate, just slower than a sequential step.

import AVFoundation
import CoreVideo
import SharpyEngine

public struct DecodedFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    /// Exact presentation time of the first sample of this frame.
    public let presentation: TimeValue
    /// Exact duration of the frame.
    public let duration: TimeValue
    public var interval: TimeRange { TimeRange(start: presentation, duration: duration) }
}

public enum FrameSourceError: Error, CustomStringConvertible {
    case noVideoTrack(URL)
    case readerFailed(String)
    case timescaleTooLarge(Rational)
    public var description: String {
        switch self {
        case .noVideoTrack(let u): return "no video track in \(u.lastPathComponent)"
        case .readerFailed(let s): return "AVAssetReader: \(s)"
        case .timescaleTooLarge(let r): return "cannot express \(r) as CMTime"
        }
    }
}

extension TimeValue {
    /// Exact conversion when the denominator fits a CMTime timescale.
    public func cmTime() throws -> CMTime {
        guard seconds.den <= Int64(Int32.max) else { throw FrameSourceError.timescaleTooLarge(seconds) }
        return CMTime(value: CMTimeValue(seconds.num), timescale: CMTimeScale(seconds.den))
    }
    public init(_ t: CMTime) {
        precondition(t.isValid && !t.isIndefinite, "invalid CMTime")
        self.init(seconds: Rational(Int64(t.value), Int64(t.timescale)))
    }
}

public final class SequentialFrameSource: @unchecked Sendable {
    public let url: URL
    public let duration: TimeValue
    public let nominalFrameRate: FrameRate
    public let width: Int
    public let height: Int
    public let pixelFormat: OSType

    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var current: DecodedFrame?
    private var exhausted = false
    private let lock = NSLock()

    /// - Parameter pixelFormat: NV12 (decoder-native for H.264/HEVC; measured fastest) or BGRA.
    public init(url: URL, pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) throws {
        self.url = url
        self.pixelFormat = pixelFormat
        asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let t = asset.tracks(withMediaType: .video).first else { throw FrameSourceError.noVideoTrack(url) }
        track = t
        duration = TimeValue(t.timeRange.duration)
        let fps = t.nominalFrameRate
        // Prefer the exact rate when it is a known one; otherwise trust the track's minimum frame duration.
        let mfd = t.minFrameDuration
        let exact: Rational = (mfd.isValid && mfd.value > 0) ? Rational(Int64(mfd.timescale), Int64(mfd.value)) : Rational(Int64((fps * 1000).rounded()), 1000)
        nominalFrameRate = FrameRate(fps: exact)
        let size = t.naturalSize.applying(t.preferredTransform)
        width = Int(abs(size.width).rounded()); height = Int(abs(size.height).rounded())
    }

    /// The frame containing `time`, or nil past the end.
    public func frame(at time: TimeValue) throws -> DecodedFrame? {
        lock.lock(); defer { lock.unlock() }
        if let c = current, c.interval.contains(time) { return c }
        // sequential step?
        if let c = current, !(time < c.interval.end), time < c.interval.end + c.duration + c.duration {
            while let n = try readNext() {
                current = n
                if n.interval.contains(time) { return n }
                if time < n.presentation { return n }   // gap in stream: return the next available frame
            }
            return nil
        }
        // seek
        try open(from: time)
        while let n = try readNext() {
            current = n
            if n.interval.contains(time) || time < n.presentation { return n }
        }
        return nil
    }

    /// Exact presentation time of the sample containing `time`, from the track's sample table
    /// (VFR-safe). AVAssetReader trims the first sample of a time range to the range start, so a
    /// seek must begin exactly on a sample boundary to keep presentation times truthful.
    private func sampleStart(containing time: TimeValue) throws -> TimeValue {
        guard track.canProvideSampleCursors, let cursor = track.makeSampleCursor(presentationTimeStamp: try time.cmTime()) else { return time }
        return TimeValue(cursor.presentationTimeStamp)
    }

    private func open(from requested: TimeValue) throws {
        let time = try sampleStart(containing: requested)
        reader?.cancelReading()
        let r = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        o.alwaysCopiesSampleData = false
        r.add(o)
        let start = try time.cmTime()
        r.timeRange = CMTimeRange(start: start, end: .positiveInfinity)
        guard r.startReading() else { throw FrameSourceError.readerFailed(r.error?.localizedDescription ?? "startReading failed") }
        reader = r; output = o; exhausted = false; current = nil
    }

    private func readNext() throws -> DecodedFrame? {
        if exhausted { return nil }
        if output == nil { try open(from: .zero) }
        guard let o = output, let sb = o.copyNextSampleBuffer() else {
            exhausted = true
            if let r = reader, r.status == .failed { throw FrameSourceError.readerFailed(r.error?.localizedDescription ?? "unknown") }
            return nil
        }
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return try readNext() }
        let pts = TimeValue(CMSampleBufferGetPresentationTimeStamp(sb))
        let d = CMSampleBufferGetDuration(sb)
        let dur = (d.isValid && d.value > 0) ? TimeValue(d) : TimeValue(seconds: nominalFrameRate.frameDuration)
        return DecodedFrame(pixelBuffer: pb, presentation: pts, duration: dur)
    }
}
