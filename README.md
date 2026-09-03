# Sharpy

An agent-first, professional-grade non-linear video editor for macOS. The agent operates it; a
person sets intent once and helps only when asked.

Every performance number below was measured on the target machine — a **Mac mini M4 with 16 GB**,
macOS 26.6 — and can be reproduced with the commands shown. Anything not measured is marked as
such in [`docs/PLAN.md`](docs/PLAN.md).

---

## Why it exists

Existing open-source editing tools cut on a **signal** — an audio threshold, a histogram delta —
never on **meaning**. None of them knows that a sentence at 04:12 sets up a payoff at 31:40, so
none can be trusted to cut. Closing that gap needs two things that do not exist together anywhere:
a real editor (frame-accurate, colour-managed, delivery-correct) and a perception layer detailed
enough for an agent to reason over.

The governing rule, which everything else serves:

> **Every edit decision carries a `basis` — the fact or rule that produced it.
> A decision with no basis does not render.**

That is enforced at the type level: `Decision.init` takes a non-optional `Basis`, and the engine's
`apply` refuses any decision whose basis sits below the project's confidence floor.

## Current state

**M0 (engine) complete. M1 (perception) gate met. M2 assertions, MCP server, falsifiable brief, elicitation logging and the cut linter landed. 141 tests green.**

| | |
|---|---|
| Compositor | Single-pass Metal kernel. **4× 4K ProRes at 83.4 fps with full ACES colour** (86.2 without) |
| Render | Frame-accurate, sample-accurate audio, **903 fps** on a 1080×1920 timeline |
| Colour | OpenColorIO 2.5.2, ACES built in. Linear→sRGB matches IEC 61966-2-1 within 2 code values |
| Loudness | EBU R128 in Swift. Agrees with ffmpeg's `ebur128` within **0.06 LU** |
| Speech | Apple `SpeechAnalyzer`, 61–79× realtime, word-level timings |
| Picture | Apple Vision — faces, hands, OCR at 0.23 s per sampled frame |
| Shots | Histogram content detector with a threshold derived from the material |
| Index | Content-addressed cache keyed by media fingerprint **and** analyser version |
| Verify | 16 assertions gate every render — `block` / `warn` / **`hold`** |
| Agent | MCP server over stdio: 11 tools, word-addressed editing, no frame arithmetic |

### Try it

```bash
swift build -c release
./.build/release/sharpy report path/to/footage.mp4
```

On a real 88-second vertical reel that produces, unprompted:

```
WHAT THIS IS
  · 1080×1920 at 30, 1:28.30 long
  · portrait aspect — shot for a vertical feed
  · integrated loudness -20.8 LUFS, range 5.4 LU, true peak -1.5 dBTP
  · speech sits at -22.8 dBFS over a -47.5 dBFS floor — 25 dB of separation
  · 265 words in 1:28.30 — 180 words per minute
  · 51 shots, median 1.0 s · median shot under 1.5 s — fast-cut, edit-forward pacing
  · a person is on screen in 78% of sampled frames
  · hands are visible in 52% — this is a gesturing delivery, not a static read
  · on-screen text in 82% of frames, 93 distinct lines

WORTH DOING
  · one shot runs 10 s at 0:40.67, 10× the median — the pacing stalls here
  · one unbroken stretch runs 15 s at 0:25.98 — the likeliest place to lose attention
  · 4 silences over 0.3 s, 0.9 s total — tightening them would save 1 s
```

Nothing there could be said about an arbitrary video. That specificity is the project's central
bet, and it is checked as a gate rather than assumed.

### Editing

```bash
# cut by frames, normalise the mix, and deliver
sharpy render --asset in.mp4 --out out.mov --cut 300-420 --loudness broadcast

# transcript-driven: the agent names words, never frames
sharpy render --asset in.mp4 --out out.mov --remove-fillers --remove-words 41-47,88

# remove dead air measured from the waveform
sharpy render --asset in.mp4 --out out.mov --tighten-pauses 0.4
```

