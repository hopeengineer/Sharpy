// sharpy — the command-line face of the engine. The same commands the MCP server will expose.
// M0 gate: a complete edit — ingest, cut, render — driven from here with no UI process anywhere.

import Foundation
import AVFoundation
import SharpyEngine
import SharpyRender

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

        // Build the edit through the command log: every decision carries a basis.
        var log = CommandLog(initial: Document(timeline: Timeline(name: "render", frameRate: r)))
        let asset = AssetRef(contentHash: "path:" + assetPath, path: assetPath, duration: src.duration, frameRate: src.nominalFrameRate, hasVideo: true, hasAudio: false)
        try log.append(.addAsset(asset))
        try log.append(.addTrack(kind: .video, name: "V1"))
        let id = log.head.assets.keys.first!
        let total = src.duration.frame(at: r)
        try log.append(.placeClip(track: 0, clip: Clip(asset: id, source: TimeRange(start: .zero, end: t(total)), start: .zero),
                                  decision: Decision(kind: .cut, at: .zero, params: ["asset": assetPath],
                                                     basis: .clientRule(rule: "render the asset given on the command line"))))
        for cut in options("--cut") {
            let parts = cut.split(separator: "-").compactMap { Int64($0) }
            guard parts.count == 2, parts[0] < parts[1] else { fail("bad --cut \(cut); expected startFrame-endFrame") }
            try log.append(.rippleDelete(track: 0, range: TimeRange(start: t(parts[0]), end: t(parts[1])),
                                         decision: Decision(kind: .cut, at: t(parts[0]), params: ["frames": cut],
                                                            basis: .clientRule(rule: "cut \(cut) requested on the command line"))))
        }
        print("timeline:  \(log.head.timeline.tracks[0].clips.count) clip(s), \(log.head.timeline.duration.frame(at: r)) frames = \(Timecode(frameIndex: log.head.timeline.duration.frame(at: r), rate: r)) @ \(r)")
        for (i, c) in log.head.timeline.tracks[0].clips.enumerated() {
            print("  clip \(i): timeline \(c.range.start.frame(at: r))-\(c.range.end.frame(at: r))  ← source \(c.source.start.frame(at: r))-\(c.source.end.frame(at: r))")
        }
        for did in log.head.decisionOrder { let d = log.head.decisions[did]!; print("  decision \(did): \(d.kind) @ frame \(d.at.frame(at: r))  basis=\(d.basis)") }
        let replayed = try log.replay().id
        precondition(replayed == log.head.id, "replay integrity")

        let session = try RenderSession(document: log.head, options: RenderOptions(width: w, height: h, codec: codec))
        let report = try session.render(to: URL(fileURLWithPath: outPath))
        print(String(format: "rendered:  %d frames in %.2f s = %.1f fps → %@", report.framesRendered, report.wallSeconds, report.fps, outPath))
    } catch { fail("render: \(error)") }

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
      sharpy render --asset <file> --out <file.mov> [--rate R] [--size WxH] [--codec prores|h264|hevc] [--cut a-b]...
      sharpy demo
    """)
}
