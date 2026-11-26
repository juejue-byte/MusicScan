import json
import subprocess
import time
from pathlib import Path

import cv2
import numpy as np
import music21

BASE = Path("/home/antigravity/MusicScan")
OUT_DIR = BASE / "experiments" / "ablations"
OUT_DIR.mkdir(parents=True, exist_ok=True)


def preprocess(img_bgr, mode="whiten_upscale"):
    gray = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2GRAY)
    h, w = gray.shape[:2]
    if mode == "whiten_upscale":
        dilated = cv2.dilate(gray, np.ones((15, 15), np.uint8))
        bg = cv2.medianBlur(dilated, 21)
        diff = 255 - cv2.absdiff(gray, bg)
        norm = cv2.normalize(diff, None, 0, 255, cv2.NORM_MINMAX)
        if max(h, w) < 1400:
            scale = 1400.0 / max(h, w)
            norm = cv2.resize(norm, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_CUBIC)
        return cv2.cvtColor(norm, cv2.COLOR_GRAY2BGR)
    return img_bgr


def eval_with_music21(xml_path: Path, expected_q: float):
    if not xml_path.exists():
        return {"measures": 0, "notes": 0, "valid": 0, "flagged": 0, "keyFifths": 0}
    score = music21.converter.parse(str(xml_path))
    parts = list(score.parts)
    if not parts:
        return {"measures": 0, "notes": 0, "valid": 0, "flagged": 0, "keyFifths": 0}
    ks = list(score.recurse().getElementsByClass(music21.key.KeySignature))
    fifths = ks[0].sharps if ks else 0
    ms = list(parts[0].getElementsByClass(music21.stream.Measure))
    notes = len(list(score.recurse().notes))
    valid, flagged = 0, 0
    for m in ms:
        dur = float(m.duration.quarterLength)
        if abs(dur - expected_q) <= 0.05:
            valid += 1
        else:
            flagged += 1
    return {"measures": len(ms), "notes": notes, "valid": valid, "flagged": flagged, "keyFifths": fifths}


def main():
    cases = [
        ("image", "image.png", 2.0),       # 2/4 piano
        ("image_2", "image_2.png", 1.5),   # 3/8 horn signals (first 2 pieces)
        ("image_3", "image_3.png", 4.0),   # 4/4 handwritten antique
    ]
    rows = []
    for cid, fname, exp_q in cases:
        raw_metrics = eval_with_music21(BASE / "musicxml" / f"{cid}.musicxml", exp_q)
        raw_metrics.update({"dataset": cid, "ablation": "A0_raw", "elapsedSec": 0.0})
        print(f"[{cid} | A0_raw] -> {raw_metrics}")
        rows.append(raw_metrics)

        img = cv2.imread(str(BASE / fname))
        proc = preprocess(img, "whiten_upscale")
        out_img = OUT_DIR / f"{cid}_A1_whiten_upscale.png"
        cv2.imwrite(str(out_img), proc)
        t0 = time.time()
        subprocess.run(["homr", "--no-title", str(out_img)], capture_output=True, text=True, timeout=180)
        elapsed = round(time.time() - t0, 1)
        a1 = eval_with_music21(out_img.with_suffix(".musicxml"), exp_q)
        a1.update({"dataset": cid, "ablation": "A1_whiten_upscale", "elapsedSec": elapsed})
        print(f"[{cid} | A1_whiten_upscale] {elapsed}s -> {a1}")
        rows.append(a1)

    (OUT_DIR / "ablation_results.json").write_text(json.dumps(rows, indent=2))
    print("Saved ablation results.")


if __name__ == "__main__":
    main()
