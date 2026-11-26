import json
import os
import re
import subprocess
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Optional

import cv2
import numpy as np
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from PIL import Image
try:
    import pillow_heif
    pillow_heif.register_heif_opener()
except Exception:
    pass

BASE_DIR = Path(__file__).resolve().parent
UPLOAD_DIR = BASE_DIR / "uploads"
UPLOAD_DIR.mkdir(exist_ok=True)

TYPE_TO_BEATS = {
    "whole": 4.0,
    "half": 2.0,
    "quarter": 1.0,
    "eighth": 0.5,
    "16th": 0.25,
    "32nd": 0.125,
    "64th": 0.0625,
}
STEP_SEMI = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}

app = FastAPI(title="MusicScan OMR MVP")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


def analyze_and_preprocess(img_path: Path, enhance: bool = True) -> dict:
    """Inspect image quality (size, contrast, darkness) and optionally enhance for OMR."""
    img = cv2.imread(str(img_path))
    if img is None:
        raise HTTPException(status_code=400, detail="Could not decode uploaded image.")
    h, w = img.shape[:2]
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    mean_lum = float(np.mean(gray))
    std_lum = float(np.std(gray))
    blur_var = float(cv2.Laplacian(gray, cv2.CV_64F).var())

    warnings = []
    if min(h, w) < 600:
        warnings.append(f"Low resolution ({w}x{h}px) — move closer or scan at 300 DPI to avoid dropped measures.")
    if blur_var < 65.0:
        warnings.append(f"Blurry image detected (sharpness {blur_var:.0f}) — hold steady or retake the blurry row.")
    if mean_lum < 110:
        warnings.append("Image looks dark or shadowed — brighter, even lighting helps prevent missed notes.")
    if std_lum < 28:
        warnings.append("Low contrast detected — auto-contrast enhancement applied.")

    out_path = img_path
    if enhance:
        # Gentle background normalization + contrast boost for uneven lighting
        dilated = cv2.dilate(gray, np.ones((15, 15), np.uint8))
        bg = cv2.medianBlur(dilated, 21)
        diff = 255 - cv2.absdiff(gray, bg)
        norm = cv2.normalize(diff, None, 0, 255, cv2.NORM_MINMAX)
        # Upscale small images so noteheads are >= 14px
        if max(h, w) < 1100:
            scale = 1200.0 / max(h, w)
            norm = cv2.resize(norm, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_CUBIC)
        proc_path = img_path.with_name(img_path.stem + "_proc.png")
        cv2.imwrite(str(proc_path), norm)
        out_path = proc_path

    return {
        "width": w,
        "height": h,
        "meanLuminance": round(mean_lum, 1),
        "contrast": round(std_lum, 1),
        "blurScore": round(blur_var, 1),
        "warnings": warnings,
        "processedPath": out_path,
    }


