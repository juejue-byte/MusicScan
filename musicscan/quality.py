"""Photo-quality verdict: combines what the image looks like with how sure the OMR reader was.

Returns {"score": 0-100, "level": "good" | "check" | "retake", "reasons": [...], "features": {...}}.
Thresholds were tuned on the benchmark (bench/), see bench/REPORT.md."""
from __future__ import annotations

import numpy as np

from .preprocess import measure

# tuned on bench results (see bench/calibrate.py)
T = {
    "staff_space_min": 9.0,      # px between staff lines on the page as read; below = too far away / too small
    "sharp_min": 0.11,           # edge steepness relative to contrast; below = out of focus
    "contrast_min": 70,          # paper minus ink grey levels after cleanup
    "low_frac_check": 0.04,      # share of uncertain symbols
    "low_frac_retake": 0.10,
    "rev_frac_check": 0.04,      # share of symbols the context model had to overrule
}


def assess(pre: dict | None, r: dict, page=None) -> dict:
    img = pre["image"] if pre else page
    m = measure(np.asarray(img.convert("L")))
    st = r["stats"]
    f = {"sharpness": m["sharpness"], "contrast": m["contrast"], "uneven": m["uneven"],
         "staff_space": st["staff_space"], "low_frac": st["low_frac"], "rev_frac": st["rev_frac"],
         "symbols": st["symbols"], "measures": st["measures"], "ink_staves": st["ink_staves"],
         "mean_conf": st["mean_conf"]}
    reasons = []
    pen = 0.0
    if st["measures"] == 0 or st["symbols"] < 10:
        return {"score": 0, "level": "retake", "reasons": ["No music staves were found in this photo."], "features": f}
    if st["staff_space"] < T["staff_space_min"]:
        pen += 30
        reasons.append("The music is too small in the photo. Move closer or photograph half a page at a time.")
    if m["sharpness"] < T["sharp_min"]:
        pen += 30
        reasons.append("The photo looks blurry. Hold the phone steady and tap to focus.")
    if m["contrast"] < T["contrast_min"]:
        pen += 20
        reasons.append("The page is too dark or faded. Use brighter, even light.")
    if not st["ink_staves"]:
        pen += 10
        reasons.append("Staff lines were hard to trace (page curved or tilted).")
    lf = st["low_frac"]
    if lf >= T["low_frac_retake"]:
        pen += 45
        reasons.append(f"The reader is unsure about {lf:.0%} of the symbols.")
    elif lf >= T["low_frac_check"]:
        pen += 20
        reasons.append(f"The reader is unsure about {lf:.0%} of the symbols.")
    if st["rev_frac"] >= T["rev_frac_check"]:
        pen += 10
        reasons.append("Many symbols needed correcting from context.")
    score = int(max(0, min(100, round(100 - pen))))
    level = "good" if score >= 75 else ("check" if score >= 45 else "retake")
    return {"score": score, "level": level, "reasons": reasons, "features": f}
