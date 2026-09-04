// The MCP tool surface: session state and every tool implementation.
//
// This is a library rather than part of the executable so the tools can be tested directly.
// `SharpyMCP` is then only transport — a run loop that reads JSON-RPC and calls `runTool`.
//
// Sharpy as an MCP server: the agent surface.
//
// The tool design follows one rule, learned from shipped agent-native editors and from the
// project spec: **the agent addresses meaning, never frame arithmetic.** `remove_words` takes
// transcript indices; nothing in this interface asks an agent to multiply seconds by a frame rate.
// Where a tool must refuse, it names the constraint and the way out, because an error an agent
// cannot act on costs a whole turn.
//
// Two more borrowed lessons, both cheap and both usually missing:
//   · multi-granularity reads — `get_transcript` returns segments by default and words on request,
//     so comprehension does not cost the whole word list
//   · an explicit staleness contract — every mutation says that indices have shifted, so the agent
//     re-reads instead of acting on a stale map
//
// Transport is newline-delimited JSON-RPC 2.0 over stdio. Logging goes to stderr, never stdout:
// a stray print on stdout corrupts the protocol stream and is a genuinely nasty bug to find.

import Foundation
import SharpyEngine
import SharpyRender
import SharpyPerception

// MARK: - JSON-RPC

public struct RPCRequest: Decodable {
    public let jsonrpc: String
    public let id: JSONValue?
    public let method: String
    public let params: JSONValue?
}

