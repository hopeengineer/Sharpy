# Sharpy — Final Plan

**Status:** decided. Every throughput claim in this document was measured on the target
machine (Mac mini M4, 16 GB, macOS 26.6.2) on 2026-09-03. Scripts and raw results are in
[`bench/`](../bench/). Anything not measured is marked *unmeasured*.

**What Sharpy is:** a standalone, agent-first, professional-grade non-linear video editor
for macOS. The agent operates it; the human sets intent once and assists only when asked;
the long-run target is no human at all beyond recording. Quality bar: DaVinci Resolve /
Premiere Pro output, not their manual toolset.

---

## 1. Decisions, and the measurement that locked each

| Decision | Locked by |
|---|---|
| **WhisperKit + Parakeet produce the transcript; their agreement is the per-word confidence. Apple `SpeechAnalyzer` is live preview only.** | On the real narration (§2.7) Apple had 18 disagreement sites and ≈9 adjudicated errors including one that inverts meaning. **This decision was violated in code for a while** — the vote ran WhisperKit + Apple, because parakeet had only been measured through Python MLX and `mlx-swift-lm` ships no ASR at all, so the decided design was unreachable through the pinned runtime. At "agent didn't make it worse" Parakeet is right and **WhisperKit and Apple are both wrong the same way**, so the old pair *agreed* and stamped the inversion high-confidence. Repaired with Parakeet TDT v3 (FluidAudio, CoreML): the site is now disputed at 0.55, under the 0.7 floor. See `bench/results/parakeet_second_engine.txt`. |
| **whisper-large-v3-turbo is the verbatim engine.** | The only model that kept all 12 spoken fillers on clean speech; ≈3 adjudicated errors on real speech. Disfluency editing needs verbatim. |
| **Parakeet is the second engine, never the only one — and it runs through CoreML, not MLX.** | Best clean WER (0.57 % via MLX) and the only engine that got the meaning-critical "didn't" right on real speech, but ≈5 other errors and sub-word tokens that must be merged into words. Re-measured through FluidAudio's CoreML build: **0.76 % WER, 12/12 fillers, 171× realtime, 0.14 GB peak.** 0.19 points worse than MLX and better on everything else — MLX's 5.5 GB is what forced "ingest, never resident"; 0.14 GB removes that constraint entirely. int8 is the highest precision shipped, so no accuracy is left unclaimed. |
| **Gemma 4 E2B-4bit is the ingest perception model; Qwen3-VL-2B-4bit is the cheap resident model behind a JSON-repair layer.** | On the user's real reel (§2.7), one frame per call: Gemma 4 E2B — 22/22 person and face, 21/22 hands, 87/90 text lines, **2.3 s per frame, 4.2 GB peak**. Qwen3-VL-4B matched it on text (90/90) at 5.0 s per frame. Qwen3-VL-2B was right on every frame it answered but returned malformed JSON on 5 of 22 — a format-discipline fault, not a perception one, so it stays resident (2.7 GB single-frame) only with repair-and-retry. Gemma 4 E4B: 90/90 text but 5.8 GB and 4.2 s per frame; it also failed an 8-image call outright. **No model invented an on-screen text line.** Gemma-3n-E2B hit **10 GB** — excluded. SmolVLM2: ~1 090 tokens/frame, 7.9 GB — excluded. Gemma 4 E2B additionally takes native audio + video. |
| **A VLM *can* stay resident during playback on this machine.** | 2B peak 3.2 GB + four concurrent 4K ProRes decodes 2.3 GB + compositor < 0.6 GB ≈ 6 GB. Earlier "evict during playback" rule is downgraded to a policy for the 4B model and large frame caches. |
| **Apple Vision is the subject/text/pose tracker.** | 1080p: face 206 fps, face + OCR 82 fps, + body pose 80 fps, ≤ 80 MB. On-device, Neural Engine, zero model files. |
| ~~**sherpa-onnx (pyannote-seg-3.0 + eres2net) is diarization.**~~ **RETIRED — see §2.2.** | The 2-of-2 result was 200 s of `say` output, not a measurement. On six real 4-person meetings the same configuration reports 64–180 speakers (DER 68.25 %). SpeakerKit replaces it on 22.7 h of annotated audio: 3.67 % DER on VoxConverse, 7.66 % on AMI, at 20–30× the speed. |
| **TransNetV2 on MPS is shot detection; PySceneDetect is the cheap pre-pass.** | TransNetV2 235 fps at 1080p (594 MB). PySceneDetect 636 fps 1080p / 159 fps 4K. OmniShotCut (2026) reports all three classic methods at F1 0.75–0.82 — good enough for a shot inventory, not for cut-frame precision, which comes from the decision record anyway. |
| **ffmpeg's `signalstats` / `ebur128` / `cropdetect` are the signal-QC tier.** | ebur128 over 203 s of audio in 0.08 s; signalstats 206 fps 1080p / 53 fps 4K; cropdetect 183 fps 4K. This is QCTools' engine, LGPL, already on the machine. |
| **The compositor is a single-pass Metal kernel, not Core Image.** | Core Image collapsed to 14.7 fps (naive) and 8.9 fps (pipelined) at four 4K layers regardless of pixel format. A compute kernel sampling the decoder's textures zero-copy did **135 fps at four 4K H.264 layers, 89 fps ProRes, and 88 / 58 fps at six** — linear in layers, decode-bound, ≤ 1 GB RSS. Decoders alone: 324 fps aggregate H.264, 342 ProRes via ffmpeg. |
| **Swift + Metal + AVFoundation, single process, engine headless — the model runtime included.** | Every Apple-native piece above compiled first try on Swift 6.3.1 and runs at the numbers shown. The model path was then measured, not assumed: through `mlx-swift-lm` (pinned to main @ 2026-09-01 — the `3.31.4` tag cannot load Gemma 4's shared-KV layers and degenerates on Qwen3-VL) the same 22 labelled frames score identically to Python — Gemma 4 E2B 22/22 person & face, 85/90 text, 2.4 s per frame, 4.05 GB; Qwen3-VL-2B 17/22 valid JSON (the same five malformed answers), 70/70 text, 2.8 s, 2.64 GB. One process; no Python sidecar. Anything linking MLX must be built with `xcodebuild` (SwiftPM cannot compile MLX's Metal shaders). |

---

## 2. Measured baseline

### 2.1 Speech → text (203 s, two TTS voices, 12 fillers, ref 528 words)

| model | wall | ×RT | peak mem | WER | fillers kept | word timing |
|---|---|---|---|---|---|---|
| Apple SpeechAnalyzer (macOS 26) | 2.2 s | **94** | **20 MB** RSS | 5.30 % | 8 / 12 | per word |
| whisper-large-v3-turbo (mlx) | 40.4 s | 5.0 | 2.16 GB | 1.52 % | **12 / 12** | per word |
| distil-whisper-large-v3 (mlx) | 15.5 s | 13.1 | 3.13 GB | 2.84 % | 9 / 12 | per word |
| parakeet-tdt-0.6b-v3 (mlx) | 6.3 s | 32.1 | 5.53 GB | **0.57 %** | 10 / 12 | sub-word |

