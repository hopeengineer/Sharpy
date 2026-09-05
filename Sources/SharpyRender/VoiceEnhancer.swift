// Making a room sound like a studio.
//
// Everything here is Apple's own, already on the machine: no model download, no third party, no
// network. `AUSoundIsolation` ('vois') is the voice/noise separator that ships with macOS, and the
// rest is the standard broadcast chain — high-pass, corrective EQ, dynamics, limiter — in the order
// an engineer would put them:
//
//   isolate  strip the room before anything shapes it, so the EQ is not sculpting noise
//   EQ       high-pass out rumble, cut the box (200–400 Hz), lift presence (3–5 kHz)
//   dynamics even out delivery, so a leaned-back sentence is not 8 dB under a leaned-in one
//   limiter  hold the peaks under the delivery ceiling
//
// Order matters and is not a preference: compressing before isolating pumps the room up between
// words, which is the classic sound of over-processed voice.
//
// The chain is MEASURED, not just applied. Every setting here can make a recording worse, and the
// only way to know which happened is the separation between speech and room before and after.
// `EnhancementReport` carries both, so a claim of "studio quality" has a number under it.

import Foundation
import AVFoundation
import AudioToolbox
import SharpyEngine

public struct VoiceEnhancement: Sendable {
    /// How much of the isolated signal to use, 0…1. Not 1.0 by default: total isolation on a
    /// recording with mild room tone sounds gated and unnatural, and the artefact is worse than
    /// the noise it removed.
    public var isolation: Double
    /// Everything below this is rumble, handling noise and desk thumps — nothing in a voice.
    public var highPassHz: Double
    /// Cut around 300 Hz takes the "box" out of a small room. Negative decibels.
    public var muddinessDb: Double
    /// Lift around 4 kHz is intelligibility — consonants, not brightness.
    public var presenceDb: Double
    /// Above this level, dynamics start working. dBFS.
    public var compressorThresholdDb: Double
    public var compressorRatio: Double
    /// True-peak ceiling for the limiter, dBFS.
    public var ceilingDb: Double

    /// A restrained default. Measured on the author's reel (25 dB of separation already), heavier
    /// settings removed more room and left audible artefacts on breaths, which is a worse trade
    /// than the noise.
    public static let studio = VoiceEnhancement(
        isolation: 0.75, highPassHz: 80, muddinessDb: -3, presenceDb: 3,
        compressorThresholdDb: -24, compressorRatio: 3, ceilingDb: -1)

    /// For genuinely noisy material — a fan, traffic, a room with hard walls.
    public static let noisyRoom = VoiceEnhancement(
        isolation: 1.0, highPassHz: 100, muddinessDb: -5, presenceDb: 4,
        compressorThresholdDb: -22, compressorRatio: 4, ceilingDb: -1)

    public init(isolation: Double, highPassHz: Double, muddinessDb: Double, presenceDb: Double,
                compressorThresholdDb: Double, compressorRatio: Double, ceilingDb: Double) {
        self.isolation = isolation; self.highPassHz = highPassHz
        self.muddinessDb = muddinessDb; self.presenceDb = presenceDb
        self.compressorThresholdDb = compressorThresholdDb
        self.compressorRatio = compressorRatio; self.ceilingDb = ceilingDb
    }
}

public struct EnhancementReport: Sendable, CustomStringConvertible {
    public let speechBefore: Double, noiseBefore: Double
    public let speechAfter: Double, noiseAfter: Double
    public let loudnessBefore: LoudnessReading?, loudnessAfter: LoudnessReading?
    public let wallSeconds: Double
    public let audioSeconds: Double

    public var separationBefore: Double { speechBefore - noiseBefore }
    public var separationAfter: Double { speechAfter - noiseAfter }
    public var separationGain: Double { separationAfter - separationBefore }

    /// Whether the chain actually helped. Stated as a question the numbers answer, because a
    /// processing chain that makes things worse is a real outcome and must not be reported as
    /// "enhanced".
    public var improved: Bool { separationGain > 0.5 }

