// sharpy — the command-line face of the engine. The same commands the MCP server will expose.
// M0 gate: a complete edit — ingest, cut, render — driven from here with no UI process anywhere.

import Foundation
import AVFoundation
import SharpyEngine
import SharpyRender
import SharpyPerception

let argv = Array(CommandLine.arguments.dropFirst())

func rate(_ s: String) -> FrameRate {
    switch s {
    case "29.97DF": return .ntsc30DF
    case "29.97": return .ntsc30
    case "23.976": return .ntsc24
    case "24": return .film24
    case "25": return .pal25
    case "30": return .r30
    case "50": return .pal50
    case "59.94DF": return .ntsc60DF
    case "59.94": return .ntsc60
    case "60": return .r60
    default: return .r30
    }
}

func option(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: name), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}

func options(_ name: String) -> [String] {
    var out: [String] = []
    for (i, a) in argv.enumerated() where a == name && i + 1 < argv.count { out.append(argv[i + 1]) }
    return out
}

func fail(_ msg: String) -> Never { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!); exit(1) }

switch argv.first {
case "version":
    print("sharpy 0.0.1 (M0 — headless engine)")

case "tc":
    guard let f = argv.dropFirst().first.flatMap({ Int64($0) }) else { fail("usage: sharpy tc <frame> [rate]") }
    let r = rate(argv.dropFirst(2).first ?? "29.97DF")
    let tc = Timecode(frameIndex: f, rate: r)
    print("\(tc)  frame \(f) @ \(r)  = \(tc.time.seconds) s  (\(String(format: "%.6f", tc.time.seconds.doubleValue)) s)")

case "probe":
    // sharpy probe <file> — the L0 facts the engine sees
    guard let path = argv.dropFirst().first else { fail("usage: sharpy probe <file>") }
    do {
        let src = try SequentialFrameSource(url: URL(fileURLWithPath: path))
        print("file:      \(path)")
        print("size:      \(src.width)x\(src.height)")
        print("rate:      \(src.nominalFrameRate)  (\(src.nominalFrameRate.fps))")
        print("duration:  \(src.duration)  = \(src.duration.frame(at: src.nominalFrameRate)) frames  = \(Timecode(frameIndex: src.duration.frame(at: src.nominalFrameRate), rate: src.nominalFrameRate))")
        if let f = try src.frame(at: .zero) { print("frame 0:   pts \(f.presentation) dur \(f.duration)  colour \(ColorTag.of(f.pixelBuffer))") }
    } catch { fail("probe: \(error)") }

case "render":
    // sharpy render --asset <file> --out <file.mov> [--rate 30] [--size 1920x1080] [--codec prores|h264|hevc]
    //               [--cut <startFrame>-<endFrame>]...   (ripple-deleted, in timeline frames, applied in order)
    guard let assetPath = option("--asset"), let outPath = option("--out") else {
        fail("usage: sharpy render --asset <file> --out <file.mov> [--rate 30] [--size WxH] [--codec prores|h264|hevc] [--cut a-b]...")
    }
    do {
        let src = try SequentialFrameSource(url: URL(fileURLWithPath: assetPath))
        let r = option("--rate").map(rate) ?? src.nominalFrameRate
        func t(_ f: Int64) -> TimeValue { TimeValue(frames: f, at: r) }
        var w = src.width, h = src.height
        if let s = option("--size"), let x = s.firstIndex(of: "x"), let ww = Int(s[..<x]), let hh = Int(s[s.index(after: x)...]) { w = ww; h = hh }
        let codec: RenderCodec = {
            switch option("--codec") ?? "prores" {
            case "h264": return .h264(bitrate: w * h * 6)
            case "hevc": return .hevc(bitrate: w * h * 4)
            default: return .proRes422HQ
            }
        }()

        let sampleRate = 48_000
        let audio = try? AudioSource(url: URL(fileURLWithPath: assetPath), sampleRate: sampleRate)

        // Build the edit through the command log: every decision carries a basis.
        var log = CommandLog(initial: Document(timeline: Timeline(name: "render", frameRate: r, sampleRate: sampleRate)))
        let asset = AssetRef(contentHash: "path:" + assetPath, path: assetPath, duration: src.duration,
                             frameRate: src.nominalFrameRate, hasVideo: true, hasAudio: audio != nil)
        try log.append(.addAsset(asset))
        try log.append(.addTrack(kind: .video, name: "V1"))
        if audio != nil { try log.append(.addTrack(kind: .audio, name: "A1")) }
        let id = log.head.assets.keys.first!
        let total = src.duration.frame(at: r)
        let place = Decision(kind: .cut, at: .zero, params: ["asset": assetPath],
                             basis: .clientRule(rule: "render the asset given on the command line"))
        try log.append(.placeClip(track: 0, clip: Clip(asset: id, source: TimeRange(start: .zero, end: t(total)), start: .zero), decision: place))
        if let audio {
            // Audio runs to its own duration on its own grid — it rarely ends exactly on a video frame.
            let audioEnd = min(audio.duration, src.duration).alignedToSample(at: sampleRate)
            try log.append(.placeClip(track: 1, clip: Clip(asset: id, source: TimeRange(start: .zero, end: audioEnd), start: .zero), decision: place))
        }
        // Transcript-driven cuts. The agent names words; these snap to each track's own grid.
        // Video is the master clock: a range is snapped to frame boundaries, and the audio track
        // removes the sample nearest those same instants. Per cut the two differ by at most one
        // sample (10.4 µs at 48 kHz) — three orders of magnitude below a frame.
        var wordPlans: [(String, WordCutPlan)] = []
        if argv.contains("--remove-fillers") || option("--remove-words") != nil {
            guard #available(macOS 26.0, *) else { fail("transcript editing needs macOS 26") }
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var transcript: Transcript?
            nonisolated(unsafe) var terr: Error?
            Task {
                do { transcript = try await SpeechIndexer().transcribe(url: URL(fileURLWithPath: assetPath), asset: id) }
                catch { terr = error }
                sem.signal()
            }
            sem.wait()
            if let terr { fail("transcribe: \(terr)") }
            guard let t = transcript else { fail("no transcript") }
            print("transcript: \(t.words.count) words, \(t.fillers.count) fillers")

            if argv.contains("--remove-fillers") {
                wordPlans.append(("fillers", WordEdit.planRemovingFillers(from: t)))
            }
            if let w = option("--remove-words") {
                var indices: [Int] = []
                for part in w.split(separator: ",") {
                    if part.contains("-"), case let bits = part.split(separator: "-").compactMap({ Int($0) }), bits.count == 2 {
                        indices.append(contentsOf: bits[0]...bits[1])
                    } else if let i = Int(part) { indices.append(i) }
                }
                let plan = WordEdit.plan(removing: indices, from: t)
                if !plan.unknownIndices.isEmpty { print("  warning: no such words: \(plan.unknownIndices)") }
                wordPlans.append(("words \(w)", plan))
            }
            _ = t   // pause tightening does not use the transcript: see below
        }

        // Dead air comes from the waveform, never from word-timing gaps: Apple's SpeechAnalyzer
        // returns contiguous word times, so gap-derived "pauses" are quantisation, not silence.
        var signalRanges: [TimeRange] = []
        if let p = option("--tighten-pauses"), let secs = Double(p) {
            let maximum = TimeValue(seconds: Rational(Int64(secs * 1000), 1000))
            let profile = try SilenceDetector.analyse(url: URL(fileURLWithPath: assetPath), minimumDuration: maximum)
            signalRanges = SilenceDetector.tighteningPlan(profile, cappingAt: maximum)
            print(String(format: "silence:    speech %.1f dBFS, %d run(s) over %.2f s, removing %.2f s",
                         profile.speechLevel, profile.runs.count, secs,
                         signalRanges.reduce(0.0) { $0 + $1.duration.seconds.doubleValue }))
        }

        // Merge every plan's ranges, snap to the frame grid, and cut both tracks together.
        let allRanges = WordEdit.merge(wordPlans.flatMap { $0.1.ranges } + signalRanges)
        for (label, plan) in wordPlans {
            print(String(format: "  %@: %d cut(s), %.2f s", label, plan.ranges.count, plan.removed.seconds.doubleValue))
        }
        for range in allRanges.reversed() {
            let vFrom = TimeValue(frames: range.start.nearestFrame(at: r), at: r)
            let vTo = TimeValue(frames: range.end.nearestFrame(at: r), at: r)
            guard vFrom < vTo else { continue }
            let d = Decision(kind: .cut, at: vFrom,
                             params: ["source": "transcript", "seconds": String(format: "%.3f", range.duration.seconds.doubleValue)],
                             basis: .measuredMaterial(ref: "transcript@\(String(format: "%.2f", range.start.seconds.doubleValue))",
                                                      detail: "word-aligned cut", confidence: Rational(9, 10)))
            try log.append(.rippleDelete(track: 0, range: TimeRange(start: vFrom, end: vTo), decision: d))
            if audio != nil {
                try log.append(.rippleDelete(track: 1, range: TimeRange(start: vFrom.alignedToSample(at: sampleRate),
                                                                       end: vTo.alignedToSample(at: sampleRate)), decision: d))
            }
        }

        for cut in options("--cut") {
            let parts = cut.split(separator: "-").compactMap { Int64($0) }
            guard parts.count == 2, parts[0] < parts[1] else { fail("bad --cut \(cut); expected startFrame-endFrame") }
            let vFrom = t(parts[0]), vTo = t(parts[1])
            let d = Decision(kind: .cut, at: vFrom, params: ["frames": cut],
                             basis: .clientRule(rule: "cut \(cut) requested on the command line"))
            try log.append(.rippleDelete(track: 0, range: TimeRange(start: vFrom, end: vTo), decision: d))
            if audio != nil {
                // Same instant, nearest sample: a frame boundary is not a sample boundary at 29.97.
                let aFrom = vFrom.alignedToSample(at: sampleRate), aTo = vTo.alignedToSample(at: sampleRate)
                try log.append(.rippleDelete(track: 1, range: TimeRange(start: aFrom, end: aTo), decision: d))
            }
        }
        print("timeline:  \(log.head.timeline.tracks.count) track(s), \(log.head.timeline.duration.frame(at: r)) frames = \(Timecode(frameIndex: log.head.timeline.duration.frame(at: r), rate: r)) @ \(r)\(audio == nil ? "  (no audio in source)" : "")")
        for (i, c) in log.head.timeline.tracks[0].clips.enumerated() {
            print("  clip \(i): timeline \(c.range.start.frame(at: r))-\(c.range.end.frame(at: r))  ← source \(c.source.start.frame(at: r))-\(c.source.end.frame(at: r))")
        }
        for e in log.head.uniqueDecisions {
            let tracks = e.applications > 1 ? " ×\(e.applications) tracks" : ""
            print("  decision \(e.id): \(e.decision.kind) @ frame \(e.decision.at.frame(at: r))\(tracks)  basis=\(e.decision.basis)")
        }
        let replayed = try log.replay().id
        precondition(replayed == log.head.id, "replay integrity")

        let target: LoudnessTarget? = {
            switch option("--loudness") {
            case "broadcast", "-23": return .ebuR128
            case "streaming", "-14": return .streaming
            case .some(let v): if let lufs = Double(v) { return LoudnessTarget(name: "\(lufs) LUFS", integrated: lufs, truePeakCeiling: -1) }; return nil
            case nil: return nil
            }
        }()
        let session = try RenderSession(document: log.head, options: RenderOptions(width: w, height: h, codec: codec, sampleRate: sampleRate, loudnessTarget: target))
        let report = try session.render(to: URL(fileURLWithPath: outPath))
        if let before = report.loudnessBefore, let gain = report.loudnessGainApplied {
            print(String(format: "loudness:  %@ → applied %+.2f dB%@", before.description, gain,
                         report.loudnessTargetMissedBy.map { String(format: "  (%.2f dB short of target — true-peak ceiling)", $0) } ?? ""))
        }
        print(String(format: "rendered:  %d frames + %d audio samples in %.2f s = %.1f fps → %@",
                     report.framesRendered, report.audioSamplesWritten, report.wallSeconds, report.fps, outPath))
    } catch { fail("render: \(error)") }

case "bench":
    // sharpy bench --asset <4k file> [--layers 1,2,4,6] [--frames 900] [--color <src>] [--display <space>]
    // The M0 gate: four 4K ProRes layers composited at >= 30 fps *with colour management on*.
    guard let assetPath = option("--asset") else { fail("usage: sharpy bench --asset <file> [--layers 1,2,4] [--frames N] [--color <space>]") }
    do {
        let layerCounts = (option("--layers") ?? "1,2,4,6").split(separator: ",").compactMap { Int($0) }
        let frameBudget = Int(option("--frames") ?? "900") ?? 900
        let url = URL(fileURLWithPath: assetPath)
        let display = option("--display") ?? "sRGB - Display"

        var pipelines: [(String, ColorPipeline)] = [("no colour management", .passthrough)]
        if let srcSpace = option("--color") {
            let p = try ColorPipeline(from: srcSpace, to: display)
            pipelines.append(("OCIO \(srcSpace) → linear → \(display)", p))
        }
        print("OpenColorIO \(ColorTransform.ocioVersion)   asset \(url.lastPathComponent)")

        for (label, pipeline) in pipelines {
            let comp = try MetalCompositor(colorPipeline: pipeline)
            print("\n\(label):")
            for n in layerCounts {
                let sources = try (0..<n).map { _ in try SequentialFrameSource(url: url) }
                let w = sources[0].width, h = sources[0].height
                let out = comp.makeOutputTexture(width: w, height: h)
                var placements: [LayerPlacement] = []
                for i in 0..<n {
                    placements.append(i == 0 ? .full : LayerPlacement(offset: SIMD2(Float(i) * 300, Float(i) * 150), scale: 0.5, opacity: 0.8))
                }
                let rate = sources[0].nominalFrameRate
                var rendered = 0
                let t0 = Date()
                var frame: Int64 = 0
                while rendered < frameBudget {
                    var layers: [CompositeLayer] = []
                    for (i, src) in sources.enumerated() {
                        guard let f = try src.frame(at: TimeValue(frames: frame, at: rate)) else { break }
                        layers.append(CompositeLayer(pixelBuffer: f.pixelBuffer, placement: placements[i]))
                    }
                    if layers.count < n { break }
                    let cb = try comp.encode(layers: layers, into: out)
                    cb.commit(); cb.waitUntilCompleted()
                    rendered += 1; frame += 1
                }
                let dt = Date().timeIntervalSince(t0)
                let fps = Double(rendered) / dt
                let gate = n == 4 ? (fps >= 30 ? "  ✓ GATE (>= 30 fps)" : "  ✗ GATE (< 30 fps)") : ""
                print(String(format: "  %d layer(s) @ %dx%d: %4d frames in %5.1f s = %6.1f fps%@", n, w, h, rendered, dt, fps, gate))
            }
        }
    } catch { fail("bench: \(error)") }

case "transcribe":
    // sharpy transcribe <file> [--segments] [--fillers] [--pauses <seconds>]
    guard let path = argv.dropFirst().first else { fail("usage: sharpy transcribe <file> [--segments] [--fillers] [--pauses 0.4]") }
    let url = URL(fileURLWithPath: path)
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var failure: Error?
    Task {
        do {
            if #available(macOS 26.0, *) {
                let t0 = Date()
                let t = try await SpeechIndexer().transcribe(url: url, asset: NodeID(contentOf: path))
                let dt = Date().timeIntervalSince(t0)
                let dur = try AudioSource(url: url).duration.seconds.doubleValue
                print(String(format: "%d words in %.1f s  (%.0f s audio, %.0f× realtime)  engines: %@",
                             t.words.count, dt, dur, dur / dt, t.engines.joined(separator: ", ")))
                if argv.contains("--segments") {
                    for s in t.segments() { print(String(format: "  [%5d] %7.2f–%7.2f  %@", s.firstWord, s.range.start.seconds.doubleValue, s.range.end.seconds.doubleValue, s.text)) }
                } else {
                    print(t.text)
                }
                if argv.contains("--fillers") {
                    let f = t.fillers
                    print("\nfillers: \(f.count)")
                    for w in f { print(String(format: "  word %d  %7.2f–%7.2f  %@", w.index, w.range.start.seconds.doubleValue, w.range.end.seconds.doubleValue, w.text)) }
                }
                if let p = option("--pauses"), let secs = Double(p) {
                    let minimum = TimeValue(seconds: Rational(Int64(secs * 1000), 1000))
                    let ps = t.pauses(longerThan: minimum)
                    let total = ps.reduce(0.0) { $0 + $1.duration.seconds.doubleValue }
                    print(String(format: "\npauses over %.2f s: %d, totalling %.1f s", secs, ps.count, total))
                    for x in ps.prefix(12) { print(String(format: "  after word %d  %7.2f–%7.2f  (%.2f s)", x.afterWord, x.range.start.seconds.doubleValue, x.range.end.seconds.doubleValue, x.duration.seconds.doubleValue)) }
                }
            } else { failure = SpeechIndexError.unsupportedLocale("macOS 26 required") }
        } catch { failure = error }
        sem.signal()
    }
    sem.wait()
    if let failure { fail("transcribe: \(failure)") }