*Caveat: clean synthetic speech. Real-room WER will be higher for all four; the ranking is what transfers.*

### 2.2 Diarization, shots, subject tracking

| task | tool | throughput | peak mem | result |
|---|---|---|---|---|
| diarization | ~~sherpa-onnx pyannote-3.0 + eres2net~~ RETIRED | 13.8× RT | 458 MB | 2 / 2 on synthetic audio; 64–180 speakers for 4 people on real meetings |
| diarization | **SpeakerKit (pyannote via CoreML)** | **377–472× RT** | ≤ 0.5 GB | **3.67 % DER VoxConverse (20.3 h), 7.66 % AMI** |
| shot boundaries | TransNetV2 (MPS) | 235 fps @1080p | 594 MB | — |
| shot boundaries | PySceneDetect Content/Adaptive | 636 fps @1080p, 159 fps @4K | ≤ 451 MB | — |
| shot boundaries | ffmpeg `select=gt(scene,…)` | 756 fps @1080p | 145 MB | — |
| face | Apple Vision | 206 fps @1080p, 135 fps @4K | 50–92 MB | *no faces in test media* |
| face + OCR | Apple Vision | 82 fps @1080p, 36 fps @4K | ≤ 107 MB | OCR exercised (25 / 324 regions) |
| face + OCR + pose | Apple Vision | 80 fps @1080p | 80 MB | — |

### 2.3 Decode / encode (VideoToolbox via ffmpeg 8.0.1; 30 s 4K@30, noisy)

| path | fps | peak RSS |
|---|---|---|
| 4K H.264 HW decode | 87.5 (ffmpeg readback path; AVAssetReader → Metal did 286–301) | 380 MB |
| 4K HEVC HW decode | 115.5 | 570 MB |
| 4K ProRes 422 HQ HW decode | 157.6 | 770 MB |
| **4 × 4K H.264 concurrent** | **324 aggregate** | 1.36 GB |
| **4 × 4K ProRes concurrent** | **342 aggregate** | 2.35 GB |
| 4K → H.264 HW encode 40 Mb/s | 59.3 | 678 MB |
| 4K → HEVC HW encode 30 Mb/s | 57.7 | 677 MB |
| 4K → ProRes 422 HQ HW encode | 177.2 | 833 MB |
| 1080p → H.264 HW encode | 219 | 220 MB |

### 2.4 Compositor (Swift: HW decode → Core Image on Metal → 4K BGRA texture)

Each cell is **H.264 / ProRes 422 HQ** fps at 4K output, 900 frames per run.

| layers | Core Image, naive (BGRA, sync per frame) | Core Image, pipelined (NV12, 3-deep ring, 3 GPU frames in flight) | **Metal compute kernel, NV12 zero-copy** | Metal kernel, BGRA |
|---|---|---|---|---|
| 1 | 301 / 93.5 | 387 / 75 | **413 / 301** | 282 / 303 |
| 2 | 98 / 91.5 | 123 / 12.9 | **262 / 178** | 173 / 176 |
| 4 | 14.7 / 28.6 | **8.9 / 3.4** | **135 / 89** | 87 / 88 |
| 6 | — | 3.7 / 1.0 | **88 / 58** | 57 / 57 |

Two findings. **Core Image is the wrong compositor**: it materialises full-resolution
intermediates per layer and collapses super-linearly no matter how decode is pipelined or
which pixel format it is fed. **A single-pass Metal compute kernel** — decoder output wrapped
as textures through `CVMetalTextureCache`, every layer sampled in one dispatch, YCbCr→RGB in
the shader — scales linearly with layers and is decode-bound: four 4K layers at 135 fps is
540 decoded frames per second, above ffmpeg's readback-limited 324. NV12 beats BGRA for
H.264 because it is the decoder's native output; for ProRes (natively 4:2:2) both paths
convert and tie. Process RSS stayed under 1 GB with six 4K ProRes streams.

### 2.5 Vision-language (mlx-vlm, 1024 px frames, 120-token answer; tokens per frame: Qwen ≈ 585, Gemma 4 ≈ 270, SmolVLM2 ≈ 1 090)

| model | model mem | 1 frame | 4 frames | 8 frames | peak (8 f) | prefill | gen |
|---|---|---|---|---|---|---|---|
| **Qwen3-VL-2B-4bit** | 1.78 GB | 2.4 s | 6.8 s | 12.8 s | **3.22 GB** | ~440 tok/s | 59–85 tok/s |
| Qwen3-VL-4B-4bit | 3.10 GB | 5.4 s | 11.9 s | 21.6 s | 4.58 GB | ~250 tok/s | 31–38 tok/s |
| **Gemma 4 E2B-4bit** (audio + video native) | 3.55 GB | 5.6 s | 6.4 s | **7.9 s** | 6.41 GB | 126→409 tok/s | 46–49 tok/s |
| Gemma 4 E4B-4bit | 5.15 GB | 6.8 s | 9.9 s | 9.2 s ✗ | 7.83 GB | 145→271 tok/s | 27 tok/s |
| gemma-3n-E2B-4bit | 4.46 GB | 5.7 s | 6.7 s | 9.1 s | **9.97 GB** | ~300 tok/s | 53 tok/s |
| SmolVLM2-2.2B | 4.49 GB | 186 s (cold) | 17.2 s | 41.4 s | 7.94 GB | ~230 tok/s | 12–21 tok/s |

Every model correctly described the test pattern and reported "no person visible" — except
Gemma 4 E4B at 8 frames (✗), which answered as if no images were attached.

**Derived indexing cost (Qwen 2B):** ≈ 1.6 s per 1024 px frame amortised. One frame per 5 s
of footage → **~19 min per hour of footage**; one per shot on talking-head material is less.
The Qwen 4B is ~32 min/hour. **Gemma 4 E2B is ≈ 1.0 s per frame → ~12 min per hour**, at
6.4 GB peak — the ingest-time choice when the machine is otherwise idle, and the only one of
these that also hears the audio. Dropping to 512 px cuts tokens ~4× (*unmeasured
extrapolation*).
Content-addressed embedding caching (literature: up to 24.7× on repeated video analysis)
is mandatory because the agent revisits the same footage every turn.

### 2.6 Memory budget on 16 GB (measured peaks, summed by phase)