def parse_homr_output(
    xml_path: Path,
    img_path: Path,
    staff_txt_path: Optional[Path],
    title: str,
    subtitle: str,
    image_url: str,
    override_beats: Optional[int] = None,
    override_beat_type: Optional[int] = None,
    override_fifths: Optional[int] = None,
) -> dict:
    raw_xml = xml_path.read_text(encoding="utf-8")

    class CommentTreeBuilder(ET.TreeBuilder):
        def comment(self, data):
            self.start("xml_comment", {"text": data.strip()})
            self.end("xml_comment")

    root = ET.fromstring(raw_xml, parser=ET.XMLParser(target=CommentTreeBuilder()))
    im = Image.open(img_path)
    img_w, img_h = im.size

    staff_boxes = []
    if staff_txt_path and staff_txt_path.exists():
        for line in staff_txt_path.read_text().splitlines():
            parts = line.strip().split()
            if len(parts) >= 5:
                cx, cy, bw, bh = map(float, parts[1:5])
                staff_boxes.append({
                    "x": max(0.0, cx - bw / 2.0),
                    "y": max(0.0, cy - bh / 2.0),
                    "w": min(1.0, bw),
                    "h": min(1.0, bh),
                })
        staff_boxes.sort(key=lambda b: b["y"])

    part = root.find("part")
    measures_out = []
    cur_divisions = 1
    cur_beats = override_beats or 4
    cur_beat_type = override_beat_type or 4
    cur_fifths = override_fifths if override_fifths is not None else 0
    cur_clefs = {"1": "G", "2": "F"}
    system_idx = 0
    last_imgpos = None

    for m_el in part.findall("measure"):
        m_num = m_el.get("number", str(len(measures_out) + 1))
        print_el = m_el.find("print")
        if print_el is not None and print_el.get("new-system") == "yes" and len(measures_out) > 0:
            system_idx += 1

        for attrs in m_el.findall("attributes"):
            div_el = attrs.find("divisions")
            if div_el is not None and div_el.text:
                cur_divisions = int(div_el.text)
            key_el = attrs.find("key")
            if key_el is not None and override_fifths is None:
                f_el = key_el.find("fifths")
                if f_el is not None and f_el.text:
                    cur_fifths = int(f_el.text)
            time_el = attrs.find("time")
            if time_el is not None and override_beats is None:
                b_el = time_el.find("beats")
                bt_el = time_el.find("beat-type")
                if b_el is not None and bt_el is not None:
                    cur_beats = int(b_el.text)
                    cur_beat_type = int(bt_el.text)
            for clef_el in attrs.findall("clef"):
                c_num = clef_el.get("number", "1")
                cur_clefs[c_num] = clef_el.findtext("sign", "G")

        expected_q = cur_beats * (4.0 / cur_beat_type)
        events = []
        voice_totals = {}
        imgpos_list = []

        for child in m_el:
            if child.tag == "xml_comment":
                m_pos = re.search(r"imgpos:\s*(\d+)\s*,\s*(\d+)", child.get("text", ""))
                if m_pos:
                    last_imgpos = [int(m_pos.group(1)), int(m_pos.group(2))]
            elif child.tag == "note":
                is_chord = child.find("chord") is not None
                is_rest = child.find("rest") is not None
                voice = child.findtext("voice", "1")
                staff = child.findtext("staff", "1")
                ntype = child.findtext("type", "quarter")
                has_dot = child.find("dot") is not None
                dur_el = child.findtext("duration")
                q_dur = TYPE_TO_BEATS.get(ntype, 1.0) * (1.5 if has_dot else 1.0)
                if dur_el is not None and cur_divisions > 0:
                    q_dur_div = int(dur_el) / float(cur_divisions)
                    if q_dur_div > 0:
                        q_dur = q_dur_div

                if is_rest:
                    step, octave, alter = None, None, 0
                else:
                    pitch_el = child.find("pitch")
                    if pitch_el is not None:
                        step = pitch_el.findtext("step", "C")
                        octave = int(pitch_el.findtext("octave", "4"))
                        alter = int(pitch_el.findtext("alter", "0"))
                    else:
                        step, octave, alter = "C", 4, 0

                if not is_chord:
                    voice_totals[voice] = voice_totals.get(voice, 0.0) + q_dur

                ev = {
                    "id": f"m{m_num}_e{len(events)}",
                    "isRest": is_rest,
                    "isChord": is_chord,
                    "step": step,
                    "octave": octave,
                    "alter": alter,
                    "type": ntype,
                    "dot": has_dot,
                    "duration": round(q_dur, 4),
                    "voice": voice,
                    "staff": staff,
                }
                if last_imgpos:
                    ev["imgpos"] = last_imgpos
                    imgpos_list.append(last_imgpos)
                    last_imgpos = None
                events.append(ev)

        flags = []
        confidence = 0.96
        primary_voice = "1" if "1" in voice_totals else (next(iter(voice_totals)) if voice_totals else None)
        actual_q = round(voice_totals.get(primary_voice, 0.0), 3) if primary_voice else 0.0

        if len(events) == 0:
            flags.append("Empty measure detected — retake close-up or add notes")
            confidence = 0.35
        else:
            diff = abs(actual_q - expected_q)
            if diff > 0.05:
                if m_num == "1" and actual_q < expected_q:
                    flags.append(f"Pickup / anacrusis ({actual_q:g} of {expected_q:g} q-beats)")
                    confidence = min(confidence, 0.84)
                else:
                    flags.append(f"Beat-math mismatch: {actual_q:g}q found vs {expected_q:g}q expected ({cur_beats}/{cur_beat_type})")
                    confidence = min(confidence, 0.52 if diff > 0.5 else 0.68)

            prev_midi = None
            leap_count = 0
            for ev in events:
                if not ev["isRest"] and not ev["isChord"] and ev["voice"] == primary_voice and ev["step"]:
                    midi = (ev["octave"] + 1) * 12 + STEP_SEMI.get(ev["step"], 0) + ev["alter"]
                    if prev_midi is not None and abs(midi - prev_midi) >= 18:
                        leap_count += 1
                    prev_midi = midi
            if leap_count >= 2:
                flags.append(f"Unusual octave/register jumps ({leap_count}x) — rescan or verify clef")
                confidence = min(confidence, 0.65)

        bbox = None
        if imgpos_list:
            xs = [p[0] for p in imgpos_list]
            ys = [p[1] for p in imgpos_list]
            bbox = {
                "x": max(0.0, (min(xs) - 25) / img_w),
                "y": max(0.0, (min(ys) - 35) / img_h),
                "w": min(1.0, (max(xs) - min(xs) + 55) / img_w),
                "h": min(1.0, (max(ys) - min(ys) + 70) / img_h),
            }

        measures_out.append({
            "number": int(m_num) if m_num.isdigit() else len(measures_out) + 1,
            "system": system_idx,
            "beats": cur_beats,
            "beatType": cur_beat_type,
            "fifths": cur_fifths,
            "clefs": dict(cur_clefs),
            "expectedBeats": round(expected_q, 3),
            "actualBeats": actual_q,
            "confidence": round(confidence, 2),
            "flags": flags,
            "bbox": bbox,
            "events": events,
        })

    img_gray = cv2.imread(str(img_path), cv2.IMREAD_GRAYSCALE)
    H_im, W_im = img_gray.shape[:2] if img_gray is not None else (img_h, img_w)

    def detect_barline_edges(sx, sy, sw, sh, n_measures):
        if img_gray is None or n_measures <= 1:
            return [round(sx + sw * i / max(1, n_measures), 4) for i in range(n_measures + 1)]
        x0, y0 = max(0, int(sx * W_im)), max(0, int(sy * H_im))
        x1, y1 = min(W_im, int((sx + sw) * W_im)), min(H_im, int((sy + sh) * H_im))
        crop = img_gray[y0:y1, x0:x1]
        ch, cw = crop.shape[:2]
        if ch < 10 or cw < 20:
            return [round(sx + sw * i / n_measures, 4) for i in range(n_measures + 1)]
        bw = cv2.adaptiveThreshold(crop, 255, cv2.ADAPTIVE_THRESH_MEAN_C, cv2.THRESH_BINARY_INV, 25, 12)
        v_kern = cv2.getStructuringElement(cv2.MORPH_RECT, (1, max(8, int(ch * 0.45))))
        v_lines = cv2.morphologyEx(bw, cv2.MORPH_OPEN, v_kern)
        col_score = v_lines.sum(axis=0).astype(float) / (255.0 * ch)
        min_dist = max(12, int(cw / (n_measures * 1.8)))
        cands = []
        for x in range(int(cw * 0.08), int(cw * 0.96)):
            if col_score[x] > 0.25:
                if not cands or x - cands[-1][0] > min_dist:
                    cands.append([x, col_score[x]])
                elif col_score[x] > cands[-1][1]:
                    cands[-1] = [x, col_score[x]]
        need = n_measures - 1
        if len(cands) >= need:
            chosen = sorted(sorted(cands, key=lambda c: -c[1])[:need], key=lambda c: c[0])
            xs = [0] + [c[0] for c in chosen] + [cw]
        else:
            xs = [int(cw * i / n_measures) for i in range(n_measures + 1)]
        return [round((x0 + x) / W_im, 4) for x in xs]

    systems_count = max(1, system_idx + 1)
    by_sys = {}
    for m in measures_out:
        by_sys.setdefault(m["system"], []).append(m)
    for s_idx, ms in by_sys.items():
        if s_idx < len(staff_boxes):
            sb = staff_boxes[s_idx]
            left_pad, top_y, usable_w, row_h = sb["x"], sb["y"], sb["w"], sb["h"]
        else:
            top_pad = 0.08
            usable_h = 0.88
            row_h = (usable_h / systems_count) * 0.85
            top_y = top_pad + s_idx * (usable_h / systems_count)
            left_pad = 0.05
            usable_w = 0.90
        edges = detect_barline_edges(left_pad, top_y, usable_w, row_h, len(ms))
        for i, m in enumerate(ms):
            if m["bbox"] is None:
                m["bbox"] = {
                    "x": edges[i],
                    "y": round(max(0.0, top_y - 0.012), 4),
                    "w": round(max(0.02, edges[i + 1] - edges[i]), 4),
                    "h": round(min(1.0, row_h + 0.024), 4),
                }

    return {
        "id": img_path.stem,
        "title": title,
        "subtitle": subtitle,
        "image": image_url,
        "imgWidth": img_w,
        "imgHeight": img_h,
        "measures": measures_out,
        "stats": {
            "totalMeasures": len(measures_out),
            "flaggedMeasures": sum(1 for m in measures_out if m["flags"]),
            "totalNotes": sum(sum(1 for e in m["events"] if not e["isRest"]) for m in measures_out),
            "avgConfidence": round(sum(m["confidence"] for m in measures_out) / max(1, len(measures_out)), 2),
        },
    }


