"""MusicScan MVP server.  Run:  uvicorn server.app:app --port 8000  (from the musicscan folder)."""
from __future__ import annotations

import io
import json
import sys
import threading
import time
import traceback
import uuid
from pathlib import Path

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from musicscan import imageio, omr, preprocess  # noqa: E402
from musicscan import sanitize as san  # noqa: E402
from musicscan.quality import assess  # noqa: E402

WORK = ROOT / "work"
WORK.mkdir(exist_ok=True)
JOBS: dict[str, dict] = {}
app = FastAPI(title="MusicScan")


def _save_job(j):
    d = WORK / j["id"]
    d.mkdir(exist_ok=True)
    (d / "job.json").write_text(json.dumps({k: v for k, v in j.items() if k != "_img"}))


def _run(job_id: str, data: bytes, name: str, opts: dict):
    j = JOBS[job_id]
    d = WORK / job_id
    try:
        j["status"] = "Cleaning up the photo"
        im = imageio.load_image(data, name)
        im.save(d / "original.jpg", quality=90)
        pre = preprocess.preprocess(im, flatten=opts.get("flatten"), strip_pen=opts.get("strip_pen", True),
                                    lock_page=opts.get("lock_page", True), quad=opts.get("quad"))
        pre["image"].save(d / "page.png")
        j["status"] = "Reading the music"
        r = omr.transcribe(pre["image"], detector=opts.get("detector", "28m"))
        _clean(r)
        q = assess(pre, r)
        j["result"] = {"xml": r["xml"], "measures": r["measures"], "systems": r["systems"], "stats": r["stats"],
                       "quality": q, "steps": pre["steps"], "quad": pre["quad"], "seconds": r["seconds"],
                       "page_size": list(pre["image"].size), "original_size": list(im.size)}
        j["status"] = "done"
    except Exception as e:
        traceback.print_exc()
        j["status"] = "error"
        j["error"] = f"{type(e).__name__}: {e}"
    _save_job(j)


@app.post("/api/jobs")
async def create_job(file: UploadFile = File(...), detector: str = Form("28m"), flatten: str = Form("auto"),
                     strip_pen: bool = Form(True)):
    data = await file.read()
    if len(data) > 40_000_000:
        raise HTTPException(413, "File is larger than 40 MB")
    jid = uuid.uuid4().hex[:12]
    (WORK / jid).mkdir()
    JOBS[jid] = {"id": jid, "status": "queued", "name": file.filename, "created": time.time()}
    opts = {"detector": detector if detector in ("28m", "2m") else "28m",
            "flatten": None if flatten == "auto" else flatten == "on", "strip_pen": strip_pen}
    threading.Thread(target=_run, args=(jid, data, file.filename or "", opts), daemon=True).start()
    return {"id": jid}


def _job(jid):
    j = JOBS.get(jid)
    if j is None:
        p = WORK / jid / "job.json"
        if not p.exists() or "/" in jid or ".." in jid:
            raise HTTPException(404, "No such job")
        j = JOBS[jid] = json.loads(p.read_text())
    return j


@app.get("/api/jobs/{jid}")
def get_job(jid: str):
    return _job(jid)


@app.get("/api/jobs/{jid}/{name}")
def job_file(jid: str, name: str):
    _job(jid)
    if name not in ("page.png", "original.jpg"):
        raise HTTPException(404)
    return FileResponse(WORK / jid / name)


def _clean(r: dict, context: dict | None = None, base: int = 0) -> dict:
    """Make the reader's MusicXML structurally sound (bars add up, staves/clefs/voices consistent); bars the
    sanitizer had to repair are marked for checking."""
    try:
        r["xml"], rep = san.sanitize(r["xml"], context=context, base=base)
    except Exception:
        traceback.print_exc()
        return r
    # a bar split in two (missed bar line): its photo box is divided to match
    meas = r["measures"]
    for gi, k in sorted(rep.get("splits", []), reverse=True):
        i = gi - base
        if not 0 <= i < len(meas):
            continue
        m = meas[i]
        x0, y0, x1, y1 = m["bbox"]
        w = (x1 - x0) / k
        parts = []
        for j in range(k):
            c = dict(m)
            c["bbox"] = [round(x0 + j * w, 1), y0, round(x0 + (j + 1) * w, 1), y1]
            c["boxes"] = [[round(b[0] + j * (b[2] - b[0]) / k, 1), b[1], round(b[0] + (j + 1) * (b[2] - b[0]) / k, 1), b[3]]
                          for b in m.get("boxes", [])]
            c["low"] = [b for b in m.get("low", []) if c["bbox"][0] <= (b[0] + b[2]) / 2 < c["bbox"][2]]
            parts.append(c)
        meas[i:i + 1] = parts
    for i, m in enumerate(meas):
        m["index"] = i
    if "systems" in r:
        for sy in r["systems"]:
            sy["measures"] = [m["index"] for m in meas if m["system"] == sy["index"]]
    if "stats" in r:
        r["stats"]["measures"] = len(meas)
    for k, fixes in rep["bars"].items():
        i = int(k) - base
        if 0 <= i < len(r["measures"]):
            m = r["measures"][i]
            m["fixes"] = fixes
            if m["level"] == "ok":
                m["level"] = "check"
    r["sanitizer"] = rep
    return r


