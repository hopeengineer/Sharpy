// sharpy-probe — measure a VLM through mlx-swift on the labelled real-footage frames, with the
// same prompt and the same scoring as bench/bench_vlm_quality.py, so the Swift path is compared
// with the Python path on accuracy and speed rather than assumed equivalent.
//
//   sharpy-probe <model-dir> <frames-dir> <labels.json> [--max-frames N]
//
// <model-dir> is a local snapshot (e.g. ~/.cache/huggingface/hub/models--mlx-community--gemma-4-E2B-it-4bit/snapshots/<hash>).

import Foundation
import MLX
import MLXVLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

struct Arguments {
    let modelDir: URL, framesDir: URL, labelsURL: URL, maxFrames: Int
    let temperature: Float, textOnly: Bool
    init() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 3 else {
            print("usage: sharpy-probe <model-dir> <frames-dir> <labels.json> [--max-frames N]"); exit(2)
        }
        modelDir = URL(fileURLWithPath: args[0])
        framesDir = URL(fileURLWithPath: args[1])
        labelsURL = URL(fileURLWithPath: args[2])
        maxFrames = args.firstIndex(of: "--max-frames").flatMap { Int(args[$0 + 1]) } ?? Int.max
        temperature = args.firstIndex(of: "--temperature").flatMap { Float(args[$0 + 1]) } ?? 0
        textOnly = args.contains("--text-only")
    }
}

let prompt = """
You are the perception module of a video editor. Look at this single frame and answer ONLY with a JSON object, no prose, no markdown:
{"person_visible": true|false, "face_count": <int>, "hands_visible": true|false, "layout": "talking_head"|"card"|"split"|"other", "on_screen_text": [<every distinct line of text you can actually read, verbatim>], "setting": "<one short phrase>"}
Rules: layout=card means a dark graphic card fills the frame with no person; split means a card on top and a person below; talking_head means a person fills the frame. Only list text you can read with confidence; an empty list is a valid answer.
"""

struct Label: Decodable {
    let person_visible: Bool
    let face_count: Int
    let hands_visible: Bool
    let hands_ambiguous: Bool?
    let layout: String
    let on_screen_text: [String]
}

func norm(_ s: String) -> String {
    let lowered = s.lowercased()
    var out = ""; var lastSpace = true
    for ch in lowered {
        if ch.isLetter || ch.isNumber { out.append(ch); lastSpace = false }
        else if !lastSpace { out.append(" "); lastSpace = true }
    }
    return out.trimmingCharacters(in: .whitespaces)
}

func parseJSON(_ text: String) -> [String: Any]? {
    guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
    var s = String(text[start...end])
    if let d = s.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return j }
    // tolerate a trailing comma before ] or }
    s = s.replacingOccurrences(of: ",\\s*([}\\]])", with: "$1", options: .regularExpression)
    if let d = s.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return j }
    return nil
}