def detect_torch_device() -> str:
    """Use Apple Silicon MPS on Mac, CUDA if available, otherwise CPU."""
    env_dev = os.environ.get("MUSICSCAN_DEVICE")
    if env_dev:
        return env_dev
    try:
        import torch
        if torch.cuda.is_available():
            return "cuda"
        if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
            return "mps"
    except Exception:
        pass
    return "cpu"


def _split_rest_duration(dur: int, divs: int) -> list[tuple[int, str]]:
    table = [
        (int(4 * divs), "whole"),
        (int(2 * divs), "half"),
        (int(1 * divs), "quarter"),
        (int(0.5 * divs), "eighth"),
        (int(0.25 * divs), "16th"),
        (int(0.125 * divs), "32nd"),
    ]
    out = []
    rem = dur
    for ticks, tname in table:
        if ticks <= 0:
            continue
        while rem >= ticks:
            out.append((ticks, tname))
            rem -= ticks
    return out or [(max(1, dur), "eighth")]


def sanitize_musicxml(xml_path: Path) -> dict:
    """Fix typeless/non-standard filler rests so MuseScore 4 / Dorico import cleanly without corruption warnings."""
    tree = ET.parse(xml_path)
    root = tree.getroot()
    divs = 4
    hidden_rest_measures: set[int] = set()
    fixed_rests = 0

    for part in root.findall("part"):
        for idx_m, m in enumerate(part.findall("measure")):
            m_num = int(m.get("number")) if (m.get("number") or "").isdigit() else (idx_m + 1)
            for attr in m.findall("attributes"):
                d_el = attr.find("divisions")
                if d_el is not None and d_el.text:
                    divs = int(d_el.text)
            for el in list(m):
                if el.tag == "note" and el.find("rest") is not None:
                    if el.get("print-object") == "no":
                        hidden_rest_measures.add(m_num)
                    if el.find("type") is None and el.find("rest").get("measure") != "yes":
                        dur = int(el.findtext("duration", "0"))
                        if dur <= 0:
                            continue
                        voice = el.findtext("voice", "1")
                        staff = el.findtext("staff")
                        po = el.get("print-object")
                        parts = _split_rest_duration(dur, divs)
                        pos = list(m).index(el)
                        m.remove(el)
                        for pi, (ticks, tname) in enumerate(parts):
                            n = ET.Element("note")
                            if po:
                                n.set("print-object", po)
                            ET.SubElement(n, "rest")
                            d_el = ET.SubElement(n, "duration")
                            d_el.text = str(ticks)
                            v_el = ET.SubElement(n, "voice")
                            v_el.text = voice
                            t_el = ET.SubElement(n, "type")
                            t_el.text = tname
                            if staff:
                                s_el = ET.SubElement(n, "staff")
                                s_el.text = staff
                            m.insert(pos + pi, n)
                        fixed_rests += 1

    header = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" '
        '"http://www.musicxml.org/dtds/partwise.dtd">\n'
    )
    ET.indent(root)
    xml_path.write_text(header + ET.tostring(root, encoding="unicode"), encoding="utf-8")
    return {"fixedRests": fixed_rests, "hiddenRestMeasures": sorted(hidden_rest_measures)}