RESCAN_WAYS = [
    ("other-detector", "Second reader model"),
    ("enlarge", "Enlarged and sharpened"),
    ("high-contrast", "High-contrast cleanup"),
]


def _variant(img: Image.Image, way: str):
    import cv2
    import numpy as np
    det = "2m" if way == "other-detector" else "28m"
    g = np.asarray(img.convert("L"))
    if way == "enlarge":
        g = cv2.resize(g, None, fx=1.6, fy=1.6, interpolation=cv2.INTER_CUBIC)
        blur = cv2.GaussianBlur(g, (0, 0), 1.2)
        g = cv2.addWeighted(g, 1.6, blur, -0.6, 0)
    elif way == "high-contrast":
        g = preprocess.flatten_light(g)
        g = cv2.adaptiveThreshold(g, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY, 41, 15)
    return Image.fromarray(g), det


@app.post("/api/jobs/{jid}/rescan")
async def rescan(jid: str, measures: str = Form(...), attempt: int = Form(0), file: UploadFile | None = File(None),
                 context: str | None = Form(None)):
    """Re-read the rows holding the selected measures. With a file: read that close-up instead.
    context (JSON, optional): the parts/staves, key, time and clefs in force at the first target bar in the score
    being edited (the editor sends it so the user's own key/time fixes carry over). Without it, it is taken from
    the original reading."""
    j = _job(jid)
    if j.get("status") != "done":
        raise HTTPException(409, "Job not finished")
    sel = sorted({int(x) for x in measures.split(",") if x.strip() != ""})
    res = j["result"]
    meas = res["measures"]
    systems = sorted({meas[i]["system"] for i in sel if 0 <= i < len(meas)})
    if not systems:
        raise HTTPException(400, "No measures selected")
    target = [m["index"] for m in meas if m["system"] in systems]
    way, label = RESCAN_WAYS[attempt % len(RESCAN_WAYS)]
    if file is not None:
        im = imageio.load_image(await file.read(), file.filename or "")
        pre = preprocess.preprocess(im)
        crop, det, label = pre["image"], "28m", "Your close-up photo"
    else:
        page = Image.open(WORK / jid / "page.png")
        W, H = page.size
        boxes = [s["bbox"] for s in res["systems"] if s["index"] in systems]
        x0 = 0
        y0 = min(b[1] for b in boxes)
        x1 = W
        y1 = max(b[3] for b in boxes)
        pad = max(40, int((y1 - y0) * 0.35))
        top, bot = max(0, int(y0) - pad), min(H, int(y1) + pad)
        # never reach into the neighbouring rows: a cut-off staff of the next system would be read as music too
        # (a 4-staff choir row used to come back with the whole page's bars)
        for s in res["systems"]:
            if s["index"] in systems:
                continue
            sy0, sy1 = s["bbox"][1], s["bbox"][3]
            if sy1 <= y0:
                top = max(top, int((sy1 + y0) / 2))
            elif sy0 >= y1:
                bot = min(bot, int((y1 + sy0) / 2))
        crop = page.crop((x0, top, x1, bot))
        # give the reader a page-like canvas: white margins around the row
        canvas = Image.new("L", (crop.width + 120, crop.height + 160), 255)
        canvas.paste(crop, (60, 80))
        crop, det = _variant(canvas, way)
    r = omr.transcribe(crop, detector=det)
    ctx = None
    if context:
        try:
            ctx = json.loads(context)
        except ValueError:
            ctx = None
    if not ctx or not ctx.get("parts"):
        ctx = san.context_at(res["xml"], target[0])
    _clean(r, context=ctx, base=target[0])
    q = assess({"image": crop}, r)
    return {"xml": r["xml"], "measures": r["measures"], "stats": r["stats"], "quality": q, "target": target,
            "way": label, "attempt": attempt, "seconds": r["seconds"]}


@app.get("/api/samples")
def samples():
    d = ROOT / "web" / "samples"
    return sorted(p.name for p in d.glob("*.jpg")) if d.exists() else []


app.mount("/", StaticFiles(directory=ROOT / "web", html=True), name="web")
