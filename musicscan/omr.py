"""OMR via KobiMusic's copisteria (Apache-2.0, https://github.com/kobimusic/copisteria).

transcribe(PIL image) -> MusicXML + per-measure confidence, bar boxes on the page, page-level stats.
Models are loaded once and reused. Calls are serialized with a lock (the reader uses process-wide env vars)."""
from __future__ import annotations

import os
import tempfile
import threading
import time
from pathlib import Path

import numpy as np
from PIL import Image

COPISTERIA_ROOT = Path(os.environ.get("COPISTERIA_ROOT", "/home/user/ext/copisteria"))
LOW = 0.85            # a reading head below this probability makes the symbol "uncertain"
_LOCK = threading.Lock()
_MODEL = {}
_DETS = {}

# heads whose mistakes change what you hear or see
HEADS = ("cls", "pos", "dots", "alter")


def pick_device() -> str:
    """Where the detector runs: MUSICSCAN_DEVICE (cpu/mps/cuda) or the fastest one available."""
    if _DEV:
        return _DEV[0]
    import torch
    want = os.environ.get("MUSICSCAN_DEVICE", "auto")
    if want == "auto":
        want = "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"
    _DEV.append(want)
    return want


_DEV: list[str] = []


def _setup():
    import sys
    src = COPISTERIA_ROOT / "src"
    if str(src) not in sys.path:
        sys.path.insert(0, str(src))
    import torch
    torch.set_num_threads(max(1, os.cpu_count() or 1))
    from copisteria import detect, read
    if "evidence" not in _MODEL:
        from copisteria.paths import EVIDENCE
        _MODEL["evidence"] = read.load_model(EVIDENCE, "cpu")
    if not getattr(detect, "_musicscan_patched", False):
        Orig = detect.Detector

        def cached(weights=None, device=None):
            key = (str(weights), os.environ.get("COPISTERIA_DETECTOR", "28m"))
            key = key + (pick_device(),)
            if key not in _DETS:
                _DETS[key] = Orig(weights, pick_device())
            return _DETS[key]
        detect.Detector = cached
        detect._musicscan_patched = True
    return _MODEL["evidence"]


def token_conf(r: dict) -> float:
    real = r.get("real", {})
    p_real = float(real.get("p", 1.0))
    c = max(p_real, 1 - p_real)
    for k in HEADS:
        v = r.get(k)
        if isinstance(v, dict) and "p" in v:
            c = min(c, float(v["p"]))
    return c


_FIRST: dict = {}          # (detector, page hash) -> that detector's 2048 px pass, so the second reading reuses it
SPACE_SURE = 0.12          # take the small detector's staff-space check only when it is this close to the ink's


def page_inputs(png: Path, model):
    """(dets, cands, feats) for a page, exactly as copisteria's pipeline.inputs reads them, but faster.

    copisteria reads a page twice with the big detector: once at 2048 px only to measure the staff space from its
    measure boxes (to confirm the staff-line finder's spacing), then again at the size that spacing asks for, throwing
    the first pass away. That measuring pass is ~6 s of a ~13 s reading on a 4-core CPU. Here the small detector
    (copista-2m, ~0.8 s) does the measuring when the staff lines were found and its boxes agree with them closely
    (well inside copisteria's own 25% tolerance), so the big detector runs once at the size copisteria would have
    chosen. Its 2048 pass is kept for the second reading, which runs the small detector anyway. When the check is not
    clear-cut, or the page is read at 2048 px, it falls back to copisteria's own steps. MUSICSCAN_FAST_INPUTS=0 turns it
    off."""
    import hashlib
    import json
    from copisteria import pipeline
    from copisteria.paths import DETECTORS
    name = os.environ.get("COPISTERIA_DETECTOR", "28m")
    if getattr(model, "feat_dim", 0) or os.environ.get("MUSICSCAN_FAST_INPUTS", "1") == "0" or name not in DETECTORS:
        return pipeline.inputs(png, model)
    from copisteria.detect import Detector, imgsz_for, measure_space, staff_space, SPACE_AGREE
    from copisteria.vision.page.scan import from_png
    from copisteria.vision.page.staves import find_staves
    with Image.open(png) as im:
        im = im.convert("L")
    key = hashlib.md5(im.tobytes() + repr(im.size).encode()).hexdigest()
    long_side = max(im.width, im.height)
    ink = find_staves(from_png(png).image()).spacing

    def first_pass(det_name):
        k = (det_name, key)
        if k not in _FIRST:
            det = Detector(DETECTORS[det_name][0])
            arr, s = det.prepare(im, 2048)
            _FIRST[k] = json.dumps(det.run_array(arr, s))
            while len(_FIRST) > 8:
                _FIRST.pop(next(iter(_FIRST)))
        return json.loads(_FIRST[k])        # a fresh copy each time, as copisteria's JSON cache gives

    det = Detector(DETECTORS[name][0])
    first = None
    if name != "2m" and ink > 0:
        boxes = measure_space(first_pass("2m"))
        if boxes > 0 and abs(ink / boxes - 1) <= SPACE_SURE < SPACE_AGREE:
            imgsz = imgsz_for(ink, long_side)        # staff_space(ink, boxes) == ink for any boxes this close
            if imgsz != 2048:
                arr, s = det.prepare(im, imgsz)
                return det.run_array(arr, s), None, None
    first = first_pass(name)
    imgsz = imgsz_for(staff_space(ink, measure_space(first)), long_side)
    if imgsz == 2048:
        return first, None, None
    arr, s = det.prepare(im, imgsz)
    return det.run_array(arr, s), None, None