### Reading the material

```bash
sharpy transcribe in.mp4 --segments --fillers   # words with stable indices
sharpy look in.mp4 --fps 1                      # faces, hands, on-screen text
sharpy silence in.mp4                           # dead air, from the signal
sharpy loudness in.mp4                          # EBU R128 + delivery targets
sharpy bench --asset 4k.mov --color ACEScg      # the compositor gate
sharpy verify --asset in.mp4 --loudness broadcast   # will this render, and should it?
```

### Verification

Assertions gate the render — they are not advisory. Three outcomes, and the third is the one
most tools leave out:

| | |
|---|---|
| `block` | the render does not happen |
| `warn` | it happens, and the report says what is wrong |
| **`hold`** | everything passed, but confidence is too low to ship unattended |

`hold` exists because *"no assertion failed"* and *"this is fit to publish"* are different
claims. An autonomous system needs the right to abstain; without it the only options are
ship-anyway and fail-loudly, and the first is what actually happens.

Two rules the layer enforces that are easy to get wrong:

- **A check that cannot run fails.** Set a loudness target without measuring the mix and the
  assertion reports that it could not run — it does not pass quietly. A QC layer that passes when
  it has nothing to say is decorative.
- **A client rule cannot override a safety constraint.** Flash limits and true-peak ceilings are
  not preferences. A standing instruction can override craft, norms and learned taste; it cannot
  switch off the things that exist to protect a viewer.

Five of the sixteen need to have looked at the material, which is where a linter stops being a
schema validator and starts catching what an editor would:

| check | outcome | why that outcome |
|---|---|---|
| a cut lands inside a spoken word | `block` | the most audible edit fault there is, and there is no deliberate version |
| a cut sits beside disputed speech | `hold` | where two ASR engines disagree is where meaning-inverting errors ship |
| on-screen text leaves the title-safe area | `warn` | cropped on some displays, covered by platform UI on others |
| text is up for less time than it takes to read | `warn` | a craft rule — neither FCC nor WCAG publishes a number |
| a cut falls inside a shot rather than on its boundary | `warn` | a jump cut is legitimate as a device, jarring as an accident |

### Driving it from an agent

`sharpy-mcp` speaks JSON-RPC over stdio. Point any MCP client at the binary:

```json
{ "mcpServers": { "sharpy": { "command": "/path/to/.build/release/sharpy-mcp" } } }
```

Eleven tools: `open_media`, `get_transcript`, `remove_words`, `tighten_pauses`, `get_report`,
`get_timeline`, `verify`, `render`, `undo`, `ask_human`, `autonomy_report`.

The interface follows one rule: **the agent addresses meaning, never frame arithmetic.**
`remove_words` takes transcript indices; nothing asks an agent to multiply seconds by a frame
rate. Three details that matter more than the tool list:

- **Multi-granularity reads.** `get_transcript` returns sentence segments by default and words on
  request, with a `firstWord` index to jump between them — comprehension does not cost the whole
  word list.
- **An explicit staleness contract.** Every mutation ends with *"WORD INDICES HAVE SHIFTED —
  call get_transcript again"*, because an agent acting on a stale map is the most common failure
  in this shape of tool.
- **Refusals name the way out.** `remove_words` on a bad index reports the range that exists;
  calling it before a transcript exists says which tool produces one.

A recorded session on a real reel: open, report, read segments, drill to words, cut words 0–14
(88.3 s → 82.7 s), tighten silences, verify — which correctly **blocks** on
*"-20.68 LUFS is +2.32 LU from the -23.0 LUFS target"* — then render, which normalises and lands
at exactly −23.0 LUFS (confirmed by ffmpeg), then undo.

### Toward needing no human

The long-run target is an agent that edits without help, so **every question it asks is logged as
a defect with a burn-down, not built as a feature.** `ask_human` records the question with a
category, and `autonomy_report` gives the headline number: questions per hour of footage.

