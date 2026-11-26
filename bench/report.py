"""Summarize bench/results/results.jsonl into bench/REPORT tables.  python bench/report.py bench/results"""
from __future__ import annotations

import json
import sys
from collections import defaultdict
from pathlib import Path

CONDS = ["clean", "photo", "shadow", "pen", "pencil", "combo", "lowq"]


def load(d: Path):
    rows = [json.loads(x) for x in (d / "results.jsonl").read_text().splitlines() if x.strip()]
    return [r for r in rows if "error" not in r]


def mean(xs):
    xs = list(xs)
    return sum(xs) / len(xs) if xs else float("nan")


def main(d: Path):
    rows = load(d)
    by = defaultdict(list)
    for r in rows:
        by[(r["cond"], r["mode"])].append(r)
    print("| Condition | Pages | Pitch F1 raw → MusicScan | Note F1 (pitch+rhythm) raw → MusicScan | Error rate (SER) MusicScan | Bars right | Quality verdicts (good/check/retake) |")
    print("| --- | --- | --- | --- | --- | --- | --- |")
    for c in CONDS:
        ms = by.get((c, "musicscan"), [])
        raw = by.get((c, "raw"), []) or ms
        if not ms:
            continue
        lv = defaultdict(int)
        for r in ms:
            lv[r["quality"]["level"]] += 1
        bars = mean(r["pred_measures"] == r["gt_measures"] for r in ms)
        print(f"| {c} | {len(ms)} | {mean(r['pitch_f1'] for r in raw):.1%} → **{mean(r['pitch_f1'] for r in ms):.1%}** | "
              f"{mean(r['note_f1'] for r in raw):.1%} → **{mean(r['note_f1'] for r in ms):.1%}** | {mean(r['ser'] for r in ms):.1%} | "
              f"{bars:.0%} | {lv['good']}/{lv['check']}/{lv['retake']} |")
    print()
    print("Per piece (MusicScan pipeline, note F1):")
    pieces = sorted({r["id"] for r in rows})
    print("| Piece | " + " | ".join(CONDS) + " |")
    print("| --- |" + " --- |" * len(CONDS))
    for p in pieces:
        cells = []
        for c in CONDS:
            m = [r for r in by.get((c, "musicscan"), []) if r["id"] == p]
            cells.append(f"{m[0]['note_f1']:.0%}" if m else "")
        print(f"| {p} | " + " | ".join(cells) + " |")


if __name__ == "__main__":
    main(Path(sys.argv[1] if len(sys.argv) > 1 else "bench/results"))
