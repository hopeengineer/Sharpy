// The local model reading a transcript, with everything it says checked before use.
//
// Separate from the main CLI because linking MLX means building with xcodebuild, and forcing that
// on the whole tool for one command would be the tail wagging the dog.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers
import SharpyEngine
import SharpyPerception
import SharpyReasoning

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let argv = CommandLine.arguments
func option(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: name), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}

guard argv.count > 1 else {
    print("""
    usage: sharpy-reason <video> [--model <dir>] [--window 180] [--overlap 40]

      Reads the transcript for MEANING, to find stretches the speaker abandoned and said again —
      the case word-matching cannot see, because the wrong version and the right one may share
      almost no words.

      The model only ever proposes word ranges. Every range is checked against the transcript
      before it counts, and what survives is held for review rather than cut automatically.
    """)
    exit(0)
}

let videoPath = argv[1]
let modelDirectory = option("--model").map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/huggingface/hub/models--mlx-community--gemma-4-E2B-it-4bit")
// The snapshot directory, whose name is a commit hash.
func resolveSnapshot(_ base: URL) -> URL {
    let snapshots = base.appendingPathComponent("snapshots")
    if let first = try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil).first {
        return first
    }
    return base
}

// A window long enough to hold the wrong version AND the correction, with overlap so a fumble
// straddling a boundary is not split in half and missed by both halves.
let windowWords = Int(option("--window") ?? "180") ?? 180
let overlapWords = Int(option("--overlap") ?? "40") ?? 40

// Asks twice with the options swapped, and only reports a verdict both passes give.
func judge(_ container: ModelContainer, before: String, candidate: String, after: String)
    async throws -> (TranscriptReasoner.Verdict, String) {
    var verdicts: [TranscriptReasoner.Verdict] = []
    var reason = ""
    for reversed in [false, true] {
        let prompt = TranscriptReasoner.adjudication(
            before: before, candidate: candidate, after: after, reverseOptions: reversed)
        let prepared = try await container.prepare(input: UserInput(prompt: prompt))
        var parameters = GenerateParameters()
        parameters.maxTokens = 60
        parameters.temperature = 0
        var answer = ""
        for await generated in try await container.generate(input: prepared, parameters: parameters) {
            if case .chunk(let chunk) = generated { answer += chunk }
        }
        let (verdict, why) = TranscriptReasoner.verdict(answer, reverseOptions: reversed)
        verdicts.append(verdict)
        if reason.isEmpty { reason = why }
    }
    return (TranscriptReasoner.agreed(first: verdicts[0], second: verdicts[1]), reason)
}

let semaphore = DispatchSemaphore(value: 0)
nonisolated(unsafe) var failure: Error?