def transcribe(im: Image.Image, detector: str = "28m") -> dict:
    t0 = time.time()
    with _LOCK:
        model = _setup()
        os.environ["COPISTERIA_DETECTOR"] = detector
        from copisteria import pipeline, write
        from copisteria.revise import read_revised
        pipeline._DET[:] = []
        with tempfile.TemporaryDirectory() as td:
            png = Path(td) / "page.png"
            g = im.convert("L")
            g.save(png)
            try:
                dets, cands, feats = page_inputs(png, model)
            except (RuntimeError, NotImplementedError):
                if pick_device() == "cpu":
                    raise
                # an op the GPU backend lacks: fall back to the CPU for the rest of this run
                _DEV[:] = ["cpu"]
                pipeline._DET[:] = []
                dets, cands, feats = page_inputs(png, model)
            rd = read_revised(dets, g.width, g.height, model, device="cpu", attention=False, image=g,
                              cands=cands, feats=feats)
            xml = write.write(rd, image=g)
    out = analyse(rd)
    xml = add_system_breaks(xml, [s["measures"][0] for s in out["systems"][1:] if s["measures"]])
    xml = add_bar_signs(xml, out.get("bar_signs", []))
    xml = merge_slivers(out, xml)
    out["xml"] = restore_bar_rests(fix_pickup(xml))
    out["seconds"] = round(time.time() - t0, 1)
    out["detector"] = detector
    out["device"] = pick_device()
    out["size"] = [im.width, im.height]
    return out


def merge_slivers(out: dict, xml: str) -> str:
    """A bar with no notes or rests in any part that is much narrower than the other bars of its row is not a bar:
    it is the space between a start-repeat sign and the clef, or the gap inside a double bar line read as two bar
    lines. It shifts every later bar by one. Fold it into the bar after it (or before it, at the end of a row):
    its clef, key, time and bar lines move there. Updates out["measures"] and out["systems"] to match."""
    from lxml import etree
    meas = out.get("measures") or []
    try:
        root = etree.fromstring(xml.encode())
    except etree.XMLSyntaxError:
        return xml
    parts = root.findall("part")
    if not parts or any(len(p.findall("measure")) != len(meas) for p in parts):
        return xml
    width = lambda m: (m["bbox"][2] - m["bbox"][0]) if m.get("bbox") else 0  # noqa: E731
    drop = []
    for i, m in enumerate(meas):
        row = [width(x) for x in meas if x["system"] == m["system"] and x is not m]
        if not row or width(m) >= 0.4 * float(np.median(row)):
            continue
        if any(p.findall("measure")[i].find("note") is not None for p in parts):
            continue
        same_next = i + 1 < len(meas) and meas[i + 1]["system"] == m["system"]
        same_prev = i > 0 and meas[i - 1]["system"] == m["system"]
        if same_next or same_prev:
            drop.append((i, i + 1 if same_next else i - 1))
    if not drop:
        return xml
    for p in parts:
        ms = p.findall("measure")
        for i, j in drop:
            src, dst = ms[i], ms[j]
            keep = [el for el in src if el.tag not in ("note", "backup", "forward")]
            if j > i:                        # leading attributes, print and left bar lines go to the start
                for k, el in enumerate(keep):
                    if el.tag == "barline" and el.get("location", "right") == "right":
                        el.set("location", "left")
                    dst.insert(k, el)
                if src.get("implicit"):
                    dst.set("implicit", src.get("implicit"))
            else:
                for el in keep:
                    if el.tag == "barline" and el.get("location") == "left":
                        el.set("location", "right")
                    dst.append(el)
            p.remove(src)
        for k, m in enumerate(p.findall("measure"), 1):
            m.set("number", str(k))
    gone = {i for i, _ in drop}
    keep_meta = [m for i, m in enumerate(meas) if i not in gone]
    new_index = {m["index"]: k for k, m in enumerate(keep_meta)}
    for k, m in enumerate(keep_meta):
        m["index"] = k
    out["measures"] = keep_meta
    for sy in out.get("systems", []):
        sy["measures"] = [new_index[i] for i in sy["measures"] if i in new_index]
    out["merged_slivers"] = sorted(gone)
    if isinstance(out.get("stats"), dict) and "measures" in out["stats"]:
        out["stats"]["measures"] = len(keep_meta)
    head = xml[: xml.find("<score-partwise")] if "<score-partwise" in xml else ""
    return head + etree.tostring(root, encoding="unicode")


