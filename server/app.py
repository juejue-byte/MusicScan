"""MusicScan MVP server.  Run:  uvicorn server.app:app --port 8000  (from the musicscan folder)."""
from __future__ import annotations

import copy
import hashlib
import hmac
import io
import json
import os
import shutil
import sys
import threading
import time
import traceback
import uuid
from pathlib import Path
from typing import Callable

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from musicscan import imageio, omr, preprocess  # noqa: E402
from musicscan import sanitize as san  # noqa: E402
from musicscan.quality import assess  # noqa: E402
from server import auth, usage  # noqa: E402

# Jobs (photo, cleaned page, reading) live here. A hosted server points it at a persistent volume.
WORK = Path(os.environ.get("MUSICSCAN_WORK", ROOT / "work"))
WORK.mkdir(parents=True, exist_ok=True)
JOBS: dict[str, dict] = {}
app = FastAPI(title="MusicScan")

# Optional remote OMR backend (set by deploy/modal_app.py to route OMR onto the GPU worker while the CPU web
# container handles static assets, auth, billing, polling, and cached samples).
_OMR_TRANSCRIBE: Callable[..., dict] | None = None
_OMR_RESCAN: Callable[..., dict] | None = None
_OMR_WARMUP: Callable[[], bool] | None = None
_REMOTE_DEVICE: str | None = None


def set_omr_backend(
    transcribe_fn: Callable[..., dict] | None,
    rescan_fn: Callable[..., dict] | None,
    device_label: str | None = None,
    warmup_fn: Callable[[], bool] | None = None,
) -> None:
    global _OMR_TRANSCRIBE, _OMR_RESCAN, _OMR_WARMUP, _REMOTE_DEVICE
    _OMR_TRANSCRIBE = transcribe_fn
    _OMR_RESCAN = rescan_fn
    _OMR_WARMUP = warmup_fn
    _REMOTE_DEVICE = device_label


# Pre-cached built-in sample scans: match uploaded bytes by SHA-256 against web/samples/* and serve precomputed
# readings from web/demo/sample*/ with zero GPU usage and <100ms latency.
_SAMPLE_CACHE: dict[str, tuple[str, Path]] | None = None
_SAMPLE_LOCK = threading.Lock()


def _sample_cache() -> dict[str, tuple[str, Path]]:
    global _SAMPLE_CACHE
    if _SAMPLE_CACHE is not None:
        return _SAMPLE_CACHE
    with _SAMPLE_LOCK:
        if _SAMPLE_CACHE is not None:
            return _SAMPLE_CACHE
        mapping: dict[str, tuple[str, Path]] = {}
        demo_dir = ROOT / "web" / "demo"
        index_path = demo_dir / "index.json"
        if index_path.exists():
            try:
                idx = json.loads(index_path.read_text())
                for fname, sid in (idx.get("samples") or {}).items():
                    sdir = demo_dir / sid
                    if not (sdir / "job.json").exists():
                        continue
                    for candidate in (ROOT / "web" / "samples" / fname, sdir / "original.jpg"):
                        if candidate.exists():
                            digest = hashlib.sha256(candidate.read_bytes()).hexdigest()
                            mapping[digest] = (sid, sdir)
            except Exception:
                traceback.print_exc()
        _SAMPLE_CACHE = mapping
        return _SAMPLE_CACHE


def _cached_sample_for(data: bytes, opts: dict) -> tuple[str, Path] | None:
    if os.environ.get("MUSICSCAN_DISABLE_SAMPLE_CACHE", "0") == "1":
        return None
    if (
        opts.get("detector", "28m") != "28m"
        or opts.get("flatten") is not None
        or not opts.get("strip_pen", True)
        or opts.get("page", 0) != 0
        or opts.get("pdf")
        or opts.get("context") is not None
        or opts.get("quad") is not None
    ):
        return None
    digest = hashlib.sha256(data).hexdigest()
    return _sample_cache().get(digest)