case "verify":
    // sharpy verify --asset <file> [--loudness broadcast|streaming|<LUFS>]
    guard let assetPath = option("--asset") else { fail("usage: sharpy verify --asset <file> [--loudness ...]") }
    do {
        let src = try SequentialFrameSource(url: URL(fileURLWithPath: assetPath))
        let r = src.nominalFrameRate
        let sampleRate = 48_000
        let audio = try? AudioSource(url: URL(fileURLWithPath: assetPath), sampleRate: sampleRate)
        var log = CommandLog(initial: Document(timeline: Timeline(name: "verify", frameRate: r, sampleRate: sampleRate)))
        let asset = AssetRef(contentHash: "path:" + assetPath, path: assetPath, duration: src.duration,
                             frameRate: r, hasVideo: true, hasAudio: audio != nil)
        try log.append(.addAsset(asset))
        try log.append(.addTrack(kind: .video, name: "V1"))
        if audio != nil { try log.append(.addTrack(kind: .audio, name: "A1")) }
        let id = log.head.assets.keys.first!
        let d = Decision(kind: .cut, at: .zero, basis: .clientRule(rule: "verify the asset as given"))
        try log.append(.placeClip(track: 0, clip: Clip(asset: id, source: TimeRange(start: .zero, end: TimeValue(frames: src.duration.frame(at: r), at: r)), start: .zero), decision: d))
        if let audio { try log.append(.placeClip(track: 1, clip: Clip(asset: id, source: TimeRange(start: .zero, end: min(audio.duration, src.duration).alignedToSample(at: sampleRate)), start: .zero), decision: d)) }

        let target: LoudnessTarget? = {
            switch option("--loudness") {
            case "broadcast", "-23": return .ebuR128
            case "streaming", "-14": return .streaming
            case .some(let v): return Double(v).map { LoudnessTarget(name: "\($0) LUFS", integrated: $0, truePeakCeiling: -1) }
            case nil: return nil
            }
        }()
        let session = try RenderSession(document: log.head, options: RenderOptions(width: src.width, height: src.height, sampleRate: sampleRate, loudnessTarget: target))
        let result = try session.verify()
        print(result.summary)
        for f in result.blocking { print("  ✗ \(f.description)") }
        for f in result.holds { print("  ⏸ \(f.description)") }
        for f in result.warnings { print("  ⚠ \(f.description)") }
        if result.canRender { print("  ✓ clear to render") }
        exit(result.canRender ? 0 : 1)
    } catch { fail("verify: \(error)") }

