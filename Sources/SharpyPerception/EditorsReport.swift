// The editor's report: everything measured about a piece of footage, said plainly.
//
// This is M1's gate, and it is a deliberately harsh one. If the report reads generic — the kind of
// thing that could be said about any video — then the perception layer is not carrying the product
// and no amount of editing verbs will save it. So every line here must either quote the material
// or cite a number taken from it. Nothing in this file is allowed to say "the pacing feels good".
//
// It is also the honest place for the plan's rule about provenance: each finding names the layer
// it came from, so a reader can tell a measurement from an inference at a glance.

import Foundation
import SharpyEngine
import SharpyRender

public struct Finding: Sendable {
    public enum Kind: String, Sendable { case fact, opportunity, problem }
    public let kind: Kind
    /// Which layer produced it — L0 container, L1 signal, L2 semantic.
    public let layer: String
    public let text: String
    /// Where in the material, when it is localised.
    public let at: TimeRange?
}

public struct EditorsReport: Sendable {
    public let path: String
    public let duration: TimeValue
    public let frameRate: FrameRate?
    public let width: Int
    public let height: Int
    public let findings: [Finding]
    public let transcript: Transcript?
    public let loudness: LoudnessReading?
    public let speech: SpeechProfile?
    public let vision: VisionIndex?
    public let shots: ShotIndex?

    public var facts: [Finding] { findings.filter { $0.kind == .fact } }
    public var opportunities: [Finding] { findings.filter { $0.kind == .opportunity } }
    public var problems: [Finding] { findings.filter { $0.kind == .problem } }
}

public struct ReportBuilder {
    public let store: IndexStore
    public init(store: IndexStore) { self.store = store }

