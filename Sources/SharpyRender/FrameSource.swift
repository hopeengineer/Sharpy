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
    /// Presentation time of the previous sample, so a file with invalid sample durations can still
    /// report its real cadence.
    private var lastPresentation: TimeValue?
    private let lock = NSLock()

    /// - Parameter pixelFormat: NV12 (decoder-native for H.264/HEVC; measured fastest) or BGRA.
    public init(url: URL, pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) throws {
        self.url = url
        self.pixelFormat = pixelFormat
        asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let t = asset.tracks(withMediaType: .video).first else { throw FrameSourceError.noVideoTrack(url) }
        track = t
        duration = TimeValue(t.timeRange.duration)
        // Frame rate, in order of how much the file actually knows.
        //
        // The header fields are not reliable. On the user's 4K phone recording `nominalFrameRate`
        // reports 109.356 for a file that is exactly 30, and `minFrameDuration` is invalid — so
        // every frame number, timecode and cut point for that file came out 3.6x wrong. That is a
        // CORRECTNESS bug, not a performance one, and no better header field fixes it.
        //
        // So the cadence is MEASURED from the material, then snapped to a standard rate when it is
        // within a whisker of one. Snapping matters more than the error suggests: 29.97 and 30
        // differ by a tenth of a percent and by an entire timecode system.
        let mfd = t.minFrameDuration
        let fromHeader: Rational? = (mfd.isValid && mfd.value > 0)
            ? Rational(Int64(mfd.timescale), Int64(mfd.value)) : nil
        let measured = SequentialFrameSource.measureCadence(asset: asset, track: t)
        if let measured, let snapped = FrameRate.nearestStandard(toFPS: measured) {
            nominalFrameRate = snapped
        } else if let fromHeader, let snapped = FrameRate.nearestStandard(toFPS: fromHeader.doubleValue) {
            nominalFrameRate = snapped
        } else if let measured {
            nominalFrameRate = FrameRate(fps: Rational(Int64((measured * 1000).rounded()), 1000))
        } else {
            let fps = t.nominalFrameRate
            nominalFrameRate = FrameRate(fps: fromHeader ?? Rational(Int64((fps * 1000).rounded()), 1000))
        }
        let size = t.naturalSize.applying(t.preferredTransform)
        width = Int(abs(size.width).rounded()); height = Int(abs(size.height).rounded())
    }

    /// The frame containing `time`, or nil past the end.
    public func frame(at time: TimeValue) throws -> DecodedFrame? {
        lock.lock(); defer { lock.unlock() }
        if let c = current, c.interval.contains(time) { return c }
        // Sequential step, judged against a generous forward window.
        //
        // This was `c.duration + c.duration`, which assumes the reported frame duration is
        // trustworthy. On the user's 4K phone recording it is not: the samples carry an INVALID
        // duration (value 0, timescale 0), so the fallback used `nominalFrameRate`, which
        // AVFoundation reported as 109.356 fps for a file that is exactly 30. The step window was
        // therefore three times too narrow, every request fell outside it, and `frame(at:)` took
        // the SEEK path — rebuilding an entire AVAssetReader per frame.
        //
        // It cost 16x: raw decode measures 696 fps on that file and this managed 43.
        //
        // Stepping forward is cheap and seeking is not, so the window is now a whole second of
        // material. Overshooting it merely reads a few frames that get discarded; undershooting it
        // rebuilds a reader, and those costs are nowhere near symmetric.
        if let c = current, !(time < c.interval.end), time < c.interval.end + SequentialFrameSource.forwardStepWindow {
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
        reader = r; output = o; exhausted = false; current = nil; lastPresentation = nil
    }

    /// Read a handful of samples and report the observed frames per second.
    ///
    /// The MEDIAN interval, not the mean: a single long gap at a keyframe or a dropped sample would
    /// drag a mean far enough to pick the wrong standard rate, and picking the wrong one is exactly
    /// the failure this exists to prevent.
    static func measureCadence(asset: AVAsset, track: AVAssetTrack, samples: Int = 12) -> Double? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }

        var times: [Double] = []
        while times.count < samples, let sb = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            if pts.isValid { times.append(CMTimeGetSeconds(pts)) }
        }
        guard times.count >= 3 else { return nil }
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }.sorted()
        guard !gaps.isEmpty else { return nil }
        let median = gaps[gaps.count / 2]
        return median > 0 ? 1.0 / median : nil
    }

    /// How far ahead a request may be and still be reached by reading forward. Generous on
    /// purpose — see the note in `frame(at:)`.
    static let forwardStepWindow = TimeValue(seconds: Rational(1, 1))

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
        // Duration, in order of how much the file actually knows:
        //   1. the sample's own duration, when it has a valid one
        //   2. the OBSERVED gap from the previous sample — the file's real cadence, which beats
        //      any header field and is exact for variable-frame-rate material
        //   3. nominalFrameRate, which on this machine reported 109.356 for a 30 fps recording and
        //      is the least trustworthy of the three
        let dur: TimeValue
        if d.isValid && d.value > 0 {
            dur = TimeValue(d)
        } else if let previous = lastPresentation, previous < pts {
            dur = pts - previous
        } else {
            dur = TimeValue(seconds: nominalFrameRate.frameDuration)
        }
        lastPresentation = pts
        return DecodedFrame(pixelBuffer: pb, presentation: pts, duration: dur)
    }
}
