# Sharpy benchmarks

Everything in `results/` was measured on the target machine: **Mac mini M4 (4P+6E), 16 GB,
macOS 26.6.2**, ffmpeg 8.0.1 (Homebrew), MLX 0.32.2, Swift 6.3.1, on 2026-09-03.

## Reproduce

```bash
# 1. test media (TTS speech with fillers + noisy 4K test pattern in H.264/HEVC/ProRes)
#    see the media-generation block in ../docs/PLAN.md §11, or regenerate with `say` + ffmpeg
# 2. python stack
curl -LsSf https://astral.sh/uv/install.sh | sh
uv venv --python 3.12 .venv && . .venv/bin/activate
uv pip install mlx mlx-vlm mlx-whisper parakeet-mlx sherpa-onnx scenedetect opencv-python-headless torch torchvision transnetv2-pytorch "huggingface_hub[cli]"
# 3. chains (serialized on purpose: concurrent runs corrupt each other's numbers on 16 GB)
./run_chain.sh && ./run_chain2.sh && ./run_chain3.sh && ./run_chain4.sh   # chain4 = Gemma 4 E2B/E4B
# 4. Apple-native (zero model RAM from the app budget)
xcrun swiftc -O -parse-as-library asr_apple.swift -o asr_apple && ./asr_apple media/speech16k.wav
xcrun swiftc -O -parse-as-library vision_bench.swift -o vision_bench && ./vision_bench
xcrun swiftc -O -parse-as-library metal_composite_bench.swift -o mc && ./mc nv12 && ./mc bgra   # the M0 compositor number
```

Caveats that apply to every number: the speech is clean TTS (WER is optimistic vs. real
rooms); the video is a synthetic test pattern with **no faces** (Vision face numbers are
throughput only); the Metal compositor kernel has no colour management or effects in it yet
(OCIO cost is unmeasured). `composite_bench.swift` and `composite_bench_coreimage_pipelined.swift`
are kept as evidence that Core Image collapses at ≥ 4 layers; `metal_composite_bench.swift`
is the M0 baseline.

## Quality on real footage (added 2026-09-03, evening)

`real/labels_nosfx.json` is hand-written ground truth for 22 frames (one every 4 s) of the
user's `~/Desktop/reel-12-NOSFX.mp4`; the frames themselves are not committed. Regenerate with
`ffmpeg -i reel-12-NOSFX.mp4 -vf "fps=1/4,scale=-2:1024" real/frames_nosfx/n%02d.jpg`, then:

```bash
xcrun swiftc -O -parse-as-library vision_frames.swift -o vision_frames && ./vision_frames real/frames_nosfx
python bench_vlm_quality.py            # all four VLMs, JSON-structured answers scored against the labels
python bench_asr_real.py               # four ASR engines on the narration + pairwise disagreement
```
`results/asr_real_adjudicated.txt` records how each disagreement was judged (against the
on-screen cards, which restate the narration) — there is no listened-to reference.

## Building anything that links MLX

SwiftPM's command-line build cannot compile MLX's Metal shaders (stated in mlx-swift's README).
`swift build` / `swift test` are correct for `SharpyEngine` and `SharpyRender`; the perception
probe and the app must be built through Xcode's build system:

```bash
xcodebuild -scheme sharpy-probe -destination 'platform=macOS' -configuration Release build
```
Running an MLX-linked product built by `swift build` fails at runtime with
"MLX error: Failed to load the default metallib".