Task {
    do {
        let url = URL(fileURLWithPath: videoPath)
        guard #available(macOS 26.0, *) else { fail("needs macOS 26") }
        let transcript = try await ParakeetIndexer().transcribe(url: url, asset: NodeID(contentOf: videoPath))
        let words = transcript.words.sorted { $0.index < $1.index }
        print("transcript: \(words.count) words")

        MLX.GPU.set(cacheLimit: 512 * 1024 * 1024)
        let directory = resolveSnapshot(modelDirectory)
        let started = Date()
        let container: ModelContainer
        do {
            container = try await LLMModelFactory.shared.loadContainer(
                from: directory, using: #huggingFaceTokenizerLoader())
        } catch {
            fail("could not load \(directory.lastPathComponent): \(error)")
        }
        print(String(format: "model loaded in %.1f s", Date().timeIntervalSince(started)))

        // CALIBRATION: score the judge on cases whose answer is known, before trusting it on cases
        // whose answer is not.
        if argv.contains("--calibrate") {
            var correct = 0, cutWhenShouldKeep = 0, keepWhenShouldCut = 0, unclear = 0
            for control in AdjudicationControls.all {
                let (verdict, reason) = try await judge(
                    container, before: control.before, candidate: control.candidate, after: control.after)
                let said = verdict == .cut ? true : false
                let right = verdict != .unclear && said == control.shouldCut
                if right { correct += 1 }
                else if verdict == .unclear { unclear += 1 }
                else if control.shouldCut { keepWhenShouldCut += 1 }
                else { cutWhenShouldKeep += 1 }
                print(String(format: "  %@ %@ (%@) — %@",
                             right ? "ok  " : "MISS",
                             verdict.rawValue.uppercased().padding(toLength: 7, withPad: " ", startingAt: 0),
                             control.note, reason.isEmpty ? "no reason given" : reason))
            }
            let total = AdjudicationControls.all.count
            print(String(format: "\ncalibration: %d/%d correct (%.0f%%) in %.1f s",
                         correct, total, 100 * Double(correct) / Double(total),
                         Date().timeIntervalSince(started)))
            print("  cut something that should have been kept: \(cutWhenShouldKeep)")
            print("  kept something that should have been cut: \(keepWhenShouldCut)")
            print("  could not decide: \(unclear)")
            print("\n  Cutting a keeper is the expensive mistake — it removes words the speaker meant.")
            semaphore.signal()
            return
        }

        // ADJUDICATION: the measurement finds candidates, the model judges them.
        if argv.contains("--adjudicate") {
            let found = SelfCorrectionFinder.find(in: transcript, minimumSimilarity: 0.55)
            print("candidates from measurement: \(found.corrections.count)")
            var cut: [Correction] = [], kept: [(Correction, String)] = [], unclear = 0, overruled = 0
            for correction in found.corrections {
                let first = correction.abandonedWords.lowerBound, last = correction.abandonedWords.upperBound
                func text(_ range: Range<Int>) -> String {
                    words.filter { $0.index >= range.lowerBound && $0.index < range.upperBound }
                        .map(\.text).joined(separator: " ")
                }
                let spelled = words.map(\.text)
                let context = TranscriptReasoner.sentenceAligned(
                    words: spelled, around: first..<(last + 1), budget: 45)
                let (verdict, reason) = try await judge(
                    container,
                    before: text(context.before),
                    candidate: text(first..<(last + 1)),
                    after: text(context.after))
                // Veto-only: the model may rescue a candidate, never add one. Anything short of a
                // clear "they meant it" leaves the measurement's proposal standing.
                let strongEnoughToOverrule = TranscriptReasoner.vetoStands(
                    gapSeconds: correction.gapSeconds, similarity: correction.similarity)
                if TranscriptReasoner.vetoes(verdict), strongEnoughToOverrule {
                    kept.append((correction, reason.isEmpty ? "the model reads this as deliberate" : reason))
                } else {
                    if verdict == .unclear { unclear += 1 }
                    if TranscriptReasoner.vetoes(verdict) { overruled += 1 }
                    cut.append(correction)
                }
            }
            print(String(format: "\nadjudicated in %.1f s: %d to cut, %d vetoed by the model (%d undecided, %d vetoes overruled by the measurement)",
                         Date().timeIntervalSince(started), cut.count, kept.count, unclear, overruled))
            for c in cut { print("  CUT  " + c.description) }
            for (c, why) in kept.prefix(8) {
                print(String(format: "  KEEP %6.2f s \"%@\" — %@",
                             c.abandoned.start.seconds.doubleValue, c.text.prefix(38) as CVarArg, why))
            }
            print("\n  The measurement proposed every candidate; the model could only veto. It scores "
                  + "4/6 at recognising deliberate repetition and 2/6 at recognising a fumble, so it "
                  + "is given the half it is good at. Run --calibrate to see those numbers.")
            semaphore.signal()
            return
        }

        var allSpans: [AbandonedSpan] = []
        var allRejected: [String] = []
        var start = 0
        while start < words.count {
            let end = min(start + windowWords, words.count)
            let numbered = TranscriptReasoner.numbered(transcript, from: start, to: end)
            let input = UserInput(prompt: TranscriptReasoner.prompt(for: numbered))
            let prepared = try await container.prepare(input: input)
            var parameters = GenerateParameters()
            parameters.maxTokens = 400
            // Zero: the same transcript must produce the same reading, or a decision cannot be
            // reproduced from the document later.
            parameters.temperature = 0
            var answer = ""
            for await generated in try await container.generate(input: prepared, parameters: parameters) {
                if case .chunk(let chunk) = generated { answer += chunk }
            }
            let (spans, rejected) = TranscriptReasoner.parse(answer, transcript: transcript)
            allSpans += spans
            allRejected += rejected
            print(String(format: "  words %d–%d: %d proposal(s), %d rejected",
                         start, end, spans.count, rejected.count))
            if end == words.count { break }
            start += max(windowWords - overlapWords, 1)
        }

        // Overlapping windows can propose the same stretch twice.
        var seen = Set<Int>()
        let unique = allSpans.sorted { $0.firstWord < $1.firstWord }.filter { seen.insert($0.firstWord).inserted }
        let edit = ReasonedEdit(abandoned: unique, rejected: allRejected,
                                modelName: directory.deletingLastPathComponent()
                                    .deletingLastPathComponent().lastPathComponent,
                                wallSeconds: Date().timeIntervalSince(started))
        print("")
        print(edit.summary)
        print("")
        print("  These are the model's READING, not a measurement — basis structuralInference at 3/5, "
              + "below every measured fact, and held for review rather than cut automatically.")
    } catch { failure = error }
    semaphore.signal()
}
semaphore.wait()
if let failure { fail("reason: \(failure)") }