| phase | resident | total |
|---|---|---|
| **ingest** (sequential, worst step) | Qwen3-VL-2B 3.2 GB — or Gemma 4 E2B 6.4 GB if chosen for the pass — *or* TransNetV2 0.6 GB *or* diarization 0.46 GB, + Apple ASR/Vision ≤ 0.1 GB | **≤ 3.3 GB** (6.5 GB with Gemma 4) |
| **edit / playback** | 4 × 4K ProRes decode 2.35 GB + compositor 0.56 GB + Qwen3-VL-2B 3.2 GB resident | **≈ 6.1 GB** |
| **render** | 4K ProRes encode 0.83 GB + decode 2.35 GB + signalstats 0.46 GB | **≈ 3.7 GB** |

Ten gigabytes of headroom for the OS, the frame cache and the UI. The machine is not the
constraint people assume; *serialization and model choice* are.

### 2.7 Quality on real footage — the user's own reel, 22 frames + 88 s of speech

Speed is not accuracy. Test set: `~/Desktop/reel-12-NOSFX.mp4` (the Cowork edit of
2026-09-03, 1080×1920, 88 s): a talking head intercut with motion-graphic cards — exactly the
content type Sharpy is for. Ground truth for 22 frames (one every 4 s) was written by viewing
each frame: person present, face count, hands, layout (talking head / card / split), and every
readable line of on-screen text. Frames are not committed; the labels are in `bench/real/`.

**Apple Vision — face + hand pose + accurate OCR, 0.63 s per frame**

| check | result |
|---|---|
| face count exact | **22 / 22** |
| hands present / absent | **21 / 21** (one motion-blurred frame excluded) |
| on-screen text recall | **89 / 90** lines |
| extra lines reported | 11 / 115 — all tiny axis labels I had not labelled, none invented |

Vision is the subject / OCR tracker. L2 face, hand and on-screen-text facts come from it,
not from a VLM.

**ASR on the real narration** (phone mic, room; wall: Apple 1.4 s · parakeet 3.1 s ·
whisper-turbo 10.2 s · distil 11.7 s). There is no reference transcript and I cannot listen,
so every disagreement site was adjudicated against the on-screen cards — which restate the
narration — and sentence context (`bench/results/asr_real_adjudicated.txt`):

| engine | disagreement sites vs parakeet | adjudicated errors | meaning-inverting |
|---|---|---|---|
| parakeet-tdt-0.6b-v3 | — | ≈5 ("tale" for *tail*, "your" for *you're*, "fixation smart model") | 0 |
| whisper-large-v3-turbo | 9 | ≈3 | **1** — "did make it worse" for *didn't* |
| distil-whisper-large-v3 | 8 | ≈4 | 1 — "will make it worse" |
| Apple SpeechAnalyzer | 18 | ≈9 ("pick" for *fix*, "they" for *it*, "cause" for *costs*) | **1** |

No engine is clean on real speech. **Every adjudicated error lies in a word where
whisper-turbo and parakeet disagree with each other; in every site where they agree, both were
right.** So the transcript is produced by both — 13 s per 88 s together — and their
per-word agreement is the confidence signal that feeds the L2 floor; on-screen text
adjudicates where it restates the line. Apple's ASR is demoted to live preview. (`reel-12-CUT`
and `-NOSFX` carry byte-identical audio; "NOSFX" refers to the graphics layer.)

**VLM structured perception** — one JSON answer per frame (person, face count, hands,
layout, every readable text line, setting), scored against the same labels:

| model | valid JSON | person & face count | hands | layout | text recall | invented text | s / frame | peak |
|---|---|---|---|---|---|---|---|---|
| **Gemma 4 E2B-4bit** | 22 / 22 | **22 / 22** | **21 / 22** | 19 / 22 | 87 / 90 | **0** | **2.3** | 4.17 GB |
| Qwen3-VL-4B-4bit | 22 / 22 | **22 / 22** | 20 / 22 | 20 / 22 | **90 / 90** | **0** | 5.0 | 4.01 GB |
| Gemma 4 E4B-4bit | 22 / 22 | **22 / 22** | 19 / 22 | **21 / 22** | **90 / 90** | **0** | 4.2 | 5.76 GB |
| Qwen3-VL-2B-4bit | **17 / 22** | 17 / 22 — every parsed frame right | 15 / 22 | 15 / 22 | 67 / 70 | **0** | 2.8 | 2.69 GB |

How to read it. *Invented text* is the failure the spec forbids; every "extra" line any model
reported was checked against the frame and was real — slider values, axis ticks, terminal
line numbers, and an "AGENT · RESULT" badge label that two models read and Apple Vision's OCR
missed. Qwen 2B's five failures were malformed JSON (a missing bracket), not wrong answers;
on the 17 frames it answered it was right about every person and face. The layout misses
cluster on the two "card above, small person inset" frames, which three of four models called
`talking_head` — a definition edge, not a perception miss. **No model ever reported a person
on a card frame or missed one on a talking-head frame.**

**Swift path (mlx-swift-lm, `sharpy-probe`):** Gemma 4 E2B 22/22 · 22/22 · hands 20/21 ·
layout 19/22 · text 85/90 · 2.4 s/frame · 4.05 GB; Qwen3-VL-2B 17/22 valid JSON · 70/70 text ·
2.8 s · 2.64 GB — parity with the Python rows above on every axis (`bench/results/swift_probe.txt`).

The ranking on this footage is Gemma 4 E2B ≈ Qwen 4B ≈ Gemma E4B > Qwen 2B on accuracy, and
E2B (2.3 s) < Qwen 2B (2.8) < E4B (4.2) < Qwen 4B (5.0) on cost. **Gemma 4 E2B is the ingest
model on both axes.** Its 6.4 GB peak was an 8-images-per-call artefact; ingest is one frame
per call, where it peaks at 4.2 GB. Gemma 4 E2B additionally accepts audio and video natively
(*unmeasured here*).

---

## 3. Architecture