def run_copista(target_img: Path) -> tuple[Path, Optional[Path]]:
    """Run Apache-2.0 copista-28m and return (sanitized_musicxml_path, reading_json_path)."""
    out_dir = target_img.with_name(target_img.stem + "_copista")
    out_dir.mkdir(exist_ok=True)
    device = detect_torch_device()
    cmd = [
        "python3", "-m", "copisteria.pipeline",
        str(target_img),
        "--out", str(out_dir),
        "--device", device,
        "--detector", "28m",
    ]
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=240)
    xml_path = out_dir / f"{target_img.stem}.musicxml"
    reading_path = out_dir / f"{target_img.stem}.reading.json"
    if res.returncode != 0 or not xml_path.exists():
        raise HTTPException(
            status_code=500,
            detail=f"Copista-28m could not read this image. ({res.stderr[-250:] if res.stderr else res.stdout[-250:]})",
        )
    # Copy sanitized MusicXML directly into UPLOAD_DIR for clean serving
    final_xml = UPLOAD_DIR / f"{target_img.stem}_copista28m.musicxml"
    final_xml.write_text(xml_path.read_text(encoding="utf-8"), encoding="utf-8")
    return final_xml, (reading_path if reading_path.exists() else None)


def apply_copista_confidence(score: dict, reading_path: Optional[Path], san_info: dict) -> None:
    """Attach real neural confidence scores & evidence revisions from copista-28m reading.json."""
    hidden_bars = set(san_info.get("hiddenRestMeasures", []))
    rev_by_bar: dict[int, list[str]] = {}
    total_tokens = 0
    low_conf_tokens = 0
    total_revisions = 0

    if reading_path and reading_path.exists():
        rj = json.loads(reading_path.read_text(encoding="utf-8"))
        tokens = rj.get("tokens", {})
        total_tokens = len(tokens)
        low_conf_tokens = sum(1 for v in tokens.values() if v.get("real", {}).get("p", 1.0) < 0.85)
        changes = rj.get("changes", [])
        total_revisions = len(changes)
        for ch in changes:
            bar_idx = ch.get("bar")
            if isinstance(bar_idx, int):
                # copisteria bars are 0-indexed per system; also track class name
                rev_by_bar.setdefault(bar_idx + 1, []).append(ch.get("cls", "symbol"))

    for m in score["measures"]:
        m_num = m["number"]
        if m_num in hidden_bars:
            m["flags"].append("Incomplete bar padded with hidden rest — verify rhythm or edit notes")
            m["confidence"] = min(m["confidence"], 0.72)
        if m_num in rev_by_bar:
            syms = ", ".join(rev_by_bar[m_num][:3])
            m["flags"].append(f"Neural context model revised uncertain symbol ({syms})")
            m["confidence"] = min(m["confidence"], 0.78)

    if total_tokens > 0 and (low_conf_tokens / total_tokens > 0.15 or total_revisions / total_tokens > 0.20):
        score.setdefault("qualityWarnings", []).insert(
            0,
            f"High uncertainty ({low_conf_tokens}/{total_tokens} low-confidence symbols, {total_revisions} revisions) — handwritten or blurry scans may need manual editing or a clearer printed photo.",
        )

    score["stats"]["flaggedMeasures"] = sum(1 for m in score["measures"] if m["flags"])
    score["stats"]["avgConfidence"] = round(
        sum(m["confidence"] for m in score["measures"]) / max(1, len(score["measures"])), 2
    )