def sharpen(im: Image.Image) -> Image.Image:
    from PIL import ImageFilter
    return im.filter(ImageFilter.UnsharpMask(radius=2, percent=200, threshold=2))


def plausibility(r: dict) -> float:
    """How believable a reading's layout is, from 0 to 2: rows of a page hold similar numbers of bars (the last row
    may be short), plus the share of bars whose voices add up to the time signature. A reading that split or merged
    rows scores low on both."""
    per = [len(sy["measures"]) for sy in r.get("systems", [])]
    rows = per[:-1] if len(per) >= 3 else per
    even = min(rows) / max(rows) if rows and max(rows) else 0.0
    ok = bars_add_up(r["xml"]) or []
    return even + (sum(ok) / len(ok) if ok else 0.0)


def transcribe_checked(im: Image.Image, detector: str = "28m") -> tuple[dict, Image.Image]:
    """Read the page, and read it again sharpened when layout plausibility leaves room to improve.
    On a slightly soft phone photo the reader can lose which staves belong to one row (a piano page then splits
    into twice the rows, or bars vanish) while every symbol is still found. Sharpening usually restores that,
    so when the two readings find a different number of bars, the one whose layout is more believable
    (plausibility) is kept. When the first pass already achieves near-perfect plausibility and high confidence,
    the redundant sharpened pass is skipped to cut GPU latency roughly in half."""
    r = transcribe(im, detector=detector)
    a = len(r["measures"])
    st = r.get("stats") or {}
    pr = plausibility(r) if a > 0 else 0.0
    already_clean = (
        a > 0
        and not any(m.get("doubled") for m in r.get("measures", []))
        and (
            pr >= 1.999
            or (pr >= 1.96 and float(st.get("mean_conf", 0.0)) >= 0.96 and float(st.get("low_frac", 1.0)) < 0.02)
        )
    )
    if already_clean:
        r["layout_check"] = {"bars": [a, a], "used": "original", "skipped": True}
        return r, im
    sim = sharpen(im)
    s = transcribe(sim, detector=detector)
    b = len(s["measures"])
    secs = round(r["seconds"] + s["seconds"], 1)
    if a != b and plausibility(s) > pr:
        s["layout_check"] = {"bars": [a, b], "used": "sharpened"}
        s["seconds"] = secs
        return s, sim
    r["layout_check"] = {"bars": [a, b], "used": "original"}
    r["seconds"] = secs
    return r, im


