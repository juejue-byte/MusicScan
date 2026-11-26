"""Summarize bench/results/results.jsonl into bench/REPORT tables.  python bench/report.py bench/results"""
from __future__ import annotations

import json
import sys
from collections import defaultdict
from pathlib import Path

CONDS = ["clean", "photo", "shadow", "pen", "pencil", "combo", "lowq"]


# What kind of page each test piece is. Piano and single-instrument pages are what MusicScan is for; songs (voice
# and piano) and ensembles/choir are reported separately.
GROUPS = {
    "piano": ["mozart_k545", "clara_polonaise", "cpebach_h186", "joplin_rag", "schoenberg_op19", "chopin_mazurka"],
    "single instrument": ["beethoven_18_vc", "beethoven_18_viola", "beethoven_59_2_vc", "beethoven_59_vn1",
                          "haydn_1_viola", "haydn_74_viola", "haydn_74_vn1", "mozart_k155_vn2", "mozart_k80_vn1",
                          "weber_clarinet"],
    "voice and piano": ["schubert_lindenbaum", "schumann_dichterliebe2", "handel_lascia"],
    "choir and ensemble": ["bach_bwv1_6", "bach_bwv269", "bach_bwv66", "bach_bwv7_7", "bach_bwv10_7", "johnson_lift",
                           "mozart_k458_quartet", "corelli_trio", "schumann_op41_quartet"],
}
GROUP_OF = {p: g for g, ps in GROUPS.items() for p in ps}
_DATA = Path("bench/data")


def reading(d: Path, pid: str, cond: str, mode: str):
    """A saved reading as the app has it now: pickup and bar rests fixed and, for MusicScan where the small model's
    reading is saved (bench/results/pred2m), the notes it adds filled in. Returns (xml, disagreement, filled bars),
    or None when the file is missing. Older result files predate these steps, so they are applied here."""
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from musicscan.omr import adopt_bars, disagreement, fix_pickup, restore_bar_rests
    f = d / "pred" / f"{pid}__{cond}__{mode}.musicxml"
    if not f.exists():
        return None
    prep = lambda x: restore_bar_rests(fix_pickup(x))  # noqa: E731
    x, dis, filled = prep(f.read_text()), None, set()
    f2 = d / "pred2m" / f"{pid}__{cond}.musicxml"
    if mode == "musicscan" and f2.exists():
        y = prep(f2.read_text())
        dis = disagreement(x, y)
        if dis:
            x, filled = adopt_bars(x, y, {i for i, t in dis.items() if t == "missed"})
            dis = {i: t for i, t in dis.items() if i not in filled}
    return x, dis, filled


def load(d: Path):
    """Rows of results.jsonl, the last one per (piece, condition, mode), with note F1 scored again from the saved
    MusicXML so a fix to the scorer applies to old runs too."""
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from musicscan.compare import compare
    rows = {}
    for x in (d / "results.jsonl").read_text().splitlines():
        if x.strip():
            r = json.loads(x)
            if "error" not in r or r.get("error") is None:
                rows[(r["id"], r["cond"], r["mode"])] = r
    for (pid, cond, mode), r in rows.items():
        g = _DATA / f"{pid}.musicxml"
        rd = reading(d, pid, cond, mode) if g.exists() else None
        if rd:
            try:
                c = compare(g.read_text(), rd[0])
                r.update({k: c[k] for k in ("note_f1", "pitch_f1", "ser")})
            except Exception:
                pass
    return list(rows.values())


def mean(xs):
    xs = list(xs)
    return sum(xs) / len(xs) if xs else float("nan")


def groups(d: Path):
    """Note F1 and whole bars right by kind of page, MusicScan pipeline."""
    rows = [r for r in load(d) if r["mode"] == "musicscan"]
    conds = [c for c in CONDS if c != "lowq"]
    print("| Kind of page | Pieces | " + " | ".join(conds) + " |")
    print("| --- | --- |" + " --- |" * len(conds))
    for g in GROUPS:
        rs = [r for r in rows if GROUP_OF.get(r["id"]) == g]
        if not rs:
            continue
        cells = [f"{mean(r['note_f1'] for r in rs if r['cond'] == c):.1%}" for c in conds]
        print(f"| {g} | {len({r['id'] for r in rs})} | " + " | ".join(cells) + " |")


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
    from musicscan.omr import level
    from musicscan.sanitize import sanitize
    tot = {"wrong": 0, "right": 0, "wrong_flag": 0, "right_flag": 0, "wrong_bad": 0, "right_bad": 0}
    per = defaultdict(lambda: {k: 0 for k in tot})
    pages = covered = n = 0
    for r in load(d):
        if r["mode"] != "musicscan" or r["cond"] == "lowq" or not r.get("bars"):
            continue
        rd = reading(d, r["id"], r["cond"], "musicscan")
        if rd is None:
            continue
        x, dis, filled = rd
        c = compare((data / f"{r['id']}.musicxml").read_text(), x)
        if c["bar_ok"] is None or len(c["bar_ok"]) != len(r["bars"]):
            continue
        n += 1
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
    from musicscan.sanitize import sanitize
    per = defaultdict(list)
    for r in load(d):
        rd = reading(d, r["id"], r["cond"], r["mode"])
        if rd is None and r["cond"] == "clean":
            rd = reading(d, r["id"], "clean", "musicscan")
        if rd is None:
            continue
        x = sanitize(rd[0])[0]
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
    data = Path(sys.argv[2] if len(sys.argv) > 2 else "bench/data")
    _DATA = data
    main(d)
    print()
    groups(d)
    print()
    flags(d, data)
    print()
    plays(d, data)