/// Minimal dynamic JSON, so tool arguments need no per-tool Decodable.
public enum JSONValue: Codable {
    case null, bool(Bool), number(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .null }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var intValue: Int? {
        if case .number(let n) = self { return Int(n) }
        if case .string(let s) = self { return Int(s) }
        return nil
    }
    public var doubleValue: Double? {
        if case .number(let n) = self { return n }
        if case .string(let s) = self { return Double(s) }
        return nil
    }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public subscript(_ key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
}

func jsonObject(_ pairs: [String: Any]) -> Any { pairs }

public func writeMessage(_ payload: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

public func log(_ message: String) {
    FileHandle.standardError.write(("[sharpy-mcp] " + message + "\n").data(using: .utf8)!)
}

public func encodeID(_ id: JSONValue?) -> Any {
    switch id {
    case .some(.number(let n)): return n.rounded() == n ? Int(n) : n
    case .some(.string(let s)): return s
    default: return NSNull()
    }
}

public func respond(id: JSONValue?, result: [String: Any]) {
    writeMessage(["jsonrpc": "2.0", "id": encodeID(id), "result": result])
}

public func respondError(id: JSONValue?, code: Int, message: String) {
    writeMessage(["jsonrpc": "2.0", "id": encodeID(id), "error": ["code": code, "message": message]])
}

/// A tool result. `isError` tells the agent this was a refusal it should act on, not a crash.
public func toolResult(_ text: String, isError: Bool = false) -> [String: Any] {
    ["content": [["type": "text", "text": text]], "isError": isError]
}

// MARK: - Session

/// One open project. The server holds exactly one, because an agent editing two timelines at once
/// through a single connection has no way to say which it means.
public final class Session {
    public var mediaURL: URL?
    public var log: CommandLog?
    public var transcript: Transcript?
    public let store: IndexStore
    public let sampleRate = 48_000
    /// Every question the agent asks is logged as a defect with a burn-down, not as a feature.
    public let elicitations: ElicitationLog

    public init(storeRoot: URL? = nil) throws {
        store = try IndexStore(root: storeRoot)
        let logURL = (storeRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Sharpy", isDirectory: true))
            .appendingPathComponent("elicitations.json")
        elicitations = ElicitationLog(url: logURL)
    }

    public var document: Document? { log?.head }

    public func requireDocument() throws -> Document {
        guard let d = log?.head else { throw SessionError.noMediaOpen }
        return d
    }
    public func requireTranscript() throws -> Transcript {
        guard let t = transcript else { throw SessionError.noTranscript }
        return t
    }
    public var frameRate: FrameRate { log?.head.timeline.frameRate ?? .r30 }
}

public enum SessionError: Error, CustomStringConvertible {
    case noMediaOpen, noTranscript
    public var description: String {
        switch self {
        case .noMediaOpen: return "no media is open — call open_media first"
        case .noTranscript: return "no transcript yet — call get_transcript first, which produces one"
        }
    }
}

// MARK: - Tool definitions

public let tools: [[String: Any]] = [
    [
        "name": "open_media",
        "description": "Open a media file and start a timeline from it. Returns the container facts the engine reads (size, frame rate, duration, timecode) plus whether it carries audio. Call this before anything else.",
        "inputSchema": ["type": "object",
                        "properties": ["path": ["type": "string", "description": "Absolute path to the media file."]],
                        "required": ["path"]],
    ],
    [
        "name": "get_transcript",
        "description": "The spoken transcript with STABLE WORD INDICES — the addressing unit for every text-based edit. Defaults to 'segments' granularity, which is sentence-level and costs a fraction of the tokens; pass granularity='words' when you are about to cut, and use the firstWord index to jump between the two. Word indices shift after any edit, so re-read before cutting again.",
        "inputSchema": ["type": "object",
                        "properties": ["granularity": ["type": "string", "enum": ["segments", "words"],
                                                       "description": "segments (default) for reading; words for cutting."]],
                        "required": []],
    ],
    [
        "name": "remove_words",
        "description": "Cut speech by word index, Descript-style. Pass indices and ranges from get_transcript — never frame numbers, which is the whole point. Removes the surrounding pause so survivors do not end up double-spaced, merges adjacent removals into one cut, and cuts the linked video with the audio. After this runs, word indices have shifted: re-read get_transcript before cutting again.",
        "inputSchema": ["type": "object",
                        "properties": [
                            "words": ["type": "array", "items": ["type": "integer"],
                                      "description": "Word indices to remove."],
                            "ranges": ["type": "array", "items": ["type": "string"],
                                       "description": "Inclusive index ranges as \"start-end\", e.g. \"41-47\"."],
                            "fillers": ["type": "boolean", "description": "Remove every filler word (um, uh, …)."],
                            "aggressiveness": ["type": "string", "enum": ["tight", "balanced", "loose"],
                                               "description": "How much of the surrounding pause survives. Default balanced."],
                        ],
                        "required": []],
    ],
    [
        "name": "tighten_pauses",
        "description": "Cap every silence at a maximum length. Dead air is measured from the WAVEFORM, not from gaps between transcript words — speech recognisers return contiguous word timings, so word-gap 'pauses' are quantisation artefacts rather than silence. The threshold adapts to this recording's own speech level.",
        "inputSchema": ["type": "object",
                        "properties": ["maxSeconds": ["type": "number", "description": "Longest silence to keep, in seconds. Try 0.4."]],
                        "required": ["maxSeconds"]],
    ],
    [
        "name": "get_report",
        "description": "The editor's report: everything measured about the open media, said plainly — format, loudness, speech level, dead air, word rate, shot count and pacing, subject presence, on-screen text, and what is worth doing about it. Every line quotes the material or cites a number from it. Start here to understand footage you have not seen.",
        "inputSchema": ["type": "object", "properties": [:], "required": []],
    ],
    [
        "name": "get_scenes",
        "description": "What kind of shot each part of the media is, what is happening, and where — from the VLM ingest pass, cross-checked against Apple Vision. Use it to answer 'keep the wide shots', to find a cutaway, or to know when the frame is a graphic card rather than a person. Every claim is the WEAKEST class of basis the document recognises and can never outrank a measured fact; claims Vision contradicted are reported but marked unusable. Returns nothing if the scene pass has not been run — it is an ingest step and needs a VLM.",
        "inputSchema": ["type": "object",
                        "properties": ["shot": ["type": "string",
                                                "enum": ["closeUp", "medium", "wide", "card", "split", "other"],
                                                "description": "Only return runs of this shot size."]],
                        "required": []],
    ],
    [
        "name": "compare_to_catalogue",
        "description": "Check whether this edit looks like the work this person actually publishes — their own cutting rate, shot length, loudness and word rate, not a general norm. Assertions catch faults; nothing else catches an edit that is technically perfect and simply not theirs. Pass the measurements for the current piece; returns the axes that are unlike their usual work, or says plainly that there is too little history to know. Record a finished piece with `record_to_catalogue` so the norm exists at all.",
        "inputSchema": ["type": "object",
                        "properties": ["metrics": ["type": "object", "description": "Named numbers for this piece, e.g. {\"cutsPerMinute\": 12.4, \"wordsPerMinute\": 155, \"lufs\": -14.1}."],
                                       "videoID": ["type": "string", "description": "Optional: exclude this id from the comparison so a re-edit is not measured against itself."]],
                        "required": ["metrics"]],
    ],
    [
        "name": "record_to_catalogue",
        "description": "Add a delivered piece's measurements to the creator's catalogue, so future edits can be compared against what they actually publish. Call it on delivery, not on a draft — a catalogue of abandoned attempts describes nothing.",
        "inputSchema": ["type": "object",
                        "properties": ["videoID": ["type": "string"],
                                       "metrics": ["type": "object", "description": "The same named numbers used by compare_to_catalogue."]],
                        "required": ["videoID", "metrics"]],
    ],
    [
        "name": "note_preference",
        "description": "Record a note the person gave about how they want their work edited, in their own words. Returns whether it has now been asked enough times to be offered as a rule. Call it every time a correction is applied, not only when it seems important — the whole point is to notice repetition, and a note you decided was minor is exactly the one that gets asked for a fourth time. An unpromoted preference justifies nothing on its own.",
        "inputSchema": ["type": "object",
                        "properties": ["note": ["type": "string", "description": "Their wording, verbatim. Do not paraphrase — a rule they cannot recognise is one they cannot audit."],
                                       "project": ["type": "string", "description": "Optional project name, if the note is about this piece rather than everything."]],
                        "required": ["note"]],
    ],
    [
        "name": "promote_preference",
        "description": "Turn a repeated note into a rule, after the person has agreed. Scope is 'project' for this piece or 'standing' for everything they do. Only a promoted preference can supply a basis for an edit, and even then it ranks below any measured fact.",
        "inputSchema": ["type": "object",
                        "properties": ["id": ["type": "string", "description": "The preference id returned by note_preference."],
                                       "scope": ["type": "string", "enum": ["project", "standing"]]],
                        "required": ["id", "scope"]],
    ],
    [
        "name": "record_autonomy",
        "description": "Write this session's question count and footage duration into the durable autonomy journal, closing out one finished video. Call it when a piece is delivered, not when it is abandoned — a video given up on is not a data point about how much help was needed. Returns the trend across recent videos: whether the number of questions per hour of footage is falling, which is the measure of whether this tool is getting closer to needing nobody.",
        "inputSchema": ["type": "object",
                        "properties": ["videoID": ["type": "string", "description": "A stable name for the piece, so re-edits are visible as separate events."]],
                        "required": ["videoID"]],
    ],
    [
        "name": "get_timeline",
        "description": "The current timeline: tracks, clips with their timeline and source ranges, duration, and the decision record with each decision's basis. Read this to see the effect of your edits.",
        "inputSchema": ["type": "object", "properties": [:], "required": []],
    ],
    [
        "name": "verify",
        "description": "Run the assertions that gate a render. Returns blocking failures, holds and warnings. A 'hold' means nothing is wrong but confidence is too low to ship unattended. A check that could not run reports as a failure rather than passing quietly.",
        "inputSchema": ["type": "object",
                        "properties": ["loudnessTarget": ["type": "string", "enum": ["broadcast", "streaming"],
                                                          "description": "Assert against a delivery target as well."]],
                        "required": []],
    ],
    [
        "name": "render",
        "description": "Write the edit to a file. Assertions run first and can refuse. Optionally normalises the mix to a delivery target; the gain is capped by the true-peak ceiling and any shortfall is reported rather than hidden behind a limiter.",
        "inputSchema": ["type": "object",
                        "properties": [
                            "out": ["type": "string", "description": "Absolute output path, .mov"],
                            "codec": ["type": "string", "enum": ["prores", "h264", "hevc"]],
                            "loudnessTarget": ["type": "string", "enum": ["broadcast", "streaming"]],
                        ],
                        "required": ["out"]],
    ],
    [
        "name": "ask_human",
        "description": "Ask the person a bounded question you cannot answer from the material, and log it. Every question is recorded as a DEFECT with a burn-down, not as a feature — the goal is to need this less over time. Choose the category honestly: taste (which take), intent (is this on topic), groundTruth (which face is the subject), permission (this cut drops the only mention of X), failure (no B-roll matches this claim). Four of those five should eventually be answered by an authored artefact instead of by asking.",
        "inputSchema": ["type": "object",
                        "properties": [
                            "category": ["type": "string", "enum": ["taste", "intent", "groundTruth", "permission", "failure"]],
                            "question": ["type": "string", "description": "The question, in the words the person will read. Bounded and specific."],
                            "atSeconds": ["type": "number", "description": "Where in the material, when it is about a moment."],
                        ],
                        "required": ["category", "question"]],
    ],
    [
        "name": "autonomy_report",
        "description": "How close this is to needing no human: questions asked per hour of footage, broken down by category, and — the number that matters — how many answers produced nothing durable and will therefore be asked again. The set of categories with outstanding residue is the definition of what still needs a person.",
        "inputSchema": ["type": "object", "properties": [:], "required": []],
    ],
    [
        "name": "undo",
        "description": "Step back one command. Undo is a pointer into the command log, not an inverse operation, so it is always exact.",
        "inputSchema": ["type": "object", "properties": [:], "required": []],
    ],
]

// MARK: - Tool implementations

public func runTool(_ name: String, _ args: JSONValue?, _ session: Session) -> [String: Any] {
    func seconds(_ t: TimeValue) -> String { String(format: "%.3f", t.seconds.doubleValue) }

    do {
        switch name {

        case "open_media":
            guard let path = args?["path"]?.stringValue else { return toolResult("open_media needs a 'path'.", isError: true) }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                return toolResult("no file at \(path)", isError: true)
            }
            let video = try? SequentialFrameSource(url: url)
            let audio = try? AudioSource(url: url, sampleRate: session.sampleRate)
            guard video != nil || audio != nil else {
                return toolResult("\(url.lastPathComponent) has neither a video nor an audio track this engine can read.", isError: true)
            }
            let rate = video?.nominalFrameRate ?? .r30
            let duration = video?.duration ?? audio!.duration
            var log = CommandLog(initial: Document(timeline: Timeline(name: url.lastPathComponent, frameRate: rate, sampleRate: session.sampleRate)))
            let asset = AssetRef(contentHash: "path:" + path, path: path, duration: duration,
                                 frameRate: rate, hasVideo: video != nil, hasAudio: audio != nil)
            try log.append(.addAsset(asset))
            let d = Decision(kind: .cut, at: .zero, params: ["asset": path],
                             basis: .clientRule(rule: "the agent opened this file"))
            let id = log.head.assets.keys.first!
            if video != nil {
                try log.append(.addTrack(kind: .video, name: "V1"))
                try log.append(.placeClip(track: 0, clip: Clip(asset: id, source: TimeRange(start: .zero, end: TimeValue(frames: duration.frame(at: rate), at: rate)), start: .zero), decision: d))
            }
            if let audio {
                try log.append(.addTrack(kind: .audio, name: "A1"))
                let end = min(audio.duration, duration).alignedToSample(at: session.sampleRate)
                try log.append(.placeClip(track: video == nil ? 0 : 1, clip: Clip(asset: id, source: TimeRange(start: .zero, end: end), start: .zero), decision: d))
            }
            session.mediaURL = url
            session.log = log
            session.transcript = nil
            var lines = ["opened \(url.lastPathComponent)"]
            if let v = video {
                lines.append("  \(v.width)×\(v.height) at \(v.nominalFrameRate)")
                lines.append("  duration \(seconds(v.duration))s = \(Timecode(frameIndex: v.duration.frame(at: rate), rate: rate))")
            }
            lines.append("  audio: \(audio != nil ? "yes, \(session.sampleRate) Hz working rate" : "none — speech tools unavailable")")
            lines.append("  tracks: \(log.head.timeline.tracks.map { "\($0.name) (\($0.kind.rawValue))" }.joined(separator: ", "))")
            return toolResult(lines.joined(separator: "\n"))

        case "get_transcript":
            let doc = try session.requireDocument()
            _ = doc
            guard let url = session.mediaURL else { throw SessionError.noMediaOpen }
            if session.transcript == nil {
                guard #available(macOS 26.0, *) else { return toolResult("speech needs macOS 26.", isError: true) }
                let sem = DispatchSemaphore(value: 0)
                nonisolated(unsafe) var produced: Transcript?
                nonisolated(unsafe) var failure: Error?
                Task {
                    do { produced = try await session.store.transcript(for: url).0 } catch { failure = error }
                    sem.signal()
                }
                sem.wait()
                if let failure { return toolResult("transcription failed: \(failure)", isError: true) }
                session.transcript = produced
            }
            let t = try session.requireTranscript()
            let granularity = args?["granularity"]?.stringValue ?? "segments"
            if granularity == "words" {
                let rows = t.words.map { "[\($0.index)] \($0.text) \(seconds($0.range.start))–\(seconds($0.range.end))" }
                return toolResult("\(t.words.count) words. Indices are stable until you edit; re-read after any cut.\n" + rows.joined(separator: "\n"))
            }
            let rows = t.segments().map { "[firstWord \($0.firstWord)] \(seconds($0.range.start))–\(seconds($0.range.end))  \($0.text)" }
            return toolResult("\(t.segments().count) segments over \(t.words.count) words. "
                              + "Pass granularity='words' to get the indices you need for remove_words.\n"
                              + rows.joined(separator: "\n"))

        case "remove_words":
            let t = try session.requireTranscript()
            guard var log = session.log else { throw SessionError.noMediaOpen }
            var indices: [Int] = args?["words"]?.arrayValue?.compactMap { $0.intValue } ?? []
            for r in args?["ranges"]?.arrayValue ?? [] {
                guard let s = r.stringValue else { continue }
                let bits = s.split(separator: "-").compactMap { Int($0) }
                if bits.count == 2, bits[0] <= bits[1] { indices.append(contentsOf: bits[0]...bits[1]) }
            }
            let wantFillers = args?["fillers"]?.boolValue ?? false
            if wantFillers { indices.append(contentsOf: t.fillers.map(\.index)) }
            guard !indices.isEmpty else {
                return toolResult("nothing to remove: pass 'words', 'ranges', or fillers=true. "
                                  + (t.fillers.isEmpty ? "Note this transcript contains no filler words." : ""), isError: true)
            }
            let aggressiveness = CutAggressiveness(rawValue: args?["aggressiveness"]?.stringValue ?? "balanced") ?? .balanced
            let plan = WordEdit.plan(removing: indices, from: t, aggressiveness: aggressiveness)
            if !plan.unknownIndices.isEmpty && plan.removedWords.isEmpty {
                return toolResult("none of those indices exist (\(plan.unknownIndices)). The transcript has \(t.words.count) words, 0–\(t.words.count - 1).", isError: true)
            }
            let rate = session.frameRate
            let before = log.head.timeline.duration
            let basis = Basis.measuredMaterial(ref: "transcript", detail: "\(plan.removedWords.count) words by index", confidence: Rational(9, 10))
            for range in plan.ranges.reversed() {
                let vFrom = TimeValue(frames: range.start.nearestFrame(at: rate), at: rate)
                let vTo = TimeValue(frames: range.end.nearestFrame(at: rate), at: rate)
                guard vFrom < vTo else { continue }
                let d = Decision(kind: .cut, at: vFrom, params: ["words": "\(plan.removedWords.map(\.index))"], basis: basis)
                for (i, track) in log.head.timeline.tracks.enumerated() {
                    let from = track.kind == .video ? vFrom : vFrom.alignedToSample(at: session.sampleRate)
                    let to = track.kind == .video ? vTo : vTo.alignedToSample(at: session.sampleRate)
                    try log.append(.rippleDelete(track: i, range: TimeRange(start: from, end: to), decision: d))
                }
            }
            session.log = log
            session.transcript = nil       // indices are now stale by construction
            let after = log.head.timeline.duration
            var out = "removed \(plan.removedWords.count) words in \(plan.ranges.count) cut(s): "
            out += "\(seconds(before))s → \(seconds(after))s (−\(seconds(before - after))s)"
            if !plan.unknownIndices.isEmpty { out += "\n  ignored, no such word: \(plan.unknownIndices)" }
            out += "\n  WORD INDICES HAVE SHIFTED — call get_transcript again before cutting further."
            return toolResult(out)

        case "tighten_pauses":
            guard let url = session.mediaURL, var log = session.log else { throw SessionError.noMediaOpen }
            guard let maxSeconds = args?["maxSeconds"]?.doubleValue else {
                return toolResult("tighten_pauses needs 'maxSeconds'.", isError: true)
            }
            let maximum = TimeValue(seconds: Rational(Int64(maxSeconds * 1000), 1000))
            let profile = try SilenceDetector.analyse(url: url, minimumDuration: maximum)
            let ranges = SilenceDetector.tighteningPlan(profile, cappingAt: maximum)
            guard !ranges.isEmpty else {
                return toolResult(String(format: "no silence longer than %.2f s. Speech sits at %.1f dBFS over a %.1f dBFS floor, and the longest gap found was under the threshold.",
                                         maxSeconds, profile.speechLevel, profile.noiseFloor))
            }
            let rate = session.frameRate
            let before = log.head.timeline.duration
            let basis = Basis.measuredMaterial(ref: "silence", detail: String(format: "runs below %.1f dBFS", profile.threshold), confidence: Rational(95, 100))
            for range in ranges.reversed() {
                let vFrom = TimeValue(frames: range.start.nearestFrame(at: rate), at: rate)
                let vTo = TimeValue(frames: range.end.nearestFrame(at: rate), at: rate)
                guard vFrom < vTo else { continue }
                let d = Decision(kind: .cut, at: vFrom, params: ["dead air": seconds(range.duration)], basis: basis)
                for (i, track) in log.head.timeline.tracks.enumerated() {
                    let from = track.kind == .video ? vFrom : vFrom.alignedToSample(at: session.sampleRate)
                    let to = track.kind == .video ? vTo : vTo.alignedToSample(at: session.sampleRate)
                    try log.append(.rippleDelete(track: i, range: TimeRange(start: from, end: to), decision: d))
                }
            }
            session.log = log
            session.transcript = nil
            let after = log.head.timeline.duration
            return toolResult(String(format: "tightened %d silence(s), %.3fs → %.3fs (−%.3fs). Speech level %.1f dBFS, threshold %.1f dBFS.\n  WORD INDICES HAVE SHIFTED — re-read get_transcript.",
                                     ranges.count, before.seconds.doubleValue, after.seconds.doubleValue,
                                     (before - after).seconds.doubleValue, profile.speechLevel, profile.threshold))

        case "get_report":
            guard let url = session.mediaURL else { throw SessionError.noMediaOpen }
            guard #available(macOS 26.0, *) else { return toolResult("the report needs macOS 26.", isError: true) }
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var report: EditorsReport?
            nonisolated(unsafe) var failure: Error?
            Task {
                do { report = try await ReportBuilder(store: session.store).build(url: url) } catch { failure = error }
                sem.signal()
            }
            sem.wait()
            if let failure { return toolResult("report failed: \(failure)", isError: true) }
            guard let r = report else { return toolResult("no report produced", isError: true) }
            var out: [String] = []
            for (title, group) in [("WHAT THIS IS", r.facts), ("WORTH DOING", r.opportunities), ("PROBLEMS", r.problems)] where !group.isEmpty {
                out.append(title)
                for f in group { out.append("  · \(f.text)   [\(f.layer)]") }
            }
            return toolResult(out.joined(separator: "\n"))

        case "get_scenes":
            guard let url = session.mediaURL else { throw SessionError.noMediaOpen }
            // Read-only: production links MLX and is an ingest step, so the agent surface serves
            // what ingest cached and says plainly when there is nothing to serve.
            guard let fingerprint = try? MediaFingerprint(of: url),
                  let record = session.store.load(fingerprint),
                  let scene = record.scene, !scene.observations.isEmpty else {
                return toolResult("no scene index for this media. It is produced at ingest by the VLM pass (sharpy-scene); nothing is inferred here without it.")
            }
            var out = ["scene index from \(scene.model): \(scene.observations.count) observations",
                       String(format: "  corroborated by Vision %.0f%%, contradicted %d, abstained %.0f%%",
                              scene.corroborationRate * 100, scene.contradicted.count,
                              scene.abstentionRate * 100)]
            if let wanted = args?["shot"]?.stringValue.flatMap({ ShotSize(rawValue: $0) }) {
                let step = scene.observations.count > 1
                    ? scene.observations[1].time - scene.observations[0].time
                    : TimeValue(seconds: Rational(1, 1))
                let runs = scene.runs(of: wanted, tolerance: step)
                if runs.isEmpty {
                    out.append("  no usable \(wanted.rawValue) runs")
                } else {
                    for r in runs {
                        out.append(String(format: "  %@  %7.2f–%7.2f  (%.1f s)", wanted.rawValue,
                                          r.start.seconds.doubleValue, r.end.seconds.doubleValue,
                                          r.duration.seconds.doubleValue))
                    }
                }
            } else {
                for o in scene.observations {
                    let mark = o.standing == .contradicted ? "  [REJECTED: \(o.reason)]"
                             : (o.standing == .unchecked ? "  [unchecked]" : "")
                    out.append(String(format: "  %7.2f  %@  %@ — %@%@", o.time.seconds.doubleValue,
                                      o.shot.rawValue, o.activity, o.setting, mark))
                }
            }
            return toolResult(out.joined(separator: "\n"))

        case "get_timeline":
            let doc = try session.requireDocument()
            let rate = doc.timeline.frameRate
            var out = ["timeline \"\(doc.timeline.name)\" at \(rate), \(seconds(doc.timeline.duration))s = \(Timecode(frameIndex: doc.timeline.duration.frame(at: rate), rate: rate))"]
            for (i, track) in doc.timeline.tracks.enumerated() {
                out.append("track \(i): \(track.name) (\(track.kind.rawValue)), \(track.clips.count) clip(s)")
                for (j, c) in track.clips.enumerated() {
                    out.append("   clip \(j): timeline \(seconds(c.range.start))–\(seconds(c.range.end))  ← source \(seconds(c.source.start))–\(seconds(c.source.end))")
                }
            }
            let unique = doc.uniqueDecisions
            out.append("decisions: \(unique.count) editorial act(s), \(doc.decisionOrder.count) track application(s)")
            for entry in unique.suffix(10) {
                let tracks = entry.applications > 1 ? " ×\(entry.applications) tracks" : ""
                out.append("   \(entry.id) \(entry.decision.kind.rawValue) @ \(seconds(entry.decision.at))s\(tracks)  basis=\(entry.decision.basis)")
            }
            return toolResult(out.joined(separator: "\n"))

        case "verify", "render":
            let doc = try session.requireDocument()
            let target: LoudnessTarget? = {
                switch args?["loudnessTarget"]?.stringValue {
                case "broadcast": return .ebuR128
                case "streaming": return .streaming
                default: return nil
                }
            }()
            guard let url = session.mediaURL else { throw SessionError.noMediaOpen }
            let video = try? SequentialFrameSource(url: url)
            let codec: RenderCodec = {
                switch args?["codec"]?.stringValue ?? "prores" {
                case "h264": return .h264(bitrate: (video?.width ?? 1920) * (video?.height ?? 1080) * 6)
                case "hevc": return .hevc(bitrate: (video?.width ?? 1920) * (video?.height ?? 1080) * 4)
                default: return .proRes422HQ
                }
            }()
            let opts = RenderOptions(width: video?.width ?? 1920, height: video?.height ?? 1080,
                                     codec: codec, sampleRate: session.sampleRate, loudnessTarget: target)
            let session2 = try RenderSession(document: doc, options: opts)

            if name == "verify" {
                // Include everything the perception index makes checkable. Layers already cached
                // cost nothing; ones that are missing make their assertions report that they
                // could not run, which is the honest outcome.
                let cachedTranscript = session.transcript
                let cachedVision = try? session.store.vision(for: url).0
                let cachedShots = try? session.store.shots(for: url).0
                let perception = PerceptionContext(transcript: cachedTranscript, vision: cachedVision,
                                                   shots: cachedShots,
                                                   width: video?.width ?? 1920, height: video?.height ?? 1080)
                let verifier = Verifier.withPerception(perception)
                let result = try session2.verify(using: verifier)
                var out = [result.summary]
                for f in result.blocking { out.append("  BLOCK  \(f.description)") }
                for f in result.holds { out.append("  HOLD   \(f.description)") }
                for f in result.warnings { out.append("  warn   \(f.description)") }
                if result.canRender { out.append("  clear to render") }
                return toolResult(out.joined(separator: "\n"))
            }

            guard let out = args?["out"]?.stringValue else { return toolResult("render needs 'out'.", isError: true) }
            let report = try session2.render(to: URL(fileURLWithPath: out))
            var lines = [String(format: "rendered %d frames + %d audio samples in %.2f s (%.0f fps) → %@",
                                report.framesRendered, report.audioSamplesWritten, report.wallSeconds, report.fps, out)]
            if let before = report.loudnessBefore, let gain = report.loudnessGainApplied {
                lines.append(String(format: "  loudness: %@ → applied %+.2f dB", before.description, gain))
                if let short = report.loudnessTargetMissedBy {
                    lines.append(String(format: "  %.2f dB short of target: the true-peak ceiling bound the gain", short))
                }
            }
            return toolResult(lines.joined(separator: "\n"))

        case "ask_human":
            guard let categoryName = args?["category"]?.stringValue,
                  let category = ElicitationCategory(rawValue: categoryName) else {
                return toolResult("ask_human needs a 'category': \(ElicitationCategory.allCases.map(\.rawValue).joined(separator: ", "))", isError: true)
            }
            guard let question = args?["question"]?.stringValue, !question.isEmpty else {
                return toolResult("ask_human needs a 'question'.", isError: true)
            }
            let at = args?["atSeconds"]?.doubleValue.map { TimeValue(seconds: Rational(Int64($0 * 1000), 1000)) }
            let id = session.elicitations.ask(category, question, at: at,
                                              asset: session.mediaURL.map { NodeID(contentOf: $0.path) })
            var out = "logged as \(category.rawValue) question \(id):\n  \(question)"
            if let collapse = category.collapsesInto {
                out += "\n  This class of question should eventually be answered by \(collapse) instead of by asking."
            } else {
                out += "\n  This is the residue class — it does not collapse into an authored artefact."
            }
            return toolResult(out)

        case "autonomy_report":
            if let url = session.mediaURL, let video = try? SequentialFrameSource(url: url) {
                _ = video    // duration is recorded by the caller that actually handled the footage
            }
            let sessionReport = session.elicitations.report()
            var lines = [sessionReport.summary]
            // The session number alone cannot show the thing M4 measures: questions naturally
            // taper within one video as it is understood. The claim worth making is across videos,
            // so the durable journal is read here too.
            if let journal = try? AutonomyJournal() {
                let trend = journal.trend()
                if !trend.entries.isEmpty { lines.append(trend.summary) }
                else { lines.append("autonomy: no completed videos recorded yet — the cross-video trend starts once one is") }
            }
            return toolResult(lines.joined(separator: "\n"))

        case "compare_to_catalogue", "record_to_catalogue":
            guard let raw = args?["metrics"]?.objectValue else {
                return toolResult("\(name) needs a metrics object", isError: true)
            }
            var metrics: [String: Double] = [:]
            for (key, value) in raw {
                guard let number = value.doubleValue else {
                    return toolResult("metric \"\(key)\" is not a number", isError: true)
                }
                metrics[key] = number
            }
            guard !metrics.isEmpty else { return toolResult("no metrics given", isError: true) }
            do {
                let catalogue = try Catalogue()
                if name == "record_to_catalogue" {
                    guard let videoID = args?["videoID"]?.stringValue, !videoID.isEmpty else {
                        return toolResult("record_to_catalogue needs a videoID", isError: true)
                    }
                    try catalogue.record(CatalogueEntry(videoID: videoID, metrics: metrics))
                    return toolResult("recorded \(videoID) — \(catalogue.all().count) piece(s) in the catalogue")
                }
                return toolResult(catalogue.compare(metrics, excluding: args?["videoID"]?.stringValue).summary)
            } catch { return toolResult("catalogue: \(error)", isError: true) }

        case "note_preference":
            guard let note = args?["note"]?.stringValue, !note.isEmpty else {
                return toolResult("note_preference needs a note", isError: true)
            }
            do {
                let profile = try StyleProfile()
                let project = args?["project"]?.stringValue
                switch try profile.note(note, project: project) {
                case .recorded(let id, let occurrences):
                    return toolResult("recorded (\(occurrences)× so far) — id \(id)")
                case .offerPromotion(let id, let text, let occurrences):
                    // The specification calls an unpromoted repeat a tooling failure, so the tool
                    // says what to do about it rather than reporting a count and moving on.
                    return toolResult("""
                    \"\(text)\" has now been asked \(occurrences) times.
                    Offer to make it a rule — this project or standing — and call promote_preference with id \(id).
                    Asking a fourth time without offering is a tooling failure, not a preference.
                    """)
                }
            } catch { return toolResult("could not record: \(error)", isError: true) }

        case "promote_preference":
            guard let id = args?["id"]?.stringValue,
                  let scopeName = args?["scope"]?.stringValue,
                  let scope = PreferenceScope(rawValue: scopeName), scope != .once else {
                return toolResult("promote_preference needs an id and scope of project or standing", isError: true)
            }
            do {
                let profile = try StyleProfile()
                let promoted = try profile.promote(id, to: scope)
                return toolResult("\"\(promoted.text)\" is now a \(scope.rawValue) rule (asked \(promoted.occurrences)×, confidence \(promoted.confidence))")
            } catch { return toolResult("could not promote: \(error)", isError: true) }

        case "record_autonomy":
            // Closes the loop: the session's asking is written to the durable journal so the trend
            // across videos exists at all. Explicit rather than automatic — a video the agent
            // abandoned halfway is not a data point about how much help it needed.
            guard let videoID = args?["videoID"]?.stringValue, !videoID.isEmpty else {
                return toolResult("record_autonomy needs a videoID", isError: true)
            }
            do {
                let journal = try AutonomyJournal()
                try journal.record(session.elicitations.report(), videoID: videoID)
                return toolResult("recorded \(videoID)\n" + journal.trend().summary)
            } catch {
                return toolResult("could not record: \(error)", isError: true)
            }

        case "undo":
            guard let log = session.log, !log.commands.isEmpty else {
                return toolResult("nothing to undo.", isError: true)
            }
            let target = log.commands.count - 1
            let restored = try log.state(after: target)
            var rebuilt = CommandLog(initial: log.initial)
            for c in log.commands.prefix(target) { try rebuilt.append(c) }
            session.log = rebuilt
            session.transcript = nil
            return toolResult("undone. timeline is now \(seconds(restored.timeline.duration))s over \(restored.decisionOrder.count) decision(s).\n  WORD INDICES MAY HAVE SHIFTED — re-read get_transcript.")

        default:
            return toolResult("no such tool: \(name)", isError: true)
        }
    } catch {
        return toolResult("\(error)", isError: true)
    }
}