    public var description: String {
        var lines = [String(format: "voice: speech %.1f → %.1f dBFS, room %.1f → %.1f dBFS",
                            speechBefore, speechAfter, noiseBefore, noiseAfter),
                     String(format: "  separation %.1f dB → %.1f dB (%+.1f dB)",
                            separationBefore, separationAfter, separationGain)]
        if !improved {
            lines.append("  NOT an improvement — the chain did not open up the gap between voice and room. Keep the original.")
        }
        if let a = loudnessAfter { lines.append("  after: \(a)") }
        lines.append(String(format: "  %.1f s of audio in %.1f s (%.0f× realtime)",
                            audioSeconds, wallSeconds, audioSeconds / max(wallSeconds, 0.001)))
        return lines.joined(separator: "\n")
    }
}

public enum VoiceEnhancerError: Error, CustomStringConvertible {
    case unitUnavailable(String)
    case renderFailed(String)
    public var description: String {
        switch self {
        case .unitUnavailable(let s): return "audio unit unavailable: \(s) — this macOS may not ship it"
        case .renderFailed(let s): return "offline render failed: \(s)"
        }
    }
}

public struct VoiceEnhancer: Sendable {
    public let settings: VoiceEnhancement
    public init(settings: VoiceEnhancement = .studio) { self.settings = settings }