def _serve_cached_sample(job_id: str, sid: str, sample_dir: Path) -> None:
    """Materialize a precomputed sample scan into WORK / job_id with $0 GPU usage while preserving full server-side
    preview masking, unlock flow, and file endpoints."""
    j = JOBS[job_id]
    d = WORK / job_id
    src_orig = sample_dir / "original.jpg"
    if src_orig.exists():
        shutil.copyfile(src_orig, d / "original.jpg")
    src_page_png = sample_dir / "page.png"
    src_page_jpg = sample_dir / "page.jpg"
    if src_page_png.exists():
        shutil.copyfile(src_page_png, d / "page.full.png")
        shutil.copyfile(src_page_png, d / "page.png")
    elif src_page_jpg.exists():
        with Image.open(src_page_jpg) as im:
            im.save(d / "page.full.png", format="PNG", compress_level=1)
            shutil.copyfile(d / "page.full.png", d / "page.png")
    demo_job = json.loads((sample_dir / "job.json").read_text())
    full_result = copy.deepcopy(demo_job["result"])
    full_result["cached_sample"] = sid
    full_result["seconds"] = 0.0
    (d / "result.full.json").write_text(json.dumps(full_result))
    j["cached_sample"] = sid
    j["_full_result"] = full_result
    j["result"] = _preview_result(full_result, d) if j.get("allowance", {}).get("access") == "preview" else full_result
    j["status"] = "done"
    _save_job(j)


# Who may use the API on a server on the public internet (deploy/modal_app.py):
#  - signed-in users: a Supabase access token (server/auth.py, on when SUPABASE_URL is set), the launch setup;
#  - a shared access key (MUSICSCAN_ACCESS_KEY) while testing: open the app once as  https://host/?key=KEY  and a
#    cookie keeps it, or send the X-MusicScan-Key header.
# Neither set (the default on your own computer) means the API is open.
ACCESS_KEY = os.environ.get("MUSICSCAN_ACCESS_KEY", "").strip().strip('"').strip("'")
OPEN_API = ("/api/health", "/api/samples", "/api/config", "/api/billing/notifications")
KEY_COOKIE = "musicscan_key"
CACHEABLE_PREFIXES = ("/js/", "/samples/", "/fonts/", "/demo/", "/vendor/")
CACHEABLE_EXTS = (".css", ".js", ".jpg", ".jpeg", ".png", ".svg", ".woff2", ".woff", ".ico")


def _given_key(request: Request) -> str:
    return (request.query_params.get("key") or request.headers.get("x-musicscan-key")
            or request.cookies.get(KEY_COOKIE) or "").strip()


def _fingerprint(key: str) -> str | None:
    """6 hex characters of the key's SHA-256: enough to tell two keys apart, useless for guessing one."""
    return hashlib.sha256(key.encode()).hexdigest()[:6] if key else None


def _key_ok(request: Request) -> bool:
    return bool(ACCESS_KEY) and hmac.compare_digest(_given_key(request).encode(), ACCESS_KEY.encode())


def _authorized(request: Request) -> bool:
    request.state.user = auth.user_from(request)
    if request.state.user or _key_ok(request):
        return True
    return not ACCESS_KEY and not auth.enabled()


@app.middleware("http")
async def access_check(request: Request, call_next):
    ok = _authorized(request)
    path = request.url.path
    if not ok and path.startswith("/api/") and path not in OPEN_API:
        msg = ("Please sign in again." if auth.enabled() and not ACCESS_KEY else
               "This MusicScan server needs its access key. Open it once with ?key=… at the end of the address.")
        return JSONResponse({"detail": msg}, status_code=401)
    resp = await call_next(request)
    if _key_ok(request) and request.cookies.get(KEY_COOKIE) != ACCESS_KEY:
        https = request.headers.get("x-forwarded-proto", request.url.scheme) == "https"
        resp.set_cookie(KEY_COOKIE, ACCESS_KEY, max_age=400 * 86400, httponly=True, secure=https, samesite="lax")
    if path.startswith("/api/"):
        resp.headers.setdefault("Cache-Control", "no-store")
    elif resp.status_code == 200 and (path.startswith(CACHEABLE_PREFIXES) or path.endswith(CACHEABLE_EXTS)):
        resp.headers.setdefault("Cache-Control", "public, max-age=3600")
    return resp