case "report":
    // sharpy report <file> [--fps 0.25] — the editor's report: everything measured, said plainly.
    guard let path = argv.dropFirst().first else { fail("usage: sharpy report <file> [--fps N]") }
    do {
        let store = try IndexStore()
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var report: EditorsReport?
        nonisolated(unsafe) var rerr: Error?
        let fps = Double(option("--fps") ?? "0.25") ?? 0.25
        Task {
            do {
                if #available(macOS 26.0, *) { report = try await ReportBuilder(store: store).build(url: URL(fileURLWithPath: path), visionFPS: fps) }
                else { rerr = SpeechIndexError.unsupportedLocale("macOS 26 required") }
            } catch { rerr = error }
            sem.signal()
        }
        sem.wait()
        if let rerr { fail("report: \(rerr)") }
        guard let r = report else { fail("no report") }
        print("── \(URL(fileURLWithPath: r.path).lastPathComponent) ─────────────────────────────")
        for (title, group) in [("WHAT THIS IS", r.facts), ("WORTH DOING", r.opportunities), ("PROBLEMS", r.problems)] where !group.isEmpty {
            print("\n\(title)")
            for f in group { print("  · \(f.text)   [\(f.layer)]") }
        }
        print("\ncached layers: \(store.count) asset(s) in \(store.root.path)")
    } catch { fail("report: \(error)") }