def run_homr(target_img: Path) -> tuple[Path, Optional[Path]]:
    cmd = ["homr", "--write-staff-positions", "--no-title", str(target_img)]
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    xml_path = target_img.with_suffix(".musicxml")
    txt_path = target_img.with_suffix(".txt")
    if res.returncode != 0 or not xml_path.exists():
        raise HTTPException(
            status_code=500,
            detail=f"OMR engine could not read this image. Try a flatter, brighter photo. ({res.stderr[-250:] if res.stderr else res.stdout[-250:]})",
        )
    return xml_path, (txt_path if txt_path.exists() else None)


def _run_scan_pipeline(png_path: Path, title: str, engine: str, enhance: bool) -> dict:
    qa = analyze_and_preprocess(png_path, enhance=enhance)
    # Only auto-enhance if explicitly requested OR image is genuinely dark/low-contrast
    use_proc = enhance or qa["meanLuminance"] < 110 or qa["contrast"] < 28
    target_for_omr = qa["processedPath"] if use_proc else png_path

    if engine == "copista":
        xml_path, reading_path = run_copista(target_for_omr)
        san_info = sanitize_musicxml(xml_path)
        score = parse_homr_output(
            xml_path=xml_path,
            img_path=png_path,
            staff_txt_path=None,
            title=title,
            subtitle=f"Copista-28m ({detect_torch_device().upper()}) • {qa['width']}x{qa['height']}px",
            image_url=f"/uploads/{png_path.name}",
        )
        score["qualityWarnings"] = list(qa["warnings"])
        apply_copista_confidence(score, reading_path, san_info)
        score["engine"] = "copista"
        score["musicxmlUrl"] = f"/uploads/{xml_path.name}"
        return score

    xml_path, txt_path = run_homr(target_for_omr)
    score = parse_homr_output(
        xml_path=xml_path,
        img_path=png_path,
        staff_txt_path=txt_path,
        title=title,
        subtitle=f"homr • {qa['width']}x{qa['height']}px",
        image_url=f"/uploads/{png_path.name}",
    )
    score["qualityWarnings"] = list(qa["warnings"])
    score["engine"] = "homr"
    score["musicxmlUrl"] = f"/uploads/{xml_path.name}"
    return score