@app.get("/api/health")
def health(request: Request):
    """Liveness plus whether this request carries the access key (the iOS app's "Test connection" uses it)."""
    user = request.state.user
    device = _REMOTE_DEVICE if _REMOTE_DEVICE else (omr.pick_device() if omr._DEV else None)
    return {"ok": True, "app": "musicscan", "authorized": _authorized(request), "key_required": bool(ACCESS_KEY),
            "sign_in": auth.enabled(), "user": user["id"] if user else None,
            "key_sent": bool(_given_key(request)),  # a key arrived (query, header or cookie), right or wrong
            # compare with scripts/sync_modal_secret.sh's local fingerprint to see which side differs
            "key_fingerprint": _fingerprint(ACCESS_KEY), "key_length": len(ACCESS_KEY),
            "sent_fingerprint": _fingerprint(_given_key(request)),
            "device": device,
            "split_gpu": _OMR_TRANSCRIBE is not None,
            "cached_samples": len(_sample_cache())}


@app.post("/api/warmup")
def warmup_gpu():
    """Non-blocking GPU container pre-warm triggered as soon as the user opens the camera or photo picker."""
    warming = bool(_OMR_WARMUP()) if _OMR_WARMUP is not None else False
    return {"ok": True, "warming": warming, "split_gpu": _OMR_TRANSCRIBE is not None}


@app.get("/api/config")
def public_config():
    """Client bootstrap values only; the Supabase service secret is never exposed here."""
    return {"supabaseUrl": auth.supabase_url(),
            "supabasePublishableKey": os.environ.get("SUPABASE_PUBLISHABLE_KEY", ""),
            "signIn": auth.enabled() and bool(os.environ.get("SUPABASE_PUBLISHABLE_KEY")),
            "storeKit": True}


@app.post("/api/billing/transaction")
async def verify_storekit_transaction(request: Request):
    """Verify Apple's signed StoreKit transaction before changing this user's existing entitlement."""
    user = request.state.user
    if not user:
        raise HTTPException(401, "Sign in before restoring or purchasing MusicScan Pro")
    try:
        body = await request.json()
        from server import billing
        transaction = billing.verify_transaction(body.get("signedTransaction", ""), user["id"])
        usage.record_transaction(user["id"], transaction)
        return {"active": transaction["active"], "product_id": transaction["product_id"],
                "period_end": transaction["period_end"], "is_trial": transaction["is_trial"]}
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    except Exception as exc:
        traceback.print_exc()
        raise HTTPException(503, "Could not verify or save the subscription right now") from exc


@app.post("/api/billing/notifications")
async def app_store_notifications(request: Request):
    """App Store Server Notifications V2 endpoint. Apple authenticates this request with its signed payload."""
    try:
        body = await request.json()
        from server import billing
        notice = billing.verify_notification(body.get("signedPayload", ""))
        transaction = notice.get("transaction")
        if transaction:
            usage.record_transaction(notice["user_id"], transaction)
        return {"ok": True}
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    except Exception as exc:
        traceback.print_exc()
        raise HTTPException(503, "Could not process the App Store notification") from exc


def _save_job(j):
    d = WORK / j["id"]
    d.mkdir(exist_ok=True)
    (d / "job.json").write_text(json.dumps({k: v for k, v in j.items() if k not in ("_img", "_full_result")}))