case "look":
    // sharpy look <file> [--fps 1] [--fast] — what Vision sees
    guard let path = argv.dropFirst().first else { fail("usage: sharpy look <file> [--fps N] [--fast]") }
    do {
        let fps = Double(option("--fps") ?? "1") ?? 1
        let opts = VisionIndexOptions(samplesPerSecond: fps, accurateText: !argv.contains("--fast"))
        let t0 = Date()
        let idx = try VisionIndexer(options: opts).index(url: URL(fileURLWithPath: path), asset: NodeID(contentOf: path))
        let dt = Date().timeIntervalSince(t0)
        let withFace = idx.frames.filter(\.personVisible).count
        let withText = idx.frames.filter { !$0.text.isEmpty }.count
        let withHands = idx.frames.filter { !$0.hands.isEmpty }.count
        print(String(format: "%d frames sampled from %dx%d in %.1f s (%.2f s/frame)", idx.frames.count, idx.width, idx.height, dt, dt / Double(max(idx.frames.count, 1))))
        print("  person visible:  \(withFace)/\(idx.frames.count) frames")
        print("  hands visible:   \(withHands)/\(idx.frames.count) frames")
        print("  on-screen text:  \(withText)/\(idx.frames.count) frames, \(idx.allText.count) distinct lines")
        let ranges = idx.personVisibleRanges(tolerance: TimeValue(seconds: Rational(Int64(1000 / max(fps, 0.001)), 1000)))
        print("  person on screen in \(ranges.count) run(s):")
        for r in ranges.prefix(8) { print(String(format: "     %7.2f–%7.2f  (%.1f s)", r.start.seconds.doubleValue, r.end.seconds.doubleValue, r.duration.seconds.doubleValue)) }
        if !idx.allText.isEmpty {
            print("  text read:")
            for line in idx.allText.prefix(20) { print("     \(line)") }
            if idx.allText.count > 20 { print("     … \(idx.allText.count - 20) more") }
        }
    } catch { fail("look: \(error)") }