def restore_bar_rests(xml: str) -> str:
    """A bar the reader left completely empty (only a <forward> of silence) is almost always a whole-bar rest it did
    not pick up. Write it back as a visible bar rest on every staff, so the page looks like the original."""
    from lxml import etree
    try:
        root = etree.fromstring(xml.encode())
    except etree.XMLSyntaxError:
        return xml
    changed = False
    for part in root.iter("part"):
        staves, div, beats, btype = 1, 1, 4, 4
        for m in part.findall("measure"):
            a = m.find("attributes")
            if a is not None:
                staves = int(a.findtext("staves", staves))
                div = int(float(a.findtext("divisions", div)))
                beats = int(a.findtext("time/beats", beats))
                btype = int(a.findtext("time/beat-type", btype))
            if m.find("note") is not None or m.get("implicit") == "yes":
                continue
            fw = m.findall("forward")
            length = beats * 4 * div // btype
            if not fw or sum(int(f.findtext("duration", "0")) for f in fw) != length:
                continue
            for f in fw:
                m.remove(f)
            for st in range(1, staves + 1):
                if st > 1:
                    b = etree.SubElement(m, "backup")
                    etree.SubElement(b, "duration").text = str(length)
                n = etree.SubElement(m, "note")
                etree.SubElement(n, "rest").set("measure", "yes")
                etree.SubElement(n, "duration").text = str(length)
                etree.SubElement(n, "voice").text = str(1 if st == 1 else 5)
                if staves > 1:
                    etree.SubElement(n, "staff").text = str(st)
            changed = True
    if not changed:
        return xml
    head = xml[: xml.find("<score-partwise")] if "<score-partwise" in xml else ""
    return head + etree.tostring(root, encoding="unicode")