@app.post("/api/scan")
async def scan_sheet_music(
    file: UploadFile = File(...),
    enhance: bool = Form(False),
    engine: str = Form("copista"),
):
    scan_id = f"scan_{uuid.uuid4().hex[:8]}"
    ext = Path(file.filename or "upload.png").suffix.lower()
    if ext not in {".png", ".jpg", ".jpeg", ".webp", ".heic", ".heif"}:
        ext = ".png"
    raw_path = UPLOAD_DIR / f"{scan_id}{ext}"
    raw_bytes = await file.read()
    raw_path.write_bytes(raw_bytes)

    from PIL import ImageOps
    png_path = UPLOAD_DIR / f"{scan_id}.png"
    im = ImageOps.exif_transpose(Image.open(raw_path)).convert("RGB")
    if max(im.size) > 2200:
        sc = 2200.0 / max(im.size)
        im = im.resize((int(im.size[0] * sc), int(im.size[1] * sc)), Image.Resampling.LANCZOS)
    im.save(png_path)

    score = _run_scan_pipeline(
        png_path=png_path,
        title=Path(file.filename or "Uploaded Score").stem,
        engine=engine,
        enhance=enhance,
    )
    return JSONResponse(score)


@app.post("/api/retry")
async def retry_scan(
    imageUrl: str = Form(...),
    title: str = Form("Retried Score"),
    engine: str = Form("copista"),
    enhance: bool = Form(False),
):
    """Re-run OMR on the currently loaded image with a different engine or photo-cleanup mode."""
    clean_name = imageUrl.lstrip("./").lstrip("/")
    cand = BASE_DIR / clean_name
    if not cand.exists():
        raise HTTPException(status_code=404, detail="Original scan image not found on server.")
    score = _run_scan_pipeline(png_path=cand, title=title, engine=engine, enhance=enhance)
    return JSONResponse(score)



@app.post("/api/rescan-measure")
async def rescan_measure(
    file: Optional[UploadFile] = File(None),
    sourceImage: Optional[str] = Form(None),
    cropX: Optional[float] = Form(None),
    cropY: Optional[float] = Form(None),
    cropW: Optional[float] = Form(None),
    cropH: Optional[float] = Form(None),
    beats: int = Form(4),
    beatType: int = Form(4),
    fifths: int = Form(0),
):
    """Re-scan a single low-confidence measure from either a new close-up photo OR a squared crop of the original scan."""
    rescan_id = f"rescan_{uuid.uuid4().hex[:8]}"
    crop_path = UPLOAD_DIR / f"{rescan_id}.png"

    if file is not None:
        raw_bytes = await file.read()
        tmp_path = UPLOAD_DIR / f"{rescan_id}_raw.png"
        tmp_path.write_bytes(raw_bytes)
        im = Image.open(tmp_path).convert("RGB")
    elif sourceImage and cropX is not None and cropY is not None and cropW is not None and cropH is not None:
        # Locate source image safely inside BASE_DIR or UPLOAD_DIR
        clean_name = sourceImage.lstrip("./").lstrip("/")
        cand = BASE_DIR / clean_name
        if not cand.exists():
            raise HTTPException(status_code=404, detail="Source scan image not found.")
        full_im = Image.open(cand).convert("RGB")
        fw, fh = full_im.size
        # Add slight horizontal padding so homr sees staff context cleanly
        x0 = max(0, int((cropX - 0.02) * fw))
        y0 = max(0, int((cropY - 0.02) * fh))
        x1 = min(fw, int((cropX + cropW + 0.02) * fw))
        y1 = min(fh, int((cropY + cropH + 0.02) * fh))
        im = full_im.crop((x0, y0, x1, y1))
    else:
        raise HTTPException(status_code=400, detail="Provide either a close-up photo or a crop rectangle.")

    # Upscale & add clean white border padding so homr detects the isolated staff reliably
    cw, ch = im.size
    if cw < 900:
        scale = 900.0 / max(1, cw)
        im = im.resize((int(cw * scale), int(ch * scale)), Image.Resampling.LANCZOS)
    pad = 80
    padded = Image.new("RGB", (im.width + pad * 2, im.height + pad * 2), (255, 255, 255))
    padded.paste(im, (pad, pad))
    padded.save(crop_path)

    qa = analyze_and_preprocess(crop_path, enhance=True)
    xml_path, txt_path = run_homr(qa["processedPath"])

    parsed = parse_homr_output(
        xml_path=xml_path,
        img_path=crop_path,
        staff_txt_path=txt_path,
        title="Rescanned Measure",
        subtitle="Close-up rescan",
        image_url=f"/uploads/{crop_path.name}",
        override_beats=beats,
        override_beat_type=beatType,
        override_fifths=fifths,
    )
    if not parsed["measures"]:
        raise HTTPException(status_code=422, detail="No notes detected in the close-up. Try framing the full staff height.")

    # Pick the measure with the most notes / best match from the close-up
    best_m = max(parsed["measures"], key=lambda m: (len(m["events"]), m["confidence"]))
    return JSONResponse({
        "events": best_m["events"],
        "confidence": best_m["confidence"],
        "flags": best_m["flags"],
        "actualBeats": best_m["actualBeats"],
        "expectedBeats": best_m["expectedBeats"],
        "cropPreviewUrl": f"/uploads/{crop_path.name}",
        "warnings": qa["warnings"],
    })


