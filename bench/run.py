"""Run the benchmark: every piece x condition, raw OMR vs MusicScan cleanup + OMR, scored against ground truth.

  python bench/run.py bench/data bench/results [--modes raw,clean] [--conds clean,photo,...]
Resumable: rows already in results.jsonl are skipped."""
from __future__ import annotations

import argparse
import json
import sys
import traceback
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from degrade import CONDITIONS, degrade  # noqa: E402

from musicscan import omr, preprocess  # noqa: E402
from musicscan.compare import compare  # noqa: E402
from musicscan.quality import assess  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("data")
    ap.add_argument("out")
    ap.add_argument("--modes", default="raw,musicscan")
    ap.add_argument("--conds", default=",".join(CONDITIONS))
    ap.add_argument("--only", default="")
    a = ap.parse_args()
    data, out = Path(a.data), Path(a.out)
    (out / "images").mkdir(parents=True, exist_ok=True)
    (out / "pred").mkdir(parents=True, exist_ok=True)
    res = out / "results.jsonl"
    done = set()
    if res.exists():
        for line in res.read_text().splitlines():
            r = json.loads(line)
            done.add((r["id"], r["cond"], r["mode"]))
    meta = json.loads((data / "index.json").read_text())
    for pi, m in enumerate(meta):
        pid = m["id"]
        if a.only and pid not in a.only.split(","):
            continue
        gt = (data / f"{pid}.musicxml").read_text()
        rgb = np.asarray(Image.open(data / f"{pid}.png").convert("RGB"))
        for ci, cond in enumerate(a.conds.split(",")):
            img_path = out / "images" / f"{pid}__{cond}.jpg"
            if img_path.exists():
                im = Image.open(img_path).convert("RGB")
            else:
                im = Image.fromarray(degrade(rgb, cond, seed=1000 * pi + ci))
                im.save(img_path, quality=92)
            for mode in a.modes.split(","):
                if (pid, cond, mode) in done:
                    continue
                if mode == "raw" and cond in ("clean",):
                    continue        # identical to musicscan on a clean render
                row = {"id": pid, "cond": cond, "mode": mode}
                try:
                    if mode == "raw":
                        page, pre = im.convert("L"), None
                        steps = []
                    else:
                        pre = preprocess.preprocess(im)
                        page, steps = pre["image"], pre["steps"]
                    r = omr.transcribe(page)
                    (out / "pred" / f"{pid}__{cond}__{mode}.musicxml").write_text(r["xml"])
                    row.update(compare(gt, r["xml"]))
                    row["omr"] = r["stats"]
                    row["seconds"] = r["seconds"]
                    row["steps"] = steps
                    q = assess(pre, r) if pre else assess(None, r, page=page)
                    row["quality"] = q
                except Exception as e:
                    row["error"] = f"{type(e).__name__}: {e}"
                    traceback.print_exc()
                with res.open("a") as f:
                    f.write(json.dumps(row) + "\n")
                print(json.dumps({k: row.get(k) for k in ("id", "cond", "mode", "note_f1", "pitch_f1", "ser", "seconds", "error")}), flush=True)


if __name__ == "__main__":
    main()
