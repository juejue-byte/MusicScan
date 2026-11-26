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
                dets, cands, feats = pipeline.inputs(png, model)
            except (RuntimeError, NotImplementedError):
                if pick_device() == "cpu":
                    raise
                # an op the GPU backend lacks: fall back to the CPU for the rest of this run
                _DEV[:] = ["cpu"]
                pipeline._DET[:] = []
                dets, cands, feats = pipeline.inputs(png, model)
            rd = read_revised(dets, g.width, g.height, model, device="cpu", attention=False, image=g,
                              cands=cands, feats=feats)
            xml = write.write(rd, image=g)
    out = analyse(rd)
    xml = add_system_breaks(xml, [s["measures"][0] for s in out["systems"][1:] if s["measures"]])
    xml = add_bar_signs(xml, out.get("bar_signs", []))
    out["xml"] = restore_bar_rests(fix_pickup(xml))
    out["seconds"] = round(time.time() - t0, 1)
    out["detector"] = detector
    out["device"] = pick_device()
    out["size"] = [im.width, im.height]
    return out


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


# Per-bar warning levels, calibrated on the benchmark (bench/REPORT.md): confidence alone finds about half of the
# wrong bars; adding "the small model reads this bar differently" finds about 85% of them.
CHECK_BELOW, BAD_BELOW = 0.85, 0.5


def level(m: dict) -> str:
    if m.get("disagree") or (m["n"] > 0 and m["min"] < BAD_BELOW):
        return "bad"
    if m["n"] == 0 or m["min"] < CHECK_BELOW:
        return "check"
    return "ok"


def second_opinion(r: dict, im: Image.Image) -> dict:
    """Read the page again with the small detector and mark the bars where the two readings differ. Two different
    models rarely make the same mistake, so a disagreement points at a likely error, including notes the big model
    missed with full confidence. Adds a few seconds per page."""
    try:
        from .compare import compare
        other = transcribe(im, detector="2m" if r.get("detector") != "2m" else "28m")
        c = compare(r["xml"], other["xml"])
    except Exception:
        return r
    if c.get("bar_ok") is None:          # the two readings found a different number of bars: can't line them up
        r["second_opinion"] = {"aligned": False}
        return r
    n = 0
    for m, ok in zip(r["measures"], c["bar_ok"]):
        if not ok:
            m["disagree"] = True
            n += 1
        m["level"] = level(m)
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
    r["second_opinion"] = {"aligned": True, "bars": n, "seconds": other["seconds"], "xml": alt}
    r["seconds"] = round(r["seconds"] + other["seconds"], 1)
    return r


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
