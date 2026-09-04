// sharpy-scene — run the VLM scene pass over a video and print what it claims, and what Vision
// refused to corroborate.
//
// Separate executable because it links MLX and must therefore be built with xcodebuild:
//   xcodebuild -scheme sharpy-scene -destination 'platform=macOS' -configuration Release \
//     -skipPackagePluginValidation -skipMacroValidation build
//
//   sharpy-scene <video> <model-dir> [--every 5] [--no-vision]

import Foundation
import SharpyEngine
import SharpyPerception
import SharpySemantics

let argv = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    argv.firstIndex(of: name).flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil }
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("sharpy-scene: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

guard argv.count >= 2 else {
    fail("usage: sharpy-scene <video> <model-dir> [--every 5] [--no-vision]")
}
let videoURL = URL(fileURLWithPath: argv[0])
let modelURL = URL(fileURLWithPath: argv[1])
let every = option("--every").flatMap { Double($0) } ?? 5

let semaphore = DispatchSemaphore(value: 0)
nonisolated(unsafe) var failure: Error?
Task {
    do {
        let asset = NodeID(contentOf: videoURL.path)

        // Vision first. Without it every claim is `unchecked`, which is exactly the state this
        // layer exists to avoid — so the default is to pay for Vision, and skipping it is an
        // explicit flag rather than a silent fallback.
        var vision: VisionIndex?
        if !argv.contains("--no-vision") {
            let t0 = Date()
            vision = try await VisionIndexer(options: VisionIndexOptions(samplesPerSecond: 1 / every))
                .index(url: videoURL, asset: asset)
            print(String(format: "vision: %d frames in %.1f s",
                         vision?.frames.count ?? 0, Date().timeIntervalSince(t0)))
        }

        let t1 = Date()
        let index = try await SceneIndexer(modelDirectory: modelURL,
                                           options: SceneIndexOptions(secondsPerSample: every))
            .index(url: videoURL, asset: asset, vision: vision)
        let elapsed = Date().timeIntervalSince(t1)

        print(String(format: "scene: %d observations in %.1f s (%.1f s/frame), model %@",
                     index.observations.count, elapsed,
                     elapsed / Double(max(index.observations.count, 1)), index.model))
        print(String(format: "corroborated by Vision: %.0f%%   contradicted: %d   abstained: %.0f%%",
                     index.corroborationRate * 100, index.contradicted.count,
                     index.abstentionRate * 100))
        for o in index.observations {
            let mark = o.standing == .contradicted ? "REJECTED" : (o.standing == .corroborated ? "ok" : "--")
            print(String(format: "  %7.2f  %-8s %-8s  %-34@ %@", o.time.seconds.doubleValue,
                         (o.shot.rawValue as NSString).utf8String!, (mark as NSString).utf8String!,
                         o.activity as NSString, o.setting as NSString))
            if o.standing == .contradicted { print("             \(o.reason)") }
        }
        for size in ShotSize.allCases {
            let runs = index.runs(of: size, tolerance: TimeValue(seconds: Rational(Int64(every * 1000), 1000)))
            if !runs.isEmpty {
                let total = runs.reduce(0.0) { $0 + $1.duration.seconds.doubleValue }
                print(String(format: "  %@: %d run(s), %.1f s total", size.rawValue, runs.count, total))
            }
        }
    } catch { failure = error }
    semaphore.signal()
}
semaphore.wait()
if let failure { fail("\(failure)") }
