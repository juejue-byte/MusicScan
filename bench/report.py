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


def flags(d: Path, data: Path):
    """Do the per-bar warnings point at the bars that are wrong? Uses the app's rule (omr.level): confidence, bars
    the sanitizer repaired, and, where bench/results/pred2m holds the small model's reading, disagreement."""
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from musicscan.compare import compare
    from musicscan.omr import disagreement, fix_pickup, level, restore_bar_rests
    from musicscan.sanitize import sanitize
    prep = lambda x: restore_bar_rests(fix_pickup(x))  # noqa: E731
    tot = {"wrong": 0, "right": 0, "wrong_flag": 0, "right_flag": 0, "wrong_bad": 0, "right_bad": 0}
    per = defaultdict(lambda: {k: 0 for k in tot})
    pages = covered = n = 0
    for r in load(d):
        if r["mode"] != "musicscan" or r["cond"] == "lowq" or not r.get("bars"):
            continue
        f = d / "pred" / f"{r['id']}__{r['cond']}__musicscan.musicxml"
        if not f.exists():
            continue
        x = prep(f.read_text())
        c = compare((data / f"{r['id']}.musicxml").read_text(), x)
        if c["bar_ok"] is None or len(c["bar_ok"]) != len(r["bars"]):
            continue
        n += 1
        dis = None
        f2 = d / "pred2m" / f"{r['id']}__{r['cond']}.musicxml"
        if f2.exists():
            dis = disagreement(x, prep(f2.read_text()))
        fixed = {int(k) for k in sanitize(x)[1].get("bars", {})}
        wrong = set()
        for i, (b, ok) in enumerate(zip(r["bars"], c["bar_ok"])):
            lv = level({"n": 1, "min": b["min"], "disagree": (dis or {}).get(i), "fixes": i in fixed},
                       second_reading=dis is not None)
            flagged, bad = lv != "ok", lv == "bad"
            if not ok:
                wrong.add(i)
            for t in (tot, per[r["cond"]]):
                k = "right" if ok else "wrong"
                t[k] += 1
                t[k + "_flag"] += flagged
                t[k + "_bad"] += bad
            if not ok and not flagged:
                wrong.add(-1)
        if wrong:
            pages += 1
            covered += -1 not in wrong
    def line(name, t):
        rec = t["wrong_flag"] / max(t["wrong"], 1)
        rec_bad = t["wrong_bad"] / max(t["wrong"], 1)
        prec = t["wrong_flag"] / max(t["wrong_flag"] + t["right_flag"], 1)
        prec_bad = t["wrong_bad"] / max(t["wrong_bad"] + t["right_bad"], 1)
        fa = t["right_flag"] / max(t["right"], 1)
        return (f"| {name} | {t['right'] + t['wrong']} | {t['wrong']} | {rec:.0%} ({rec_bad:.0%} red) | "
                f"{prec:.0%} (red {prec_bad:.0%}) | {fa:.0%} |")
    print("| Condition | Bars compared | Bars with an error | Wrong bars marked | Marks that were wrong bars | Correct bars marked |")
    print("| --- | --- | --- | --- | --- | --- |")
    for c in CONDS:
        if c in per:
            print(line(c, per[c]))
    print(line("all", tot))
    print(f"\n({n} pages where the bar count matched the ground truth. On {covered} of the {pages} pages with an "
          "error, every wrong bar was marked.)")


def plays(d: Path, data: Path):
    """Would the file play the same as the original? Same notes at the same beats with the same lengths, per part,
    plus the same key and time signature. Tempo is not compared: the ground-truth pages carry no tempo marking."""
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from musicscan.compare import plays_same
    from musicscan.omr import fix_pickup, restore_bar_rests
    from musicscan.sanitize import sanitize
    per = defaultdict(list)
    for r in load(d):
        f = d / "pred" / f"{r['id']}__{r['cond']}__{r['mode']}.musicxml"
        if not f.exists() and r["cond"] == "clean":
            f = d / "pred" / f"{r['id']}__clean__musicscan.musicxml"
        if not f.exists():
            continue
        x = f.read_text()
        x = sanitize(restore_bar_rests(fix_pickup(x)))[0]   # what the app does to every reading now; older result files predate it
        if r["cond"] == "clean":
            per[("clean", "raw")].append(plays_same((data / f"{r['id']}.musicxml").read_text(), x))
        per[(r["cond"], r["mode"])].append(plays_same((data / f"{r['id']}.musicxml").read_text(), x))
    print("| Condition | Pages | Plays identically raw → MusicScan | Notes at the right beat, pitch and length raw → MusicScan | Key right | Time right |")
    print("| --- | --- | --- | --- | --- | --- |")
    for c in CONDS:
        ms, raw = per.get((c, "musicscan"), []), per.get((c, "raw"), [])
        if not ms:
            continue
        n = len(ms)
        ident = lambda xs: f"{sum(x['identical'] for x in xs)}/{len(xs)}"  # noqa: E731
        print(f"| {c} | {n} | {ident(raw) if raw else '–'} → **{ident(ms)}** | "
              f"{mean(x['play_f1'] for x in raw):.1%} → **{mean(x['play_f1'] for x in ms):.1%}** | "
              f"{sum(x['key_ok'] for x in ms)}/{n} | {sum(x['time_ok'] for x in ms)}/{n} |")


if __name__ == "__main__":
    d = Path(sys.argv[1] if len(sys.argv) > 1 else "bench/results")
    main(d)
    data = Path(sys.argv[2] if len(sys.argv) > 2 else "bench/data")
    print()
    flags(d, data)
    print()
    plays(d, data)
