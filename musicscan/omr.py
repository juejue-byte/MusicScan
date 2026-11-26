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
    out["xml"] = fix_pickup(xml)
    out["seconds"] = round(time.time() - t0, 1)
    out["detector"] = detector
    out["device"] = pick_device()
    out["size"] = [im.width, im.height]
    return out


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
        m["level"] = "ok" if m["low_n"] == 0 and m["n"] > 0 else ("check" if m["low_n"] <= 2 and m["min"] > 0.4 else "bad")
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
        "measures": meas, "systems": systems,
        "stats": {"symbols": n, "low": n_low, "low_frac": round(n_low / max(n, 1), 4),
                  "mean_conf": round(float(np.mean(tok_conf)) if n else 0.0, 4),
                  "revisions": changes, "rev_frac": round(changes / max(n, 1), 4),
                  "staves": len(L.staves), "systems": len(L.systems), "ink_staves": bool(L.ink),
                  "staff_space": round(float(L.sp), 2), "staves_per_system": staves_per_sys,
                  "measures": n_meas},
    }
