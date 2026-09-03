#!/usr/bin/env python3
"""Run sherpa-onnx diarization over a directory of wavs and emit one RTTM per file.

The point of this script is to make sherpa-onnx and SpeakerKit scoreable by the *same*
scorer on the *same* material, because the only reason to prefer one is a number.

  python diar_sherpa.py --audio DIR --out DIR --embedding MODEL.onnx [--threshold F] [--files LIST]
"""
import argparse, os, sys, time, wave, json
import numpy as np
import sherpa_onnx


def read_wav_16k_mono(path):
    """sherpa wants float32 mono at the model's rate. Resample rather than refuse."""
    with wave.open(path, "rb") as w:
        n, ch, sw, sr = w.getnframes(), w.getnchannels(), w.getsampwidth(), w.getframerate()
        raw = w.readframes(n)
    if sw != 2:
        raise ValueError(f"{path}: expected 16-bit PCM, got {sw*8}-bit")
    x = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    if ch > 1:
        x = x.reshape(-1, ch).mean(axis=1)
    if sr != 16000:
        # Linear resample. Diarization runs on 16 kHz; the fidelity that matters here is timing.
        t = np.arange(0, len(x) / sr, 1 / 16000)[: int(len(x) * 16000 / sr)]
        x = np.interp(t, np.arange(len(x)) / sr, x).astype(np.float32)
        sr = 16000
    return x, sr


def build(seg_model, emb_model, threshold, num_speakers, threads):
    cfg = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
            pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(model=seg_model),
            num_threads=threads),
        embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=emb_model, num_threads=threads),
        clustering=sherpa_onnx.FastClusteringConfig(
            num_clusters=num_speakers if num_speakers else -1, threshold=threshold),
        min_duration_on=0.3, min_duration_off=0.5)
    if not cfg.validate():
        raise RuntimeError("sherpa-onnx rejected the diarization config")
    return sherpa_onnx.OfflineSpeakerDiarization(cfg)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--audio", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--seg", default="models/sherpa-onnx-pyannote-segmentation-3-0/model.onnx")
    ap.add_argument("--embedding", required=True)
    ap.add_argument("--threshold", type=float, default=0.5)
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--files", help="file with one basename per line; default = every wav")
    ap.add_argument("--timing", help="write per-file wall/duration json here")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    if args.files:
        names = [l.strip() for l in open(args.files) if l.strip()]
    else:
        names = sorted(f[:-4] for f in os.listdir(args.audio) if f.endswith(".wav"))

    sd = build(args.seg, args.embedding, args.threshold, None, args.threads)
    timing = []
    for i, name in enumerate(names, 1):
        path = os.path.join(args.audio, name + ".wav")
        try:
            x, sr = read_wav_16k_mono(path)
        except Exception as e:
            print(f"  SKIP {name}: {e}", file=sys.stderr); continue
        t0 = time.time()
        result = sd.process(x).sort_by_start_time()
        dt = time.time() - t0
        dur = len(x) / sr
        with open(os.path.join(args.out, name + ".rttm"), "w") as f:
            for seg in result:
                f.write(f"SPEAKER {name} 1 {seg.start:.3f} {seg.end - seg.start:.3f} "
                        f"<NA> <NA> spk{seg.speaker} <NA> <NA>\n")
        n_spk = len({s.speaker for s in result})
        timing.append({"file": name, "wall": dt, "duration": dur, "speakers": n_spk})
        print(f"[{i}/{len(names)}] {name} {dur:7.1f}s in {dt:6.1f}s "
              f"({dur/max(dt,1e-3):5.1f}x RT) -> {n_spk} speakers", flush=True)

    if args.timing:
        json.dump(timing, open(args.timing, "w"), indent=1)
    tot_w = sum(t["wall"] for t in timing); tot_d = sum(t["duration"] for t in timing)
    print(f"\n{len(timing)} files, {tot_d/3600:.2f} h audio in {tot_w/60:.1f} min "
          f"= {tot_d/max(tot_w,1e-3):.1f}x realtime")


if __name__ == "__main__":
    main()