@app.post("/api/rescan-row")
async def rescan_row(
    file: UploadFile = File(...),
    systemIdx: int = Form(0),
    beats: int = Form(4),
    beatType: int = Form(4),
    fifths: int = Form(0),
):
    """Re-scan an entire horizontal system (1 row across the page) — proven 7/7 clean recovery vs 0/8 on single-bar crops."""
    row_id = f"row_{uuid.uuid4().hex[:8]}"
    raw_path = UPLOAD_DIR / f"{row_id}_raw.png"
    row_path = UPLOAD_DIR / f"{row_id}.png"
    raw_path.write_bytes(await file.read())
    im = Image.open(raw_path).convert("RGB")
    pad = 70
    padded = Image.new("RGB", (im.width + pad * 2, im.height + pad * 2), (248, 245, 240))
    padded.paste(im, (pad, pad))
    padded.save(row_path)

    qa = analyze_and_preprocess(row_path, enhance=False)
    xml_path, reading_path = run_copista(row_path)
    san_info = sanitize_musicxml(xml_path)
    parsed = parse_homr_output(
        xml_path=xml_path,
        img_path=row_path,
        staff_txt_path=None,
        title=f"System {systemIdx + 1}",
        subtitle="Full-row retake (Copista-28m)",
        image_url=f"/uploads/{row_path.name}",
        override_beats=beats,
        override_beat_type=beatType,
        override_fifths=fifths,
    )
    apply_copista_confidence(parsed, reading_path, san_info)
    if not parsed["measures"]:
        raise HTTPException(status_code=422, detail="Could not read this row. Make sure the full horizontal staff line is sharp and in frame.")

    for m in parsed["measures"]:
        m["system"] = systemIdx
    return JSONResponse({
        "systemIdx": systemIdx,
        "measures": parsed["measures"],
        "warnings": qa["warnings"],
        "blurScore": qa["blurScore"],
    })


def _order_quad_points(pts: np.ndarray) -> np.ndarray:
    """Order 4 points as [top-left, top-right, bottom-right, bottom-left]."""
    rect = np.zeros((4, 2), dtype="float32")
    s = pts.sum(axis=1)
    rect[0] = pts[np.argmin(s)]
    rect[2] = pts[np.argmax(s)]
    diff = np.diff(pts, axis=1)
    rect[1] = pts[np.argmin(diff)]
    rect[3] = pts[np.argmax(diff)]
    return rect