def _preview_result(result: dict, directory: Path) -> dict:
    """Cut the score and cover every later bar in the public preview image. Full data stays server-side."""
    from lxml import etree
    measures = result.get("measures", [])
    visible_count = max(1, (len(measures) + 1) // 2)
    visible = measures[:visible_count]
    hidden = measures[visible_count:]
    public = dict(result)
    public["measures"] = visible
    public["stats"] = dict(result.get("stats", {}), measures=len(visible))
    public["systems"] = [dict(s, measures=[i for i in s.get("measures", []) if i < visible_count])
                         for s in result.get("systems", []) if any(i < visible_count for i in s.get("measures", []))]
    try:
        root = etree.fromstring(result["xml"].encode(), etree.XMLParser(recover=True, huge_tree=True))
        for part in root.xpath("//*[local-name()='part']"):
            bars = part.xpath("./*[local-name()='measure']")
            for bar in bars[visible_count:]:
                part.remove(bar)
        public["xml"] = etree.tostring(root, encoding="unicode")
    except Exception:
        # If the score can't be safely cut, fail closed: do not send MusicXML to a preview user.
        public["xml"] = ""

    image_path = directory / "page.full.png"
    if image_path.exists() and hidden:
        image = Image.open(image_path).convert("RGB")
        width, height = image.size
        x0, y0, x1, y1 = hidden[0].get("bbox", [0, height // 2, width, height])
        same_row = all(m.get("system") == visible[-1].get("system") for m in hidden)
        if same_row:
            mask_box = (max(0, int(x0)), max(0, int(min(visible[-1]["bbox"][1], y0))), width, min(height, int(max(visible[-1]["bbox"][3], y1))))
            # Later rows are hidden too if they follow the visible bar sequence.
            mask_box = (mask_box[0], 0, mask_box[2], height)
        else:
            mask_box = (0, max(0, int(y0)), width, height)
        from PIL import ImageDraw
        ImageDraw.Draw(image).rectangle(mask_box, fill="white")
        image.save(directory / "page.png")
    return public


def _run(job_id: str, data: bytes, name: str, opts: dict):
    j = JOBS[job_id]
    d = WORK / job_id
    try:
        j["status"] = "Cleaning up the photo"
        im = imageio.load_image(data, name, page=opts.get("page", 0))
        im.save(d / "original.jpg", quality=90)
        pre = preprocess.preprocess(im, flatten=opts.get("flatten"), strip_pen=opts.get("strip_pen", True),
                                    lock_page=opts.get("lock_page", True), quad=opts.get("quad"))
        j["status"] = "Reading the music"
        det = opts.get("detector", "28m")

        def _save_page(img: Image.Image) -> None:
            img.save(d / "page.full.png", format="PNG", compress_level=1)
            shutil.copyfile(d / "page.full.png", d / "page.png")

        def _transcribe(img):
            if _OMR_TRANSCRIBE is not None:
                return _OMR_TRANSCRIBE(img, detector=det, allow_second_opinion=(det == "28m"))
            res, read_im = omr.transcribe_checked(img, detector=det)
            if det == "28m":
                if omr.should_skip_second_opinion(res):
                    res["second_opinion"] = {
                        "aligned": True,
                        "skipped": True,
                        "reason": "high_confidence",
                        "bars": 0,
                        "filled": [],
                        "seconds": 0.0,
                    }
                else:
                    j["status"] = "Double-checking"
                    omr.second_opinion(res, read_im)
            return res

        # If a photo is unmistakably sideways (landscape capture with vertical staff lines), rotate 90° CW
        # BEFORE calling GPU OMR so we don't burn a full pass on sideways staves.
        orig_pre_im = pre["image"]
        if preprocess.strongly_sideways(orig_pre_im):
            rot_cw = orig_pre_im.transpose(Image.Transpose.ROTATE_270)
            r_cw = _transcribe(rot_cw)
            if (r_cw.get("stats") or {}).get("measures"):
                pre["image"] = rot_cw
                pre["steps"].append("auto-rotate-90cw")
                r = r_cw
            else:
                rot_ccw = orig_pre_im.transpose(Image.Transpose.ROTATE_90)
                r_ccw = _transcribe(rot_ccw)
                if (r_ccw.get("stats") or {}).get("measures"):
                    pre["image"] = rot_ccw
                    pre["steps"].append("auto-rotate-90ccw")
                    r = r_ccw
                else:
                    r = _transcribe(orig_pre_im)
        else:
            r = _transcribe(orig_pre_im)
            # Safety net for mildly sideways photos: if primary OMR found 0 measures and gradients look
            # sideways, retry rotated 90° CW then CCW.
            if not (r.get("stats") or {}).get("measures") and preprocess.looks_sideways(orig_pre_im):
                for label, transpose in (("auto-rotate-90cw", Image.Transpose.ROTATE_270),
                                         ("auto-rotate-90ccw", Image.Transpose.ROTATE_90)):
                    j["status"] = "Checking page orientation"
                    rot_im = orig_pre_im.transpose(transpose)
                    r_rot = _transcribe(rot_im)
                    if (r_rot.get("stats") or {}).get("measures"):
                        pre["image"] = rot_im
                        pre["steps"].append(label)
                        r = r_rot
                        break
        _save_page(pre["image"])
        ctx, notes = page_context(r["xml"], opts.get("context"))
        _clean(r, context=ctx)
        if notes and r["measures"]:
            m0 = r["measures"][0]
            m0["notes"] = m0.get("notes", []) + notes
            if m0["level"] == "ok":
                m0["level"] = "check"
        q = assess(pre, r)
        lc = r.get("layout_check") or {}
        if lc.get("bars") and lc["bars"][0] != lc["bars"][1]:
            # the two reads split the page into a different number of bars: the rows were hard to tell apart
            q["reasons"].append(f"The rows were hard to tell apart in this photo (one reading found {lc['bars'][0]} "
                                f"bars, another {lc['bars'][1]}). Check that each row has the right number of bars.")
            if q["level"] == "good":
                q["level"] = "check"
        full_result = {"xml": r["xml"], "measures": r["measures"], "systems": r["systems"], "stats": r["stats"],
                       "quality": q, "steps": pre["steps"], "quad": pre["quad"], "seconds": r["seconds"],
                       "page_size": list(pre["image"].size), "original_size": list(im.size),
                       "second_opinion": r.get("second_opinion"), "layout_check": r.get("layout_check"),
                       "pdf_page": opts.get("page", 0) if opts.get("pdf") else None}
        (d / "result.full.json").write_text(json.dumps(full_result))
        j["_full_result"] = full_result
        j["result"] = _preview_result(full_result, d) if j.get("allowance", {}).get("access") == "preview" else full_result
        j["status"] = "done"
    except Exception as e:
        traceback.print_exc()
        j["status"] = "error"
        j["error"] = f"{type(e).__name__}: {e}"
    _save_job(j)


def page_context(raw_xml: str, context: dict | None) -> tuple[dict | None, list[str]]:
    """For a page that continues a score: what carries over from the end of the pages before it.
    The part/staff layout and the clefs always do (so parts line up across the page turn). The time signature does
    unless this page prints one (it usually doesn't: only the first page shows it), and so does the key when no key
    was read. A key read on this page that differs from the previous page's is kept (it may be a real key change)
    but flagged for checking."""
    if not context or not context.get("parts"):
        return None, []
    from lxml import etree
    try:
        root = san._strip_ns(etree.fromstring(raw_xml.encode() if isinstance(raw_xml, str) else raw_xml,
                                              etree.XMLParser(recover=True, huge_tree=True)))
    except Exception:
        return None, []
    m0 = [p.find("measure") for p in root.findall("part")]
    def first(tag):
        for m in m0:
            if m is None:
                continue
            for c in m:
                if c.tag == "note":
                    break
                if c.tag == "attributes" and c.find(tag) is not None:
                    return c.find(tag)
        return None
    has_time = first("time") is not None and first("time").findtext("beats")
    k = first("key")
    read_fifths = int(k.findtext("fifths")) if k is not None and (k.findtext("fifths") or "").lstrip("-").isdigit() else None
    parts, notes = [], []
    for p in context["parts"]:
        q = {"staves": int(p.get("staves", 1)), "clefs": p.get("clefs", {})}
        if not has_time and "beats" in p and "beat_type" in p:
            q["beats"], q["beat_type"] = int(p["beats"]), int(p["beat_type"])
        if read_fifths is None and "fifths" in p:
            q["fifths"] = int(p["fifths"])
        parts.append(q)
    prev = context["parts"][0].get("fifths")
    if read_fifths is not None and prev is not None and int(prev) != read_fifths:
        notes.append("the key read on this page differs from the page before")
    return {"parts": parts}, notes


def _pdf_pages(data: bytes, name: str) -> int:
    if not (name.lower().endswith(".pdf") or data[:5] == b"%PDF-"):
        return 0
    import pypdfium2 as pdfium
    try:
        return len(pdfium.PdfDocument(data))
    except Exception:
        raise HTTPException(400, "Could not open this PDF")


@app.post("/api/jobs")
async def create_job(request: Request, file: UploadFile = File(...), detector: str = Form("28m"), flatten: str = Form("auto"),
                     strip_pen: bool = Form(True), page: int = Form(0), context: str | None = Form(None)):
    """Read one page. A PDF reads page `page` (0-based); the reply says how many pages it has.
    context (JSON, optional): the layout, key, time and clefs in force at the end of the score this page continues
    (the editor sends it when you add a page), so parts, clefs and the time signature carry across the page turn."""
    data = await file.read()
    if len(data) > 40_000_000:
        raise HTTPException(413, "File is larger than 40 MB")
    n_pdf = _pdf_pages(data, file.filename or "")
    if n_pdf and not 0 <= page < n_pdf:
        raise HTTPException(400, f"This PDF has {n_pdf} page{'s' if n_pdf != 1 else ''}")
    ctx = None
    if context:
        try:
            ctx = json.loads(context)
        except ValueError:
            ctx = None
    jid = uuid.uuid4().hex[:12]
    user = request.state.user
    try:
        allowance = usage.claim(user, jid)
    except Exception:
        traceback.print_exc()
        raise HTTPException(503, "Could not check your pages right now. Please try again in a moment.")
    if allowance["access"] == "cap":
        raise HTTPException(402, {"code": "page_cap", "renews_at": allowance["renews_at"],
                                  "message": f"You've read all {allowance['page_limit']} pages for this month."})
    (WORK / jid).mkdir()
    JOBS[jid] = {"id": jid, "status": "queued", "name": file.filename, "created": time.time(),
                 "page": page if n_pdf else 0, "pages": n_pdf or 1, "user": user["id"] if user else None,
                 "allowance": allowance}
    opts = {"detector": detector if detector in ("28m", "2m") else "28m",
            "flatten": None if flatten == "auto" else flatten == "on", "strip_pen": strip_pen,
            "page": page if n_pdf else 0, "pdf": bool(n_pdf), "context": ctx}
    cached = _cached_sample_for(data, opts)
    if cached is not None:
        sid, sample_dir = cached
        _serve_cached_sample(jid, sid, sample_dir)
        return {"id": jid, "pages": 1, "page": 0, "allowance": allowance, "cached": True}
    threading.Thread(target=_run, args=(jid, data, file.filename or "", opts), daemon=True).start()
    return {"id": jid, "pages": n_pdf or 1, "page": page if n_pdf else 0, "allowance": allowance}


@app.post("/api/jobs/{jid}/unlock")
def unlock_job(jid: str, request: Request):
    """After a purchase: the preview of this page becomes a full Pro page (counts toward the month's pages)."""
    j = _job(jid, request)
    allowance = usage.unlock(request.state.user, j.get("reread_of") or jid)
    if allowance["access"] == "cap":
        raise HTTPException(402, {"code": "page_cap", "renews_at": allowance["renews_at"],
                                  "message": f"You've read all {allowance['page_limit']} pages for this month."})
    if allowance["access"] != "full":
        raise HTTPException(402, {"code": "subscription_required", "message": "An active MusicScan Pro subscription is required."})
    if j.get("status") != "done":
        raise HTTPException(409, "The page is still being read")
    full_path = WORK / jid / "result.full.json"
    if not full_path.exists():
        raise HTTPException(410, "The full reading is no longer available. Please scan this page again.")
    j["result"] = json.loads(full_path.read_text())
    shutil.copyfile(WORK / jid / "page.full.png", WORK / jid / "page.png")
    j["allowance"] = allowance
    _save_job(j)
    return allowance


@app.post("/api/jobs/{jid}/reread")
async def reread(jid: str, request: Request, quad: str = Form(...), detector: str = Form("28m"), context: str | None = Form(None)):
    """Read a page again from its stored photo, with page corners the user placed (the automatic page finder missed
    the page, or cut a row off). quad: JSON [[x, y] x4] in original.jpg pixels, any order; an empty list reads the
    whole photo without flattening. Returns a new job, like POST /api/jobs."""
    old = _job(jid, request)
    if old.get("allowance", {}).get("access") == "preview":
        raise HTTPException(402, "Unlock this page before adjusting its edges")
    src = WORK / jid / "original.jpg"
    if not src.exists():
        raise HTTPException(404, "The photo of this page is no longer on the server")
    try:
        q = json.loads(quad)
        assert isinstance(q, list) and (not q or (len(q) == 4 and all(len(p) == 2 for p in q)))
        q = [[float(x), float(y)] for x, y in q]
    except (ValueError, AssertionError, TypeError):
        raise HTTPException(400, "quad must be four [x, y] corners")
    ctx = None
    if context:
        try:
            ctx = json.loads(context)
        except ValueError:
            ctx = None
    nid = uuid.uuid4().hex[:12]
    (WORK / nid).mkdir()
    # the same page read again: same owner and allowance, not another page counted
    JOBS[nid] = {"id": nid, "status": "queued", "name": old.get("name"), "created": time.time(), "page": 0, "pages": 1,
                 "user": old.get("user"), "allowance": old.get("allowance"), "reread_of": old.get("reread_of") or jid}
    opts = {"detector": detector if detector in ("28m", "2m") else "28m", "flatten": None, "strip_pen": True,
            "page": 0, "pdf": False, "context": ctx, "lock_page": bool(q),
            "quad": preprocess.order_quad(q) if q else None}
    threading.Thread(target=_run, args=(nid, src.read_bytes(), "original.jpg", opts), daemon=True).start()
    return {"id": nid, "pages": 1, "page": 0, "allowance": old.get("allowance")}


def _job(jid, request: Request | None = None):
    j = JOBS.get(jid)
    if j is None:
        p = WORK / jid / "job.json"
        if not p.exists() or "/" in jid or ".." in jid:
            raise HTTPException(404, "No such job")
        j = JOBS[jid] = json.loads(p.read_text())
    if request is not None and j.get("user"):  # a signed-in user's scans are visible to that user only
        user = getattr(request.state, "user", None)
        if not user or user["id"] != j["user"]:
            raise HTTPException(404, "No such job")
    return j


@app.get("/api/jobs/{jid}")
def get_job(jid: str, request: Request):
    return _job(jid, request)


@app.get("/api/jobs/{jid}/{name}")
def job_file(jid: str, name: str, request: Request):
    job = _job(jid, request)
    if name not in ("page.png", "original.jpg"):
        raise HTTPException(404)
    if name == "original.jpg" and job.get("allowance", {}).get("access") == "preview":
        raise HTTPException(403, "Original page is hidden in preview mode")
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
async def rescan(jid: str, request: Request, measures: str = Form(...), attempt: int = Form(0), file: UploadFile | None = File(None),
                 context: str | None = Form(None)):
    """Re-read the rows holding the selected measures. With a file: read that close-up instead.
    context (JSON, optional): the parts/staves, key, time and clefs in force at the first target bar in the score
    being edited (the editor sends it so the user's own key/time fixes carry over). Without it, it is taken from
    the original reading."""
    j = _job(jid, request)
    if j.get("allowance", {}).get("access") == "preview":
        raise HTTPException(402, "Unlock this page before rescanning bars")
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
    # Serve precomputed single-system rescan for built-in cached samples with $0 GPU usage.
    cached_sid = j.get("cached_sample")
    if file is None and cached_sid and len(systems) == 1:
        cached_rescan = ROOT / "web" / "demo" / cached_sid / f"rescan_{systems[0]}_{attempt % len(RESCAN_WAYS)}.json"
        if cached_rescan.exists():
            out = json.loads(cached_rescan.read_text())
            out["target"] = target
            out["attempt"] = attempt
            out["cached_sample"] = cached_sid
            out["seconds"] = 0.0
            return out
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
    r = _OMR_RESCAN(crop, detector=det) if _OMR_RESCAN is not None else omr.transcribe(crop, detector=det)
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