@main struct Probe {
    static func main() async throws {
        let a = Arguments()
        let modelDir = a.modelDir, framesDir = a.framesDir, labelsURL = a.labelsURL, maxFrames = a.maxFrames
        let labels = try JSONDecoder().decode([String: Label].self, from: Data(contentsOf: labelsURL))
        let frames = try FileManager.default.contentsOfDirectory(atPath: framesDir.path).filter { $0.hasSuffix(".jpg") }.sorted().prefix(maxFrames)

        MLX.GPU.set(cacheLimit: 512 * 1024 * 1024)
        let t0 = Date()
        let container = try await VLMModelFactory.shared.loadContainer(from: modelDir, using: #huggingFaceTokenizerLoader())
        let loadSeconds = Date().timeIntervalSince(t0)
        print(String(format: "loaded %@ in %.1f s  activeMem=%.2f GB  temperature=%.2f", modelDir.lastPathComponent, loadSeconds, Double(MLX.GPU.activeMemory) / 1e9, a.temperature))

        if a.textOnly {
            // Sanity check of the text path alone: no image, a trivial instruction.
            let lm = try await container.prepare(input: UserInput(prompt: "Reply with exactly the JSON object {\"ok\": true} and nothing else."))
            var params = GenerateParameters(); params.maxTokens = 40; params.temperature = a.temperature
            var text = ""
            for await g in try await container.generate(input: lm, parameters: params) { if case .chunk(let s) = g { text += s } }
            print("text-only reply: \(text.prefix(200))")
            return
        }

        var parsed = 0, personOK = 0, faceOK = 0, handsOK = 0, handsN = 0, layoutOK = 0
        var textHit = 0, textGT = 0, textExtra = 0, textReported = 0
        var wall = 0.0, promptTok = 0, genTok = 0, promptTime = 0.0, genTime = 0.0
        var peak: Double = 0

        for f in frames {
            guard let gt = labels[f] else { continue }
            var input = UserInput(prompt: prompt, images: [.url(framesDir.appendingPathComponent(f))])
            input.processing.resize = CGSize(width: 1024, height: 1024)   // same 1024 px budget as the Python run
            let t1 = Date()
            let lm = try await container.prepare(input: input)
            var params = GenerateParameters()
            params.maxTokens = 200
            params.temperature = a.temperature
            let stream = try await container.generate(input: lm, parameters: params)
            var text = ""
            for await g in stream {
                switch g {
                case .chunk(let s): text += s
                case .info(let i):
                    promptTok += i.promptTokenCount; genTok += i.generationTokenCount
                    promptTime += i.promptTime; genTime += i.generateTime
                default: break
                }
            }
            let dt = Date().timeIntervalSince(t1); wall += dt
            peak = max(peak, Double(MLX.GPU.peakMemory) / 1e9)

            guard let j = parseJSON(text) else { print("  \(f): unparseable (\(String(format: "%.1f", dt)) s): \(text.prefix(120))"); continue }
            parsed += 1
            if (j["person_visible"] as? Bool) == gt.person_visible { personOK += 1 }
            if (j["face_count"] as? Int) == gt.face_count { faceOK += 1 }
            if gt.hands_ambiguous != true { handsN += 1; if (j["hands_visible"] as? Bool) == gt.hands_visible { handsOK += 1 } }
            if (j["layout"] as? String)?.lowercased() == gt.layout { layoutOK += 1 }
            let g = gt.on_screen_text.map(norm).filter { !$0.isEmpty }
            let p = ((j["on_screen_text"] as? [String]) ?? []).map(norm).filter { !$0.isEmpty }
            textGT += g.count; textReported += p.count
            textHit += g.filter { x in p.contains { y in y.contains(x) || x.contains(y) } }.count
            textExtra += p.filter { y in !g.contains { x in y.contains(x) || x.contains(y) } }.count
            print(String(format: "  %@  %.2f s  person=%@ faces=%@ layout=%@ text=%d", f, dt,
                         String(describing: j["person_visible"] ?? "?"), String(describing: j["face_count"] ?? "?"),
                         String(describing: j["layout"] ?? "?"), (j["on_screen_text"] as? [String])?.count ?? 0))
        }
        let n = frames.count
        print("""

        SWIFT-PROBE \(modelDir.lastPathComponent): frames=\(n) parsed_json=\(parsed)/\(n) wall=\(String(format: "%.0f", wall)) s (\(String(format: "%.1f", wall / Double(max(n, 1))))s/frame) peakMLX=\(String(format: "%.2f", peak)) GB
           person_visible acc \(personOK)/\(n)
           face_count acc     \(faceOK)/\(n)
           hands_visible acc  \(handsOK)/\(handsN)
           layout acc         \(layoutOK)/\(n)
           text recall        \(textHit)/\(textGT) lines   extra lines \(textExtra)/\(textReported) reported
           prefill \(String(format: "%.0f", Double(promptTok) / max(promptTime, 1e-9))) tok/s   gen \(String(format: "%.0f", Double(genTok) / max(genTime, 1e-9))) tok/s   (\(promptTok) prompt tokens total)
        """)
    }
}