case "silence":
    // sharpy silence <file> [--below 25] [--min 0.4]
    guard let path = argv.dropFirst().first else { fail("usage: sharpy silence <file> [--below dB] [--min seconds]") }
    do {
        let below = Double(option("--below") ?? "25") ?? 25
        let minSec = Double(option("--min") ?? "0.4") ?? 0.4
        let p = try SilenceDetector.analyse(url: URL(fileURLWithPath: path), belowSpeechLevel: below,
                                            minimumDuration: TimeValue(seconds: Rational(Int64(minSec * 1000), 1000)))
        print(String(format: "speech level:  %.1f dBFS  (55th percentile of frames above −45 dB)", p.speechLevel))
        print(String(format: "noise floor:   %.1f dBFS", p.noiseFloor))
        print(String(format: "threshold:     %.1f dBFS  (%.0f dB below speech)", p.threshold, below))
        print(String(format: "dead air:      %d run(s), %.2f s total", p.runs.count, p.totalSilence.seconds.doubleValue))
        for r in p.runs.prefix(15) {
            print(String(format: "   %7.2f–%7.2f  (%.2f s, %.1f dBFS)", r.range.start.seconds.doubleValue,
                         r.range.end.seconds.doubleValue, r.duration.seconds.doubleValue, r.level))
        }
        if p.runs.count > 15 { print("   … \(p.runs.count - 15) more") }
    } catch { fail("silence: \(error)") }