def fix_pickup(xml: str) -> str:
    """A pickup (anacrusis) bar comes back padded with hidden rests to a full bar, which makes playback wait before
    the second bar. When the first bar's printed content is shorter than the time signature in every part, drop the
    hidden padding and mark the bar implicit, the way MusicXML writes a pickup."""
    from lxml import etree
    try:
        root = etree.fromstring(xml.encode())
    except etree.XMLSyntaxError:
        return xml
    parts = root.findall("part")
    firsts = [pt.find("measure") for pt in parts]
    if not parts or any(m is None for m in firsts):
        return xml
    dur = lambda el: int(float(el.findtext("duration", "0") or 0))  # noqa: E731
    ends, bar = [], None
    for m in firsts:
        div, cur, last, end = 1, 0, 0, 0
        for el in m:
            if el.tag == "attributes":
                if el.findtext("divisions"):
                    div = int(float(el.findtext("divisions")))
                if el.findtext("time/beats"):
                    bar = (int(el.findtext("time/beats")), int(el.findtext("time/beat-type")), div)
            elif el.tag == "backup":
                cur -= dur(el)
            elif el.tag == "forward":
                cur += dur(el)
            elif el.tag == "note":
                chord = el.find("chord") is not None
                start = last if chord else cur
                if el.get("print-object") != "no" and el.find("grace") is None:
                    end = max(end, start + dur(el))
                if not chord:
                    last, cur = cur, cur + dur(el)
        ends.append((end, div))
    if bar is None:
        return xml
    full = [bar[0] * 4 * d // bar[1] for _, d in ends]
    if not all(0 < e < f for (e, _), f in zip(ends, full)):
        return xml
    for m, (E, _) in zip(firsts, ends):
        oc = nc = last = 0
        for el in list(m):
            if el.tag == "backup":
                target = oc - dur(el)
                oc = target
                el.find("duration").text = str(nc - min(target, E))
                nc = min(target, E)
            elif el.tag == "forward":
                if oc >= E:
                    m.remove(el)
                else:
                    nc += dur(el)
                oc += dur(el)
            elif el.tag == "note":
                chord = el.find("chord") is not None
                if chord:
                    continue
                d = dur(el)
                if oc >= E and el.get("print-object") == "no" and el.find("rest") is not None:
                    m.remove(el)
                else:
                    nc += d
                oc += d
        m.set("implicit", "yes")
    for pt in parts:
        for i, m in enumerate(pt.findall("measure")):
            m.set("number", str(i))
    head = xml[: xml.find("<score-partwise")] if "<score-partwise" in xml else ""
    return head + etree.tostring(root, encoding="unicode")


def add_system_breaks(xml: str, starts: list[int]) -> str:
    """Mark where each line of music starts on the photo (<print new-system="yes"/>), so the file keeps the
    original line breaks in notation programs and in the editor."""
    from lxml import etree
    try:
        root = etree.fromstring(xml.encode())
    except etree.XMLSyntaxError:
        return xml
    want = set(starts)
    for part in root.iter("part"):
        for mi, m in enumerate(part.findall("measure")):
            if mi not in want:
                continue
            pr = m.find("print")
            if pr is None:
                pr = etree.Element("print")
                m.insert(0, pr)
            pr.set("new-system", "yes")
    head = xml[: xml.find("<score-partwise")] if "<score-partwise" in xml else ""
    return head + etree.tostring(root, encoding="unicode")


RIGHT_SIGNS = {"barLine_repeat_end": ("light-heavy", "backward"), "barLine_final": ("light-heavy", None),
               "barLine_double": ("light-light", None)}


def bar_signs(rd, first, n_meas) -> list:
    """[global bar, sign class] for bar-closing signs (end repeat, final, double bar line), placed at the bar
    line they stand on. The writer assigns a sign to the bar whose box holds its centre; a repeat sign drawn
    right on the bar line can land in the next bar and be dropped (the choir sample lost its repeat this way)."""
    L = rd.layout
    out = {}
    for s in L.syms:
        tok = rd.tok.get(s.i) if hasattr(rd.tok, "get") else None
        c = (tok or {}).get("cls", {}).get("v", s.cls) if isinstance(tok, dict) else s.cls
        if c not in RIGHT_SIGNS or s.staff < 0:
            continue
        st = L.staves[s.staff]
        if st.system < 0:
            continue
        best = None
        for b in range(len(st.bars)):
            try:
                x0, _, x1, _ = L.bar_box(s.staff, b)
                col = L.column(s.staff, b)
            except Exception:
                continue
            d = abs(s.cx - x1)
            if best is None or d < best[0]:
                best = (d, col)
        if best is None or best[0] > 2.5 * float(L.sp):
            continue
        gi = first[st.system] + best[1]
        if 0 <= gi < n_meas:
            out.setdefault(gi, c)
    return sorted([gi, c] for gi, c in out.items())


def add_bar_signs(xml: str, signs: list) -> str:
    """Write the bar-closing signs the writer dropped as right <barline>s in every part."""
    from lxml import etree
    if not signs:
        return xml
    try:
        root = etree.fromstring(xml.encode())
    except etree.XMLSyntaxError:
        return xml
    for part in root.iter("part"):
        ms = part.findall("measure")
        for gi, c in signs:
            if gi >= len(ms):
                continue
            m = ms[gi]
            if any(b.get("location", "right") == "right" for b in m.findall("barline")):
                continue
            style, rep = RIGHT_SIGNS[c]
            bl = etree.SubElement(m, "barline", location="right")
            etree.SubElement(bl, "bar-style").text = style
            if rep:
                etree.SubElement(bl, "repeat", direction=rep)
    head = xml[: xml.find("<score-partwise")] if "<score-partwise" in xml else ""
    return head + etree.tostring(root, encoding="unicode")


# Per-bar warning levels, calibrated on the benchmark (bench/REPORT.md, 1,638 bars). What the small model's second
# reading says about a bar, and how often the bar really was wrong:
#   it has notes the big model lacks ("missed")       91%   -> red
#   both have notes the other lacks ("differs")       43%   -> red
#   only rests differ ("rests")                        54%   -> amber
#   the big model has notes it lacks ("small_missed")  9%   -> not marked: the small model just missed them
# Confidence alone is a weak signal once the second reading is in (bars below 0.85 without a disagreement were wrong
# 15% of the time), so it only marks bars when there is no usable second reading.
# Result: 80% of wrong bars marked, half of the marks are real errors, 16% of all bars marked (was 28%).
CHECK_BELOW, BAD_BELOW = 0.85, 0.5
RED_DISAGREE = {"missed", "differs", "main_short"}
AMBER_DISAGREE = {"rests"}


def level(m: dict, second_reading: bool = False) -> str:
    if m.get("doubled"):
        return "bad"
    d = m.get("disagree")
    if d is True or d in RED_DISAGREE:
        return "bad"
    if d in AMBER_DISAGREE or m.get("fixes"):
        return "check"
    if second_reading:
        return "check" if m["n"] > 0 and m["min"] < BAD_BELOW else "ok"
    if m["n"] > 0 and m["min"] < BAD_BELOW:
        return "bad"
    if m["n"] == 0 or m["min"] < CHECK_BELOW:
        return "check"
    return "ok"


def disagreement(xml: str, other: str) -> dict[int, str] | None:
    """Bar index -> how the second reading differs ("missed", "differs", "rests", "small_missed"), or None when the
    two readings have a different number of bars and can't be lined up."""
    from collections import Counter
    from .compare import parse
    a, b = parse(xml), parse(other)
    if a["measures"] != b["measures"]:
        return None
    out = {}
    for mi in range(a["measures"]):
        A, B = Counter(), Counter()
        for k in a["bars"]:
            A.update(map(tuple, a["bars"][k].get(mi, [])))
        for k in b["bars"]:
            B.update(map(tuple, b["bars"][k].get(mi, [])))
        if A == B:
            continue
        only_a = sum(1 for e in (A - B).elements() if e[0] != "r")
        only_b = sum(1 for e in (B - A).elements() if e[0] != "r")
        out[mi] = ("rests" if only_a == only_b == 0 else "missed" if only_a == 0 else
                   "small_missed" if only_b == 0 else "differs")
    return out


def bars_add_up(xml: str) -> list[bool] | None:
    """For each bar: does every voice run without a gap or overlap from the downbeat to the end of the bar, as the
    time signature says? A reading whose bar doesn't add up has lost or misread a note or rest there."""
    from lxml import etree
    from .sanitize import _strip_ns, read_part
    try:
        root = _strip_ns(etree.fromstring(xml.encode()))
    except etree.XMLSyntaxError:
        return None
    out = None
    for part in root.findall("part"):
        bars, _ = read_part(part)
        ok = []
        for b in bars:
            good = True
            voices = {}
            for ev in b.events:
                voices.setdefault((ev.staff, ev.voice), []).append(ev)
            for evs in voices.values():
                t = 0
                for ev in sorted(evs, key=lambda e: e.onset):
                    if ev.onset != t:
                        good = False
                    t = ev.end
                if t != b.length:
                    good = False
            ok.append(good)
        out = ok if out is None else [x and y for x, y in zip(out, ok)]
    return out


MUSIC = ("note", "backup", "forward")


def adopt_bars(xml: str, other: str, bars: set[int]) -> tuple[str, set[int]]:
    """Put the second reading's notes into the given bars (0-based measure indices), part by part. Used where the
    second reading has notes the main one lacks and nothing else differs: on the benchmark the second reading was
    right in 84% of those bars and the main one in 4%. Durations are rescaled when the two readings use different
    divisions; a bar that can't be rescaled exactly is left alone. Returns the new XML and the bars changed."""
    from fractions import Fraction
    from lxml import etree
    if not bars:
        return xml, set()
    try:
        ra, rb = etree.fromstring(xml.encode()), etree.fromstring(other.encode())
    except etree.XMLSyntaxError:
        return xml, set()
    pa, pb = ra.findall("part"), rb.findall("part")
    if len(pa) != len(pb):
        return xml, set()

    def divs(part):
        out, d = [], 1
        for m in part.findall("measure"):
            t = m.findtext("attributes/divisions")
            if t:
                d = int(float(t))
            out.append(d)
        return out

    plan = {}                                              # (part, bar) -> new children
    for k, (A, B) in enumerate(zip(pa, pb)):
        ma, mb = A.findall("measure"), B.findall("measure")
        if len(ma) != len(mb):
            return xml, set()
        da, db = divs(A), divs(B)
        for i in bars:
            if i >= len(ma):
                continue
            scale = Fraction(da[i], db[i])
            new = []
            for el in mb[i]:
                if el.tag not in MUSIC:
                    continue
                el = etree.fromstring(etree.tostring(el))
                for d in el.iter("duration"):
                    v = Fraction(int(float(d.text or 0))) * scale
                    if v.denominator != 1:
                        new = None
                        break
                    d.text = str(int(v))
                if new is None:
                    break
                new.append(el)
            plan[(k, i)] = new
    done = {i for i in bars if all(plan.get((k, i)) is not None for k in range(len(pa)))}
    for k, A in enumerate(pa):
        ma = A.findall("measure")
        for i in done:
            m = ma[i]
            old = [el for el in m if el.tag in MUSIC]
            at = list(m).index(old[0]) if old else len(m)
            for el in old:
                m.remove(el)
            for j, el in enumerate(plan[(k, i)]):
                m.insert(at + j, el)
    if not done:
        return xml, set()
    head = xml[: xml.find("<score-partwise")] if "<score-partwise" in xml else ""
    return head + etree.tostring(ra, encoding="unicode"), done


def reconcile(xml: str, other: str):
    """Line the two readings up bar by bar and settle what can be settled. Returns (xml, {bar: kind}, bars taken
    from the second reading), or None when the two have a different number of bars. Calibrated on the benchmark
    (28 pieces x 6 photo conditions, which reading matched the original):
      second has notes the main lacks, nothing else differs      second right 84%, main 4%  -> take the second's
      only rests differ, the main's bar doesn't add up, the second's does   second 21 of 22  -> take the second's
      notes differ (or rests), the main's bar adds up and the second's doesn't   main right 92%  -> not marked
      the small model lacks notes but the main's bar doesn't add up   main wrong 81%  -> red ("main_short")"""
    dis = disagreement(xml, other)
    if dis is None:
        return None
    xml, filled = adopt_bars(xml, other, {i for i, t in dis.items() if t == "missed"})
    fm, fs = bars_add_up(xml), bars_add_up(other)
    if fm is None or fs is None or len(fm) != len(fs):
        return xml, {i: t for i, t in dis.items() if i not in filled}, filled
    take = {i for i, t in dis.items() if t == "rests" and i not in filled and i < len(fm) and not fm[i] and fs[i]}
    xml, more = adopt_bars(xml, other, take)
    filled |= more
    out = {}
    for i, t in dis.items():
        if i in filled or i >= len(fm):
            continue
        if t in ("differs", "rests") and fm[i] and not fs[i]:
            t = "second_short"
        elif t == "small_missed" and not fm[i]:
            t = "main_short"
        out[i] = t
    return xml, out, filled


def second_opinion(r: dict, im: Image.Image) -> dict:
    """Read the page again with the small detector and mark the bars where the two readings differ. Two different
    models rarely make the same mistake, so a disagreement points at a likely error, including notes the big model
    missed with full confidence. Adds a few seconds per page."""
    try:
        other = transcribe(im, detector="2m" if r.get("detector") != "2m" else "28m")
        rc = reconcile(r["xml"], other["xml"])
    except Exception:
        return r
    if rc is None:                       # the two readings found a different number of bars: can't line them up
        r["second_opinion"] = {"aligned": False}
        return r
    # bars taken from the second reading are then wrong about as often (16%) as an unmarked bar read with middling
    # confidence (15%), so they get no mark of their own
    r["xml"], dis, filled = rc
    n = 0
    for i, m in enumerate(r["measures"]):
        if i in filled:
            m["filled"] = True
        elif i in dis:
            m["disagree"] = dis[i]
            n += level({"n": 0, "min": 1, "disagree": dis[i]}, True) == "bad"
        m["level"] = level(m, second_reading=True)
    # keep the second reading so the editor can offer it bar by bar ("Use second reading" in Fix it); bar k of it
    # lines up with measure index k of this reading (before any sanitizer split)
    alt = other["xml"]
    try:
        from . import sanitize as san
        cleaned, rep = san.sanitize(alt)
        if not rep.get("splits"):
            alt = cleaned
    except Exception:
        pass
    r["second_opinion"] = {"aligned": True, "bars": n, "filled": sorted(filled), "seconds": other["seconds"], "xml": alt}
    r["seconds"] = round(r["seconds"] + other["seconds"], 1)
    return r


def should_skip_second_opinion(r: dict) -> bool:
    """Skip the extra 2m second-opinion pass (~35-45% GPU time) when the primary 28m reading is already
    unambiguously high-confidence, every measure is clean, and original vs sharpened layout checks agree.
    Set MUSICSCAN_SKIP_SECOND_OPINION_CONF=0 (or >1.0) to force second_opinion on every page."""
    raw = os.environ.get("MUSICSCAN_SKIP_SECOND_OPINION_CONF", "0.985").strip().lower()
    if raw in ("0", "off", "false", "no"):
        return False
    try:
        min_conf = float(raw)
    except ValueError:
        min_conf = 0.985
    if min_conf > 1.0:
        return False
    st = r.get("stats") or {}
    if st.get("measures", 0) <= 0:
        return True  # never waste GPU time running a second opinion when 0 bars were detected
    if st.get("symbols", 0) < 10:
        return False
    if float(st.get("mean_conf", 0.0)) < min_conf:
        return False
    if int(st.get("low", 1)) > 0 or float(st.get("low_frac", 1.0)) >= 0.01:
        return False
    if any(m.get("doubled") or m.get("level") != "ok" for m in r.get("measures", [])):
        return False
    lc = r.get("layout_check") or {}
    bars = lc.get("bars")
    if bars and len(bars) == 2 and bars[0] != bars[1]:
        return False
    return True


def doubled_staff(boxes: list) -> bool:
    """Two staff boxes of one bar that cover mostly the same height: a single staff the reader traced twice (seen on
    a shadowed, slightly bowed photo of a one-staff part, where the staff-line finder lost the right half of a row).
    The second copy becomes a made-up extra part, read in the wrong clef. Real systems (piano, quartets) have their
    staves stacked with a gap, so their boxes don't overlap like this."""
    for i in range(len(boxes)):
        for j in range(i + 1, len(boxes)):
            a, b = boxes[i], boxes[j]
            ov = min(a[3], b[3]) - max(a[1], b[1])
            if ov > 0.5 * min(a[3] - a[1], b[3] - b[1]):
                return True
    return False


def analyse(rd) -> dict:
    L = rd.layout
    # columns per system -> global measure index
    sys_cols = []
    for sy in L.systems:
        n = 0
        for cols in sy.columns:
            if cols:
                n = max(n, max(cols) + 1)
        sys_cols.append(n)
    first = np.concatenate([[0], np.cumsum(sys_cols)]).astype(int).tolist()
    n_meas = int(first[-1])
    meas = [{"index": i, "system": -1, "confs": [], "boxes": []} for i in range(n_meas)]
    for si, sy in enumerate(L.systems):
        for i in range(first[si], first[si + 1]):
            meas[i]["system"] = si
    # bar boxes: each staff's bar -> column
    for st_i, st in enumerate(L.staves):
        if st.system < 0:
            continue
        for b in range(len(st.bars)):
            try:
                col = L.column(st_i, b)
            except Exception:
                continue
            gi = first[st.system] + col
            if 0 <= gi < n_meas:
                meas[gi]["boxes"].append([round(v, 1) for v in L.bar_box(st_i, b)])
    tok_conf = []
    n_low = 0
    for si, r in rd.tok.items():
        s = L.syms[si]
        if s.fam == "measure" or s.staff < 0:
            continue
        c = token_conf(r)
        real = r.get("real", {}).get("p", 1.0)
        if real < 0.5 and c >= LOW:
            continue                       # confidently not a symbol: not part of the music
        tok_conf.append(c)
        if c < LOW:
            n_low += 1
        st = L.staves[s.staff]
        if st.system < 0 or s.bar < 0:
            continue
        try:
            gi = first[st.system] + L.column(s.staff, s.bar)
        except Exception:
            continue
        if 0 <= gi < n_meas:
            meas[gi]["confs"].append(c)
            if c < LOW:
                meas[gi].setdefault("low", []).append([round(v, 1) for v in s.box])
    for m in meas:
        cs = m.pop("confs")
        m["n"] = len(cs)
        m["low_n"] = int(sum(c < LOW for c in cs))
        m["min"] = round(min(cs), 3) if cs else 0.0
        m["conf"] = round(float(np.mean(cs)) if cs else 0.0, 3)
        x0 = min((b[0] for b in m["boxes"]), default=0); y0 = min((b[1] for b in m["boxes"]), default=0)
        x1 = max((b[2] for b in m["boxes"]), default=0); y1 = max((b[3] for b in m["boxes"]), default=0)
        m["bbox"] = [x0, y0, x1, y1]
        if doubled_staff(m["boxes"]):
            m["doubled"] = True
            m.setdefault("notes", []).append("one staff was read as two here; check the notes and the clef")
        m["level"] = level(m)
    systems = []
    for si in range(len(L.systems)):
        ms = [m for m in meas if m["system"] == si]
        if ms:
            systems.append({"index": si, "measures": [m["index"] for m in ms],
                            "bbox": [min(m["bbox"][0] for m in ms), min(m["bbox"][1] for m in ms),
                                     max(m["bbox"][2] for m in ms), max(m["bbox"][3] for m in ms)]})
    n = len(tok_conf)
    changes = 0
    try:
        from copisteria import read
        changes = len(read.changes(rd))
    except Exception:
        pass
    staves_per_sys = [len(s.staves) for s in L.systems]
    return {
        "measures": meas, "systems": systems, "bar_signs": bar_signs(rd, first, n_meas),
        "stats": {"symbols": n, "low": n_low, "low_frac": round(n_low / max(n, 1), 4),
                  "mean_conf": round(float(np.mean(tok_conf)) if n else 0.0, 4),
                  "revisions": changes, "rev_frac": round(changes / max(n, 1), 4),
                  "staves": len(L.staves), "systems": len(L.systems), "ink_staves": bool(L.ink),
                  "staff_space": round(float(L.sp), 2), "staves_per_system": staves_per_sys,
                  "measures": n_meas},
    }
