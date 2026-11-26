import json
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

BASE = Path("/home/antigravity/MusicScan")
TYPE_BEATS = {"whole": 4.0, "half": 2.0, "quarter": 1.0, "eighth": 0.5, "16th": 0.25, "32nd": 0.125}


def score_measure_xml(xml_path: Path, expected_q: float):
    """Parse MusicXML from a cropped rescan and return the best measure's beat-math score."""
    if not xml_path.exists():
        return None
    root = ET.parse(xml_path).getroot()
    part = root.find("part")
    best = None
    for m_el in part.findall("measure"):
        divs = 1
        attrs = m_el.find("attributes")
        if attrs is not None:
            d = attrs.findtext("divisions")
            if d:
                divs = int(d)
        events = []
        v_tot = {}
        for n in m_el.findall("note"):
            is_ch = n.find("chord") is not None
            is_r = n.find("rest") is not None
            v = n.findtext("voice", "1")
            tp = n.findtext("type", "quarter")
            dot = n.find("dot") is not None
            dur_t = n.findtext("duration")
            q = TYPE_BEATS.get(tp, 1.0) * (1.5 if dot else 1.0)
            if dur_t and divs > 0 and int(dur_t) > 0:
                q = int(dur_t) / float(divs)
            if not is_ch:
                v_tot[v] = v_tot.get(v, 0.0) + q
            pitch = None
            if not is_r:
                p = n.find("pitch")
                if p is not None:
                    pitch = f"{p.findtext('step','?')}{p.findtext('alter','')}{p.findtext('octave','?')}"
            events.append(("R" if is_r else pitch, tp, round(q, 3)))
        if not events:
            continue
        pv = "1" if "1" in v_tot else next(iter(v_tot))
        actual = round(v_tot[pv], 3)
        diff = abs(actual - expected_q)
        conf = 0.96 if diff <= 0.05 else (0.68 if diff <= 0.5 else 0.52)
        cand = {"events": events, "actual": actual, "expected": expected_q, "diff": round(diff, 3), "conf": conf}
        if best is None or (cand["diff"], -len(cand["events"])) < (best["diff"], -len(best["events"])):
            best = cand
    return best


def preprocess_crop(crop_bgr, mode="clean"):
    gray = cv2.cvtColor(crop_bgr, cv2.COLOR_BGR2GRAY)
    # Background whitening (removes yellowed vintage paper)
    dilated = cv2.dilate(gray, np.ones((15, 15), np.uint8))
    bg = cv2.medianBlur(dilated, 21)
    diff = 255 - cv2.absdiff(gray, bg)
    norm = cv2.normalize(diff, None, 0, 255, cv2.NORM_MINMAX)

    if mode == "darken":
        # Darken faint ink (helps faded rests/stems on aged paper)
        norm = np.clip((norm.astype(np.float32) - 210) * 2.2 + 210, 0, 255).astype(np.uint8)
        # Slight erosion to thicken thin/faded stems & rests
        norm = cv2.erode(norm, np.ones((2, 2), np.uint8), iterations=1)

    # Upscale 2.5x for crisp noteheads (~20-25px)
    h, w = norm.shape[:2]
    scale = max(2.0, 900.0 / max(1, w))
    up = cv2.resize(norm, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_CUBIC)
    # Pad clean white margins so homr detects the staff cleanly
    padded = cv2.copyMakeBorder(up, 80, 80, 80, 80, cv2.BORDER_CONSTANT, value=255)
    return padded


def run_homr_crop(img_gray, work_dir: Path, name: str, expected_q: float):
    p = work_dir / f"{name}.png"
    cv2.imwrite(str(p), img_gray)
    res = subprocess.run(["homr", "--no-title", str(p)], capture_output=True, text=True, timeout=90)
    return score_measure_xml(p.with_suffix(".musicxml"), expected_q)


def main():
    omr_js = (BASE / "omr_data.js").read_text()
    scores = json.loads(omr_js.replace("window.OMR_SCORES = ", "").rstrip(";\n"))
    piano = next(s for s in scores if s["id"] == "image")
    full_img = cv2.imread(str(BASE / piano["image"]))
    H, W = full_img.shape[:2]

    flagged = [m for m in piano["measures"] if m["flags"]]
    print(f"Testing iterative single-measure repair on {len(flagged)} flagged measures of image.png:\n")

    # Group measures by system to grab left clef/key strip when needed
    by_sys = {}
    for m in piano["measures"]:
        by_sys.setdefault(m["system"], []).append(m)

    improved = 0
    resolved = 0

    with tempfile.TemporaryDirectory() as td:
        work = Path(td)
        for m in flagged:
            b = m["bbox"]
            x0, y0 = max(0, int((b["x"] - 0.01) * W)), max(0, int((b["y"] - 0.015) * H))
            x1, y1 = min(W, int((b["x"] + b["w"] + 0.01) * W)), min(H, int((b["y"] + b["h"] + 0.015) * H))
            crop = full_img[y0:y1, x0:x1]

            # Pass 1: Clean 1-measure crop
            p1 = run_homr_crop(preprocess_crop(crop, "clean"), work, f"m{m['number']}_p1", m["expectedBeats"])
            best = p1
            best_pass = "Pass 1 (1-measure clean crop)"

            # Pass 2: Prepend clef+key strip from start of same system + darken faint ink
            if not best or best["conf"] < 0.90:
                sys_m1 = by_sys[m["system"]][0]["bbox"]
                cx0 = max(0, int(sys_m1["x"] * W))
                cx1 = min(W, int((sys_m1["x"] + 0.085) * W))
                clef_strip = full_img[y0:y1, cx0:cx1]
                stitched = np.hstack([clef_strip, crop])
                p2 = run_homr_crop(preprocess_crop(stitched, "darken"), work, f"m{m['number']}_p2", m["expectedBeats"])
                if p2 and (not best or p2["diff"] < best["diff"]):
                    best = p2
                    best_pass = "Pass 2 (clef+key stitched + ink-darken)"

            orig_conf = m["confidence"]
            new_conf = best["conf"] if best else 0.0
            new_actual = best["actual"] if best else 0.0
            status = "RESOLVED" if new_conf >= 0.90 else ("IMPROVED" if new_conf > orig_conf else "STILL UNCERTAIN")
            if new_conf >= 0.90:
                resolved += 1
            if new_conf > orig_conf:
                improved += 1
            print(
                f"M{m['number']:>2} | Before: {m['actualBeats']}q/{m['expectedBeats']}q ({int(orig_conf*100)}%) "
                f"-> After: {new_actual}q/{m['expectedBeats']}q ({int(new_conf*100)}%) [{status}] via {best_pass}"
            )

    print(f"\nSummary: {resolved}/{len(flagged)} fully resolved to 96% conf, {improved}/{len(flagged)} improved.")


if __name__ == "__main__":
    main()