```
┌──────────────────────────────── Sharpy.app (single process, Swift) ────────────────────────────────┐
│                                                                                                     │
│  ENGINE (headless, no UI dependency)                                                                │
│  ├─ Media: AVFoundation + VideoToolbox decode/encode · BRAW SDK · ffmpeg (LGPL build) for the tail  │
│  ├─ Time: rational (CMTime), drop-frame exact, source + record timecode                             │
│  ├─ Document: immutable content-addressed edit graph · every state has an id · branches are free   │
│  ├─ Render: Metal compositor · OpenColorIO (ACES) · emits ID + coverage pass per frame (§6)         │
│  ├─ Audio: graph with buses · EBU R128 metering · sub-frame edits                                   │
│  └─ Verify: assertions (block / warn / hold) run on the RENDER, not the plan                        │
│                                                                                                     │
│  PERCEPTION (local, phase-scheduled)                                                                │
│  ├─ L0 container facts · L1 signal facts (ffmpeg filters, DSP)                                      │
│  ├─ L2 semantic: Apple ASR → whisper-turbo (verbatim) · sherpa diarization · Vision face/OCR/pose   │
│  │           · TransNetV2 shots · Qwen3-VL-2B scene semantics · prosody (arousal) · valence (text)  │
│  ├─ L3 structure: beats / argument graph / loops / tone — inferred WITH basis + confidence          │
│  └─ Index: multi-resolution, content-addressed, runs over renders as well as sources                │
│                                                                                                     │
│  AGENT SURFACE                                                                                      │
│  ├─ MCP server: tools return decision records · Tasks for every long op · elicitation for help     │
│  ├─ MCP Apps: take-picker, cut-diff, "which face", note surface — rendered in the agent host        │
│  └─ CLI: same commands, for humans and CI                                                           │
│                                                                                                     │
│  HUMAN SURFACE (thin, attachable, optional)                                                         │
│  ├─ Feed (what the agent did, with basis) · Assist queue · Cut diff · Override timeline             │
│  └─ All four read the same document the agent writes; none is required for an edit to complete     │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

**One rule above all others:** every edit decision carries a `basis`; a decision with no
basis does not render. Everything else in this plan exists to make that rule enforceable.

---

## 4. The specification, amended

The user-authored *Context-Aware Video Editing — Tool Specification* is the base. It is
adopted whole. The amendments below are the only changes, each with its reason.

### 4.1 Basis table (§0) — two additions, one re-ordering

| basis | authority | note |
|---|---|---|
| **`safety_constraint`** *(new, top)* | non-overridable, block-only | WCAG 2.3.1 three-flashes (Level A) with the stricter saturated-red test; loudness ceilings; anything a client may not override. §3.3 "perceptual constraints" had no basis type at all — this is it. |
| `client_rule` | overridable only by safety | unchanged, but no longer top |
| `platform_req` | | unchanged |
| `measured_material` | | unchanged |
| `measured_norm` | now carries `evidence_class` (§4.4) | |
| **`learned_preference`** *(new)* | below `measured_norm`; requires `n` and confidence | where the style profile writes; §6 promotion covers *stated* preferences, this covers *inferred* ones |
| `craft_rule` | | unchanged |
| **`structural_inference`** *(new)* | for L3 only; requires cited L2 evidence + confidence | see §4.2 |

### 4.2 L3 gets basis discipline

Beat boundaries and purposes are the most consequential judgement in the system and were the
only layer allowed to guess. Every L3 entry now carries `basis: structural_inference` with
the L2 evidence that produced it (topic shift, prosodic reset, speaker turn, discourse marker)
and a confidence. **L3 confidence is subject to the same floor as L2**, and a low-confidence
beat boundary is the *correct* thing to escalate — it has the largest blast radius.

### 4.3 The brief becomes falsifiable

§L4's one-sentence brief cannot be checked, which is why "misread the intent" was uncatchable.
The brief gains fields that compile to assertions exactly as house rules already do:

```
brief.register            grave | earnest | neutral | playful | irreverent
brief.stakes              routine | elevated | high | irreversible
brief.prohibited_devices  [whip, sound_on_cut, comedic_timing, meme_caption, …]
brief.required_devices    [...]
```

A brief that cannot compile is stored as a warning meaning *"I cannot check that I
understood you."* Confidence floors scale with `stakes`: routine 0.70 · elevated 0.85 ·
high 0.95 · irreversible → `hold`.

### 4.4 Norms carry an evidence class

`measured_norm` gains `evidence_class: correlational | outcome_linked` and a confidence
interval, not just `n`. Corpus norms (§3.1) are correlational and survivorship-biased;
retention-joined norms (§3.2) are outcome-linked. Prefer outcome-linked when both exist;
disclose when acting on correlational. Minimum `n` per norm is enforced.

### 4.5 Tone is measured bottom-up, never from faces

Barrett et al. 2019 (*Psychological Science in the Public Interest*): emotion is not reliably
inferable from facial movements. A facial-affect reading is therefore **not a
`measured_material` fact** and is prohibited as a basis.

| quantity | source | status |
|---|---|---|
| arousal / energy | acoustics: rate, pause structure, pitch variance, loudness dynamics | deterministic L1 |
| valence | language (transcript) | model; SOTA CCC ≈ 0.63 → flag, never fact |
| affect from face | — | **prohibited** |

§L3's tone map is inverted: derive tone from the material independently of the brief, then
assert agreement. Mismatch is the misread-intent alarm.

### 4.6 Decisions claim resources

A decision declares what it occupies — screen region × time, audio bus × time, subject box ×
time. The tool refuses a decision that double-claims. Two individually valid decisions can be
jointly illegal; this catches it at decision time rather than at render. No prior art in
editing; closest analogue is register allocation.

### 4.7 Verification gains `hold`; notes gain a source

§5 modes become `block | warn | hold` — `hold` is "every assertion passed but confidence is
low; do not ship." §6 notes become `{at, text, source: human | critic | retention |
assertion}` so the identical loop serves a person, the agent's own review, and audience data.

### 4.8 VFR policy

L0 detects VFR; nothing said what happens next. Policy: normalise to CFR on ingest with a
recorded time map, so every §2 anchor resolves through one clock.

### 4.9 Assertions run on the render

§5 as written evaluates the decision record. Under autonomy nobody watches the pixels, so
ingest is media-agnostic and a render is just another asset: it goes back through L0→L2 and
assertions compare *achieved* against *intended*. See §6.

---

## 5. Perception stack, chosen per measurement

| layer | component | measured | licence | RAM |
|---|---|---|---|---|
| L1 audio | ffmpeg `ebur128`, `astats`, `silencedetect` | 203 s in 0.08–0.09 s | LGPL | ~20 MB |
| L1 video | ffmpeg `signalstats`, `cropdetect`; PySceneDetect pre-pass | 53–206 fps | LGPL / BSD | ≤ 0.45 GB |
| L2 transcript | whisper-turbo + parakeet, per-word agreement = confidence; Apple SpeechAnalyzer for live preview only | 8.6× + 28× RT on real speech (13 s per 88 s together); Apple 94× | MIT / NVIDIA model licence / OS | 2.2 + 5.5 GB (sequential) / 0.02 GB |
| L2 speakers | sherpa-onnx pyannote-3.0 + eres2net | 13.8× RT | Apache-2.0 / model licences | 0.46 GB |
| L2 shots | TransNetV2 (MPS) | 235 fps | MIT | 0.6 GB |
| L2 subject / OCR / pose | Apple Vision | 82 fps @1080p | OS | ≤ 0.1 GB |
| L2 active speaker | LR-ASD (0.84 M params, 0.51 GFLOPs) | *unmeasured* | see repo | small |
| L2 scene semantics | Qwen3-VL-2B-4bit resident; **Gemma 4 E2B-4bit for the ingest pass** (native audio + video) | 1.6 / 1.0 s per frame | Apache-2.0 / Gemma terms (*unverified this session*) | 3.2 / 6.4 GB |
| L2 prosody | DSP over the transcript's word spans | trivial | — | — |
| L3 structure | Qwen3-VL / text LLM over L2, with `structural_inference` basis | *unmeasured* | Apache-2.0 | shared |

Phase scheduling: ingest runs the heavy models sequentially (≤ 3.3 GB at any moment);
playback keeps the 2B resident (6.1 GB total); render evicts models (3.7 GB).

---

## 6. Render verification — four tiers, model last

1. **The renderer instruments itself.** The Metal compositor emits a Cryptomatte-style
   ID + coverage pass per frame. Spatial assertions (edge vs. subject box, safe area,
   text collision, subject-in-frame during a move) become exact intersection tests at every
   frame, not 6–8 fps samples. Cryptomatte is an open standard implemented by every major
   renderer and read by Nuke, Fusion and After Effects; no NLE emits it.
2. **Signal QC on the output.** `signalstats` (temporal outliers, broadcast range, repeats),
   `cropdetect`, `ebur128` — measured at 53 fps for 4K, so a full QC pass on a 10-minute
   4K master costs ~6 minutes of background time; on the 1080p proxy, ~90 s.
3. **Differential: predicted vs. achieved.** The plan predicts loudness, contrast at text
   regions, luma; the render is measured; deltas are asserted. Catches wrong colour
   transforms, dropped frames, encoder-introduced desync.
4. **The VLM, as proposer only.** It emits candidate observations; each compiles into a
   deterministic assertion or is discarded. It never holds the judge's seat — the spec's own
   rule ("the agent should never be the source of a claim") forbids it, and it sidesteps the
   documented VLM-judge failures (human disagreement, position bias, instability, hallucination).

The honest limit: the intersection test is exact on the renderer's side and probabilistic on
the subject-track side. The failure mode moves from "we never looked" to "the subject track
was wrong" — attributable, measurable, and already gated by the L2 confidence floor.

---

## 7. The path to no human

| mechanism | what it replaces | measured / verified |
|---|---|---|
| **Elicitation logging** — every question logged with category and resolution from v1 | nothing; it is the burn-down instrument | — |
| **Authored-once artifacts** — brief, policy, enrollment registry, style profile as versioned engine documents | four of five question categories (taste, intent, ground truth, permission) | — |
| **Regression gate** — finished edit measured against the creator's own catalogue band; outside → `hold` | most of what "the edit is shit" means, pre-publish, no human | — |
| **Selective review** — agent requests a look only where expected information gain is highest; **the request rate is the autonomy metric** | blanket human review | — |
| **Compile-rate residue** — per note, did it become a rule? The set that never compiles *is* what still needs a human | declaring autonomy | — |
| **Retention as ground truth** | taste labelling | YouTube Analytics API: `elapsedVideoTimeRatio` × `audienceWatchRatio`, 100 points/video, filter `audienceType==ORGANIC`. Instagram: aggregate completion only. **TikTok: not available** to commercial API access. The fully autonomous loop closes on YouTube first. |
| **A/B by retention** | human taste judgement | works where a curve exists (YouTube) |

What does not go to zero: rights and legal; factual integrity when a speaker misspoke;
relationship context that isn't in the footage; frontier taste. These reduce to policy
authored once, or to a person. The product claim is *"zero questions on a routine video,
escalate on the exceptional"* — achievable and honest.

---

## 8. Components and licences (verified)

| component | licence | role |
|---|---|---|
| FFmpeg, **LGPL build only** — `--enable-gpl` flips the whole build to GPL v2+; pin configure flags in CI and assert | LGPL 2.1+ | long-tail decode, analysis filters |
| OpenColorIO | BSD-3-Clause | colour management, ACES 2.0 configs |
| OpenImageIO | Apache-2.0 (small pre-2023 BSD-3) | image I/O |
| OpenTimelineIO | Apache-2.0 | interchange in/out; **not** the internal model |
| Blackmagic RAW SDK | free, no fees, GPU decode | BRAW day one |
| MLX, mlx-vlm, mlx-whisper, parakeet-mlx | MIT / Apache-2.0 | local models |
| sherpa-onnx | Apache-2.0 | diarization |
| TransNetV2 | MIT | shots |
| Gemma 4 E2B (mlx-community 4-bit) | Gemma Terms of Use — **not verified this session**; check redistribution terms before bundling | ingest-time perception, audio + video |
| Apple Speech / Vision / VideoToolbox / Metal | OS frameworks | ASR, subject tracking, decode, render |
| **Olive** | GPLv3 | **excluded** — cannot be embedded closed-source |
| MLT | LGPL 2.1 / GPL | not used; model isn't agent-shaped |
| Remotion | source-available, per-company commercial licence | not used; Revideo (MIT) if motion-graphics-as-code is ever needed |

---

## 9. Build order with exit criteria

Each milestone has a gate written against a number in §2. A milestone is not done until its
gate is measured on the target machine.

### M0 — headless engine *(everything inherits from this)*
- Rational time; immutable content-addressed document; branch = pointer; command log replay.
- Pipelined decode (per-source thread, bounded ring) → Metal compositor → OCIO-managed frame.
- **Gate:** four 4K ProRes layers composited to a 4K texture at **≥ 30 fps sustained with
  OCIO applied**. The bare kernel already measures 89 fps (H.264: 135); the gate exists to
  prove the margin survives colour management and the effect stack.
- **Gate:** a complete edit — ingest, cut, place a graphic, render — driven by a script with
  **no UI process in existence**.
- **Gate:** ffmpeg build flags asserted LGPL in CI.

**Status 2026-09-03 (late evening) — M0 roughly two-thirds done. 33 tests green.**

Built and verified: exact rational time and SMPTE drop-frame timecode (round-tripped over every
frame of an hour); the content-addressed document with the basis rule enforced at the type level
and the confidence floor enforced in `apply`; the replayable command log; frame-accurate decode
(`AVSampleCursor`-positioned seeks, explicit BT.709 tags, per-layer YCbCr matrix in the kernel);
the single-pass Metal compositor; **sample-accurate audio** — read, sum across tracks, and write.

*Picture gate, on the user's reel:* `--cut 300-420` produced 2 529 frames, exactly 4.0 s shorter,
output frame 300 = source frame 420 (41.5 dB PSNR; the mismatched-frame control reads 23 dB).

*Audio gate, same render:* 4 046 400 samples = 84.3 s at 48 kHz alongside the picture. Output
audio after the cut differs from source-plus-4 s by −35 to −39 dB (AAC re-encode residue) and
from the wrong offset by −19 to −21 dB — louder than the signal itself, as uncorrelated audio
must be. 974 fps at 1080×1920 ProRes.

Two defects the tests caught, both fixed at the cause:
- **Edit-point alignment was global.** `requireFrameAligned` was applied to every track, which
  quantised audio cuts to 1/30 s. Alignment is now per track kind: video on the frame grid, audio
  on the sample grid. At 29.97 fps one frame is 48000 × 1001/30000 = **1601.6 samples**, so a
  frame boundary is not a sample boundary — audio takes the nearest sample (≤ 10.4 µs away).
- **The writer deadlocked.** Writing all video then all audio hung indefinitely:
  `AVAssetWriter` stalls an input that races ahead of its sibling, and polling
  `isReadyForMoreMediaData` from the calling thread never clears. Both inputs are now driven by
  `requestMediaDataWhenReady` on their own queues — the documented pattern.

**Colour management gate — MET.** OpenColorIO 2.5.2 (BSD-3-Clause, Homebrew) is linked through a
C++ bridge (`Sources/COCIO`) that emits Metal Shading Language and splices it into the compositor
kernel. OCIO 2.5 ships the ACES configs built in (`ocio://default`), so nothing external is
located or version-matched at runtime, and every ACES path in that config is analytic — zero LUT
textures. A transform that *did* need LUTs is refused with a named error rather than rendering
wrong colour.