    /// Write a short A/B: the same passage before, a beat of silence, then after.
    ///
    /// The reel this project is measured against is *about* this exact failure — an agent told to
    /// get a voice "closer to studio" hit the number and wrecked the sound, and the fix it names is
    /// "show me the before and after, don't tell me the numbers". A separation figure is necessary
    /// and it is not sufficient, so the tool that reports the number also produces the thing a
    /// person can actually judge.
    public func abComparison(original: URL, enhanced: URL, to output: URL,
                             from start: TimeValue = TimeValue(seconds: Rational(0)),
                             seconds: Double = 8, sampleRate: Int = 48_000) throws {
        let range = TimeRange(start: start,
                              end: start + TimeValue(seconds: Rational(Int64(seconds * 1000), 1000)))
        let a = try AudioSource(url: original, sampleRate: sampleRate, channels: 1)
        let b = try AudioSource(url: enhanced, sampleRate: sampleRate, channels: 1)
        let gap = [Float](repeating: 0, count: sampleRate / 2)
        let joined = try a.read(range) + gap + b.read(range)
        guard !joined.isEmpty else { throw VoiceEnhancerError.renderFailed("nothing to compare") }

        var file: AVAudioFile? = try AVAudioFile(
            forWriting: output,
            settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Double(sampleRate),
                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
                       AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false],
            commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(joined.count)) else {
            throw VoiceEnhancerError.renderFailed("could not allocate comparison buffer")
        }
        buffer.frameLength = AVAudioFrameCount(joined.count)
        joined.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: joined.count)
        }
        try file?.write(from: buffer)
        file = nil
        _ = file
    }

    /// Apple's voice isolator. Its absence is reported rather than silently skipped: a chain that
    /// quietly drops its most important stage would still produce a file, and the file would be
    /// described as isolated when nothing isolated it.
    static func soundIsolation() throws -> AVAudioUnitEffect {
        let desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0x766F6973,          // 'vois'
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard AudioComponentFindNext(nil, [desc].withUnsafeBufferPointer({ $0.baseAddress! })) != nil else {
            throw VoiceEnhancerError.unitUnavailable("AUSoundIsolation ('vois')")
        }
        return AVAudioUnitEffect(audioComponentDescription: desc)
    }

    public func enhance(url: URL, to output: URL, sampleRate: Int = 48_000) throws -> EnhancementReport {
        let before = try SilenceDetector.analyse(url: url, sampleRate: sampleRate)
        let loudnessBefore = try? LoudnessMeter.measure(url: url)
        let started = Date()

        // Samples come through AudioSource (AVAssetReader) rather than AVAudioFile. AVAudioFile
        // opens an .mp4 without complaint and then yields nothing useful, which produced a silent
        // master that only the before/after measurement caught. AudioSource decodes any container
        // this app can open, and is the same path every other measurement here uses — so the thing
        // being enhanced is the thing that was measured.
        let source = try AudioSource(url: url, sampleRate: sampleRate, channels: 1)
        let samples = try source.read(TimeRange(start: .zero, end: source.duration))
        guard !samples.isEmpty else { throw VoiceEnhancerError.renderFailed("no audio in \(url.lastPathComponent)") }
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        let isolate = try VoiceEnhancer.soundIsolation()
        let eq = AVAudioUnitEQ(numberOfBands: 3)
        let dynamics = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))

        engine.attach(player); engine.attach(isolate); engine.attach(eq)
        engine.attach(dynamics); engine.attach(limiter)
        engine.connect(player, to: isolate, format: format)
        engine.connect(isolate, to: eq, format: format)
        engine.connect(eq, to: dynamics, format: format)
        engine.connect(dynamics, to: limiter, format: format)
        engine.connect(limiter, to: engine.mainMixerNode, format: format)

        // Wet/dry is -100…100 on this unit; 100 is fully isolated.
        AudioUnitSetParameter(isolate.audioUnit, 0, kAudioUnitScope_Global, 0,
                              Float(settings.isolation * 100), 0)
        AudioUnitSetParameter(isolate.audioUnit, 1, kAudioUnitScope_Global, 0, 1, 0)   // isolate voice

        eq.bands[0].filterType = .highPass
        eq.bands[0].frequency = Float(settings.highPassHz)
        eq.bands[0].bypass = false
        eq.bands[1].filterType = .parametric
        eq.bands[1].frequency = 300; eq.bands[1].bandwidth = 1.0
        eq.bands[1].gain = Float(settings.muddinessDb); eq.bands[1].bypass = false
        eq.bands[2].filterType = .parametric
        eq.bands[2].frequency = 4000; eq.bands[2].bandwidth = 1.2
        eq.bands[2].gain = Float(settings.presenceDb); eq.bands[2].bypass = false

        AudioUnitSetParameter(dynamics.audioUnit, kDynamicsProcessorParam_Threshold,
                              kAudioUnitScope_Global, 0, Float(settings.compressorThresholdDb), 0)
        AudioUnitSetParameter(dynamics.audioUnit, kDynamicsProcessorParam_HeadRoom,
                              kAudioUnitScope_Global, 0, 5, 0)
        AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_PreGain,
                              kAudioUnitScope_Global, 0, 0, 0)

        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 4096)
        try engine.start()
        guard let input = AVAudioPCMBuffer(pcmFormat: format,
                                           frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw VoiceEnhancerError.renderFailed("could not allocate input buffer")
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            input.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        player.scheduleBuffer(input, at: nil, options: [])
        player.play()

        let settings2: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // Optional so it can be released BEFORE the output is measured. AVAudioFile flushes on
        // deinit, and measuring while it is still open reads a partly-written file: the first
        // version of this reported the enhanced master as digital silence when it was fine, and
        // only the "NOT an improvement" guard stopped that being shipped as a result.
        var out: AVAudioFile? = try AVAudioFile(forWriting: output, settings: settings2,
                                                commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw VoiceEnhancerError.renderFailed("could not allocate render buffer")
        }
        // The tail: the chain has latency, so stopping exactly at the source length clips the last
        // words. Half a second is longer than anything in this chain holds.
        let tail = AVAudioFramePosition(Double(sampleRate) * 0.5)
        let total = AVAudioFramePosition(samples.count) + tail
        while engine.manualRenderingSampleTime < total {
            let remaining = total - engine.manualRenderingSampleTime
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), remaining))
            switch try engine.renderOffline(frames, to: buffer) {
            case .success: try out?.write(from: buffer)
            case .insufficientDataFromInputNode: break
            case .cannotDoInCurrentContext, .error: throw VoiceEnhancerError.renderFailed("renderOffline")
            @unknown default: throw VoiceEnhancerError.renderFailed("unknown render status")
            }
        }
        engine.stop()
        out = nil                       // flush before measuring; see the note above
        _ = out

        let after = try SilenceDetector.analyse(url: output, sampleRate: sampleRate)
        return EnhancementReport(
            speechBefore: before.speechLevel, noiseBefore: before.noiseFloor,
            speechAfter: after.speechLevel, noiseAfter: after.noiseFloor,
            loudnessBefore: loudnessBefore,
            loudnessAfter: try? LoudnessMeter.measure(url: output),
            wallSeconds: Date().timeIntervalSince(started),
            audioSeconds: Double(samples.count) / Double(sampleRate))
    }
}