    @available(macOS 26.0, *)
    public func build(url: URL, visionFPS: Double = 0.25) async throws -> EditorsReport {
        var findings: [Finding] = []
        func fact(_ layer: String, _ text: String, at: TimeRange? = nil) { findings.append(Finding(kind: .fact, layer: layer, text: text, at: at)) }
        func opportunity(_ layer: String, _ text: String, at: TimeRange? = nil) { findings.append(Finding(kind: .opportunity, layer: layer, text: text, at: at)) }
        func problem(_ layer: String, _ text: String, at: TimeRange? = nil) { findings.append(Finding(kind: .problem, layer: layer, text: text, at: at)) }
        func hms(_ t: TimeValue) -> String {
            let s = t.seconds.doubleValue
            return String(format: "%d:%05.2f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
        }

        // ---- L0: what the file is -------------------------------------------------------
        let video = try? SequentialFrameSource(url: url)
        let audio = try? AudioSource(url: url)
        let duration = video?.duration ?? audio?.duration ?? .zero
        if let v = video {
            fact("L0", "\(v.width)×\(v.height) at \(v.nominalFrameRate), \(hms(v.duration)) long")
            if v.height > v.width { fact("L0", "portrait aspect — shot for a vertical feed") }
        }
        if audio == nil { problem("L0", "no audio track: every speech-driven edit is unavailable") }

        // ---- L1: signal -----------------------------------------------------------------
        var loudness: LoudnessReading?
        var speech: SpeechProfile?
        if audio != nil {
            let l = try LoudnessMeter.measure(url: url)
            loudness = l
            if let i = l.integrated {
                fact("L1", String(format: "integrated loudness %.1f LUFS, range %.1f LU, true peak %.1f dBTP", i, l.range, l.truePeak))
                // Delivery targets are alternatives, not a checklist — a piece ships to one of
                // them. Stating the distance to each is a fact; calling both a problem would mean
                // no mix could ever pass, since −14 and −23 cannot both be satisfied.
                let distances = [LoudnessTarget.streaming, .ebuR128].map {
                    String(format: "%+.1f dB to %@", $0.integrated - i, $0.name)
                }
                fact("L1", "to hit a delivery target: \(distances.joined(separator: ", "))")
                if l.truePeak > -1 { problem("L1", String(format: "true peak %.1f dBTP exceeds the −1 dBTP ceiling every platform applies", l.truePeak)) }
                if l.range < 3 { opportunity("L1", String(format: "loudness range is only %.1f LU — heavily compressed, little dynamic contrast", l.range)) }
            } else {
                problem("L1", "no audio passed the −70 LUFS gate: the track is effectively silent")
            }

            let s = try SilenceDetector.analyse(url: url, minimumDuration: TimeValue(seconds: Rational(3, 10)))
            speech = s
            fact("L1", String(format: "speech sits at %.1f dBFS over a %.1f dBFS floor — %.0f dB of separation",
                              s.speechLevel, s.noiseFloor, s.speechLevel - s.noiseFloor))
            if s.speechLevel - s.noiseFloor < 20 {
                problem("L1", String(format: "only %.0f dB between speech and room — noise reduction will be audible", s.speechLevel - s.noiseFloor))
            }
            if !s.runs.isEmpty {
                let total = s.totalSilence.seconds.doubleValue
                opportunity("L1", String(format: "%d silences over 0.3 s, %.1f s total (%.1f%% of the piece) — tightening them would save %.0f s",
                                         s.runs.count, total, 100 * total / max(duration.seconds.doubleValue, 0.001), total))
                if let longest = s.runs.max(by: { $0.duration.seconds.doubleValue < $1.duration.seconds.doubleValue }) {
                    opportunity("L1", String(format: "the longest gap is %.1f s at %@", longest.duration.seconds.doubleValue, hms(longest.range.start)), at: longest.range)
                }
            }
        }

        // ---- L2: speech -----------------------------------------------------------------
        var transcript: Transcript?
        if audio != nil {
            let (t, cached) = try await store.transcript(for: url)
            transcript = t
            let words = t.words.count
            let spoken = duration.seconds.doubleValue
            fact("L2", "\(words) words in \(hms(duration)) — \(Int(Double(words) / max(spoken, 0.001) * 60)) words per minute\(cached ? " (cached)" : "")")
            let segments = t.segments()
            fact("L2", "\(segments.count) spoken segments; the piece opens \"\(segments.first?.text.prefix(80) ?? "")\"")
            if let last = segments.last { fact("L2", "and closes \"\(last.text.suffix(80))\"", at: last.range) }
            if !t.fillers.isEmpty {
                opportunity("L2", "\(t.fillers.count) filler words — removing them would save about \(String(format: "%.1f", t.fillers.reduce(0.0) { $0 + $1.range.duration.seconds.doubleValue })) s")
            }
            let unsure = t.lowConfidence(below: Rational(7, 10))
            if !unsure.isEmpty {
                problem("L2", "\(unsure.count) words below the confidence floor — a second engine has not voted on this transcript yet")
            }
            // Longest segment: usually where the piece rambles.
            if let longest = segments.max(by: { $0.range.duration.seconds.doubleValue < $1.range.duration.seconds.doubleValue }),
               longest.range.duration.seconds.doubleValue > 12 {
                opportunity("L2", String(format: "one unbroken stretch runs %.0f s at %@ — the likeliest place to lose attention",
                                         longest.range.duration.seconds.doubleValue, hms(longest.range.start)), at: longest.range)
            }
        }

        // ---- L2: shots --------------------------------------------------------------------
        var shots: ShotIndex?
        if video != nil {
            let (si, cached) = try store.shots(for: url)
            shots = si
            let median = si.medianDuration.seconds.doubleValue
            if si.shots.count == 1 {
                fact("L2", "one continuous shot — no cuts to work with, so pacing lives entirely in the audio\(cached ? " (cached)" : "")")
            } else {
                fact("L2", String(format: "%d shots, median %.1f s%@", si.shots.count, median, cached ? " (cached)" : ""))
                if median < 1.5 { fact("L2", String(format: "median shot under 1.5 s — fast-cut, edit-forward pacing")) }
                if median > 8 { opportunity("L2", String(format: "median shot is %.0f s — long takes; consider punch-ins or B-roll to add cuts", median)) }
                if let longest = si.shots.max(by: { $0.duration.seconds.doubleValue < $1.duration.seconds.doubleValue }),
                   longest.duration.seconds.doubleValue > max(median * 4, 10) {
                    opportunity("L2", String(format: "one shot runs %.0f s at %@, %.0f× the median — the pacing stalls here",
                                             longest.duration.seconds.doubleValue, hms(longest.range.start),
                                             longest.duration.seconds.doubleValue / max(median, 0.001)), at: longest.range)
                }
            }
        }

        // ---- L2: picture ----------------------------------------------------------------
        var vision: VisionIndex?
        if video != nil {
            let (v, cached) = try store.vision(for: url, indexer: VisionIndexer(options: VisionIndexOptions(samplesPerSecond: visionFPS)))
            vision = v
            let sampled = v.frames.count
            let withFace = v.frames.filter(\.personVisible).count
            let withText = v.frames.filter { !$0.text.isEmpty }.count
            let withHands = v.frames.filter { !$0.hands.isEmpty }.count
            guard sampled > 0 else { return EditorsReport(path: url.path, duration: duration, frameRate: video?.nominalFrameRate, width: video?.width ?? 0, height: video?.height ?? 0, findings: findings, transcript: transcript, loudness: loudness, speech: speech, vision: vision, shots: shots) }
            fact("L2", "a person is on screen in \(Int(100.0 * Double(withFace) / Double(sampled)))% of sampled frames\(cached ? " (cached)" : "")")
            if withHands > 0 { fact("L2", "hands are visible in \(Int(100.0 * Double(withHands) / Double(sampled)))% — this is a gesturing delivery, not a static read") }
            if withText > 0 {
                fact("L2", "on-screen text in \(Int(100.0 * Double(withText) / Double(sampled)))% of frames, \(v.allText.count) distinct lines")
                let sample = v.allText.prefix(3).joined(separator: "\" / \"")
                fact("L2", "the graphics read \"\(sample)\"")
            }
            let ranges = v.personVisibleRanges(tolerance: TimeValue(seconds: Rational(Int64(1000 / max(visionFPS, 0.001)), 1000)))
            if ranges.count > 1 {
                fact("L2", "the subject appears in \(ranges.count) runs — the piece cuts away to graphics and back")
            }
            // Cross-layer: talking with nothing on screen is the classic dead patch.
            if withFace == 0 && withText == 0 { problem("L2", "no face and no text in any sampled frame — nothing anchors the viewer visually") }
        }

        return EditorsReport(path: url.path, duration: duration, frameRate: video?.nominalFrameRate,
                             width: video?.width ?? 0, height: video?.height ?? 0,
                             findings: findings, transcript: transcript, loudness: loudness,
                             speech: speech, vision: vision, shots: shots)
    }
}