Four of the five categories should collapse into an artefact authored once, which is the actual
mechanism — not a better model, but moving the human's input from *during* the edit to *before* it:

| category | retired by |
|---|---|
| taste — *which of these takes?* | a style profile learned from picks |
| intent — *is this tangent on topic?* | the brief |
| groundTruth — *which face is the subject?* | the enrollment registry |
| permission — *this drops the only mention of X* | policy |
| **failure** — *no B-roll matches this claim* | **nothing. This is the residue.** |

The measurement that matters is not the count but whether an answer **compiled into something
durable**. An answer that changed nothing means the same question returns, so the log counts it as
residue — and the set of categories with outstanding residue is the working definition of what
still needs a person.

## Architecture

```
SharpyEngine      exact rational time · SMPTE drop-frame timecode · immutable
                  content-addressed document · replayable command log · transcript
                  and word-addressed edit planning
SharpyRender      AVFoundation/VideoToolbox decode · single-pass Metal compositor ·
                  OpenColorIO · sample-accurate audio · EBU R128 · silence detection
SharpyPerception  Apple Speech · Apple Vision · shot detection · content-addressed
                  index cache · the editor's report
COCIO             C++ bridge emitting Metal Shading Language from OpenColorIO
SharpyCLI         the command surface
SharpyMCPCore     the tool surface — session state and every tool, testable directly
SharpyMCP         transport only: JSON-RPC over stdio
```

The engine is headless by construction. The M0 exit gate was *a complete edit driven by a script
with no UI process in existence*, and it is met.

### Things that are deliberately not shortcuts

- **Time is rational, never floating point.** 30 000 frames at 29.97 sum to exactly 1001 seconds.
  Drop-frame timecode round-trips over every frame of an hour.
- **Alignment is per track kind.** Video edits land on frames, audio on samples. At 29.97 fps one
  frame is 48000 × 1001/30000 = **1601.6 samples**, so a frame boundary is not a sample boundary.
- **Blending happens in linear light.** A 50 % black/white mix renders as **188, not 128**.
- **Dead air is measured from the waveform.** Apple's word timings are contiguous — on 88 s of
  narration every "gap" was exactly 0.06 or 0.12 s, the analyzer's quantisation. The same audio
  has 4 real silences totalling 0.90 s.
- **Two ASR engines vote per word.** Every adjudicated error on real speech sat where whisper-turbo
  and parakeet disagreed; where they agreed, both were right. The merge requires equality after
  joining sub-word tokens — substring matching made *"did"* agree with *"didn't"*, the exact
  meaning-inverting error the mechanism exists to catch.
- **Unimplementable transforms refuse.** A colour transform needing LUTs the compositor cannot bind
  raises a named error rather than rendering wrong colour.
- **The brief can be contradicted.** A one-line brief is unfalsifiable, which is exactly why
  nothing catches its misreading — a serious video cut funny produces a *self-consistent wrong
  answer*, and every downstream check validates against the misreading. Give the brief a register
  and stakes and "made a serious video funny" becomes an assertion violation with a timecode.
  A brief that compiles to nothing warns that it cannot catch a misreading.

## Requirements

- macOS 26 or later, Apple silicon
- Xcode 26 toolchain (Swift 6.3)
- `brew install opencolorio` (BSD-3-Clause)
- Anything linking MLX must be built with `xcodebuild` — SwiftPM cannot compile MLX's Metal shaders

## Licensing

The app links **no ffmpeg** — decode and encode are AVFoundation; ffmpeg is used only by
[`bench/`](bench/). OpenColorIO (BSD-3-Clause) is the single third-party dylib. Full component
table in [`docs/PLAN.md`](docs/PLAN.md).

## Documentation

- [`docs/PLAN.md`](docs/PLAN.md) — the plan, every measurement, and the milestone gates
- [`bench/`](bench/) — benchmark scripts and raw results, reproducible on any Apple silicon Mac