Measured on 4K ProRes, 600 frames per point:

| layers | no colour management | ACEScg → linear → sRGB Display |
|---|---|---|
| 1 | 308.2 fps | 218.4 fps |
| 2 | 177.7 fps | 162.0 fps |
| **4** | **86.2 fps** | **83.4 fps ✓ gate (≥ 30)** |
| 6 | 55.2 fps | 55.5 fps |

**Colour costs ~3 % at four layers** — the margin survives easily, because the pipeline is
decode-bound, not shader-bound. Reproduce with `sharpy bench --asset <4k> --color ACEScg`.

Correctness is asserted against the published transfer functions, not self-consistency: linear
→ sRGB matches IEC 61966-2-1 within 2 code values at three points; sRGB → ACEScg → sRGB round
trips within 2; and a 50 % black/white mix renders as **188, not 128**, proving the blend happens
in linear light rather than in display code values.

**Loudness gate — MET.** EBU R128 / ITU-R BS.1770-4 is implemented in Swift: K-weighting
derived from the analog prototype for whatever sample rate the audio actually is (hardcoding the
48 kHz coefficients and feeding them 44.1 kHz gives a quietly wrong reading), both gates,
loudness range, and true peak with 4× oversampling.

Cross-checked against ffmpeg's `ebur128`, an independent implementation, on the user's reel:

| | Sharpy | ffmpeg |
|---|---|---|
| integrated | −20.84 LUFS | −20.9 LUFS |
| loudness range | 5.36 LU | 5.4 LU |
| true peak | −1.50 dBTP | −1.5 dBFS |

and on amplitude-0.2 tones at 60 / 1000 / 6000 Hz: −17.57 / −13.97 / −10.64 against ffmpeg's
−17.6 / −14.0 / −10.6 — **agreement within 0.06 LU everywhere**, which validates the filter, the
gating and the peak detector together.

Normalisation is wired into render: `sharpy render … --loudness broadcast` measures the mix,
applies the gain, and ffmpeg confirms the output at **exactly −23.0 LUFS**. The gain is capped by
the true-peak ceiling and any shortfall is reported rather than papered over with a limiter —
a limiter changes the sound, which is a creative decision, not a delivery step.

**Deferred, with reason:** the playback ring. Render is synchronous per frame and still hits
790–974 fps, so it is not the bottleneck for rendering; the ring only matters for interactive
scrubbing, which needs the UI that arrives in M3. Building it now would be speculative.

The LGPL assertion turned out moot: `otool -L` shows the binary links no ffmpeg at all — decode
and encode are AVFoundation, ffmpeg is used only by `bench/`. The one third-party dylib is
OpenColorIO (BSD-3-Clause).

**M0 is complete. 48 tests green at that point; 65 now.**

### M1 in progress — the perception index

**Transcript and word-addressed editing.** `Transcript` / `Word` live in the engine, and the
addressing rule is the point: *the agent names words, never frames*. `WordEdit` turns word indices
into ranges, absorbing the surrounding pause so survivors do not end up double-spaced, merging
consecutive removals into one cut, and reporting indices that do not exist rather than ignoring
them. It refuses a track where transcript time is not timeline time instead of cutting in the
wrong place. Apple's `SpeechAnalyzer` runs the live pass: 265 words off the user's reel at
**61–79× realtime**.

Two findings that changed the design, both from measurement:

1. **Apple's ASR drops fillers entirely** — `fillers: 0` on a reel that audibly contains them.
   For disfluency editing it is unusable, which is exactly why whisper-turbo is the verbatim
   engine. The live pass and the authoritative pass are genuinely different jobs.
2. **Word gaps are not silence.** Apple returns contiguous word timings: every "gap" on 88 s of
   real narration was exactly 0.06 s or 0.12 s — the analyzer's quantisation — totalling 2.0 s.
   Deriving pauses from them would find 28 imaginary ones. Measured from the waveform instead,
   the same audio has **4 real silences totalling 0.90 s**. Dead air is an L1 signal fact and
   nothing else will do.

**Silence detection** follows the spec's own method: 25 ms frames, keep those above −45 dB, take
the 55th percentile as the speech level, and judge silence *relative to that* rather than against
an absolute dBFS — which is what lets one setting work on a quiet phone recording and a loud
studio one. Runs are padded inward so a cut never clips a breath.

**The two-engine confidence rule is implemented and tested.** `TranscriptMerge.agree` aligns by
time overlap and requires equality after joining sub-word tokens. An early version used substring
matching and the test caught it marking **"did" as agreeing with "didn't"** — precisely the one
meaning-inverting error measured on real speech. It now errs toward *lower* confidence, because a
false disagreement invites a check while a false agreement asserts a correctness nobody
established.

End to end on the user's reel: `sharpy render --tighten-pauses 0.3 --loudness broadcast` measures
the speech level, removes signal-detected dead air, cuts picture and sound on their own grids, and
delivers at **exactly −23.0 LUFS** (confirmed by ffmpeg) at 903 fps.

**Vision indexing** (faces, hands, on-screen text) runs at 0.23 s per sampled frame on the reel,
converting Vision's bottom-left normalised rects once, into top-left pixels, because every
downstream consumer — safe areas, the ID pass, an agent reading a box — thinks that way. On the
reel it reads **93 distinct lines** of on-screen text and tracks the subject across two runs.

**The perception cache** keys every layer by a media fingerprint (size + mtime + first and last
megabyte — hashing a 3 GB master would cost more than transcribing it) *and* an analyser version,
so changing one analyser re-derives its own layer and leaves the others intact. A second report on
the same file drops from 1.25 s to 0.84 s; the point is not those numbers but the VLM pass at
~19 min/hour, which cannot be re-derived per question.

