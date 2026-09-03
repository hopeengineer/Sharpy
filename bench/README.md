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

## Re-measuring a swapped component (added 2026-09-04)

When a component is replaced, it must be re-measured against the baseline it replaces, on the
same reference media and the same known truth. Regenerate the ASR reference:

```bash
say -v Samantha -r 175 -o a1.aiff -f script_a.txt ; say -v Daniel -r 170 -o b1.aiff -f script_b.txt
say -v Samantha -r 180 -o a2.aiff -f script_a.txt ; say -v Daniel -r 165 -o b2.aiff -f script_b.txt
ffmpeg -i a1.aiff -i b1.aiff -i a2.aiff -i b2.aiff \
  -filter_complex "[0:a][1:a][2:a][3:a]concat=n=4:v=0:a=1,aresample=16000" -ac 1 speech16k.wav
sharpy transcribe speech16k.wav --engine whisper     # then score with wer.py
```

The diarization set (`script_c.txt` is the third voice):

```bash
say -v Samantha -r 175 -o v1.aiff -f script_a.txt
say -v Daniel   -r 170 -o v2.aiff -f script_b.txt
say -v Karen    -r 172 -o v3.aiff -f script_c.txt
ffmpeg -i v1.aiff -af aresample=16000 -ac 1 one_voice.wav                       # truth 1
ffmpeg -i v1.aiff -i v2.aiff -i v1.aiff -i v2.aiff -filter_complex \
  "[0:a][1:a][2:a][3:a]concat=n=4:v=0:a=1,aresample=16000" -ac 1 two_voices.wav  # truth 2
ffmpeg -i v1.aiff -i v2.aiff -i v3.aiff -i v1.aiff -i v2.aiff -i v3.aiff -filter_complex \
  "[0:a][1:a][2:a][3:a][4:a][5:a]concat=n=6:v=0:a=1,aresample=16000" -ac 1 three_voices.wav
sharpy speakers two_voices.wav        # automatic — over-counts; --speakers N is exact
```

Results and the verdict on each swap: `results/swift_asr_diarization.txt`.
The clustering-parameter sweep behind the diarization verdict: `results/diarization_sweep.txt`.

**Caveat that matters:** these multi-speaker files are hard concatenations of separately recorded
voices, so their turn boundaries are harsher than real conversation. A diarization rule tuned to
pass them may be fitting the fixture. A real multi-speaker recording is what would settle it.

## Diarization on real corpora (added 2026-09-04)

The synthetic `say` splices above are NOT adequate for diarization. They certified sherpa-onnx as
"2 of 2 speakers correct" and condemned SpeakerKit as over-counting; on real audio both verdicts
were wrong. Hard splices of separate takes produce boundary artefacts real conversation does not
have. Use annotated corpora instead — they are a free download:

```bash
# VoxConverse dev: 216 YouTube/broadcast recordings, 20.30 h, 1-20 speakers, CC BY 4.0
curl -LO https://www.robots.ox.ac.uk/~vgg/data/voxconverse/data/voxconverse_dev_wav.zip && unzip -q voxconverse_dev_wav.zip
curl -L https://github.com/joonson/voxconverse/archive/refs/heads/master.zip -o vc.zip && unzip -q vc.zip   # reference RTTMs

# AMI dev: spontaneous 4-speaker meetings, Mix-Headset. RTTMs from BUT's standard setup.
curl -L https://github.com/BUTSpeechFIT/AMI-diarization-setup/archive/refs/heads/main.zip -o ami.zip && unzip -q ami.zip
for M in IS1008a ES2011a TS3004a IB4001 IS1008b ES2011b; do
  curl -Lo "ami_audio/$M.wav" "https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/$M/audio/$M.Mix-Headset.wav"
done

# scoring stack
uv venv --python 3.12 dvenv && uv pip install --python dvenv/bin/python sherpa-onnx pyannote.metrics

# both engines emit RTTM, one scorer, same protocol
sharpy diarize-batch audio --rttm-dir hyp_speakerkit
dvenv/bin/python diar_sherpa.py --audio audio --out hyp_sherpa \
  --seg models/sherpa-onnx-pyannote-segmentation-3-0/model.onnx \
  --embedding models/nemo_en_titanet_large.onnx --threshold 1.10
dvenv/bin/python score_der.py --ref voxconverse-master/dev --hyp hyp_speakerkit --name SpeakerKit
```

`score_der.py` reports DER in BOTH conventions — 0.25 s collar excluding overlap, and no collar
including overlap — plus speaker-count accuracy separately, because a diarizer can post a decent
DER while getting the count wrong, and for an editor the count is what drives "cut the
interviewer".

Results: `results/diarization_real_corpora.txt`.
