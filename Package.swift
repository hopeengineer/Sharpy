// swift-tools-version: 6.0
// Sharpy — agent-first professional NLE for macOS. See docs/PLAN.md.
import PackageDescription
import Foundation

// OpenColorIO comes from Homebrew (BSD-3-Clause). Locate it rather than hardcoding one prefix,
// so the package builds on Apple Silicon (/opt/homebrew) and Intel (/usr/local) alike.
let ocioPrefix: String = {
    for p in ["/opt/homebrew/opt/opencolorio", "/usr/local/opt/opencolorio"] where FileManager.default.fileExists(atPath: p + "/include/OpenColorIO/OpenColorIO.h") {
        return p
    }
    return "/opt/homebrew/opt/opencolorio"   // build fails with a clear "file not found" if absent
}()

let package = Package(
    name: "Sharpy",
    platforms: [.macOS(.v15)],
    // The OCIO bridge is C++17.

    products: [
        .library(name: "SharpyEngine", targets: ["SharpyEngine"]),
        .library(name: "SharpyRender", targets: ["SharpyRender"]),
        .library(name: "SharpyPerception", targets: ["SharpyPerception"]),
        .library(name: "SharpyMCPCore", targets: ["SharpyMCPCore"]),
        .executable(name: "sharpy", targets: ["SharpyCLI"]),
        .executable(name: "sharpy-probe", targets: ["SharpyPerceptionProbe"]),
        .executable(name: "sharpy-mcp", targets: ["SharpyMCP"]),
    ],
    dependencies: [
        // Local VLM/LLM inference (Qwen3-VL, Gemma 4 registered in VLMModelFactory). Pinned.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", revision: "5694a2f6705f7c8b9cf195f29ec6d05938d42d22"),   // main @ 2026-09-01: Gemma 4 shared-KV + loader fixes absent from 3.31.4
        // Tokenizer + Hub integration that mlx-swift-lm's MLXHuggingFace macros expand against.
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        // WhisperKit + SpeakerKit (pyannote diarization), MIT, CoreML — no Python, no MLX, so
        // this builds under plain `swift build` unlike the MLX path.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
        // Parakeet TDT v3 on CoreML. The plan locks parakeet as the SECOND voting engine —
        // agreement between two independent engines is the per-word confidence — and mlx-swift-lm
        // ships no ASR at all, so the decided design was unreachable through the pinned runtime.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.1.0"),
    ],
    targets: [
        // The headless engine core. Pure value types, exact arithmetic, no UI, no media I/O.
        // Rule: every edit decision carries a basis; a decision without one is refused here,
        // at the type level, before anything can render.
        .target(
            name: "SharpyEngine",
            path: "Sources/SharpyEngine",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // C++ bridge to OpenColorIO's GPU path: config → Metal Shading Language + LUTs.
        .target(
            name: "COCIO",
            path: "Sources/COCIO",
            cxxSettings: [.unsafeFlags(["-I\(ocioPrefix)/include", "-std=c++17"])],
            linkerSettings: [.unsafeFlags(["-L\(ocioPrefix)/lib", "-lOpenColorIO",
                                           "-Xlinker", "-rpath", "-Xlinker", "\(ocioPrefix)/lib"])]
        ),
        // Decode → single-pass Metal composite → encode. Measured design (bench/).
        .target(
            name: "SharpyRender",
            dependencies: ["SharpyEngine", "COCIO"],
            path: "Sources/SharpyRender",
            swiftSettings: [.swiftLanguageMode(.v5)]   // AVFoundation/Metal types are not Sendable; audited by hand
        ),
        // Perception that needs no model files: Apple Speech and Vision, both on-device.
        // MLX-backed indexers live apart because anything linking MLX needs xcodebuild.
        .target(
            name: "SharpyPerception",
            dependencies: ["SharpyEngine", "SharpyRender",
                           .product(name: "WhisperKit", package: "argmax-oss-swift"),
                           .product(name: "SpeakerKit", package: "argmax-oss-swift"),
                           .product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/SharpyPerception",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The agent surface. Tools live in a library so they can be tested without a process;
        // the executable is transport only.
        .target(
            name: "SharpyMCPCore",
            dependencies: ["SharpyEngine", "SharpyRender", "SharpyPerception"],
            path: "Sources/SharpyMCPCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SharpyMCP",
            dependencies: ["SharpyMCPCore"],
            path: "Sources/SharpyMCP",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SharpyCLI",
            dependencies: ["SharpyEngine", "SharpyRender", "SharpyPerception"],
            path: "Sources/SharpyCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Measurement tool, not product code: runs a VLM through mlx-swift on the labelled
        // real-footage frames so the Swift path is compared with the Python numbers in bench/.
        .executableTarget(
            name: "SharpyPerceptionProbe",
            dependencies: [
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/SharpyPerceptionProbe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SharpyEngineTests",
            dependencies: ["SharpyEngine"],
            path: "Tests/SharpyEngineTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SharpyRenderTests",
            dependencies: ["SharpyEngine", "SharpyRender"],
            path: "Tests/SharpyRenderTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SharpyMCPTests",
            dependencies: ["SharpyEngine", "SharpyMCPCore"],
            path: "Tests/SharpyMCPTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SharpyPerceptionTests",
            dependencies: ["SharpyEngine", "SharpyRender", "SharpyPerception"],
            path: "Tests/SharpyPerceptionTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