case "loudness":
    // sharpy loudness <file> — EBU R128, cross-checkable against ffmpeg's ebur128
    guard let path = argv.dropFirst().first else { fail("usage: sharpy loudness <file>") }
    do {
        let r = try LoudnessMeter.measure(url: URL(fileURLWithPath: path))
        print("file:            \(path)")
        print("integrated:      \(r.integrated.map { String(format: "%.2f LUFS", $0) } ?? "−∞ (silent)")")
        print("loudness range:  \(String(format: "%.2f LU", r.range))")
        print("true peak:       \(String(format: "%.2f dBTP", r.truePeak))")
        if let m = r.maxMomentary { print("max momentary:   \(String(format: "%.2f LUFS", m))") }
        if let st = r.maxShortTerm { print("max short-term:  \(String(format: "%.2f LUFS", st))") }
        for target in [LoudnessTarget.ebuR128, .streaming] {
            let g = r.gain(toReach: target.integrated).map { String(format: "%+.2f dB", $0) } ?? "n/a"
            let peakOK = r.truePeak <= target.truePeakCeiling
            print("  \(target.name): needs \(g), true peak \(peakOK ? "within" : "OVER") \(String(format: "%.0f", target.truePeakCeiling)) dBTP")
        }
    } catch { fail("loudness: \(error)") }

