# Sharpy

An agent-first, professional-grade non-linear video editor for macOS. It runs entirely on your
own Mac — no cloud render, no service dependency — and it is built so that an AI agent is the
primary operator rather than a script poking at a UI meant for hands.

**Status: early.** The headless engine core, a frame-accurate render path, and the local
perception probe exist and are tested. There is no UI, no audio graph and no colour management
yet. See [Not built yet](#not-built-yet) for the honest list and
[`docs/PLAN.md`](docs/PLAN.md) for the full plan with every measurement behind it.

## The one rule

> **Every edit decision carries a `basis` — the specific fact or rule that produced it.
> A decision with no basis does not render.**

There are eight legal bases, ranked by authority: a safety constraint (WCAG flash limits,
loudness ceilings — non-overridable), a client rule, a platform requirement, a fact measured
from the footage, a statistic from a reference corpus, a learned preference, a documented craft
convention, and a structural inference with its cited evidence. Nothing else. Not "it felt
better", not "usually", not a model's prior.

This is enforced by the type system, not by convention: `Decision.init` takes a non-optional
`Basis`, so a basis-less decision cannot be constructed. A second gate rejects any decision
resting on an inferred fact below the project's confidence floor:

```
$ swift run sharpy demo
head:      f8596925e070
replay:    f8596925e070
duration:  9s = 00:00:09:00
clip 0:    timeline [0s, 10/3s)  source [0s, 10/3s)
clip 1:    timeline [10/3s, 9s)  source [13/3s, 10s)
decision f40a4e3e2c10: cut @ 0s  basis=measuredMaterial(ref: "take1", detail: "selected take", confidence: 1)
decision c6683260a3cd: cut @ 10/3s  basis=measuredMaterial(ref: "pause@3.33", detail: "1.0 s dead air", confidence: 19/20)
refused:   basis confidence 1/2 is below the project floor 7/10
```

`head` and `replay` match because the document is content-addressed over a canonical encoding
that is deterministic **by construction** — maps keyed by id are encoded as arrays sorted by
that id. Getting this wrong is not a theoretical risk: the first implementation let Codable
encode those maps in Swift's per-process-randomised `Dictionary` order, so the same document
hashed to one of n! values and replay integrity held about half the time. See
`Tests/SharpyEngineTests/CanonicalFormTests.swift`, which fails deterministically against that
mistake.

## What works today

- **Exact time.** Rational arithmetic throughout — a frame at 29.97 fps is `1001/30000` s
  exactly, never a float. SMPTE drop-frame timecode round-trips over every frame of an hour.
- **Content-addressed document.** Every state has an id (its hash); history is a replayable
  command log; undo is a pointer move and a branch costs nothing. The agent and any UI change
  the document only through `apply(_:)`.
- **Frame-accurate decode.** `AVSampleCursor`-positioned seeks so a seek lands on a real sample
  boundary, explicit BT.709 tagging, and per-layer BT.601/709/2020 handling in the shader.
- **Single-pass Metal compositor.** Decoder output is wrapped zero-copy through
  `CVMetalTextureCache` and every layer is sampled in one compute dispatch.
- **Render to ProRes / H.264 / HEVC**, driven from the CLI with no UI process in existence.

```bash
swift test                                                    # 30 tests, engine + render
swift run sharpy tc 107892 29.97DF                            # → 01:00:00;00
swift run sharpy probe input.mp4                              # the L0 facts the engine sees
swift run sharpy render --asset input.mp4 --out cut.mov --cut 300-420
```

## Measured, not assumed

Every number in the plan was measured on the target machine — a **Mac mini M4 with 16 GB**,
macOS 26.6.2. Raw results and the scripts that produced them are in [`bench/`](bench/).
Headlines:

| | measured |
|---|---|
| Metal compositor, four 4K layers | **135 fps** H.264 / **89 fps** ProRes (Core Image collapsed to 8.9) |
| Render of a real 88 s reel with a ripple cut | 2 529 frames in 3.9 s (**646 fps**, 1080×1920 ProRes), frame-accurate at 41.5 dB PSNR |
| Four concurrent 4K decodes | 324 fps aggregate H.264, 342 ProRes |
| Perception (Gemma 4 E2B, 22 hand-labelled real frames) | 22/22 faces, 85/90 on-screen text lines, 2.4 s/frame, 4.05 GB peak |
| Speech (whisper-turbo + parakeet) | every adjudicated error sits where the two disagree — so both run, and their agreement is the per-word confidence |

The perception numbers were taken twice, once through Python (`mlx-vlm`) and once through Swift
(`mlx-swift-lm`), and they match — which is what closed the "Swift-native or a Python sidecar"
question on evidence rather than preference.

## Requirements

- Apple Silicon Mac, 16 GB or more. macOS 15+ to build the engine; some benchmarks use
  macOS 26 APIs (`SpeechAnalyzer`).
- Xcode 26 / Swift 6.3.
- **Anything that links MLX must be built with `xcodebuild`, not `swift build`** — SwiftPM's
  command-line build cannot compile MLX's Metal shaders, and the failure only shows up at
  runtime as *"Failed to load the default metallib"*:

  ```bash
  xcodebuild -downloadComponent MetalToolchain   # once
  xcodebuild -scheme sharpy-probe -destination 'platform=macOS,arch=arm64' \
             -skipPackagePluginValidation -skipMacroValidation build
  ```

  `swift build` and `swift test` are correct for `SharpyEngine` and `SharpyRender`, which do
  not link MLX.

## Layout

| path | what |
|---|---|
| `Sources/SharpyEngine` | time, timecode, the document, the command log — pure values, no I/O |
| `Sources/SharpyRender` | decode → single-pass Metal composite → encode |
| `Sources/SharpyCLI` | `sharpy` |
| `Sources/SharpyPerceptionProbe` | measurement tool: scores a local VLM against labelled frames |
| `docs/PLAN.md` | the plan, the amended specification, and every measurement |
| `bench/` | benchmark scripts and raw results, including the real-footage quality pass |

## Not built yet

OpenColorIO inside the compositor (the ≥ 30 fps-with-colour-management gate), the audio graph,
the playback ring (render is still synchronous per frame), the LGPL build-flag assertion in CI,
the MCP server the agent will drive, and the perception/indexing pipeline itself. The roadmap
with exit criteria for each is in [`docs/PLAN.md` §9](docs/PLAN.md).

## Licence

[Apache-2.0](LICENSE). Chosen because every dependency is MIT or Apache-2.0, so it is
compatible throughout, and it carries a patent grant that matters in codec-adjacent code.

Two redistribution notes, also in [`NOTICE`](NOTICE): FFmpeg must be linked as **LGPL 2.1+**
(its default — `--enable-gpl` relicenses the whole build as GPL v2+), and model weights are not
part of this repository and carry their own licences.