**The M1 gate — the editor's report — is met.** Run on the user's reel it produces, unprompted:

> 1080×1920 at 30, 1:28.30 long · portrait aspect — shot for a vertical feed
> integrated loudness −20.8 LUFS, range 5.4 LU, true peak −1.5 dBTP
> speech sits at −22.8 dBFS over a −47.5 dBFS floor — 25 dB of separation
> 265 words in 1:28.30 — **180 words per minute**
> 30 spoken segments; the piece opens *"This morning, my AI made my audio 3 times better…"*
> a person is on screen in **78 %** of sampled frames; hands in **52 %** — a gesturing delivery
> on-screen text in 82 % of frames, 93 distinct lines; the graphics read *"AGENT · RESULT" / "3x"*
> the subject appears in 2 runs — the piece cuts away to graphics and back
> **worth doing:** one unbroken stretch runs 15 s at 0:25.98 — the likeliest place to lose attention

Nothing there could be said about an arbitrary video: it quotes the actual opening line, reads the
actual graphics, and localises a real editorial weakness. That is the gate.

One logic flaw the gate itself exposed and which is now fixed: the first version reported distance
to *both* −14 LUFS streaming and −23 LUFS broadcast as problems. They are alternatives — no mix can
satisfy both — so stating the distance to each is a fact, and only the true-peak ceiling, which
every platform applies, is a problem.

**Shot detection** landed: a histogram content detector over a decoder-scaled proxy, with the
threshold derived from the material's own score distribution rather than fixed. A locked-off
interview has almost no frame-to-frame change, so a constant threshold finds nothing there and
fires constantly on handheld — the same principle as judging silence against the recording's own
speech level. On the reel: **51 shots, median 1.0 s**, and it localises *"one shot runs 10 s at
0:40.67, 10× the median — the pacing stalls here"*.

### M2 in progress — decisions, assertions, the agent surface

**Assertions gate the render.** Eleven checks across provenance, structure, audio and safety run
before a frame is written; a blocking failure refuses outright. Three outcomes, and the third is
the one most tools omit: `block`, `warn`, and **`hold`** — everything passed and confidence is
still too low to ship unattended. *"No assertion failed"* and *"fit to publish"* are different
claims, and an autonomous system needs the right to abstain.

Two rules enforced there are easy to get backwards: **a check that cannot run fails** (set a
loudness target without measuring the mix and it reports that it could not run, rather than
passing quietly), and **a client rule cannot override a safety constraint** — a standing
instruction may override craft, norms and learned taste, never a flash limit or a true-peak
ceiling.

**The MCP server is the agent surface**: JSON-RPC over stdio, nine tools, built on the rule that
the agent addresses meaning and never frame arithmetic. A test asserts that literally — no tool
schema may expose a property whose name contains "frame" or "timecode". `get_transcript` reads at
sentence granularity by default and word granularity on request; every mutation ends with *"WORD
INDICES HAVE SHIFTED"*; refusals name the way out. Tools live in a library so they are tested
directly rather than by spawning a process, and the executable is transport only.

Driven end to end on the user's reel: open → report → segments → words → cut 0–14
(88.3 s → 82.7 s) → tighten silences → verify, which correctly **blocked** with *"−20.68 LUFS is
+2.32 LU from the −23.0 LUFS target"* → render, which normalised to exactly −23.0 LUFS as
confirmed by ffmpeg → undo.

**M1's perception stack is feature-complete; one layer is measured-and-wanting.** The second ASR engine and diarization both arrived from
one place: `argmaxinc/argmax-oss-swift` (MIT) ships WhisperKit and SpeakerKit as CoreML Swift
packages, so neither needs Python *or* MLX and the whole project still builds under plain
`swift build`. That removed the xcodebuild constraint this milestone was blocked on.

**The two-engine confidence mechanism is real and validated.** WhisperKit supplies the words (it
keeps fillers, which Apple normalises away, and returns a per-word probability Apple does not
expose); Apple votes. The merge had to be rewritten: aligning by *time overlap* is the obvious
approach and fails badly, because the engines place the same words up to a few hundred
milliseconds apart, so each word smears across its neighbours and **197 of 263 came back
"disputed"** — 75 % false disagreement, enough to hold every render.

Aligning by *sequence* — a longest common subsequence over normalised words, windowed by time so
an hour of speech is not a 9 000 × 9 000 table — brings that to **22 of 263**. Those 22 are
precisely the sites found earlier by hand-adjudicating this reel against its on-screen cards:
*"fix"* where Apple heard *"pick"*, *"decibels"* for *"decimals"*, *"checked"* for *"check"*, and
the single meaning inversion. **The mechanism independently reproduces the manual analysis**,
which is the strongest evidence available that it works. 16.3 s for 88 s of audio — 5× realtime,
matching the Python whisper-turbo benchmark exactly.

**ASR was re-measured against the baseline it replaced**, on the same regenerated reference audio
and the same known truth. WhisperKit: **0.76 % WER against MLX whisper-turbo's 1.52 %**, at 10×
realtime versus 5×. Its two "lost" fillers are `uh` transcribed as `ah`, and `ah` is in
`Word.fillerWords`, so `isFiller` detects 12/12 — no functional regression. **The swap is
justified on measurement**, which is how it should have been justified in the first place rather
than on "MIT and builds under `swift build`".

**Diarization is measured on 22.7 hours of real annotated audio**, not on anything generated
here: VoxConverse dev (216 YouTube/broadcast recordings, 20.30 h, 1–20 speakers) and AMI dev
(6 meetings, 2.37 h, 4 speakers, spontaneous and overlapping). Both CC BY 4.0 with reference
RTTMs, scored with `pyannote.metrics` in both conventions.

| | DER (0.25 collar, no overlap) | DER (no collar, +overlap) | count exact | speed |
|---|---|---|---|---|
| **SpeakerKit, default** — VoxConverse | **3.67 %** | **8.98 %** | 127 / 216 | 377× RT |
| **SpeakerKit, default** — AMI | **7.66 %** | **20.17 %** | 4 / 6 | 472× RT |
| sherpa-onnx TitaNet @1.10 — VoxConverse | 12.32 % | 15.67 % | 56 / 216 | 15× RT |
| sherpa-onnx TitaNet @1.10 — AMI | 14.92 % | 24.02 % | 0 / 6 | 19× RT |
| sherpa-onnx eres2net @1.10 — AMI | 13.50 % | 23.13 % | 0 / 6 | 16× RT |
| sherpa-onnx eres2net @0.5 — AMI | 68.25 % | 77.05 % | 0 / 6 | 16× RT |

