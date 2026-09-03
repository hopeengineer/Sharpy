// Sample-accurate PCM read from a media file, in the engine's exact rational time.
//
// AVAssetReader's `timeRange` gets us to the right neighbourhood; it does not guarantee the first
// returned buffer starts exactly at the requested instant, because audio is stored in packets.
// So we read from a packet boundary at or before the request and trim by an exact sample count.
// Everything downstream counts samples, never seconds-as-Double.

import AVFoundation
import SharpyEngine

public struct AudioFormatInfo: Sendable, Equatable, CustomStringConvertible {
    public let sampleRate: Int
    public let channels: Int
    public var description: String { "\(sampleRate) Hz, \(channels) ch" }
}

public enum AudioSourceError: Error, CustomStringConvertible {
    case noAudioTrack(URL)
    case fileNotFound(URL)
    case readerFailed(String)
    case formatUnavailable(URL)
    public var description: String {
        switch self {
        case .fileNotFound(let u): return "no file at \(u.path)"
        case .noAudioTrack(let u): return "no audio track in \(u.lastPathComponent)"
        case .readerFailed(let s): return "audio AVAssetReader: \(s)"
        case .formatUnavailable(let u): return "cannot read audio format of \(u.lastPathComponent)"
        }
    }
}

extension TimeValue {
    /// Sample index at a rate, floored — the sample containing this instant.
    public func sampleIndex(at rate: Int) -> Int64 { (seconds * Rational(Int64(rate))).floor }

    /// Nearest sample boundary. A frame boundary is *not* always a sample boundary: at 29.97 fps
    /// one frame is 48000 × 1001/30000 = 1601.6 samples, so a frame-aligned video cut lands
    /// between two samples. Video keeps the frame; audio takes the nearest sample (≤ 10.4 µs away).
    public func alignedToSample(at rate: Int) -> TimeValue {
        TimeValue(seconds: Rational((seconds * Rational(Int64(rate))).rounded, Int64(rate)))
    }
}

public final class AudioSource: @unchecked Sendable {
    public let url: URL
    public let format: AudioFormatInfo
    public let duration: TimeValue
    /// The format samples are delivered in: 32-bit float, interleaved, at `format`.
    private let asset: AVURLAsset
    private let track: AVAssetTrack

    public init(url: URL, sampleRate: Int = 48_000, channels: Int = 2) throws {
        self.url = url
        // Distinguish "the file is not there" from "the file has no sound". Conflating them sends
        // the caller hunting for a codec problem that does not exist.
        guard FileManager.default.fileExists(atPath: url.path) else { throw AudioSourceError.fileNotFound(url) }
        asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let t = asset.tracks(withMediaType: .audio).first else { throw AudioSourceError.noAudioTrack(url) }
        track = t
        duration = TimeValue(t.timeRange.duration)
        format = AudioFormatInfo(sampleRate: sampleRate, channels: channels)
    }

    /// Interleaved float samples for exactly `range`, converted to the project format.
    /// Returns `range.duration × sampleRate` frames, zero-padded if the source runs out.
    public func read(_ range: TimeRange) throws -> [Float] {
        let wantFrames = Int((range.duration.seconds * Rational(Int64(format.sampleRate))).rounded)
        guard wantFrames > 0 else { return [] }
        var out = [Float](repeating: 0, count: wantFrames * format.channels)

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        // Start a little early so the first packet certainly covers the request, then trim exactly.
        let pad = TimeValue(seconds: Rational(1, 10))
        let readStart = range.start < pad ? TimeValue.zero : range.start - pad
        reader.timeRange = CMTimeRange(start: try readStart.cmTime(), end: try range.end.cmTime())
        guard reader.startReading() else { throw AudioSourceError.readerFailed(reader.error?.localizedDescription ?? "startReading") }

        // Absolute sample index (in project sample rate) of the first sample we want.
        let wantStart = range.start.sampleIndex(at: format.sampleRate)
        var written = 0

        while let sb = output.copyNextSampleBuffer() {
            let pts = TimeValue(CMSampleBufferGetPresentationTimeStamp(sb))
            let bufStart = pts.sampleIndex(at: format.sampleRate)
            let n = CMSampleBufferGetNumSamples(sb)
            guard n > 0, let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var lengthAtOffset = 0, totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                                              totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == kCMBlockBufferNoErr,
                  let dataPointer else { continue }
            let floats = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
            let available = min(n, totalLength / (MemoryLayout<Float>.size * format.channels))

            // Overlap of [bufStart, bufStart+available) with [wantStart, wantStart+wantFrames)
            let from = max(wantStart, bufStart)
            let to = min(wantStart + Int64(wantFrames), bufStart + Int64(available))
            if from < to {
                let srcOffset = Int(from - bufStart) * format.channels
                let dstOffset = Int(from - wantStart) * format.channels
                let count = Int(to - from) * format.channels
                out.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.advanced(by: dstOffset).update(from: floats.advanced(by: srcOffset), count: count)
                }
                written = max(written, Int(to - wantStart))
            }
            if bufStart + Int64(available) >= wantStart + Int64(wantFrames) { break }
        }
        reader.cancelReading()
        if reader.status == .failed { throw AudioSourceError.readerFailed(reader.error?.localizedDescription ?? "read") }
        return out
    }
}

// MARK: - Building sample buffers for the writer

public enum AudioPacking {
    /// Wrap interleaved float samples as a CMSampleBuffer at `pts`, ready for AVAssetWriterInput.
    public static func sampleBuffer(interleaved samples: [Float], format: AudioFormatInfo, pts: TimeValue) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(format.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size * format.channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size * format.channels),
            mChannelsPerFrame: UInt32(format.channels),
            mBitsPerChannel: 32,
            mReserved: 0)

        var formatDesc: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                                    layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                                    extensions: nil, formatDescriptionOut: &formatDesc)
        guard status == noErr, let formatDesc else { throw AudioSourceError.readerFailed("CMAudioFormatDescriptionCreate \(status)") }

        let frames = samples.count / format.channels
        let byteCount = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
                                                    blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                    offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block else { throw AudioSourceError.readerFailed("CMBlockBufferCreate \(status)") }
        try samples.withUnsafeBytes { raw in
            let s = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
            guard s == kCMBlockBufferNoErr else { throw AudioSourceError.readerFailed("CMBlockBufferReplaceDataBytes \(s)") }
        }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
                                        presentationTimeStamp: try pts.cmTime(), decodeTimeStamp: .invalid)
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDesc,
                                           sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 1, sampleSizeArray: [MemoryLayout<Float>.size * format.channels],
                                           sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { throw AudioSourceError.readerFailed("CMSampleBufferCreateReady \(status)") }
        return sampleBuffer
    }
}
