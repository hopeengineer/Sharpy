#!/usr/bin/env python3
"""Score a directory of hypothesis transcripts against a reference corpus.

Two things this does that a naive scorer does not, both of which change the ranking:

1. **Whisper's EnglishTextNormalizer.** Engines differ in how they render the same words —
   digits vs words, "Mr." vs "mister", contractions. Without normalisation the score measures
   formatting convention, and it penalises whichever engine formats differently from the
   reference rather than whichever engine mis-heard. This is the normalizer the field uses, so
   the numbers are comparable to published ones.

2. **Missing and empty hypotheses count as total loss for that utterance**, rather than being
   skipped. A crash that drops 10% of a corpus must make the score worse, not better.

Usage:
  score_wer.py --ref-kind librispeech --ref DIR --hyp DIR --name ENGINE
  score_wer.py --ref-kind jsonl       --ref FILE --hyp DIR --name ENGINE
"""
import argparse, os, sys, json, glob
import jiwer
from whisper_normalizer.english import EnglishTextNormalizer


def librispeech_refs(root):
    refs = {}
    for path in glob.glob(os.path.join(root, "**", "*.trans.txt"), recursive=True):
        for line in open(path):
            utt, _, text = line.strip().partition(" ")
            if utt and text:
                refs[utt] = text
    return refs


def jsonl_refs(path):
    refs = {}
    for line in open(path):
        row = json.loads(line)
        refs[row["id"]] = row["text"]
    return refs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", required=True)
    ap.add_argument("--ref-kind", default="librispeech", choices=["librispeech", "jsonl"])
    ap.add_argument("--hyp", required=True)
    ap.add_argument("--name", default="engine")
    ap.add_argument("--json", help="write per-utterance rows here")
    args = ap.parse_args()

    refs = librispeech_refs(args.ref) if args.ref_kind == "librispeech" else jsonl_refs(args.ref)
    if not refs:
        print(f"no references found under {args.ref}", file=sys.stderr); sys.exit(1)

    norm = EnglishTextNormalizer()
    pairs, missing, empty, rows = [], 0, 0, []
    for utt, ref_text in sorted(refs.items()):
        hyp_path = os.path.join(args.hyp, utt + ".txt")
        if not os.path.exists(hyp_path):
            missing += 1
            hyp_text = ""
        else:
            hyp_text = open(hyp_path).read().strip()
            if not hyp_text:
                empty += 1
        r, h = norm(ref_text), norm(hyp_text)
        if not r:
            continue          # a reference that normalises to nothing cannot be scored
        pairs.append((r, h))
        rows.append({"id": utt, "ref": r, "hyp": h})

    refs_n = [p[0] for p in pairs]
    hyps_n = [p[1] for p in pairs]
    out = jiwer.process_words(refs_n, hyps_n)
    total_ref_words = sum(len(r.split()) for r in refs_n)

    print(f"=== {args.name} — {len(pairs)} utterances, {total_ref_words} reference words ===")
    print(f"  WER            : {out.wer:7.2%}")
    print(f"  substitutions  : {out.substitutions:6d}")
    print(f"  deletions      : {out.deletions:6d}")
    print(f"  insertions     : {out.insertions:6d}")
    if missing or empty:
        print(f"  !! {missing} hypotheses missing, {empty} empty — counted as full loss")
    if args.json:
        json.dump(rows, open(args.json, "w"), indent=1)


if __name__ == "__main__":
    main()
