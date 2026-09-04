#!/usr/bin/env python3
"""Transcribe a LibriSpeech split with parakeet-mlx, writing one .txt per utterance.

This exists to settle one question with data: the plan chose MLX parakeet on a 0.57% WER measured
over 528 words of synthetic TTS, against the CoreML build's 0.76% over the same 528 words — a gap
of exactly ONE WORD. Whether that gap is real can only be answered on a corpus large enough for
one word not to be the whole margin.

  python asr_mlx_parakeet.py --audio LibriSpeech/test-clean --out DIR
"""
import argparse, os, glob, time, sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--audio", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--model", default="mlx-community/parakeet-tdt-0.6b-v3")
    args = ap.parse_args()

    from parakeet_mlx import from_pretrained
    os.makedirs(args.out, exist_ok=True)
    files = sorted(glob.glob(os.path.join(args.audio, "**", "*.flac"), recursive=True))
    if not files:
        print(f"no flac under {args.audio}", file=sys.stderr); sys.exit(1)

    model = from_pretrained(args.model)
    t0, failures = time.time(), 0
    for i, path in enumerate(files, 1):
        stem = os.path.splitext(os.path.basename(path))[0]
        try:
            text = model.transcribe(path).text
        except Exception as e:
            # Empty, not absent: the scorer counts an empty hypothesis as full loss, so a failure
            # makes the score worse rather than quietly shrinking the corpus.
            text, failures = "", failures + 1
            print(f"  FAILED {stem}: {e}", file=sys.stderr)
        with open(os.path.join(args.out, stem + ".txt"), "w") as f:
            f.write(text)
        if i % 250 == 0 or i == len(files):
            print(f"[{i}/{len(files)}] {time.time()-t0:.0f}s elapsed, {failures} failed", flush=True)
    print(f"\n{len(files)} files in {(time.time()-t0)/60:.1f} min, {failures} failed")


if __name__ == "__main__":
    main()
