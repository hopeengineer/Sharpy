#!/usr/bin/env python3
"""Score a directory of hypothesis RTTMs against reference RTTMs.

Reports the two conventions rather than one, because picking the flattering convention is
how a bad diarizer looks good:

  DER(0.25, no overlap)  the common "forgiving" convention: 250 ms collar around every
                         boundary, overlapped speech excluded.
  DER(0.0, overlap)      full DER: no collar, overlap counted. This is the honest number
                         and it is always worse.

Speaker counting is reported separately, because for an editor the count is what drives
"cut the interviewer" and a diarizer can score a fine DER while getting the count wrong.
"""
import argparse, os, sys, json
from collections import Counter
from pyannote.core import Segment, Annotation
from pyannote.metrics.diarization import DiarizationErrorRate


def load_rttm(path):
    """Load an RTTM, preserving OVERLAP.

    `ann[segment] = label` writes to a default track, so two speakers talking over the same span
    silently overwrite each other and the file loses exactly the speech that overlap-aware
    diarizers exist to find. Giving every line its own track id keeps them. This mattered: the
    first version of this scorer reported 51.49% DER for Sortformer, which predicts overlap, and
    much of that was the scorer discarding its output rather than the model being wrong.
    """
    ann = Annotation()
    for i, line in enumerate(open(path)):
        p = line.split()
        if not p or p[0] != "SPEAKER":
            continue
        start, dur, spk = float(p[3]), float(p[4]), p[7]
        if dur <= 0:
            continue
        ann[Segment(start, start + dur), i] = spk
    return ann


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", required=True)
    ap.add_argument("--hyp", required=True)
    ap.add_argument("--name", default="hyp")
    ap.add_argument("--json", help="write per-file rows here")
    args = ap.parse_args()

    metrics = {"collar": DiarizationErrorRate(collar=0.25, skip_overlap=True),
               "full": DiarizationErrorRate(collar=0.0, skip_overlap=False)}
    rows, count_exact, count_delta = [], 0, Counter()
    scored = 0
    for f in sorted(os.listdir(args.ref)):
        if not f.endswith(".rttm"):
            continue
        hyp_path = os.path.join(args.hyp, f)
        if not os.path.exists(hyp_path):
            continue
        ref, hyp = load_rttm(os.path.join(args.ref, f)), load_rttm(hyp_path)
        if not ref:
            continue
        scored += 1
        row = {"file": f[:-5],
               "ref_speakers": len(ref.labels()), "hyp_speakers": len(hyp.labels()),
               "duration": ref.get_timeline().extent().duration}
        for key, m in metrics.items():
            row[key] = m(ref, hyp)          # accumulates into m for the corpus total
        d = row["hyp_speakers"] - row["ref_speakers"]
        count_delta[d] += 1
        count_exact += (d == 0)
        rows.append(row)

    if not scored:
        print("no files scored — check --ref/--hyp paths", file=sys.stderr); sys.exit(1)

    print(f"=== {args.name} — {scored} files ===")
    for key, m in metrics.items():
        label = "DER collar=0.25 no-overlap" if key == "collar" else "DER collar=0    +overlap "
        print(f"  {label}: {abs(m):6.2%}")
    print(f"  speaker count exact      : {count_exact}/{scored} = {count_exact/scored:.1%}")
    print("  count error distribution : " +
          "  ".join(f"{'+' if d>0 else ''}{d}:{n}" for d, n in sorted(count_delta.items())))
    over = sum(n for d, n in count_delta.items() if d > 0)
    under = sum(n for d, n in count_delta.items() if d < 0)
    print(f"  over-counted {over}  under-counted {under}")
    if args.json:
        json.dump(rows, open(args.json, "w"), indent=1)


if __name__ == "__main__":
    main()