case "colorspaces":
    do { for s in try ColorTransform.colorSpaces() { print(s) } } catch { fail("\(error)") }

case "demo":
    let r = FrameRate.r30
    func t(_ f: Int64) -> TimeValue { TimeValue(frames: f, at: r) }
    var log = CommandLog(initial: Document(timeline: Timeline(name: "main", frameRate: r)))
    let asset = AssetRef(contentHash: "sha256:demo", path: "/media/take1.mov", duration: t(3000), frameRate: r, hasVideo: true, hasAudio: true)
    do {
        try log.append(.addAsset(asset))
        try log.append(.addTrack(kind: .video, name: "V1"))
        let assetID = log.head.assets.keys.first!
        try log.append(.placeClip(track: 0, clip: Clip(asset: assetID, source: TimeRange(start: t(0), end: t(300)), start: t(0)),
                                  decision: Decision(kind: .cut, at: t(0), basis: .measuredMaterial(ref: "take1", detail: "selected take", confidence: Rational(1)))))
        try log.append(.rippleDelete(track: 0, range: TimeRange(start: t(100), end: t(130)),
                                     decision: Decision(kind: .cut, at: t(100), basis: .measuredMaterial(ref: "pause@3.33", detail: "1.0 s dead air", confidence: Rational(19, 20)))))
        print("head:      \(log.head.id)")
        print("replay:    \(try log.replay().id)")
        print("duration:  \(log.head.timeline.duration) = \(Timecode(frameIndex: log.head.timeline.duration.frame(at: r), rate: r))")
        for (i, c) in log.head.timeline.tracks[0].clips.enumerated() { print("clip \(i):    timeline \(c.range)  source \(c.source)") }
        for id in log.head.decisionOrder { let d = log.head.decisions[id]!; print("decision \(id): \(d.kind) @ \(d.at)  basis=\(d.basis)") }
        let guess = Decision(kind: .structure, at: t(0), basis: .structuralInference(evidence: ["maybe a topic shift"], confidence: Rational(1, 2)))
        do { try log.append(.recordDecision(guess)); print("BUG: guess accepted") } catch { print("refused:   \(error)") }
    } catch { fail("error: \(error)") }

default:
    print("""
    sharpy — agent-first NLE engine (M0)
      sharpy version
      sharpy tc <frame> [29.97DF|29.97|23.976|24|25|30|50|59.94DF|59.94|60]
      sharpy probe <file>
      sharpy render --asset <file> --out <file.mov> [--rate R] [--size WxH] [--codec prores|h264|hevc]
                    [--cut a-b]... [--loudness broadcast|streaming|<LUFS>]
                    [--remove-fillers] [--remove-words 1,5,10-12] [--tighten-pauses <seconds>]
      sharpy bench --asset <file> [--layers 1,2,4,6] [--frames N] [--color <space>] [--display <space>]
      sharpy transcribe <file> [--segments] [--fillers] [--pauses <seconds>]
      sharpy verify --asset <file> [--loudness broadcast|streaming|<LUFS>]
      sharpy report <file> [--fps N]
      sharpy look <file> [--fps N] [--fast]
      sharpy silence <file> [--below dB] [--min seconds]
      sharpy loudness <file>
      sharpy colorspaces
      sharpy demo
    """)
}
