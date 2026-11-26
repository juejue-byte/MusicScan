import json
import subprocess
import time
import xml.etree.ElementTree as ET
from pathlib import Path

import cv2
import numpy as np

BASE = Path("/home/antigravity/MusicScan")
EXP_DIR = BASE / "experiments"
EXP_DIR.mkdir(exist_ok=True)

TYPE_BEATS = {"whole": 4.0, "half": 2.0, "quarter": 1.0, "eighth": 0.5, "16th": 0.25, "32nd": 0.125}


def evaluate_xml(xml_path: Path, expected_q: float = 2.0) -> dict:
    if not xml_path.exists():
        return {"ok": False, "measures": 0, "notes": 0, "validMeasures": 0, "flaggedMeasures": 0, "error": "No XML produced"}
    root = ET.parse(xml_path).getroot()
    part = root.find("part")
    measures = part.findall("measure")
    total_notes = 0
    valid = 0
    flagged = 0
    cur_div = 1
    for m_el in measures:
        for attrs in m_el.findall("attributes"):
            d = attrs.findtext("divisions")
            if d:
                cur_div = int(d)
        v_tot = {}
        for n in m_el.findall("note"):
            is_ch = n.find("chord") is not None
            is_r = n.find("rest") is not None
            if not is_r:
                total_notes += 1
            v = n.findtext("voice", "1")
            tp = n.findtext("type", "quarter")
            dot = n.find("dot") is not None
            dur_t = n.findtext("duration")
            q = TYPE_BEATS.get(tp, 1.0) * (1.5 if dot else 1.0)
            if dur_t and cur_div > 0 and int(dur_t) > 0:
                q = int(dur_t) / float(cur_div)
            if not is_ch:
                v_tot[v] = v_tot.get(v, 0.0) + q
        if not v_tot:
            flagged += 1
            continue
        pv = "1" if "1" in v_tot else next(iter(v_tot))
        if abs(v_tot[pv] - expected_q) <= 0.05:
            valid += 1
        else:
            flagged += 1
    return {
        "ok": True,
        "measures": len(measures),
        "notes": total_notes,
        "validMeasures": valid,
        "flaggedMeasures": flagged,
    }


def run_case(name: str, img_bgr: np.ndarray, expected_q: float = 2.0) -> dict:
    img_path = EXP_DIR / f"{name}.png"
    cv2.imwrite(str(img_path), img_bgr)
    t0 = time.time()
    res = subprocess.run(["homr", "--no-title", str(img_path)], capture_output=True, text=True, timeout=180)
    elapsed = round(time.time() - t0, 1)
    xml_path = img_path.with_suffix(".musicxml")
    metrics = evaluate_xml(xml_path, expected_q=expected_q)
    metrics["name"] = name
    metrics["image"] = str(img_path)
    metrics["elapsedSec"] = elapsed
    metrics["exitCode"] = res.returncode
    print(f"[{name}] {elapsed}s -> measures={metrics['measures']}, notes={metrics['notes']}, valid={metrics['validMeasures']}, flagged={metrics['flaggedMeasures']}")
    return metrics


def deshadow(img_bgr: np.ndarray) -> np.ndarray:
    gray = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2GRAY)
    dilated = cv2.dilate(gray, np.ones((21, 21), np.uint8))
    bg = cv2.medianBlur(dilated, 31)
    diff = 255 - cv2.absdiff(gray, bg)
    norm = cv2.normalize(diff, None, 0, 255, cv2.NORM_MINMAX)
    return cv2.cvtColor(norm, cv2.COLOR_GRAY2BGR)


def main():
    orig = cv2.imread(str(BASE / "image.png"))
    H, W = orig.shape[:2]
    results = []

    # 0. Baseline (reuse existing image.musicxml metrics for speed)
    base_metrics = evaluate_xml(BASE / "musicxml" / "image.musicxml", expected_q=2.0)
    base_metrics.update({"name": "00_baseline_clean", "image": str(BASE / "image.png"), "elapsedSec": 0.0, "exitCode": 0})
    print(f"[00_baseline_clean] -> measures={base_metrics['measures']}, notes={base_metrics['notes']}, valid={base_metrics['validMeasures']}, flagged={base_metrics['flaggedMeasures']}")
    results.append(base_metrics)

    # 1. Localized Blur on System 2 (y: 19%..36%)
    blurred = orig.copy()
    sy0, sy1 = int(0.19 * H), int(0.36 * H)
    blurred[sy0:sy1, :] = cv2.GaussianBlur(blurred[sy0:sy1, :], (9, 9), 3.0)
    results.append(run_case("01a_blurred_system2", blurred))

    # 1b. Recovery: Clean Full-System Close-up of System 2 (simulating user retaking just System 2!)
    sys2_clean = orig[max(0, sy0 - 15):min(H, sy1 + 15), int(0.02 * W):int(0.98 * W)]
    sys2_pad = cv2.copyMakeBorder(sys2_clean, 70, 70, 70, 70, cv2.BORDER_CONSTANT, value=(245, 240, 230))
    results.append(run_case("01b_recovery_system2_closeup", sys2_pad))

    # 2a. Perspective Warp / Angled Camera Photo
    src_pts = np.float32([[0, 0], [W, 0], [W, H], [0, H]])
    dst_pts = np.float32([[W * 0.10, H * 0.05], [W * 0.90, H * 0.02], [W * 0.98, H * 0.96], [W * 0.02, H * 0.92]])
    M = cv2.getPerspectiveTransform(src_pts, dst_pts)
    warped = cv2.warpPerspective(orig, M, (W, H), borderValue=(40, 40, 40))
    results.append(run_case("02a_perspective_warped", warped))

    # 2b. Recovery: Inverse Perspective Deskew (simulating auto document-flatten before OMR)
    M_inv = cv2.getPerspectiveTransform(dst_pts, src_pts)
    unwarped = cv2.warpPerspective(warped, M_inv, (W, H), borderValue=(255, 255, 255))
    results.append(run_case("02b_recovery_deskewed", unwarped))

    # 3a. Heavy Diagonal Shadow (classic phone-photo lighting problem)
    yy, xx = np.mgrid[0:H, 0:W]
    grad = np.clip(0.28 + 0.85 * ((xx / W) * 0.7 + (yy / H) * 0.3), 0.25, 1.0)
    shadowed = np.clip(orig.astype(np.float32) * grad[:, :, None], 0, 255).astype(np.uint8)
    results.append(run_case("03a_heavy_shadow", shadowed))

    # 3b. Recovery: Adaptive Background Illumination Normalization
    results.append(run_case("03b_recovery_deshadowed", deshadow(shadowed)))

    # 4. Low Resolution (50% downscale — standing too far back)
    lowres = cv2.resize(orig, (W // 2, H // 2), interpolation=cv2.INTER_AREA)
    results.append(run_case("04a_lowres_50pct", lowres))

    out_json = EXP_DIR / "stress_test_results.json"
    out_json.write_text(json.dumps(results, indent=2))
    print("\nSaved results to", out_json)


if __name__ == "__main__":
    main()
