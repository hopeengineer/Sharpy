// swift-tools-version: 6.0
// Sharpy — agent-first professional NLE for macOS. See docs/PLAN.md.
import PackageDescription

let package = Package(
    name: "Sharpy",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SharpyEngine", targets: ["SharpyEngine"]),
        .library(name: "SharpyRender", targets: ["SharpyRender"]),
        .executable(name: "sharpy", targets: ["SharpyCLI"]),
        .executable(name: "sharpy-probe", targets: ["SharpyPerceptionProbe"]),
    ],
    dependencies: [
        // Local VLM/LLM inference (Qwen3-VL, Gemma 4 registered in VLMModelFactory). Pinned.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", revision: "5694a2f6705f7c8b9cf195f29ec6d05938d42d22"),   // main @ 2026-09-01: Gemma 4 shared-KV + loader fixes absent from 3.31.4
        // Tokenizer + Hub integration that mlx-swift-lm's MLXHuggingFace macros expand against.
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
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
        // Decode → single-pass Metal composite → encode. Measured design (bench/).
        .target(
            name: "SharpyRender",
            dependencies: ["SharpyEngine"],
            path: "Sources/SharpyRender",
            swiftSettings: [.swiftLanguageMode(.v5)]   // AVFoundation/Metal types are not Sendable; audited by hand
        ),
        .executableTarget(
            name: "SharpyCLI",
            dependencies: ["SharpyEngine", "SharpyRender"],
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
    ]
)
