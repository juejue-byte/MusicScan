import json
import os
import re
import xml.etree.ElementTree as ET
from PIL import Image

OMR_DIR = "/home/antigravity/.gemini/jetski/brain/v1/default/jetski_remote_agents_3p_devbox/075a5e39-3a89-4187-8926-10eb74239b21/scratch/omr"
ART_DIR = "/home/antigravity/.gemini/jetski/brain/v1/default/jetski_remote_agents_3p_devbox/075a5e39-3a89-4187-8926-10eb74239b21"

TYPE_TO_BEATS = {
    "whole": 4.0,
    "half": 2.0,
    "quarter": 1.0,
    "eighth": 0.5,
    "16th": 0.25,
    "32nd": 0.125,
    "64th": 0.0625,
}

def parse_musicxml(xml_path, img_path, title, subtitle):
    with open(xml_path, "r", encoding="utf-8") as f:
        raw_xml = f.read()

    # Extract imgpos comments if present: <!-- imgpos: x, y -->
    # ElementTree skips comments by default unless we use a custom parser, so let's parse with XMLParser(target=...)
    class CommentTreeBuilder(ET.TreeBuilder):
        def comment(self, data):
            self.start("xml_comment", {"text": data.strip()})
            self.end("xml_comment")

    root = ET.fromstring(raw_xml, parser=ET.XMLParser(target=CommentTreeBuilder()))
    im = Image.open(img_path)
    img_w, img_h = im.size

    # Read staff positions txt if present (YOLO format: class cx cy w h)
    staff_txt = os.path.splitext(img_path)[0] + ".txt"
    staff_boxes = []
    if os.path.exists(staff_txt):
        with open(staff_txt) as sf:
            for line in sf:
                parts = line.strip().split()
                if len(parts) >= 5:
                    cx, cy, w, h = map(float, parts[1:5])
                    staff_boxes.append({
                        "x": max(0.0, cx - w / 2.0),
                        "y": max(0.0, cy - h / 2.0),
                        "w": min(1.0, w),
                        "h": min(1.0, h),
                    })
        staff_boxes.sort(key=lambda b: b["y"])

    part = root.find("part")
    measures_out = []
    cur_divisions = 1
    cur_beats = 4
    cur_beat_type = 4
    cur_fifths = 0
    cur_clefs = {"1": "G", "2": "F"}
    system_idx = 0
    last_imgpos = None

    for m_el in part.findall("measure"):
        m_num = m_el.get("number", str(len(measures_out) + 1))
        print_el = m_el.find("print")
        if print_el is not None and print_el.get("new-system") == "yes" and len(measures_out) > 0:
            system_idx += 1

        attrs = m_el.find("attributes")
        if attrs is not None:
            div_el = attrs.find("divisions")
            if div_el is not None and div_el.text:
                cur_divisions = int(div_el.text)
            key_el = attrs.find("key")
            if key_el is not None:
                f_el = key_el.find("fifths")
                if f_el is not None and f_el.text:
                    cur_fifths = int(f_el.text)
            time_el = attrs.find("time")
            if time_el is not None:
                b_el = time_el.find("beats")
                bt_el = time_el.find("beat-type")
                if b_el is not None and bt_el is not None:
                    cur_beats = int(b_el.text)
                    cur_beat_type = int(bt_el.text)
            for clef_el in attrs.findall("clef"):
                c_num = clef_el.get("number", "1")
                sign = clef_el.findtext("sign", "G")
                cur_clefs[c_num] = sign

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

        # Compute confidence & flags based on real beat-math & OMR heuristics
        flags = []
        confidence = 0.96
        primary_voice = "1" if "1" in voice_totals else (next(iter(voice_totals)) if voice_totals else None)
        actual_q = round(voice_totals.get(primary_voice, 0.0), 3) if primary_voice else 0.0

        if len(events) == 0:
            flags.append("Empty measure detected")
            confidence = 0.35
        else:
            diff = abs(actual_q - expected_q)
            if diff > 0.05:
                # Allow pickup measure on measure 1 if shorter
                if m_num == "1" and actual_q < expected_q:
                    flags.append(f"Pickup / anacrusis ({actual_q:g} of {expected_q:g} beats)")
                    confidence = min(confidence, 0.84)
                else:
                    flags.append(f"Beat-math mismatch: {actual_q:g} beats found vs {expected_q:g} expected ({cur_beats}/{cur_beat_type})")
                    confidence = min(confidence, 0.52 if diff > 0.5 else 0.68)

            # Check for extreme pitch leaps (> 16 semitones in same voice, non-chord)
            prev_midi = None
            leap_count = 0
            STEP_SEMI = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
            for ev in events:
                if not ev["isRest"] and not ev["isChord"] and ev["voice"] == primary_voice and ev["step"]:
                    midi = (ev["octave"] + 1) * 12 + STEP_SEMI.get(ev["step"], 0) + ev["alter"]
                    if prev_midi is not None and abs(midi - prev_midi) >= 18:
                        leap_count += 1
                    prev_midi = midi
            if leap_count >= 2:
                flags.append(f"Unusual octave/register jumps ({leap_count}x) — check clef or ledger lines")
                confidence = min(confidence, 0.65)

            # Check if multi-voice duration discrepancy
            if len(voice_totals) > 1:
                v_vals = list(voice_totals.values())
                if max(v_vals) - min(v_vals) > 0.5:
                    flags.append("Voice alignment drift between upper/lower voices")
                    confidence = min(confidence, 0.72)

        # Estimate bounding box on original image if imgpos exists
        bbox = None
        if imgpos_list:
            xs = [p[0] for p in imgpos_list]
            ys = [p[1] for p in imgpos_list]
            bbox = {
                "x": max(0, (min(xs) - 25) / img_w),
                "y": max(0, (min(ys) - 35) / img_h),
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

    # Assign normalized bboxes from detected staff boxes if imgpos wasn't emitted
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
        col_w = usable_w / max(1, len(ms))
        for i, m in enumerate(ms):
            if m["bbox"] is None:
                m["bbox"] = {
                    "x": round(left_pad + i * col_w, 4),
                    "y": round(max(0.0, top_y - 0.012), 4),
                    "w": round(col_w, 4),
                    "h": round(min(1.0, row_h + 0.024), 4),
                }

    return {
        "id": os.path.splitext(os.path.basename(img_path))[0],
        "title": title,
        "subtitle": subtitle,
        "image": os.path.basename(img_path),
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

if __name__ == "__main__":
    scores = [
        parse_musicxml(
            f"{OMR_DIR}/image_2.musicxml",
            f"{OMR_DIR}/image_2.png",
            "Posta Kürtjelei (Printed Monophonic)",
            "image_2.png • Printed horn signals (3/8 & 6/8) — Best OMR case",
        ),
        parse_musicxml(
            f"{OMR_DIR}/image.musicxml",
            f"{OMR_DIR}/image.png",
            "Vintage Piano Score (Printed Polyphonic)",
            "image.png • Aged paper, 3 flats, dense chords & articulations",
        ),
        parse_musicxml(
            f"{OMR_DIR}/image_3.musicxml",
            f"{OMR_DIR}/image_3.png",
            "Lied ohne Worte (Handwritten Antique)",
            "image_3.png • Tilted camera photo of handwritten piano score — Stress test",
        ),
    ]
    out_path = f"{OMR_DIR}/parsed_scores.json"
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(scores, f, indent=2)
    for s in scores:
        print(s["id"], s["stats"])
