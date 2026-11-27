"""Score MusicScan on real iPhone photos with their true scores: Greg Clarke's Sheet Music Scanner test set
(huggingface.co/datasets/gregology/sheet-music-scanner-eval, CC BY 4.0; the music is OpenScore, CC0).

  python -c "from huggingface_hub import snapshot_download as s; s('gregology/sheet-music-scanner-eval',
      repo_type='dataset', allow_patterns=['photos/*'], local_dir='../sheet-music-scanner-eval')"
  python bench/real_photos_eval.py ../sheet-music-scanner-eval/photos bench/real_out [--only real] [--limit N]

Runs the app's own steps on every photo (page lock, cleanup, reading with the sharpened check, second reading,
sanitizer) and scores the reading against the true MusicXML: note F1 (pitch and length, in order), whether every
bar is there, and whether it plays the same. Resumable: rows go to <out>/results.jsonl. Prints a table by kind of
photo (flat, shadow, curve, angle, stand) and music (real string parts, made-up sheets)."""
from __future__ import annotations

import argparse
import json
import sys
import time
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


def read(path: Path) -> dict:
    from PIL import Image
    from musicscan import omr, preprocess
    from musicscan.quality import assess
    from server.app import _clean
    im = Image.open(path)
    im = im.convert("RGB")
    pre = preprocess.preprocess(im)
    if hasattr(omr, "transcribe_checked"):
        r, read_im = omr.transcribe_checked(pre["image"])
    else:                                            # an older checkout, for a before/after comparison
        r, read_im = omr.transcribe(pre["image"]), pre["image"]
    omr.second_opinion(r, read_im)
    _clean(r)
    q = assess(pre, r)
    return {"xml": r["xml"], "levels": [m["level"] for m in r["measures"]], "steps": pre["steps"],
            "quality": q["level"], "layout": r.get("layout_check"), "seconds": r["seconds"]}


def main():
    from musicscan.compare import compare, plays_same
    ap = argparse.ArgumentParser()
    ap.add_argument("photos", help="the set's photos/ folder (metadata.jsonl, sheets/)")
    ap.add_argument("out")
    ap.add_argument("--only", default="", help="real or made-up")
    ap.add_argument("--limit", type=int, default=0)
    a = ap.parse_args()
    src, out = Path(a.photos), Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    res = out / "results.jsonl"
    done = {json.loads(x)["file"] for x in res.read_text().splitlines()} if res.exists() else set()
    meta = [json.loads(x) for x in (src / "metadata.jsonl").read_text().splitlines() if x.strip()]
    if a.only:
        meta = [m for m in meta if m["music"] == a.only]
    if a.limit:
        meta = meta[:a.limit]
    for m in meta:
        if m["file_name"] in done:
            continue
        gt = (src / m["truth"]).read_text()
        t0 = time.time()
        row = {"file": m["file_name"], "music": m["music"], "condition": m["condition"]}
        try:
            r = read(src / m["file_name"])
            (out / (Path(m["file_name"]).stem + ".musicxml")).write_text(r["xml"])
            c, p = compare(gt, r["xml"]), plays_same(gt, r["xml"])
            row.update({"note_f1": c["note_f1"], "pitch_f1": c["pitch_f1"], "gt_bars": c["gt_measures"],
                        "bars": c["pred_measures"], "play_f1": p["play_f1"], "identical": p["identical"],
                        "marked": sum(x != "ok" for x in r["levels"]), "quality": r["quality"],
                        "steps": r["steps"], "layout": r["layout"]})
        except Exception as e:
            row["error"] = f"{type(e).__name__}: {e}"[:300]
        row["seconds"] = round(time.time() - t0, 1)
        with res.open("a") as f:
            f.write(json.dumps(row) + "\n")
        print(json.dumps(row), flush=True)
    rows = [json.loads(x) for x in res.read_text().splitlines() if x.strip()]
    rows = [r for r in rows if "error" not in r]
    groups = defaultdict(list)
    for r in rows:
        groups[(r["music"], r["condition"])].append(r)
        groups[(r["music"], "all")].append(r)
    print("\n| Music | Photo | Photos | Note F1 | Bars all there | Plays the same (notes) | Rated retake |")
    print("| --- | --- | --- | --- | --- | --- | --- |")
    for (mu, co), rs in sorted(groups.items()):
        n = len(rs)
        print(f"| {mu} | {co} | {n} | {sum(r['note_f1'] for r in rs) / n:.1%} | "
              f"{sum(r['bars'] == r['gt_bars'] for r in rs)}/{n} | {sum(r['play_f1'] for r in rs) / n:.1%} | "
              f"{sum(r['quality'] == 'retake' for r in rs)} |")


if __name__ == "__main__":
    main()