**The last row retires the baseline in §1.** `@0.5` is the exact configuration recorded above as
"13.8× realtime, found exactly 2 of 2 speakers". On six four-person meetings it reports 64, 86,
104, 116, 159 and 180 speakers. That row was never a measurement of sherpa-onnx; it was a
measurement of 200 seconds of `say` output, and the same fixture is what made SpeakerKit look
broken in the previous revision of this section. The fixture was the fault in both directions:
hard splices of separate takes produce boundary artefacts real conversation does not have.

sherpa was given every advantage — threshold swept 0.5–1.4 across four embedding models
(eres2net, NeMo TitaNet-large, WeSpeaker CAM++, 3D-Speaker CAM++ en) — and its best configuration
still loses by roughly 2× at 20–30× the cost. Its best single-meeting score, 4.98 %, sits on a
spike (1.05 → 8.08 %, 1.10 → 4.98 %, 1.20 → 13.65 %) found by searching one file; across six
meetings it collapses to 14.92 % with the count wrong every time. SpeakerKit's own threshold was
swept on the same material and its default is already on the optimum, which is a plateau — there
is nothing to tune, and an engine whose best setting must be searched for is one whose best
setting will not transfer.

**The weak axis is counting, not timing.** 127 of 216 exact on VoxConverse (58.8 %), skewed to
under-counting (−1 on 35 files, −2 on 13; +1 on 32). DER stays low because the dominant speakers
are right and the missed ones are brief, but an instruction like "cut every question from the
interviewer" depends on the count in a way DER does not capture. `numberOfSpeakers` is honoured
exactly and should be passed whenever the count is known — the same guidance as before, now on
real evidence rather than on a splice.

Still open in M2: resource claims and MCP Tasks for long operations. Still unbuilt: VLM scene
semantics (the Swift probe works; wiring it into the index is the remaining M1 nicety), M3's
render verification and UI, and M4's autonomy instruments beyond the elicitation log. Code: `Sources/SharpyEngine`, `Sources/SharpyRender`, `Sources/SharpyCLI`,
`Sources/SharpyPerceptionProbe`.

### M1 — perception index
- L0/L1 via ffmpeg filters; L2 via Apple ASR + whisper-verbatim, sherpa, Vision, TransNetV2,
  Qwen3-VL-2B; content-addressed embedding cache; index runs over renders as well as sources.
- **Gate:** one hour of 1080p talking-head footage fully indexed (L0–L2) in **≤ 25 min**
  on this machine. Derived from measured rates: whisper-turbo 7 min + parakeet 2 min,
  diarization 4.3 min, shots 4.3 min, Vision faces at 206 fps (~0.5 min) with accurate OCR +
  hand pose only on shot changes and 1 fps keyframes (0.63 s each, ~10 min), VLM ~19 min at
  one frame per 5 s. Sequential that is ~47 min, so the gate holds only if ASR, Vision and
  diarization run *under* the VLM — whisper 2.2 GB + Vision 0.1 GB + VLM 3.2 GB fits;
  parakeet's 5.5 GB runs after the VLM. The overlap is a requirement, not an optimisation.
- **Gate:** "editor's report" for that hour reads specific, not generic — judged on three
  real recordings before any editing verb exists.

### M2 — decisions, assertions, agent surface
- `basis` enforced; §5 assertions as `block | warn | hold`; resource claims; falsifiable brief;
  brief / policy / enrollment / style as versioned documents; elicitation logging.
- MCP server with Tasks for every long op, elicitation as the help channel, MCP Apps for
  take-picker / cut-diff / "which face".
- **Gate:** a sound-cue change costs **< 30 s** end to end via range preview (spec §10.2).
- **Gate:** a note resolves to a decision id, applies, and offers promotion; a preference
  repeated twice is promoted (spec §10.4).

### M3 — render verification and human surface
- Cryptomatte-style ID + coverage pass; signalstats/ebur128 tier; predicted-vs-achieved tier;
  VLM as proposer. Feed, assist queue, cut diff, override timeline attach to the running engine.
- **Gate:** every spatial assertion in §5 evaluated on rendered frames, every frame.
- **Gate:** zero regressions on a fixture set of deliberately broken renders (edge on face,
  illegal levels, dropped frame, off-target LUFS).

### M4 — autonomy instruments
- Regression gate against own catalogue; selective review; compile-rate residue report;
  YouTube retention ingestion joined to the decision record; style profile writing
  `learned_preference`.
- **Gate:** request rate per hour of footage reported and falling across ten consecutive
  routine videos for one creator.

---

## 10. Risks, re-ranked by measurement

1. **Agent latency, not playback.** Playback headroom is proven (§2.3, §2.6). VLM indexing at
   ~19 min/hour is the wall-clock item; the levers are frame resolution, sampling density and
   the embedding cache. Measure prefill at 512 px first thing in M1.
2. **Real-world perception accuracy.** Every §2 number is on clean synthetic media. Real rooms,
   real faces, real cross-talk will lower ASR, diarization and Vision accuracy; the L2
   confidence floor exists for exactly this, but the floors must be calibrated on real footage
   before M2.
3. **Compositor cost once OCIO and effects are in the kernel.** The bare kernel has a 3–4×
   margin over the 30 fps gate at four 4K layers; every colour transform and effect spends
   some of it, and none of that is measured yet. Fallback remains proxy playback (1080p H.264
   encodes at 219 fps, decodes at 206) with full-resolution render only.
4. **Elicitation fatigue.** An agent that asks 200 questions is worse than one that guesses.
   Batching and stakes-scaled thresholds are M2 deliverables, not polish.
5. **TikTok has no retention API.** Shortform autonomy on that platform keeps a human eye
   longer; nothing in the architecture can change that.

---

## 11. Reproducing the measurements

Scripts, raw logs and the two TTS scripts are in [`bench/`](../bench/). Regenerate media with:

```bash
say -v Samantha -r 175 -o a1.aiff -f bench/script_a.txt; say -v Daniel -r 170 -o b1.aiff -f bench/script_b.txt
say -v Samantha -r 180 -o a2.aiff -f bench/script_a.txt; say -v Daniel -r 165 -o b2.aiff -f bench/script_b.txt
ffmpeg -i a1.aiff -i b1.aiff -i a2.aiff -i b2.aiff -filter_complex "[0:a][1:a][2:a][3:a]concat=n=4:v=0:a=1,aresample=16000" -ac 1 speech16k.wav
ffmpeg -f lavfi -i "testsrc2=size=3840x2160:rate=30:duration=30" -vf "noise=alls=18:allf=t+u,format=nv12" -c:v h264_videotoolbox -b:v 40M test4k_h264.mp4
ffmpeg -i test4k_h264.mp4 -c:v prores_videotoolbox -profile:v 3 test4k_prores422hq.mov
```

Not measured, and stated as such: real faces; noisy speech; BRAW decode; OCIO transform cost
inside the compositor kernel; LR-ASD throughput; L3 structural inference quality. Each is an
M1 measurement, not an assumption.