def detect_page_quad(img_path: Path) -> tuple[list[list[float]], bool]:
    """Auto-detect the 4 corners of a sheet music page in a photo. Returns (normalized_corners, auto_found)."""
    img = cv2.imread(str(img_path))
    if img is None:
        return [[0.04, 0.04], [0.96, 0.04], [0.96, 0.96], [0.04, 0.96]], False
    h, w = img.shape[:2]
    scale = 800.0 / max(h, w)
    small = cv2.resize(img, (max(1, int(w * scale)), max(1, int(h * scale))))
    sh, sw = small.shape[:2]
    gray = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY)
    blur = cv2.GaussianBlur(gray, (5, 5), 0)

    # Try Canny + adaptive threshold contours to find the largest bright/paper quadrilateral
    best_quad = None
    best_area = 0.0
    min_area = 0.18 * sw * sh
    max_area = 0.97 * sw * sh

    for edges in [
        cv2.dilate(cv2.Canny(blur, 40, 140), np.ones((3, 3), np.uint8), iterations=2),
        cv2.morphologyEx(cv2.threshold(blur, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)[1], cv2.MORPH_CLOSE, np.ones((9, 9), np.uint8)),
    ]:
        cnts, _ = cv2.findContours(edges, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        for c in sorted(cnts, key=cv2.contourArea, reverse=True)[:6]:
            area = cv2.contourArea(c)
            if area < min_area or area > max_area:
                continue
            peri = cv2.arcLength(c, True)
            approx = cv2.approxPolyDP(c, 0.025 * peri, True)
            if len(approx) == 4 and area > best_area:
                best_area = area
                best_quad = approx.reshape(4, 2).astype("float32")

    if best_quad is not None:
        ordered = _order_quad_points(best_quad)
        norm = [[round(float(x / sw), 4), round(float(y / sh), 4)] for x, y in ordered]
        return norm, True

    return [[0.04, 0.04], [0.96, 0.04], [0.96, 0.96], [0.04, 0.96]], False


@app.post("/api/detect-page")
async def api_detect_page(imageUrl: str = Form(...)):
    clean_name = imageUrl.lstrip("./").lstrip("/")
    cand = BASE_DIR / clean_name
    if not cand.exists():
        raise HTTPException(status_code=404, detail="Original scan image not found on server.")
    corners, auto_found = detect_page_quad(cand)
    return JSONResponse({"corners": corners, "autoFound": auto_found})


@app.post("/api/flatten-page")
async def api_flatten_page(
    imageUrl: str = Form(...),
    corners: str = Form(...),
    title: str = Form("Flattened Scan"),
    engine: str = Form("copista"),
    enhance: bool = Form(False),
):
    """Apply 4-point perspective warp to square/flatten a tilted page photo, then transcribe it."""
    clean_name = imageUrl.lstrip("./").lstrip("/")
    cand = BASE_DIR / clean_name
    if not cand.exists():
        raise HTTPException(status_code=404, detail="Original scan image not found on server.")

    pts_norm = json.loads(corners)
    if not isinstance(pts_norm, list) or len(pts_norm) != 4:
        raise HTTPException(status_code=400, detail="Expected exactly 4 corner points.")

    img = cv2.imread(str(cand))
    if img is None:
        raise HTTPException(status_code=400, detail="Could not read source image.")
    h, w = img.shape[:2]

    src_pts = np.array([[p[0] * w, p[1] * h] for p in pts_norm], dtype="float32")
    src_pts = _order_quad_points(src_pts)
    tl, tr, br, bl = src_pts

    width_a = np.linalg.norm(br - bl)
    width_b = np.linalg.norm(tr - tl)
    max_w = max(600, int(max(width_a, width_b)))

    height_a = np.linalg.norm(tr - br)
    height_b = np.linalg.norm(tl - bl)
    max_h = max(600, int(max(height_a, height_b)))

    dst_pts = np.array([[0, 0], [max_w - 1, 0], [max_w - 1, max_h - 1], [0, max_h - 1]], dtype="float32")
    M = cv2.getPerspectiveTransform(src_pts, dst_pts)
    warped = cv2.warpPerspective(img, M, (max_w, max_h), flags=cv2.INTER_CUBIC, borderMode=cv2.BORDER_REPLICATE)

    flat_id = f"flat_{uuid.uuid4().hex[:8]}"
    flat_path = UPLOAD_DIR / f"{flat_id}.png"
    cv2.imwrite(str(flat_path), warped)

    score = _run_scan_pipeline(
        png_path=flat_path,
        title=title if "(Squared)" in title else f"{title} (Squared)",
        engine=engine,
        enhance=enhance,
    )
    return JSONResponse(score)


@app.get("/")
def serve_index():
    return FileResponse(BASE_DIR / "index.html")


app.mount("/uploads", StaticFiles(directory=str(UPLOAD_DIR)), name="uploads")
app.mount("/", StaticFiles(directory=str(BASE_DIR)), name="static")
